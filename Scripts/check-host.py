#!/usr/bin/env python3
"""Accept a packaged adapter through an installed Computer MCP CLI's public MCP surface.

Fixture mode uses real native Codex with a private loopback Responses server.
Full mode additionally requires authenticated model execution. All host instances,
workspaces, runtime homes and failure injection targets are private to this run.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import uuid

MODEL_SOURCE = Path(__file__).resolve().parents[1] / "Tests/Fixtures/NativeCodex/ModelServer.py"
MAX_MESSAGE = 8_388_608


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def executable(value):
    path = Path(value)
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise argparse.ArgumentTypeError("Expected an existing absolute executable file")
    return path.resolve()


def absolute_file(value):
    path = Path(value)
    if not path.is_absolute() or not path.is_file():
        raise argparse.ArgumentTypeError("Expected an existing absolute file")
    return path.resolve()


def timeout_seconds(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Timeout must be an integer") from error
    if not 1 <= number <= 900:
        raise argparse.ArgumentTypeError("Timeout must be between 1 and 900 seconds")
    return number


def parse_arguments(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=executable, help="Installed computer-mcp CLI")
    parser.add_argument("--adapter", required=True, type=executable, help="Adapter from the verified, relocated archive")
    parser.add_argument("--codex", required=True, type=executable, help="User-installed vendor Codex")
    parser.add_argument("--output-directory", required=True, type=Path, help="New private directory in ignored build output")
    parser.add_argument("--mode", choices=("fixture", "full"), default="full")
    parser.add_argument("--auth-file", type=absolute_file, help="Full mode: existing vendor auth.json; copied privately and deleted on exit")
    parser.add_argument("--model", help="Full mode: authenticated model ID")
    parser.add_argument("--timeout-seconds", type=timeout_seconds, default=180)
    options = parser.parse_args(arguments)
    root = options.output_directory
    if not root.is_absolute() or root.exists() or root.is_symlink():
        parser.error("--output-directory must be a new absolute path")
    if options.mode == "full" and (not options.auth_file or not options.model or not options.model.strip()):
        parser.error("Full mode requires --auth-file and --model")
    if options.mode == "fixture" and (options.auth_file or options.model):
        parser.error("Authentication inputs require full mode")
    if options.model and any(c in options.model for c in "\0\r\n"):
        parser.error("Model ID must be a single nonempty line")
    return options


def unwrap(result, indirect=False):
    for _ in range(2 if indirect else 1):
        require(isinstance(result, dict), "Malformed MCP tool result")
        if result.get("isError"):
            raise RuntimeError(json.dumps(result, ensure_ascii=False))
        result = result["structuredContent"]["result"]
    return result


def archive_disposition(result, thread_id):
    if not isinstance(thread_id, str) or not thread_id or any(c.isspace() for c in thread_id):
        return "failed"
    if not result.get("isError"):
        return "archived" if isinstance(result.get("structuredContent", {}).get("result"), dict) else "failed"
    # A missing rollout is only terminal for this exact ID and this exact native error.
    error = result.get("structuredContent", {}).get("error", {})
    detail = error.get("message")
    marker = "no rollout found for thread id " + thread_id
    if isinstance(detail, str) and (detail == marker or detail.endswith(": " + marker)):
        return "already-absent"
    return "failed"


def completed_turn(page, thread_id, turn_id, expected_status):
    require(page["missed_events"] == 0, "Event cursor lost evidence")
    for row in page["events"]:
        payload = row.get("payload", {})
        params = payload.get("params", {})
        if (payload.get("method") == "turn/completed" and params.get("threadId") == thread_id
                and params.get("turn", {}).get("id") == turn_id):
            require(params["turn"]["status"] == expected_status, params["turn"])
            return True
    return False


def command_exit(output):
    match = re.search(r"Process exited with code (-?[0-9]+)", output)
    require(match is not None, "Native command output lacks an exit status")
    return int(match.group(1))


def wait_until(check, timeout, label):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise TimeoutError(label + "; outcome is unknown, mutations must not be replayed")


def exited(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def descendant(pid, ancestor, parent):
    seen = set()
    while pid != ancestor:
        if not isinstance(pid, int) or pid <= 1 or pid in seen or len(seen) >= 32:
            return False
        seen.add(pid)
        pid = parent(pid)
    return bool(seen)


def process_parent(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid="], capture_output=True,
                            text=True, timeout=3, check=False)
    return int(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip().isdigit() else None


class MCPClient:
    def __init__(self, process, evidence, timeout):
        self.process, self.evidence, self.timeout = process, evidence, timeout
        self.sequence = 0
        self.queue = queue.Queue(maxsize=1024)
        self.failure = None
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            while True:
                line = self.process.stdout.readline(MAX_MESSAGE + 1)
                if not line:
                    raise EOFError("Host MCP stdout closed")
                require(len(line.encode()) <= MAX_MESSAGE, "MCP message exceeded acceptance bound")
                self.queue.put_nowait(json.loads(line))
        except Exception as error:
            self.failure = error

    def send(self, method, params, notification=False, timeout=None):
        self.sequence += 1
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            message["id"] = self.sequence
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        if notification:
            return
        deadline = time.monotonic() + (timeout or self.timeout)
        while time.monotonic() < deadline:
            try:
                response = self.queue.get(timeout=min(0.1, max(0.01, deadline - time.monotonic())))
            except queue.Empty:
                if self.failure:
                    raise self.failure
                continue
            if response.get("id") != message["id"]:
                require("method" in response and "id" not in response, "Unexpected MCP response/request")
                continue
            self.evidence.write(json.dumps({"request": message, "response": response}) + "\n")
            self.evidence.flush()
            require(self.evidence.tell() <= 32 * 1024 * 1024, "Protocol evidence exceeded acceptance bound")
            require("error" not in response, response)
            return response["result"]
        raise TimeoutError(method + "; result unknown, no write retry")

    def initialize(self):
        self.send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                "clientInfo": {"name": "codex-host-acceptance", "version": "1"}})
        self.send("notifications/initialized", {}, notification=True)
        catalog, cursor, seen = {}, None, set()
        for _ in range(100):
            page = self.send("tools/list", {"cursor": cursor} if cursor else {})
            for tool in page["tools"]:
                require(tool["name"] not in catalog, "Duplicate catalog tool")
                catalog[tool["name"]] = tool
            cursor = page.get("nextCursor")
            if not cursor:
                return catalog
            require(cursor not in seen, "Cyclic tool catalog")
            seen.add(cursor)
        raise RuntimeError("Unbounded tool catalog")


APP_READ = ["status", "methods.list", "models.list", "skills.list", "apps.list", "events.read",
            "thread.list", "thread.loaded.list", "thread.read", "thread.recent", "goal.get",
            "approvals.list", "requests.list", "handoff.diagnose", "runtimes.history"]
APP_WRITE = ["thread.start", "thread.fork", "thread.reclaim", "thread.release", "turn.start",
             "turn.steer", "turn.interrupt", "goal.set", "goal.clear", "review.start", "methods.call",
             "approvals.respond", "requests.respond", "runtime.stop"]
RISKS = {**{"codex.app." + name: "read-only" for name in APP_READ},
         **{"codex.app." + name: "full-shell" for name in APP_WRITE},
         **{"codex.exec." + name: "read-only" for name in ["list", "events", "result"]},
         **{"codex.exec." + name: "full-shell" for name in ["start", "resume"]},
         "codex.exec.cancel": "destructive", "codex.exec.release": "workspace-write",
         "codex.diagnostics.snapshot": "read-only", "codex.run.list": "read-only",
         "codex.worktree.managed.list": "read-only", "codex.worktree.leases.list": "read-only",
         "codex.worktree.leases.acquire": "workspace-write", "codex.worktree.leases.release": "workspace-write"}


class Host:
    def __init__(self, fixture, indirect=True):
        self.fixture, self.indirect = fixture, indirect
        self.workspace = "primary"
        fixture.generation += 1
        self.log = (fixture.root / f"host-{fixture.generation}.log").open("w")
        self.evidence = (fixture.root / f"protocol-{fixture.generation}.jsonl").open("w")
        self.process = subprocess.Popen([str(fixture.options.host), "serve", "stdio", "--config",
                                         str(fixture.root / "host.toml"), "--database", str(fixture.root / "host.sqlite")],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                        text=True, bufsize=1, env=fixture.environment, cwd=fixture.root)
        fixture.hosts.append(self)
        self.client = MCPClient(self.process, self.evidence, fixture.options.timeout_seconds)
        self.catalog = self.client.initialize()
        require(set(RISKS) <= self.catalog.keys(), {"missing_tools": sorted(set(RISKS) - self.catalog.keys())})
        require(self.catalog["mcp.tools.call"]["inputSchema"]["properties"]["workspace_id"]["type"] == "string",
                "Generic dispatch lacks workspace selection")

    def raw(self, name, arguments=None, timeout=None):
        name = name if name.startswith("codex.") else "codex.app." + name
        arguments = arguments or {}
        require(set(arguments) <= self.catalog[name]["inputSchema"]["properties"].keys(), {"tool": name, "undeclared_inputs": sorted(set(arguments) - self.catalog[name]["inputSchema"]["properties"].keys())})
        if self.indirect:
            params = {"name": "mcp.tools.call", "arguments": {"server": "codex", "tool": name,
                      "workspace_id": self.workspace, "arguments": arguments}}
        else:
            params = {"name": name, "arguments": dict(arguments, workspace_id=self.workspace)}
        result = self.client.send("tools/call", params, timeout=timeout)
        return unwrap(result) if self.indirect else result

    def call(self, name, arguments=None, timeout=None):
        return unwrap(self.raw(name, arguments, timeout))

    def method(self, name, params=None, timeout=None):
        return self.call("methods.call", {"method": name, "params": params or {}}, timeout)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
                raise RuntimeError("Host did not exit after MCP EOF")
        self.client.reader.join(timeout=2)
        self.log.close()
        self.evidence.close()
        require(self.process.returncode == 0, {"host_exit": self.process.returncode})

    def processes(self):
        status = self.call("status")
        require(Path(status["workspace"]).resolve() == (self.fixture.root / self.workspace).resolve(), status)
        pids = [status["process"][key] for key in ("process_id", "supervisor_process_id", "parent_process_id")]
        require(all(isinstance(pid, int) and pid > 1 for pid in pids), status)
        self.fixture.pids.update(pids)
        return pids

    def release(self, thread, goal=False):
        value = self.call("thread.release", {"thread_id": thread})
        require(value["final_classification"] == "released_persisted" and value["externally_claimable"]
                and not value["computer_mcp_writer_ownership_remaining"], value)
        if goal:
            require(value["goal_preservation"] == "persisted-and-unchanged", value)
        return value

    def turn(self, thread, expected="completed", approve=False, **arguments):
        turn = self.call("turn.start", {"thread_id": thread, "prompt": "Run the isolated acceptance response.",
                                       **arguments})["turn"]["id"]
        self.wait_turn(thread, turn, expected, approve)
        return turn

    def wait_turn(self, thread, turn, expected="completed", approve=False):
        cursor, approvals = 0, 0
        def poll():
            nonlocal cursor, approvals
            page = self.call("events.read", {"after_cursor": cursor, "max_results": 100})
            cursor = page["next_cursor"]
            if approve:
                for approval in self.call("approvals.list", {"state": "pending"})["approvals"]:
                    require(approval["thread_id"] == thread, "Unrelated native approval")
                    self.call("approvals.respond", {"approval_id": approval["id"], "response": {"decision": "accept"}})
                    approvals += 1
            return completed_turn(page, thread, turn, expected)
        wait_until(poll, self.fixture.options.timeout_seconds, "Native turn completion")
        if approve:
            require(approvals == 1, f"Expected one native approval, observed {approvals}")

    def exec_result(self, session, expected="completed"):
        def poll():
            states = self.call("codex.exec.list")["sessions"]
            current = next(row for row in states if row["session_id"] == session)
            if current["state"] not in {"completed", "failed", "cancelled"}:
                return None
            value = self.call("codex.exec.result", {"session_id": session})
            require(value["state"] == expected and value["cleanup_confirmed"], value)
            return value
        return wait_until(poll, self.fixture.options.timeout_seconds, "Exec termination and cleanup")


class Fixture:
    def __init__(self, options):
        self.options, self.root = options, options.output_directory.resolve()
        self.root.mkdir(mode=0o700, parents=True)
        self.hosts, self.pids, self.threads, self.steps = [], set(), set(), []
        self.generation = 0
        self.model = None
        self.model_log = None
        self.home = self.root / "codex-home"
        self.home.mkdir(mode=0o700)
        # Private HOME also isolates Git, native skills, hooks and host configuration.
        self.environment = {"HOME": str(self.root), "PATH": str(options.codex.parent) + ":/usr/bin:/bin",
                            "TMPDIR": str(self.root / "tmp"), "GIT_CONFIG_GLOBAL": os.devnull,
                            "GIT_CONFIG_NOSYSTEM": "1"}
        (self.root / "tmp").mkdir(mode=0o700)

    def setup(self):
        for name in ("primary", "other"):
            (self.root / name).mkdir()
            self.git(["init", "--quiet"], name)
            for key, value in (("user.name", "Acceptance"), ("user.email", "acceptance@example.invalid"),
                               ("commit.gpgsign", "false"), ("core.hooksPath", str(self.root / name / ".git/hooks"))):
                self.git(["config", key, value], name)
        wrapper = self.root / "configured-codex"
        wrapper.write_text(f'''#!{sys.executable}
import json, os, sys
keys = ("COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD", "CODEX_THREAD_ID")
assert not any(key in os.environ for key in keys), "Parent authority leaked"
assert os.environ.get("COMPUTER_MCP_FIXTURE_VALUE") == "preserved", "Ordinary environment lost"
with open({str(self.root / 'launches.jsonl')!r}, "a") as receipt:
    receipt.write(json.dumps({{"mode": sys.argv[1], "cwd": os.getcwd(), "argv": sys.argv[1:], "pid": os.getpid()}}) + "\\n")
os.execv({str(self.options.codex)!r}, [{str(self.options.codex)!r}] + sys.argv[1:])
''')
        wrapper.chmod(0o700)
        self.response("initial")
        (self.root / "network-token").write_text(uuid.uuid4().hex)
        self.model_log = (self.root / "model.log").open("w")
        self.model = subprocess.Popen([sys.executable, str(MODEL_SOURCE), str(self.root)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.model_log,
                                      text=True, env=self.environment)
        ready = queue.Queue()
        threading.Thread(target=lambda: ready.put(self.model.stdout.readline(65536)), daemon=True).start()
        self.port = json.loads(ready.get(timeout=10))["port"]
        self.configure()

    def configure(self, sandbox="danger-full-access", approval="never", authenticated=False):
        q = json.dumps
        config = f'''model = {q(self.options.model if authenticated else "acceptance-fixture")}
cli_auth_credentials_store = "file"
approval_policy = {q(approval)}
sandbox_mode = {q(sandbox)}
web_search = "disabled"
'''
        if not authenticated:
            config += f'''model_provider = "fixture"
[model_providers.fixture]
name = "Isolated acceptance"
base_url = "http://127.0.0.1:{self.port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
'''
        config += '[analytics]\nenabled = false\n[otel]\nmetrics_exporter = "none"\n'
        (self.home / "config.toml").write_text(config)
        (self.root / "adapter.json").write_text(json.dumps({
            "enabled": True, "executable": "configured-codex", "app_server_enabled": True,
            "exec_enabled": True, "app_server_request_timeout_seconds": 30,
            "app_server_app_list_timeout_seconds": 120,
        }))
        policies = ", ".join(q(name) + " = " + q(risk) for name, risk in RISKS.items())
        config = f'''schema_version = 1
[runtime]
caller = "local-mcp"
profile = "acceptance"
[[profiles]]
id = "acceptance"
mode = "local-full-access"
confirmation_policy = "never"
full_shell_enabled = true
capabilities = ["mcp.tools.call", "workspace.list"]
workspaces = ["primary", "other"]
allowed_callers = ["local-mcp"]
'''
        for name in ("primary", "other"):
            config += f'''[[workspaces]]
id = {q(name)}
display_name = {q(name)}
path = {q(str(self.root / name))}
'''
        config += f'''[[mcp.servers]]
id = "codex"
transport = "stdio"
command = {q(str(self.options.adapter))}
args = ["--config", {q(str(self.root / 'adapter.json'))}, "--state-directory", {q(str(self.root / 'adapter-state'))}]
exposure = "reexport"
prefix = ""
allowed_tools = {q(list(RISKS))}
host_services = true
tool_risks = {{ {policies} }}
startup_timeout_ms = 10000
request_timeout_ms = {max(130, self.options.timeout_seconds) * 1000}
[mcp.servers.env]
CODEX_HOME = {q(str(self.home))}
PATH = {q(str(self.root) + os.pathsep + self.environment['PATH'])}
CODEX_THREAD_ID = "acceptance-parent-session"
COMPUTER_MCP_FIXTURE_VALUE = "preserved"
'''
        (self.root / "host.toml").write_text(config)

    def git(self, args, workspace="primary"):
        return subprocess.run(["/usr/bin/git", *args], cwd=self.root / workspace, env=self.environment,
                              text=True, capture_output=True, timeout=10, check=True).stdout

    def response(self, phase, command=None, hold=False):
        temporary = self.root / "response.tmp"
        temporary.write_text(json.dumps({"id": phase, "command": command, "hold_after_command": hold}))
        temporary.replace(self.root / "response.json")

    def command_result(self, phase, success=True):
        path = self.root / ("result-" + phase + ".json")
        wait_until(path.exists, 15, "Native command receipt")
        value = json.loads(path.read_text())
        require(value["type"] == "function_call_output", value)
        require((command_exit(value["output"]) == 0) == success, value)

    def thread(self, host, params=None):
        started = host.method("thread/start", params)
        thread = started["thread"]["id"]
        self.threads.add((host.workspace, thread))
        return thread, started

    def record(self, name):
        self.steps.append(name)
        print(json.dumps({"passed": name}), flush=True)

    def catalog_and_diagnostics(self):
        host = Host(self)
        require(not (self.root / "launches.jsonl").exists(), "Discovery started the vendor")
        diagnostic = host.call("codex.diagnostics.snapshot", {"limit": 10})
        require(diagnostic["persistence_available"] and diagnostic["host_diagnostics_available"], diagnostic)
        require(diagnostic["state_storage"]["scope"] == "authorization_subject", diagnostic)
        require(not (self.root / "launches.jsonl").exists(), "Diagnostics started the vendor")
        host.call("codex.run.list")
        host.call("codex.worktree.managed.list")
        host.call("codex.worktree.leases.list")
        lease = host.call("codex.worktree.leases.acquire", {"agent_id": "acceptance"})
        host.call("codex.worktree.leases.release", {"lease_id": lease["id"],
                  "expected_revision": lease["revision"], "reason": "Acceptance complete"})
        require(not (self.root / "launches.jsonl").exists(), "Domain lease operations started the vendor")
        host.close()
        self.record("catalog-diagnostics-domain-leases-lazy-start")

    def directories(self):
        host = Host(self)
        started = time.monotonic()
        skills = host.method("skills/list", {"cwds": [str(self.root / "primary")], "forceReload": False}, timeout=35)
        require(time.monotonic() - started < 30, "skills/list exceeded normal deadline")
        require(len(skills["data"]) == 1 and skills["data"][0]["cwd"] == str(self.root / "primary"), skills)
        started = time.monotonic()
        apps = host.method("app/list", {"limit": 1, "forceRefetch": False}, timeout=125)
        require(time.monotonic() - started < 120 and len(apps["data"]) <= 1, apps)
        host.processes()
        host.close()
        self.record("skills-explicit-directory-and-app-list-deadlines")

    def native_permissions(self):
        for explicit in (False, True):
            self.configure(sandbox="workspace-write" if explicit else "danger-full-access")
            host = Host(self, indirect=explicit)
            thread, started = self.thread(host, {"sandbox": "danger-full-access"} if explicit else {})
            require(started["sandbox"]["type"] == "dangerFullAccess", started)
            phase = "explicit" if explicit else "inherited"
            hook = self.root / "primary/.git/hooks/pre-commit"
            hook.write_text("#!/bin/sh\n/usr/bin/touch .git/hook-ran\n")
            hook.chmod(0o700)
            self.response(phase, f"/usr/bin/printf '{phase}\\n' > {phase}.txt && "
                          f"/usr/bin/git add {phase}.txt && /usr/bin/git commit -m 'Native {phase} acceptance' && "
                          f"/usr/bin/curl --silent --show-error --max-time 3 http://127.0.0.1:{self.port}/probe > network.txt && "
                          "/usr/bin/printf 'outside' > ../outside-workspace.txt")
            host.turn(thread)
            self.command_result(phase)
            require((self.root / "primary/.git/hook-ran").exists(), "Git hook did not execute")
            require(self.git(["log", "-1", "--pretty=%s"]).strip() == f"Native {phase} acceptance", "Wrong Git commit")
            require((self.root / "primary/network.txt").read_text() == (self.root / "network-token").read_text(), "Loopback denied")
            require((self.root / "outside-workspace.txt").read_text() == "outside", "Explicit outside path denied")
            (self.root / "primary/network.txt").unlink()
            require(not self.git(["status", "--porcelain"]), "Native Git worktree not clean")
            host.processes()
            host.release(thread)
            host.close()
        self.configure()
        host = Host(self)
        thread, started = self.thread(host, {"sandbox": "read-only", "approvalPolicy": "never"})
        require(started["sandbox"]["type"] == "readOnly", started)
        self.response("read-only", "/usr/bin/touch native-denied.txt")
        host.turn(thread)
        self.command_result("read-only", success=False)
        require(not (self.root / "primary/native-denied.txt").exists(), "Read-only native request wrote a file")
        host.processes()
        host.release(thread)
        host.close()
        self.record("native-inherited-explicit-full-access-git-hook-loopback-outside-path-and-read-only")

    def handoff(self):
        self.configure()
        for indirect in (False, True):
            thread, goal, processes = None, None, set()
            self.response("handoff-" + str(indirect))
            for generation in range(3):
                host = Host(self, indirect=indirect)
                if thread:
                    host.call("thread.reclaim", {"thread_id": thread})
                else:
                    thread, _ = self.thread(host)
                    goal = host.call("goal.set", {"thread_id": thread, "objective": "Persist the acceptance Goal", "status": "paused"})["goal"]
                    host.turn(thread)
                require(host.call("thread.read", {"thread_id": thread})["thread"]["id"] == thread, "Wrong persisted thread")
                require(host.call("goal.get", {"thread_id": thread})["goal"] == goal, "Goal changed across handoff")
                pids = host.processes()
                require(pids[0] not in processes, "Native generation reused")
                processes.add(pids[0])
                host.release(thread, goal=True)
                host.close()
                wait_until(lambda: all(exited(pid) for pid in pids), 15, "Released process exit")
            history_host = Host(self, indirect=indirect)
            history = history_host.call("runtimes.history")["runtimes"]
            recorded = {row.get("process", {}).get("process_id") for row in history if row.get("process")}
            require(processes <= recorded, "Runtime history lost process receipts")
            require(all(row["state"] == "stopped" for row in history if row.get("process", {}).get("process_id") in processes), history)
            history_host.close()
        self.record("three-connection-thread-goal-handoff-direct-and-generic")

    def sibling_workspace(self):
        self.response("siblings")
        host = Host(self)
        first, _ = self.thread(host)
        host.turn(first)
        first_pid = host.processes()[0]
        host.workspace = "other"
        other, _ = self.thread(host)
        host.turn(other)
        second_pid = host.processes()[0]
        require(first_pid != second_pid, "Workspaces shared a native process")
        host.workspace = "primary"
        host.release(first)
        require(not exited(second_pid), "Release stopped the sibling workspace")
        host.workspace = "other"
        require(host.call("thread.read", {"thread_id": other})["thread"]["id"] == other, "Sibling thread lost")
        host.release(other)
        host.close()
        self.record("workspace-process-isolation-and-sibling-release")

    def recovery(self):
        for crash_adapter in (False, True):
            phase = "crash-adapter" if crash_adapter else "crash-vendor"
            path = self.root / "primary" / (phase + ".txt")
            host = Host(self)
            thread, _ = self.thread(host)
            goal = host.call("goal.set", {"thread_id": thread, "objective": "Preserve unfinished native work", "status": "paused"})["goal"]
            self.response(phase, f"/usr/bin/printf 'once\\n' >> {phase}.txt", hold=True)
            turn = host.call("turn.start", {"thread_id": thread, "prompt": "Run the isolated response."})["turn"]["id"]
            self.command_result(phase)
            require(path.read_text() == "once\n", "Write did not run once")
            pids = host.processes()
            target = pids[2 if crash_adapter else 0]
            require(descendant(target, host.process.pid, process_parent), "Failure target is not owned by this host")
            os.kill(target, signal.SIGKILL)
            if not crash_adapter:
                def retired():
                    state = host.call("status")
                    return state["connection_state"] != "running" and state.get("last_request_failure") and all(exited(pid) for pid in pids[:2])
                wait_until(retired, 15, "Retirement after vendor crash")
            host.close()
            wait_until(lambda: all(exited(pid) for pid in pids), 15, "Crash watchdog cleanup")
            replacement = Host(self)
            replacement.call("thread.reclaim", {"thread_id": thread})
            require(replacement.call("goal.get", {"thread_id": thread})["goal"] == goal, "Crash changed Goal")
            turns = replacement.call("thread.read", {"thread_id": thread, "include_turns": True})["thread"]["turns"]
            recovered = next(row for row in turns if row["id"] == turn)
            require(recovered["status"] not in {"inProgress", "completed"}, recovered)
            require(path.read_text() == "once\n", "Unacknowledged write replayed")
            self.response(phase + "-new", f"/usr/bin/printf 'new\\n' >> {phase}.txt")
            require(replacement.turn(thread) != turn, "Recovery reused turn identity")
            self.command_result(phase + "-new")
            require(path.read_text() == "once\nnew\n", "Recovery duplicated or lost writes")
            replacement.processes()
            replacement.release(thread, goal=True)
            replacement.close()
        self.record("vendor-and-adapter-crash-recovery-without-write-replay")

    def app_lifecycle(self):
        self.configure(sandbox="workspace-write", approval="on-request")
        config = self.root / "adapter.json"
        settings = json.loads(config.read_text())
        settings.update(sandbox="workspace-write", approval_policy="untrusted")
        config.write_text(json.dumps(settings))
        host = Host(self)
        thread = host.call("thread.start")["thread"]["id"]
        self.threads.add(("primary", thread))
        (self.root / "primary/probe.sh").write_text("#!/bin/sh\n/usr/bin/printf 'native-approval-fixture\\n'\n")
        self.response("native-approval", "/bin/sh ./probe.sh")
        host.turn(thread, approve=True)
        self.command_result("native-approval")
        missing = host.raw("requests.respond", {"request_id": "acceptance-no-active-request", "response": {}})
        require(missing.get("isError") and "codex.app.request_unknown" in json.dumps(missing), missing)
        self.response("steer", hold=True)
        active = host.call("turn.start", {"thread_id": thread, "prompt": "Wait for the fixture response."})["turn"]["id"]
        wait_until((self.root / "started-steer").exists, 15, "Active native turn")
        host.call("turn.steer", {"thread_id": thread, "expected_turn_id": active, "prompt": "Continue waiting."})
        host.call("turn.interrupt", {"thread_id": thread, "turn_id": active})
        host.wait_turn(thread, active, "interrupted")
        fork = host.call("thread.fork", {"thread_id": thread})["thread"]["id"]
        require(fork != thread, "Fork returned the parent")
        self.threads.add(("primary", fork))
        self.response("review", hold=True)
        review = host.call("review.start", {"thread_id": thread, "target": {"type": "uncommittedChanges"}, "delivery": "inline"})
        review_thread = review["reviewThreadId"]
        self.threads.add(("primary", review_thread))
        wait_until((self.root / "started-review").exists, 15, "Native review model request")
        require(review["turn"]["status"] == "inProgress", review)
        host.processes()
        # Both threads belong to this one disposable runtime; the force operation is exact.
        released = host.call("thread.release", {"thread_id": thread, "mode": "force-computer-mcp-owned-runtime-only", "interrupt_active_turn": True})
        require(released["externally_claimable"], released)
        host.close()
        self.configure()
        self.record("native-approval-fork-review-steer-interrupt-and-unknown-input")

    def exec_lifecycle(self):
        self.response("exec")
        host = Host(self)
        for native_options in (None, {"sandbox": "workspace-write", "approval_policy": "never"}):
            arguments = {"prompt": "Return the isolated fixture response."}
            if native_options:
                arguments["options"] = native_options
            session = host.call("codex.exec.start", arguments)["session_id"]
            result = host.exec_result(session)
            require("Fixture complete." in json.dumps(result), result)
            upstream = result["upstream_session_id"]
            require(isinstance(upstream, str) and upstream, "Exec lost native thread identity")
            self.threads.add(("primary", upstream))
            page = host.call("codex.exec.events", {"session_id": session, "after_cursor": 0, "max_results": 1000})
            require(page["missed_events"] == 0 and page["events"], page)
            host.call("codex.exec.release", {"session_id": session})
        launches = [json.loads(line) for line in (self.root / "launches.jsonl").read_text().splitlines()]
        exec_launches = [entry for entry in launches if entry["mode"] == "exec"]
        require(len(exec_launches) == 2, exec_launches)
        inherited, explicit = (entry["argv"] for entry in exec_launches)
        require("--sandbox" not in inherited and not any("approval_policy=" in arg for arg in inherited), inherited)
        require("workspace-write" in explicit and 'approval_policy="never"' in explicit, explicit)
        require(all("--ignore-user-config" not in entry["argv"] for entry in exec_launches), exec_launches)
        resumed = host.call("codex.exec.resume", {"upstream_session_id": upstream, "prompt": "Return the fixture response again."})["session_id"]
        result = host.exec_result(resumed)
        require(result["upstream_session_id"] == upstream and "Fixture complete." in json.dumps(result), result)
        host.call("codex.exec.release", {"session_id": resumed})
        self.response("exec-cancel", hold=True)
        session = host.call("codex.exec.start", {"prompt": "Wait for the isolated response."})["session_id"]
        wait_until((self.root / "started-exec-cancel").exists, 15, "Running Exec model request")
        host.call("codex.exec.cancel", {"session_id": session})
        result = host.exec_result(session, "cancelled")
        if result.get("upstream_session_id"):
            self.threads.add(("primary", result["upstream_session_id"]))
        events = host.call("codex.exec.events", {"session_id": session, "after_cursor": 0, "max_results": 1000})
        require(events["missed_events"] == 0 and any(row["kind"] == "session.cancelled" for row in events["events"]), events)
        host.call("codex.exec.release", {"session_id": session})
        require(host.call("codex.exec.list")["sessions"] == [], "Released Exec results retained")
        host.close()
        self.response("cleanup")
        self.record("exec-defaults-overrides-events-result-resume-cancel-release")

    def host_callbacks(self):
        source = MODEL_SOURCE.with_name("HostToolVendor.py")
        vendor = self.root / "host-tool-vendor"
        vendor.write_text("#!" + sys.executable + "\n" + source.read_text().split("\n", 1)[1])
        vendor.chmod(0o700)
        sequence = 900

        def callback(name, arguments, success=True, request_error=None):
            nonlocal sequence
            sequence += 1
            request = {"id": sequence, "method": "item/tool/call", "params": {
                "namespace": "computer-mcp", "tool": name, "arguments": arguments,
                "callId": f"callback-{sequence}", "threadId": "callback-thread", "turnId": "callback-turn"}}
            temporary = self.home / "queued.tmp"
            temporary.write_text(json.dumps(request))
            temporary.replace(self.home / f"queued-{sequence}.json")
            response = self.home / f"callback-{sequence}.json"
            wait_until(response.exists, 15, "Native host callback")
            value = json.loads(response.read_text())
            if request_error:
                require(value.get("error") == request_error, value)
                return value
            require(value.get("result", {}).get("success") is success, value)
            if not success:
                return value
            text = value["result"]["contentItems"][0]["text"]
            return unwrap(json.loads(text))

        for confirmation in ("never", "all-writes"):
            self.configure()
            config = self.root / "adapter.json"
            settings = json.loads(config.read_text())
            settings["executable"] = str(vendor)
            config.write_text(json.dumps(settings))
            host_config = self.root / "host.toml"
            text = host_config.read_text().replace('confirmation_policy = "never"',
                                                   'confirmation_policy = "' + confirmation + '"')
            text = text.replace('capabilities = ["mcp.tools.call", "workspace.list"]',
                                'capabilities = ["mcp.tools.call", "workspace.list", "policy.probe", '
                                '"operations.prepare", "operations.commit", "file.read", "file.write", "git.add", "git.commit"]')
            text += '\n[[cli.commands]]\nid = "git"\nexecutable = "/usr/bin/git"\n'
            text += '\n[builtin]\nenabled = ["file.read", "file.write", "git.add", "git.commit"]\n'
            host_config.write_text(text)
            host = Host(self)
            host.call("thread.loaded.list")
            receipt = json.loads((self.home / "vendor.json").read_text())
            require(not receipt["inherited_host_env"] and not receipt["inherited_host_socket"], receipt)
            self.pids.add(receipt["pid"])
            callback("file.read", {"workspace_id": "other", "path": "product.txt"}, success=False)
            callback("codex.app.status", {}, request_error={"code": -32001,
                     "message": "This App Server request is not part of the supported coding contract."})
            if confirmation == "never":
                (self.root / "primary/product.txt").write_text("governed-native\n")
                index = self.root / "primary/.git/index"
                before = index.read_bytes()
                staged = self.git(["diff", "--cached", "--name-only"])
                callback("git.add", {"paths": ["product.txt"], "dry_run": True})
                require(index.read_bytes() == before and self.git(["diff", "--cached", "--name-only"]) == staged,
                        "Native dry-run callback changed the index")
                require(host.call("approvals.list", {"state": "pending"})["approvals"] == [],
                        "Host dry-run created native approval")
                (self.root / "primary/product.txt").unlink()
                # Keep all acceptance artifacts out of this exact Git workflow's status.
                (self.root / "primary/.git/info/exclude").write_text("*\n!product.txt\n")
                hook = self.root / "primary/.git/hooks/pre-commit"
                hook.write_text("#!/bin/sh\n/usr/bin/touch .git/callback-hook-ran\n")
                hook.chmod(0o700)
                steps = [("file.write", {"path": "product.txt", "content": "governed-native\n"}),
                         ("git.add", {"paths": ["product.txt"]}),
                         ("git.commit", {"message": "Governed native callback acceptance"})]
                for tool, arguments in steps:
                    ticket = callback("operations.prepare", {"tool": tool, "arguments": arguments})["ticket_id"]
                    if tool == "file.write":
                        require(not (self.root / "primary/product.txt").exists(), "Prepare executed the write")
                    elif tool == "git.add":
                        require(not self.git(["diff", "--cached", "--name-only"]), "Prepare staged files")
                    else:
                        require(not (self.root / "primary/.git/callback-hook-ran").exists(), "Prepare committed")
                    commit = {"tool": tool, "arguments": arguments, "ticket_id": ticket}
                    callback("operations.commit", dict(commit, ticket_id="unrelated-ticket"), success=False)
                    callback("operations.commit", commit)
                    callback("operations.commit", commit, success=False)
                require((self.root / "primary/.git/callback-hook-ran").exists(), "Callback Git hook did not run")
                require(self.git(["show", "HEAD:product.txt"]) == "governed-native\n", "Callback commit content differs")
                require(not self.git(["status", "--porcelain"]), "Callback worktree is not clean")
            else:
                arguments = {"path": "pending.txt", "content": "must require local approval"}
                prepared = callback("operations.prepare", {"tool": "file.write", "arguments": arguments})
                require("pending_approval" in json.dumps(prepared), prepared)
                callback("operations.commit", {"tool": "file.write", "arguments": arguments,
                                                "ticket_id": prepared["ticket_id"]}, success=False)
                require(not (self.root / "primary/pending.txt").exists(), "Pending host ticket was consumed")
            host.processes()
            host.close()
        self.configure()
        self.record("native-host-callback-scope-dry-run-exact-tickets-hooked-git-and-pending-approval")

    def authenticated(self):
        with self.options.auth_file.open("rb") as source:
            auth = source.read(1_048_577)
        require(0 < len(auth) <= 1_048_576, "Vendor authentication file exceeds bound")
        destination = self.home / "auth.json"
        with open(destination, "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as handle:
            handle.write(auth.decode())
        self.configure(sandbox="read-only", authenticated=True)
        host = Host(self)
        # Every upstream failure remains a failure, including directory challenges.
        host.call("models.list")
        host.method("account/usage/read")
        host.method("experimentalFeature/list", {})
        thread, _ = self.thread(host)
        marker = "CMCP_AUTHENTICATED_APP_OK"
        turn = host.call("turn.start", {"thread_id": thread, "prompt": f"Reply with exactly {marker}. Do not call tools or modify files."})["turn"]["id"]
        host.wait_turn(thread, turn)
        history = host.call("thread.read", {"thread_id": thread, "include_turns": True})
        turns = history["thread"]["turns"]
        current = next(value for value in turns if value["id"] == turn)
        require(any(item.get("type") == "agentMessage" and marker in item.get("text", "") for item in current["items"]),
                "Authenticated App Server did not return the marker")
        host.processes()
        host.release(thread)
        for resume in (False, True):
            marker = "CMCP_AUTHENTICATED_EXEC_RESUME_OK" if resume else "CMCP_AUTHENTICATED_EXEC_OK"
            arguments = {"prompt": f"Reply with exactly {marker}. Do not call tools or modify files."}
            if resume:
                arguments["upstream_session_id"] = upstream
            session = host.call("codex.exec.resume" if resume else "codex.exec.start", arguments)["session_id"]
            result = host.exec_result(session)
            require(marker in (result.get("final_message") or ""), "Authenticated Exec did not return the marker")
            upstream = result["upstream_session_id"]
            self.threads.add(("primary", upstream))
            host.call("codex.exec.release", {"session_id": session})
        self.record("authenticated-model-app-exec-resume")
        host.close()
        host = Host(self)
        host.method("app/list", {"forceRefetch": False, "limit": 1}, timeout=125)
        host.processes()
        self.record("authenticated-directories")
        host.close()
        destination.unlink()
        self.configure()

    def archive_threads(self):
        self.response("archive")
        if not self.threads:
            return
        host = Host(self)
        for workspace, thread in sorted(self.threads):
            host.workspace = workspace
            result = host.raw("methods.call", {"method": "thread/archive", "params": {"threadId": thread}})
            disposition = archive_disposition(result, thread)
            require(disposition != "failed", {"thread": thread, "archive_result": result})
        host.processes()
        host.close()
        self.record("exact-workspace-thread-archive-cleanup")

    def cleanup(self):
        errors = []
        for host in reversed(self.hosts):
            try:
                if not host.log.closed:
                    host.close()
            except Exception as error:
                errors.append(f"Host cleanup: {error}")
        if self.model:
            try:
                self.model.stdin.close()
            except Exception as error:
                errors.append(f"Model stdin cleanup: {error}")
            try:
                try:
                    self.model.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.model.kill()
                    self.model.wait(timeout=5)
                    errors.append("Model fixture required forced exit")
                if self.model.returncode != 0:
                    errors.append(f"Model fixture exit: {self.model.returncode}")
            except Exception as error:
                errors.append(f"Model fixture cleanup: {error}")
        try:
            if self.model_log:
                self.model_log.close()
        except Exception as error:
            errors.append(f"Model log cleanup: {error}")
        try:
            launches = self.root / "launches.jsonl"
            if launches.exists():
                entries = [json.loads(line) for line in launches.read_text().splitlines()]
                self.pids.update(entry["pid"] for entry in entries)
                roots = {str((self.root / name).resolve()) for name in ("primary", "other")}
                if not all(str(Path(entry["cwd"]).resolve()) in roots for entry in entries):
                    errors.append("Vendor launched outside selected workspaces")
        except Exception as error:
            errors.append(f"Launch receipts: {error}")
        try:
            wait_until(lambda: all(exited(pid) for pid in self.pids), 15, "All receipted native/adapter processes exited")
        except Exception as error:
            errors.append(str(error))
        return errors


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while data := source.read(1024 * 1024):
            value.update(data)
    return value.hexdigest()


def run(options):
    fixture = Fixture(options)
    report = {"schema_version": 1, "mode": options.mode, "passed": False,
              "authenticated_model_verified": False, "steps": fixture.steps,
              "binaries": {key: {"path": str(getattr(options, key)), "sha256": digest(getattr(options, key))}
                           for key in ("host", "adapter", "codex")},
              "fixture_sha256": {source.name: digest(source) for source in
                                  (MODEL_SOURCE, MODEL_SOURCE.with_name("HostToolVendor.py"))}}
    try:
        fixture.setup()
        for key in ("host", "adapter", "codex"):
            result = subprocess.run([str(getattr(options, key)), "--version"], text=True, capture_output=True,
                                    timeout=10, check=True, env=fixture.environment)
            report["binaries"][key]["version"] = result.stdout.strip()
        fixture.catalog_and_diagnostics()
        fixture.directories()
        fixture.native_permissions()
        fixture.handoff()
        fixture.sibling_workspace()
        fixture.recovery()
        fixture.app_lifecycle()
        fixture.exec_lifecycle()
        fixture.host_callbacks()
        if options.mode == "full":
            fixture.authenticated()
            report["authenticated_model_verified"] = True
        fixture.archive_threads()
        report["passed"] = True
    except Exception as error:
        report["failure"] = str(error)
    finally:
        report["cleanup_errors"] = []
        try:
            (fixture.home / "auth.json").unlink(missing_ok=True)
        except Exception as error:
            report["cleanup_errors"].append(f"Credential cleanup: {error}")
        report["authenticated_model_verified"] = "authenticated-model-app-exec-resume" in fixture.steps
        try:
            report["cleanup_errors"].extend(fixture.cleanup())
        except Exception as error:
            report["cleanup_errors"].append(f"Fixture cleanup: {error}")
        try:
            (fixture.home / "auth.json").unlink(missing_ok=True)
        except Exception as error:
            report["cleanup_errors"].append(f"Credential cleanup: {error}")
        try:
            report["binary_digests_unchanged"] = all(digest(getattr(options, key)) == value["sha256"]
                                                    for key, value in report["binaries"].items())
        except Exception as error:
            report["binary_digests_unchanged"] = False
            report["cleanup_errors"].append(f"Binary digest verification: {error}")
        report["passed"] = report["passed"] and not report["cleanup_errors"] and report["binary_digests_unchanged"]
        (fixture.root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "mode": options.mode,
                      "authenticated_model_verified": report["authenticated_model_verified"],
                      "report": str(fixture.root / "report.json"),
                      "failure": report.get("failure"), "cleanup_errors": report["cleanup_errors"]}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(run(parse_arguments()))
