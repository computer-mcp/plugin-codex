#!/usr/bin/env python3
"""Exercise a linked adapter and real Codex protocol without model authentication."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import uuid


repository = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("workflow_check", repository / "Scripts/check-workflow.py")
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class ProcessObservation:
    """Retain the native child identity before asking its owner to stop it."""

    def __init__(self, pid):
        self.pid = pid
        self.handle = None
        if os.name == "nt":
            from ctypes import wintypes
            self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            self.kernel.OpenProcess.restype = wintypes.HANDLE
            self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            self.kernel.WaitForSingleObject.restype = wintypes.DWORD
            self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            self.kernel.CloseHandle.restype = wintypes.BOOL
            self.handle = self.kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
            if not self.handle:
                raise ctypes.WinError(ctypes.get_last_error())

    def require_exited(self):
        if self.handle:
            assert self.kernel.WaitForSingleObject(self.handle, 0) == 0, "Owned child has not exited"
        else:
            try:
                os.kill(self.pid, 0)
            except ProcessLookupError:
                return
            raise AssertionError("Owned child has not exited")

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def remove_private_state(root):
    """Git marks immutable object files read-only on Windows, even in a private home."""
    repaired = 0

    def remove_read_only(function, path, failure):
        nonlocal repaired
        error = failure[1]
        mode = os.lstat(path).st_mode
        if (not isinstance(error, PermissionError) or function is not os.unlink
                or not stat.S_ISREG(mode) or mode & stat.S_IWRITE):
            raise error
        os.chmod(path, mode | stat.S_IWRITE)
        function(path)
        repaired += 1

    shutil.rmtree(root, onerror=remove_read_only)
    return repaired


def run(adapter, codex, evidence_directory=None):
    if evidence_directory is not None:
        evidence_directory.mkdir(parents=True, exist_ok=False)
    root = Path(tempfile.mkdtemp(prefix="native-adapter-汉字-")).resolve()
    workspace = root / "workspace"
    state = root / "codex"
    home = root / "home"
    for directory in [workspace, state, home, home / "AppData/Roaming", home / "AppData/Local"]:
        directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    # Only system/toolchain lookup inputs are inherited; credentials and user homes are not.
    environment = {"PATH": os.environ.get("PATH", ""), "HOME": str(home),
                   "USERPROFILE": str(home), "APPDATA": str(home / "AppData/Roaming"),
                   "LOCALAPPDATA": str(home / "AppData/Local"), "CODEX_HOME": str(state),
                   "TEMP": str(root), "TMP": str(root)}
    for key in ["SystemRoot", "WINDIR", "COMSPEC"]:
        if key in os.environ:
            environment[key] = os.environ[key]
    (state / "config.toml").write_text('cli_auth_credentials_store = "file"\n', encoding="utf-8")
    context = {"formatVersion": 1, "runtimeID": str(uuid.uuid4()), "caller": "local-mcp",
               "profileID": "local-admin", "principalID": "native-protocol-check",
               "workspace": {"id": "native-protocol-check", "rootPath": str(workspace)}}
    environment["COMPUTER_MCP_HOST_CONTEXT"] = json.dumps(context)
    config = root / "adapter.json"
    config.write_text(json.dumps({"enabled": True, "executable": str(codex),
                                  "app_server_enabled": True, "exec_enabled": True,
                                  "sandbox": "read-only", "approval_policy": "untrusted"}), encoding="utf-8")
    arguments = [str(adapter), "--config", str(config), "--state-directory", str(root / "adapter-state")]
    receipt = {"evidence_class": "native-standard-mcp-protocol", "real_model_verified": False,
               "model_turns_started": 0, "production_host_used": False, "inherited_credentials": False,
               "runtime_environment": "selected-toolchain", "clean_machine_relocation_verified": False,
               "adapter_sha256": hashlib.sha256(adapter.read_bytes()).hexdigest(),
               "codex_sha256": hashlib.sha256(codex.read_bytes()).hexdigest(), "connections": []}
    process = None
    observations = []
    confirmed = False
    phase = "executable versions"
    try:
        for executable, key in [(adapter, "adapter_version"), (codex, "codex_version")]:
            receipt[key] = subprocess.run([str(executable), "--version"], env=environment,
                                          capture_output=True, text=True, check=True, timeout=10).stdout.strip()
        with (root / "adapter-stderr.log").open("w", encoding="utf-8") as stderr:
            for attempt in range(2):
                process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=stderr, text=True, encoding="utf-8", cwd=workspace, env=environment)
                client = workflow.MCPClient(process)
                phase = f"connection {attempt + 1} initialize"
                initialized = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "native-adapter-protocol-check", "version": "1"}})
                client.send({"method": "notifications/initialized", "params": {}})
                client.request("ping", {})
                phase = f"connection {attempt + 1} catalog"
                catalog = client.request("tools/list", {})["tools"]
                names = {tool["name"] for tool in catalog}
                assert len(names) == len(catalog), "Duplicate tool names"
                assert {"codex.app.thread.start", "codex.app.runtime.stop", "codex.exec.start",
                        "codex.exec.cancel", "codex.diagnostics.snapshot"} <= names, names
                assert client.work() == [], "Discovery created native work"
                diagnostic = client.request("tools/call", {"name": "codex.diagnostics.snapshot", "arguments": {"limit": 10}})
                assert diagnostic.get("isError") is False, diagnostic
                result = diagnostic["structuredContent"]["result"]
                assert json.loads(diagnostic["content"][0]["text"]) == result, diagnostic
                assert result["persistence_available"] is True, result
                assert result["host_diagnostics_available"] is False, result
                assert client.call("thread.loaded.list")["data"] == []
                phase = f"connection {attempt + 1} native lifecycle"
                started = client.call("thread.start")
                thread_id = started["thread"]["id"]
                origin = client.last_invocation
                assert thread_id in client.call("thread.loaded.list")["data"]
                rows = client.work()
                threads = [row for row in rows if row["kind"] == "codex.app.thread"]
                assert len(threads) == 1 and threads[0]["handles"]["thread_id"] == thread_id, rows
                assert threads[0]["acquired_by"] == origin, rows
                status = client.call("status")
                native = status["process"]
                assert native["state"] == "running" and native["parent_process_id"] == process.pid, status
                owned = [native["process_id"]]
                if native.get("supervisor_process_id") is not None:
                    owned.append(native["supervisor_process_id"])
                for pid in owned:
                    assert isinstance(pid, int) and pid > 1 and pid != process.pid, native
                    observations.append(ProcessObservation(pid))
                stopped = client.call("runtime.stop")
                assert stopped["runtime_state"] == "stopped" and stopped["process"]["state"] == "stopped", stopped
                if os.name == "nt":
                    assert stopped["process"]["cleanup_confirmed"] is True, stopped
                for observation in observations:
                    observation.require_exited()
                    observation.close()
                observations.clear()
                assert client.work() == [], "Joined cleanup retained native work"
                assert client.call("runtime.stop")["runtime_state"] == "stopped"
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                client.reader.join(timeout=2)
                assert not client.reader.is_alive(), "Protocol reader did not join EOF"
                receipt["connections"].append({"protocol": initialized["protocolVersion"],
                    "tool_count": len(catalog), "thread_id": thread_id, "native_processes": owned,
                    "owned_stop": stopped["process"], "adapter_exit_code": process.returncode})
        confirmed = True
    except Exception as error:
        receipt["failure_phase"] = phase
        receipt["error"] = str(error)[:4096]
        raise RuntimeError(f"Native protocol check failed during {phase}; evidence retained at {root}: {error}") from error
    finally:
        if process and process.poll() is None:
            if not process.stdin.closed:
                process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for observation in observations:
            observation.close()
        receipt["success"] = confirmed
        receipt["protocol_success"] = confirmed
        receipt["adapter_exit_code"] = process.poll() if process else None
        stderr_path = root / "adapter-stderr.log"
        if stderr_path.exists():
            with stderr_path.open("rb") as handle:
                stderr_bytes = handle.read(16385)
            receipt["stderr"] = stderr_bytes[:16384].decode("utf-8", errors="replace")
            receipt["stderr_truncated"] = len(stderr_bytes) > 16384
        cleanup_error = None
        if confirmed:
            try:
                receipt["read_only_files_removed"] = remove_private_state(root)
                receipt["private_state_removed"] = True
            except Exception as error:
                cleanup_error = error
                receipt["success"] = False
                receipt["private_state_removed"] = False
                receipt["failure_phase"] = "private-state cleanup"
                receipt["error"] = str(error)[:4096]
        if evidence_directory is not None:
            (evidence_directory / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        if not receipt["success"]:
            print(json.dumps(receipt, indent=2), flush=True)
        if cleanup_error is not None:
            raise RuntimeError(f"Native protocol passed but private-state cleanup failed at {root}") from cleanup_error
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--evidence-directory", type=Path)
    options = parser.parse_args()
    for executable in [options.adapter, options.codex]:
        if not executable.is_absolute() or not executable.is_file():
            parser.error("Executables must be existing absolute file paths")
    print(json.dumps(run(options.adapter, options.codex, options.evidence_directory), indent=2))
