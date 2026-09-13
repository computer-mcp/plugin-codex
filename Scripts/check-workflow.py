#!/usr/bin/env python3
"""Isolated standard-MCP / installed-Codex workflow check with a loopback model fixture.

This does not validate a real model or user authentication. No inherited credentials,
existing threads, production host, dependency installation, or public service is used.
"""

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import uuid


class ModelFixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), ModelHandler)
        self.block_next = False
        self.block_started = threading.Event()
        self.finish = threading.Event()
        self.requests = 0
        self.tools = []


class ModelHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 4_194_304 or self.path != "/v1/responses":
            self.send_error(400)
            return
        payload = json.loads(self.rfile.read(length))
        self.server.tools = payload.get("tools", [])
        self.server.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        response_id = "resp_" + uuid.uuid4().hex
        item = {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
                "status": "completed", "content": [{"type": "output_text", "text": "Fixture complete.", "annotations": []}]}
        if self.server.requests == 1:
            names = [tool.get("name", tool.get("function", {}).get("name")) for tool in self.server.tools]
            if "exec_command" not in names:
                raise RuntimeError("Installed Codex does not expose exec_command to this fixture provider")
            item = {"id": "fc_" + uuid.uuid4().hex, "type": "function_call", "name": "exec_command",
                    "call_id": "call_" + uuid.uuid4().hex,
                    "arguments": json.dumps({"cmd": "/bin/sh ./probe.sh", "yield_time_ms": 1000, "max_output_tokens": 1000})}
        response = {"id": response_id, "object": "response", "created_at": int(time.time()),
                    "model": "workflow-fixture", "status": "completed", "output": [item],
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
        try:
            self.event("response.created", {"response": dict(response, status="in_progress", output=[])})
            if self.server.block_next:
                self.server.block_started.set()
                while not self.server.finish.wait(0.1):
                    self.wfile.write(b": fixture waiting\n\n")
                    self.wfile.flush()
                return
            self.event("response.output_item.added", {"output_index": 0, "item": item})
            if item["type"] == "message":
                self.event("response.output_text.delta", {"item_id": item["id"], "output_index": 0, "content_index": 0, "delta": "Fixture complete."})
            self.event("response.output_item.done", {"output_index": 0, "item": item})
            self.event("response.completed", {"response": response})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, kind, fields):
        data = json.dumps(dict(fields, type=kind)).encode()
        self.wfile.write(b"event: " + kind.encode() + b"\ndata: " + data + b"\n\n")
        self.wfile.flush()


class MCPClient:
    def __init__(self, process, tool_prefix=""):
        self.process = process
        self.tool_prefix = tool_prefix
        self.messages = queue.Queue(maxsize=1024)
        self.sequence = 0
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            for line in self.process.stdout:
                if len(line) > 8_388_608:
                    raise RuntimeError("MCP message exceeds fixture bound")
                self.messages.put_nowait(json.loads(line))
        except Exception as error:
            self.messages.put_nowait(error)
        finally:
            self.messages.put_nowait(EOFError("MCP stdout closed"))

    def send(self, message):
        self.process.stdin.write(json.dumps(dict(message, jsonrpc="2.0")) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError(message["error"])
            return message["result"]
        raise TimeoutError(method)

    def call(self, suffix, **arguments):
        result = self.request("tools/call", {"name": self.tool_prefix + "codex.app." + suffix, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(f"{suffix}: {result['content']}")
        return result["structuredContent"]["result"]

def verify_owned_stop(status):
    assert status["runtime_state"] == "stopped", status
    snapshot = status["process"]
    assert snapshot["state"] == "stopped", snapshot
    for key in ["process_id", "supervisor_process_id"]:
        pid = snapshot[key]
        assert isinstance(pid, int) and pid > 1, snapshot
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise AssertionError(f"Receipted {key} {pid} is still alive")
    return snapshot


def run(adapter, codex, gateway=None, database=None, control_socket=None, registered_workspace=None):
    root = Path(tempfile.mkdtemp(prefix="codex-workflow-")).resolve()
    state, workspace = root / "state", registered_workspace or root / "workspace"
    state.mkdir(mode=0o700)
    if registered_workspace is None:
        workspace.mkdir(mode=0o700)
    probe = workspace / "probe.sh"
    with probe.open("x") as handle:
        handle.write("#!/bin/sh\n/usr/bin/printf 'native-approval-fixture\\n'\n")
    model = ModelFixture()
    worker = threading.Thread(target=model.serve_forever, daemon=True)
    worker.start()
    config = f'''model = "workflow-fixture"
model_provider = "workflow_fixture"
cli_auth_credentials_store = "file"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
web_search = "disabled"
[model_providers.workflow_fixture]
name = "Isolated workflow fixture"
base_url = "http://127.0.0.1:{model.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[analytics]
enabled = false
[otel]
metrics_exporter = "none"
'''
    (state / "config.toml").write_text(config)
    context = {"formatVersion": 1, "runtimeID": str(uuid.uuid4()), "caller": "local-mcp",
               "profileID": "local-admin", "readOnly": False,
               "workspace": {"id": "workflow-fixture", "rootPath": str(workspace)}}
    environment = {"PATH": "/usr/bin:/bin", "CODEX_HOME": str(state),
                   "COMPUTER_MCP_HOST_CONTEXT": json.dumps(context)}
    adapter_config = root / "adapter.json"
    adapter_config.write_text(json.dumps({
        "enabled": True, "executable": str(codex), "app_server_enabled": True,
        "exec_enabled": False, "mcp_enabled": False, "sandbox": "workspace-write",
        "approval_policy": "untrusted", "app_server_auto_approve_workspace_writes": False,
    }))
    adapter_arguments = ["--config", str(adapter_config), "--state-directory", str(root / "adapter-state")]
    launch_arguments = [str(adapter), *adapter_arguments]
    if gateway:
        # The actual Gateway supplies provenance; do not inject the adapter's fixture context.
        environment.pop("COMPUTER_MCP_HOST_CONTEXT")
        manifest = (root if database else workspace) / "gateway.toml"
        manifest.write_text('schema_version = 1\n[runtime]\ncaller = "local-cli"\nprofile = "local-admin"\n'
                            '[policy]\nshell_enabled = false\n[[mcp.servers]]\nid = "adapter"\ntransport = "stdio"\n'
                            'command = ' + json.dumps(str(adapter)) + '\nargs = ' + json.dumps(launch_arguments[1:]) + '\n'
                            'allow_any_tool = true\nexposure = "reexport"\nprefix = "adapter"\n'
                            'startup_timeout_ms = 10000\nrequest_timeout_ms = 40000\n')
        launch_arguments = [str(gateway), "serve", "stdio", "--config", str(manifest)]
        if database:
            # This mode is for the fresh isolated control-plane fixture created by the host tests.
            # The package is already installed; startup settings still go through the owner CLI.
            manifest.write_text('schema_version = 1\n[runtime]\ncaller = "local-cli"\nprofile = "local-admin"\n'
                                '[policy]\nshell_enabled = false\n')
            shown = subprocess.run([str(gateway), "plugins", "show", "codex", "--control-socket", str(control_socket)],
                                   env=environment, capture_output=True, text=True, timeout=15, check=True)
            snapshot = json.loads(shown.stdout)
            assert len(snapshot["state"]["installations"]) == 1, "Expected one isolated Codex installation"
            settings = {"enabled": True, "mcp": {"app-server": {"prefix": "adapter", "exposure": "reexport",
                        "allowAnyTool": True, "args": adapter_arguments}}}
            settings_path = root / "plugin-settings.json"
            settings_path.write_text(json.dumps(settings))
            subprocess.run([str(gateway), "plugins", "configure", "codex", "--settings-file", str(settings_path),
                            "--control-socket", str(control_socket), "--expected-revision", str(snapshot["state"]["revision"])],
                           env=environment, capture_output=True, text=True, timeout=15, check=True)
            launch_arguments += ["--database", str(database)]
    process = None
    confirmed = False
    stderr_path = root / "adapter-stderr.log"
    receipt = {"model_backend": "loopback-fixture", "real_model_verified": False,
               "production_host_used": False, "inherited_credentials": False,
               "northbound": "installed-plugin-gateway" if database else ("isolated-gateway" if gateway else "direct-standard-mcp"), "steps": []}
    receipt["codex_version"] = subprocess.run([str(codex), "--version"], env={"PATH": "/usr/bin:/bin"},
                                              capture_output=True, text=True, timeout=5, check=True).stdout.strip()
    receipt["adapter_sha256"] = hashlib.sha256(adapter.read_bytes()).hexdigest()
    try:
        with stderr_path.open("w") as stderr:
            process = subprocess.Popen(launch_arguments,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                       text=True, cwd=workspace, env=environment)
            client = MCPClient(process, tool_prefix="adapter." if gateway else "")
            client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                           "clientInfo": {"name": "workflow-check", "version": "1"}})
            client.send({"method": "notifications/initialized", "params": {}})
            catalog = client.request("tools/list", {})["tools"]
            receipt["tool_count"] = len([tool for tool in catalog if tool["name"].startswith(client.tool_prefix + "codex.app.")])
            names = {tool["name"] for tool in catalog}
            assert len(names) == len(catalog), "Duplicate tool names"
            required = {"thread.start", "thread.list", "thread.read", "thread.loaded.list", "thread.fork",
                        "thread.release", "thread.reclaim", "goal.set", "goal.get", "goal.clear", "turn.start",
                        "turn.steer", "events.read", "approvals.list", "approvals.respond", "runtime.stop"}
            assert {client.tool_prefix + "codex.app." + name for name in required} <= names
            diagnostic_result = client.request("tools/call", {
                "name": client.tool_prefix + "codex.diagnostics.snapshot", "arguments": {"limit": 10}})
            assert diagnostic_result.get("isError") is False, diagnostic_result
            diagnostic = diagnostic_result["structuredContent"]["result"]
            assert json.loads(diagnostic_result["content"][0]["text"]) == diagnostic
            assert diagnostic["persistence_available"] is True, diagnostic
            assert diagnostic["host_diagnostics_available"] is False, diagnostic
            assert diagnostic["recent_tool_audits"] is None, diagnostic
            assert diagnostic["summary"]["effective_elevation_grant_count"] is None, diagnostic
            assert diagnostic["elevation"]["effective_next_eligible_start"] is None, diagnostic
            receipt["steps"].append("diagnostics→adapter persistence→host data explicitly unavailable")
            assert client.call("thread.list")["data"] == []
            started = client.call("thread.start")
            thread_id = started["thread"]["id"]
            assert thread_id in client.call("thread.loaded.list")["data"]
            receipt["steps"].append("thread/list→start→loaded/list")
            turn = client.call("turn.start", thread_id=thread_id, prompt="Return the fixture response.")
            turn_id = turn["turn"]["id"]
            cursor = 0
            deadline = time.monotonic() + 30
            completed = None
            approved = 0
            command = None
            while time.monotonic() < deadline and completed is None:
                page = client.call("events.read", after_cursor=cursor)
                cursor = page["next_cursor"]
                assert page["missed_events"] == 0, page
                for row in page["events"]:
                    if row["kind"] != "notification":
                        continue
                    event = row["payload"]
                    if event["method"] == "turn/completed" and event["params"]["turn"]["id"] == turn_id:
                        completed = event["params"]["turn"]
                    if event["method"] == "item/completed" and event["params"].get("item", {}).get("type") == "commandExecution":
                        command = event["params"]["item"]
                for approval in client.call("approvals.list", state="pending")["approvals"]:
                    assert approval["kind"] == "command_execution", approval
                    assert Path(approval["workspace_path"]).resolve() == workspace, approval
                    assert approval["thread_id"] == thread_id, approval
                    client.call("approvals.respond", approval_id=approval["id"], decision="approve_once")
                    approved += 1
                if completed is None:
                    time.sleep(0.05)
            assert completed and completed["status"] == "completed", completed
            assert approved == 1, f"Expected one native approval; observed {approved}"
            assert command and command["exitCode"] == 0 and "native-approval-fixture" in command["aggregatedOutput"], command
            receipt["steps"].append("turn/start→native command approval→harmless command→events→completed")
            receipt["native_approvals"] = approved
            client.call("goal.set", thread_id=thread_id, objective="Isolated adapter workflow check", status="paused")
            goal = client.call("goal.get", thread_id=thread_id)
            assert goal["goal"]["status"] == "paused", goal
            receipt["steps"].append("goal/set→get")
            read = client.call("thread.read", thread_id=thread_id)
            assert read["thread"]["id"] == thread_id
            fork = client.call("thread.fork", thread_id=thread_id)
            fork_id = fork["thread"]["id"]
            assert fork_id != thread_id
            receipt["steps"].append("thread/fork")
            try:
                released = client.call("thread.release", thread_id=thread_id)
                assert released["externally_claimable"] is True, released
                receipt["multi_thread_graceful_release"] = "released"
            except RuntimeError as error:
                if "codex.app.handoff_still_loaded:" not in str(error):
                    raise
                assert fork_id in client.call("thread.loaded.list")["data"]
                assert client.call("status")["process"]["state"] == "running"
                receipt["multi_thread_graceful_release"] = "refused-still-loaded-sibling-preserved"
            # Both threads and this runtime belong exclusively to this disposable check.
            forced = client.call("thread.release", thread_id=fork_id,
                                 mode="force-computer-mcp-owned-runtime-only")
            assert forced["externally_claimable"] is True, forced
            stopped = client.call("status")
            receipt["first_owned_stop"] = verify_owned_stop(stopped)
            process.stdin.close()
            assert process.wait(timeout=10) == 0
            client.reader.join(timeout=2)
            receipt["steps"].append("multi-thread release boundary→explicit fixture-owned runtime stop→MCP EOF")
            process = subprocess.Popen(launch_arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=stderr, text=True, cwd=workspace, env=environment)
            client = MCPClient(process, tool_prefix="adapter." if gateway else "")
            client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                           "clientInfo": {"name": "workflow-check", "version": "1"}})
            client.send({"method": "notifications/initialized", "params": {}})
            assert client.call("thread.loaded.list")["data"] == []
            client.call("thread.reclaim", thread_id=thread_id)
            assert client.call("goal.get", thread_id=thread_id)["goal"] == goal["goal"]
            client.call("goal.clear", thread_id=thread_id)
            receipt["steps"].append("new adapter connection→reclaim→persisted Goal→clear")
            model.block_next = True
            active = client.call("turn.start", thread_id=thread_id, prompt="Hold this fixture response until interrupted.")
            assert model.block_started.wait(10), "Fixture model request did not start"
            client.call("turn.steer", thread_id=thread_id, expected_turn_id=active["turn"]["id"], prompt="Keep waiting for interruption.")
            released = client.call("thread.release", thread_id=thread_id, interrupt_active_turn=True)
            assert released["externally_claimable"] is True, released
            receipt["steps"].append("active turn→steer→reviewed interrupt/release→owned runtime stop")
            stopped = client.call("runtime.stop")
            receipt["final_owned_stop"] = verify_owned_stop(stopped)
            confirmed = True
            process.stdin.close()
            assert process.wait(timeout=10) == 0
            client.reader.join(timeout=2)
            receipt["steps"].append("owned process exit→MCP EOF")
            receipt["model_requests"] = model.requests
            receipt["native_tools"] = [tool.get("name", tool.get("function", {}).get("name")) for tool in model.tools]
            receipt["adapter_exit_code"] = process.returncode
    except Exception as error:
        raise RuntimeError(f"Workflow check failed; isolated state retained at {root}: {error}") from error
    finally:
        model.finish.set()
        model.shutdown()
        model.server_close()
        worker.join(timeout=2)
        if process and process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if confirmed and process and process.returncode == 0:
            if registered_workspace:
                probe.unlink()
            shutil.rmtree(root)
            receipt["private_state_removed"] = True
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--gateway", type=Path, help="Optional existing Computer MCP executable; starts only an isolated stdio Gateway")
    parser.add_argument("--database", type=Path, help="Fresh isolated host-test database containing an installed Codex plugin")
    parser.add_argument("--control-socket", type=Path, help="Owner socket of that isolated host-test instance")
    parser.add_argument("--workspace", type=Path, help="Existing disposable workspace registered in that test database")
    options = parser.parse_args()
    fixture_options = [options.database, options.control_socket, options.workspace]
    if any(fixture_options) and (not all(fixture_options) or not options.gateway):
        parser.error("Installed-plugin checks require --gateway, --database, --control-socket and --workspace together")
    for path in filter(None, fixture_options):
        if not path.is_absolute() or not path.exists():
            parser.error("Fixture paths must be absolute and already exist")
    for executable in [options.adapter, options.codex] + ([options.gateway] if options.gateway else []):
        if not executable.is_absolute() or not os.access(executable, os.X_OK):
            parser.error("Both executables must be existing absolute executable paths")
    print(json.dumps(run(options.adapter, options.codex, options.gateway, options.database, options.control_socket, options.workspace), indent=2))
