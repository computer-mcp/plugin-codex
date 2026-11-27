#!/usr/bin/env python3
"""Accept a packaged adapter through a source-built registered Computer MCP gateway.

Container mode uses a deterministic protocol peer. Fixture mode uses native
Codex with a private loopback Responses server.
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
import shutil
import signal
import subprocess
import sys
import tarfile
import threading
import time
from types import SimpleNamespace
import uuid

REPOSITORY = Path(__file__).resolve().parents[1]
MODEL_SOURCE = REPOSITORY / "Tests/Fixtures/NativeCodex/ModelServer.py"
REGISTERED_HOST_SOURCE = REPOSITORY / "Tests/Fixtures/RegisteredHost/RegisteredHost.swift"
HOST_PIN = REPOSITORY / ".github/computer-mcp-host.sha"
MANIFEST = REPOSITORY / "computer-mcp-plugin.toml"
ADAPTER_PATH = Path("bin/codex-mcp-adapter")
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


def checkout_directory(value):
    path = Path(value)
    if not path.is_absolute() or not path.is_dir():
        raise argparse.ArgumentTypeError("Expected an existing absolute Git checkout directory")
    return path.resolve()


def full_revision(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value) or value == "0" * 40:
        raise ValueError("A full 40-character Git commit SHA is required")
    return value


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
    parser.add_argument("--host-source", type=checkout_directory, help="Container mode: clean checkout at the committed Host pin")
    parser.add_argument("--plugin-revision", help="Container mode: full plugin checkout SHA")
    parser.add_argument("--archive", type=absolute_file, help="Container mode: plugin release ZIP")
    parser.add_argument("--receipt", type=absolute_file, help="Container mode: release ZIP receipt")
    parser.add_argument("--host", type=executable, help="Native modes: source-built CodexRegisteredHost fixture")
    parser.add_argument("--adapter", type=executable, help="Native modes: adapter from the verified, relocated archive")
    parser.add_argument("--codex", type=executable, help="Native modes: user-installed vendor Codex")
    parser.add_argument("--output-directory", required=True, type=Path, help="New private directory in ignored build output")
    parser.add_argument("--mode", choices=("container", "fixture", "full"), default="full")
    parser.add_argument("--auth-file", type=absolute_file, help="Full mode: existing vendor auth.json; copied privately and deleted on exit")
    parser.add_argument("--model", help="Full mode: authenticated model ID")
    parser.add_argument("--timeout-seconds", type=timeout_seconds, default=180)
    options = parser.parse_args(arguments)
    root = options.output_directory
    if not root.is_absolute() or root.exists() or root.is_symlink():
        parser.error("--output-directory must be a new absolute path")
    source_inputs = (options.host_source, options.plugin_revision, options.archive, options.receipt)
    if options.mode == "container":
        if not all(source_inputs) or any((options.host, options.adapter, options.codex)):
            parser.error("Container mode requires --host-source, --plugin-revision, --archive and --receipt")
        try:
            full_revision(options.plugin_revision)
        except ValueError as error:
            parser.error(str(error))
    elif any(source_inputs) or not all((options.host, options.adapter, options.codex)):
        parser.error("Native modes require --host, --adapter and --codex")
    if options.mode == "full" and (not options.auth_file or not options.model or not options.model.strip()):
        parser.error("Full mode requires --auth-file and --model")
    if options.mode != "full" and (options.auth_file or options.model):
        parser.error("Authentication inputs require full mode")
    if options.model and any(c in options.model for c in "\0\r\n"):
        parser.error("Model ID must be a single nonempty line")
    return options


def git_at(directory, *arguments):
    return ["/usr/bin/git", "--no-optional-locks", "--no-replace-objects", "-C", str(directory), *arguments]


def checked_revision(directory, expected, label):
    def read(*arguments):
        return subprocess.run(git_at(directory, *arguments), text=True, check=True,
                              stdout=subprocess.PIPE, timeout=30).stdout.strip()

    expected = full_revision(expected)
    require(Path(read("rev-parse", "--show-toplevel")).resolve() == directory,
            f"{label} must be a separate Git checkout root: {directory}")
    actual = read("rev-parse", "--verify", "HEAD^{commit}")
    require(actual == expected, f"{label} HEAD {actual} differs from required {expected}")
    require(not read("status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"),
            f"{label} checkout must be clean: {directory}")
    return actual


def prepare_pinned_host(options):
    pin = full_revision(HOST_PIN.read_text(encoding="ascii").strip())
    require(options.host_source != REPOSITORY, "Host and plugin require separate checkouts")
    host_revision = checked_revision(options.host_source, pin, "Host")
    plugin_revision = checked_revision(REPOSITORY, options.plugin_revision, "Plugin")
    receipt = json.loads(options.receipt.read_text())
    require(isinstance(receipt, dict) and receipt.get("configuration") == "release",
            "Pinned Host acceptance requires a release archive")
    stage = options.output_directory.resolve()
    require(not stage.is_relative_to(options.host_source), "Build output must be outside the Host checkout")
    stage.mkdir(mode=0o700, parents=True)
    source = stage / "host-source"
    source.mkdir()
    with subprocess.Popen(git_at(options.host_source, "archive", host_revision),
                          stdout=subprocess.PIPE) as archive:
        with archive.stdout, tarfile.open(fileobj=archive.stdout, mode="r|") as tar:
            tar.extractall(source, filter="data")
        require(archive.wait(timeout=30) == 0, "Failed to export pinned Host source")
    target = source / "Tests/CodexRegisteredHost"
    target.mkdir()
    shutil.copy2(REGISTERED_HOST_SOURCE, target / REGISTERED_HOST_SOURCE.name)
    with (source / "Package.swift").open("a") as manifest:
        manifest.write("""
package.targets.append(.executableTarget(
  name: "CodexRegisteredHost",
  dependencies: [
    "ComputerMCPConfiguration", "ComputerMCPCore", "ComputerMCPGateway", "ComputerMCPMacOS",
    "ComputerMCPPermissions", "ComputerMCPPlatform", "ComputerMCPPlugins", "ComputerMCPTransport",
    .product(name: "MCP", package: "swift-sdk"),
  ],
  path: "Tests/CodexRegisteredHost"
))
""")
    options.package = stage / "relocated"
    verified = subprocess.run([
        sys.executable, str(REPOSITORY / "scripts/check-package.py"),
        "--archive", str(options.archive), "--receipt", str(options.receipt),
        "--destination", str(options.package),
    ], text=True, check=True, stdout=subprocess.PIPE, timeout=120)
    archive = json.loads(verified.stdout)
    options.adapter = executable(str(options.package / ADAPTER_PATH))
    build = ["/usr/bin/swift", "build", "--package-path", str(source),
             "--build-system", "native", "--disable-swift-testing", "--disable-automatic-resolution"]
    products = ("CodexRegisteredHost", "computer-mcp-execution-bootstrap")
    lock = (source / "Package.resolved").read_bytes()
    for product in products:
        subprocess.run([*build, "--product", product], check=True)
    require((source / "Package.resolved").read_bytes() == lock, "Host dependency lock changed")
    binary_directory = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
    options.host = executable(str(binary_directory / products[0]))
    bootstrap = executable(str(binary_directory / products[1]))
    options.output_directory = stage / "runtime"
    return {"host_revision": host_revision, "plugin_revision": plugin_revision,
            "archive": archive, "execution_bootstrap_sha256": digest(bootstrap)}


def unwrap(result, indirect=False):
    for _ in range(2 if indirect else 1):
        require(isinstance(result, dict), "Malformed MCP tool result")
        if result.get("isError"):
            raise RuntimeError(json.dumps(result, ensure_ascii=False))
        result = result["structuredContent"]["result"]
    return result


def observe_worktree_removal(result, worktree_id, project, operation_id):
    if isinstance(result, dict) and result.get("isError") is True:
        structured = result.get("structuredContent")
        if isinstance(structured, dict):
            error = structured.get("error")
            execution = structured.get("gateway_execution")
            # The removal can invalidate the Host's project snapshot during read admission.
            if (isinstance(error, dict) and error.get("code") == "configuration.changed"
                    and isinstance(execution, dict) and execution.get("capability_id") == "mcp.tools.call"
                    and execution.get("project_id") == "primary" and "result" not in structured):
                return operation_id, None
    result = unwrap(result)
    current = result.get("structuredContent", {}).get("result")
    require(isinstance(current, dict) and current["id"] == worktree_id
            and current["project_id"] == project and current["source_project_id"] == "primary", result)
    observed_id = uuid.UUID(current["operation_id"])
    require(operation_id is None or operation_id == observed_id, current)
    if current["state"] == "removed":
        return observed_id, unwrap(result)
    require(current["state"] == "removing" and current["host_state"] in {"reserved", "running"}, current)
    return observed_id, None


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


CONTAINER_RISKS = {
    "codex.app.status": "read-only",
    "codex.app.thread.loaded.list": "read-only",
    "codex.app.runtimes.cleanup.preview": "read-only",
    "codex.app.runtimes.cleanup.perform": "workspace-write",
    "codex.diagnostics.snapshot": "read-only",
    "codex.worktree.managed.list": "read-only",
    "codex.worktree.managed.read": "read-only",
    "codex.worktree.leases.list": "read-only",
    "codex.worktree.leases.acquire": "workspace-write",
    "codex.worktree.leases.release": "workspace-write",
    "codex.worktree.provision.plan": "workspace-write",
    "codex.worktree.provision.perform": "workspace-write",
    "codex.worktree.remove.plan": "workspace-write",
    "codex.worktree.remove.perform": "destructive",
}


class Host:
    def __init__(self, fixture, indirect=True, *, with_observer=False, streams=None):
        self.fixture, self.indirect = fixture, indirect
        self.workspace = "primary"
        fixture.generation += 1
        self.log = (fixture.root / f"host-{fixture.generation}.log").open("w")
        self.evidence = (fixture.root / f"protocol-{fixture.generation}.jsonl").open("w")
        self.process = self.observer_streams = None
        if streams is None:
            command = [str(fixture.options.host), "serve", str(fixture.root)]
            child_fds = ()
            if with_observer:
                input_fd, writer = os.pipe()
                reader, output_fd = os.pipe()
                child_fds = (input_fd, output_fd)
                command.extend(str(fd) for fd in child_fds)
                self.observer_streams = SimpleNamespace(
                    stdin=os.fdopen(writer, "w"), stdout=os.fdopen(reader))
            try:
                self.process = subprocess.Popen(
                    command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                    text=True, bufsize=1, env=fixture.environment, cwd=fixture.root, pass_fds=child_fds)
            except OSError:
                if self.observer_streams:
                    self.observer_streams.stdin.close()
                    self.observer_streams.stdout.close()
                self.log.close()
                self.evidence.close()
                raise
            finally:
                for fd in child_fds:
                    os.close(fd)
            streams = self.process
        fixture.hosts.append(self)
        self.client = MCPClient(streams, self.evidence, fixture.options.timeout_seconds)
        gateway_catalog = self.client.initialize()
        downstream_catalog = self.project_catalog()
        self.catalog = downstream_catalog if indirect else gateway_catalog
        require(set(fixture.risks) <= self.catalog.keys(), {"missing_tools": sorted(set(fixture.risks) - self.catalog.keys())})
        require(gateway_catalog["mcp.tools.call"]["inputSchema"]["properties"]["project_id"]["type"] == "string",
                "Generic dispatch lacks project selection")

    def project_catalog(self):
        tools = unwrap(self.client.send("tools/call", {
            "name": "mcp.tools.list", "arguments": {"server": "codex", "project_id": self.workspace},
        }))
        return {tool["name"]: tool for tool in tools}

    def select_project(self, project):
        self.workspace = project
        self.catalog = self.project_catalog()

    def raw(self, name, arguments=None, timeout=None, *, gateway_envelope=False):
        name = name if name.startswith("codex.") else "codex.app." + name
        arguments = arguments or {}
        require(set(arguments) <= self.catalog[name]["inputSchema"]["properties"].keys(), {"tool": name, "undeclared_inputs": sorted(set(arguments) - self.catalog[name]["inputSchema"]["properties"].keys())})
        result = self.dispatch(name, arguments, timeout)
        return unwrap(result) if self.indirect and not gateway_envelope else result

    def dispatch(self, name, arguments=None, timeout=None):
        arguments = arguments or {}
        if self.indirect:
            params = {"name": "mcp.tools.call", "arguments": {"server": "codex", "tool": name,
                      "project_id": self.workspace, "arguments": arguments}}
        else:
            params = {"name": name, "arguments": dict(arguments, project_id=self.workspace)}
        return self.client.send("tools/call", params, timeout=timeout)

    def call(self, name, arguments=None, timeout=None):
        return unwrap(self.raw(name, arguments, timeout))

    def method(self, name, params=None, timeout=None):
        return self.call("methods.call", {"method": name, "params": params or {}}, timeout)

    def close(self):
        if self.process is None:
            self.client.process.stdin.close()
            self.log.close()
            self.evidence.close()
            return
        if self.observer_streams:
            self.observer_streams.stdin.close()
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
        if self.observer_streams:
            self.observer_streams.stdout.close()
        self.log.close()
        self.evidence.close()
        require(self.process.returncode == 0, {"host_exit": self.process.returncode})

    def processes(self):
        status = self.call("status")
        require(Path(status["workspace"]).resolve() == self.fixture.projects[self.workspace], status)
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
        self.container = None
        self.authorization = {}
        self.adapter_config = self.root / "adapter.json"
        self.launches = self.root / "launches.jsonl"
        self.risks = CONTAINER_RISKS if options.mode == "container" else RISKS
        self.projects = {name: self.root / name for name in ("primary", "other")}
        self.home = self.root / "codex-home"
        self.home.mkdir(mode=0o700)
        # Private HOME also isolates Git, native skills, hooks and host configuration.
        self.environment = {"HOME": str(self.root), "PATH": "/usr/bin:/bin",
                            "TMPDIR": str(self.root / "tmp"), "GIT_CONFIG_GLOBAL": os.devnull,
                            "GIT_CONFIG_NOSYSTEM": "1"}
        (self.root / "tmp").mkdir(mode=0o700)

    def setup(self):
        for name, path in self.projects.items():
            path.mkdir()
            self.git(["init", "--quiet", "--initial-branch=main"], name)
            for key, value in (("user.name", "Acceptance"), ("user.email", "acceptance@example.invalid"),
                               ("commit.gpgsign", "false"), ("core.hooksPath", str(self.root / name / ".git/hooks"))):
                self.git(["config", key, value], name)
        if self.options.mode == "container":
            (self.projects["primary"] / "product.txt").write_text("caller project fixture\n")
            self.git(["add", "product.txt"])
            self.git(["commit", "--quiet", "-m", "Fixture base"])
        self.register()
        if self.options.mode == "container":
            self.configure_adapter(self.peer, exec_enabled=False)
            return
        wrapper = self.package / "bin/configured-codex"
        wrapper.write_text(f'''#!{sys.executable}
import json, os, sys
keys = ("COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD", "CODEX_THREAD_ID")
assert not any(key in os.environ for key in keys), "Parent authority leaked"
assert os.environ.get("CODEX_HOME") == {str(self.home)!r}, "Wrong vendor container"
with open({str(self.launches)!r}, "a") as receipt:
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
        self.configure_adapter(self.package / "bin/configured-codex", exec_enabled=True)

    def configure_adapter(self, vendor, exec_enabled):
        self.adapter_config.write_text(json.dumps({
            "enabled": True, "executable": str(vendor), "app_server_enabled": True,
            "exec_enabled": exec_enabled, "app_server_request_timeout_seconds": 30,
            "app_server_app_list_timeout_seconds": 120,
        }))

    def register(self):
        q = json.dumps
        self.package = self.root / "plugin"
        bin_directory = self.package / "bin"
        if self.options.mode == "container":
            shutil.copytree(self.options.package, self.package)
        else:
            bin_directory.mkdir(parents=True)
            shutil.copy2(MANIFEST, self.package / MANIFEST.name)
            shutil.copy2(self.options.adapter, bin_directory / "codex-mcp-adapter")
            resources = self.options.adapter.with_name("codex-plugin_CodexAdapter.bundle")
            shutil.copytree(resources, bin_directory / resources.name)

        config = '''schema_version = 1
[runtime]
caller = "local-mcp"
profile = "acceptance"
project_id = "primary"

[[profiles]]
id = "acceptance"
allowed_callers = ["local-mcp"]
full_access = false

[profiles.projects]
primary = { access = "write", network = "none" }
other = { access = "write", network = "none" }

[profiles.plugins]
codex = "use"
'''
        if self.options.mode == "container":
            config += '''
[[profiles]]
id = "observer"
allowed_callers = ["local-mcp"]
full_access = false

[profiles.projects]
primary = { access = "write", network = "none" }
other = { access = "write", network = "none" }

[profiles.plugins]
codex = "use"
'''
        config += '''
[builtin]
enabled = ["file.read"]
'''
        for name in ("primary", "other"):
            config += f'''[[projects]]
id = {q(name)}
display_name = {q(name)}
path = {q(str(self.root / name))}
'''
        (self.root / "host.toml").write_text(config)
        (self.root / "contribution.json").write_text(json.dumps({
            "registrationID": "codex", "exposure": "gateway" if self.options.mode == "container" else "reexport",
            "prefix": "",
            "hostServices": True, "allowedTools": list(self.risks),
            "toolRisks": {name: "project-write" if risk == "workspace-write" else risk
                          for name, risk in self.risks.items()},
        }))
        result = subprocess.run([str(self.options.host), "register", str(self.root)],
                                env=self.environment, cwd=self.root, capture_output=True, text=True,
                                timeout=self.options.timeout_seconds)
        (self.root / "registration.log").write_text(result.stderr)
        require(result.returncode == 0, {"registration_exit": result.returncode, "stderr": result.stderr})
        self.container = json.loads(result.stdout)
        for key in ("home", "cache", "state", "config"):
            require(Path(self.container[key]).is_relative_to(self.root / "host.sqlite.providers"),
                    {"invalid_container_path": key})
        (self.root / "registration.json").write_text(json.dumps(self.container, indent=2) + "\n")
        self.home = Path(self.container["home"]) / ".codex"
        self.home.mkdir(mode=0o700)
        if self.options.mode == "container":
            self.authorization["registration"] = {
                key: self.container[key] for key in ("manifest_digest", "provider_revision", "authorization_epoch")
            }
            self.peer = Path(self.container["home"]) / "fixture-vendor"
            shutil.copy2(self.options.host, self.peer)
        self.adapter_config = Path(self.container["config"])
        self.launches = self.home / "launches.jsonl"

    def git(self, args, workspace="primary"):
        return subprocess.run(["/usr/bin/git", *args], cwd=self.projects[workspace], env=self.environment,
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
        require(not self.launches.exists(), "Discovery started the vendor")
        diagnostic = host.call("codex.diagnostics.snapshot", {"limit": 10})
        require(diagnostic["persistence_available"] and diagnostic["host_diagnostics_available"], diagnostic)
        require(diagnostic["state_storage"]["scope"] == "authorization_subject", diagnostic)
        require(not self.launches.exists(), "Diagnostics started the vendor")
        host.call("codex.run.list")
        host.call("codex.worktree.managed.list")
        host.call("codex.worktree.leases.list")
        lease = host.call("codex.worktree.leases.acquire", {"agent_id": "acceptance"})
        host.call("codex.worktree.leases.release", {"lease_id": lease["id"],
                  "expected_revision": lease["revision"], "reason": "Acceptance complete"})
        require(not self.launches.exists(), "Domain lease operations started the vendor")
        host.close()
        self.record("catalog-diagnostics-domain-leases-lazy-start")

    def directories(self):
        host = Host(self)
        cwd = str(self.root / "primary")
        started = time.monotonic()
        skills = host.method("skills/list", {"cwds": [cwd], "forceReload": False}, timeout=35)
        require(time.monotonic() - started < 30, "skills/list exceeded normal deadline")
        require(len(skills["data"]) == 1 and skills["data"][0]["cwd"] == cwd, skills)
        errors = skills["data"][0].get("errors")
        require(
            errors == [],
            f"skills/list expected no directory errors for {cwd}, got {json.dumps(errors, ensure_ascii=False)}",
        )
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
        config = self.adapter_config
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
        launches = [json.loads(line) for line in self.launches.read_text().splitlines()]
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

    def provision_worktree(self, host):
        parent = host.call("codex.worktree.leases.acquire", {"agent_id": "acceptance-parent"})
        plan = host.call("codex.worktree.provision.plan", {
            "name": "fixture", "agent_id": "acceptance-child", "parent_lease_id": parent["id"],
        })
        require(plan["state"] == "planned" and plan["source_project_id"] == "primary", plan)
        worktree = host.call("codex.worktree.provision.perform", plan["perform_arguments"])
        require(worktree["id"] == plan["id"] and worktree["state"] == "active"
                and worktree["host_state"] == "completed" and worktree["lease"]["state"] == "acquired", worktree)
        operation = worktree["host_response"]["structuredContent"]["result"]
        require(operation["source_project_id"] == "primary" and operation["project_id"] == "primary"
                and uuid.UUID(operation["operation_id"]) == uuid.UUID(worktree["operation_id"]), operation)
        child = worktree["project_id"]
        path = Path(worktree["resolved"]["path"]).resolve(strict=True)
        require(path.is_relative_to(self.root / "worktrees") and child not in self.projects, worktree)
        self.projects[child] = path
        require(self.git(["rev-parse", "HEAD"], child) == self.git(["rev-parse", "HEAD"]), worktree)
        inventory = host.call("codex.worktree.managed.list")
        require(worktree["resolved"]["worktree_id"] in json.dumps(inventory), inventory)
        self.record("host-created-associated-worktree")
        return worktree, parent

    def remove_worktree(self, host, worktree, parent):
        worktree_id, project = worktree["id"], worktree["project_id"]
        selector = {"managed_worktree_id": worktree_id}
        observed = host.call("codex.worktree.managed.read", selector)
        require(observed["state"] == "active" and observed["operation_id"] == worktree["operation_id"], observed)
        host.select_project("other")
        refused = host.raw("codex.worktree.managed.read", selector)
        require(refused.get("isError") is True and "Unknown Computer MCP-managed worktree" in json.dumps(refused),
                refused)
        host.select_project(project)
        require(host.call("codex.worktree.managed.read", selector)["project_id"] == project,
                "Caller did not resolve its derived project")
        path = self.projects[project]
        trigger = path / "fixture-edit-request"
        trigger.touch()
        require(host.call("thread.loaded.list")["data"] == [], "Unexpected fixture threads")
        peer = self.vendor_receipt()
        child_pids = host.processes()
        require((path / "fixture-edit.txt").read_text() == "edited by the registered peer\n"
                and not (self.projects["primary"] / "fixture-edit.txt").exists(), path)
        trigger.unlink()
        self.git(["add", "fixture-edit.txt"], project)
        self.git(["-c", "user.name=Acceptance", "-c", "user.email=acceptance@example.invalid",
                  "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture edit"], project)
        tip = self.git(["rev-parse", "HEAD"], project).strip()
        lease = next(row for row in host.call("codex.worktree.leases.list")["leases"]
                     if row["id"] == worktree["lease"]["lease_id"])
        host.call("codex.worktree.leases.release", {"lease_id": lease["id"],
                  "expected_revision": lease["revision"], "reason": "Fixture edit committed"})
        plan = host.call("codex.worktree.remove.plan", selector)
        require(plan["state"] == "removal_planned", plan)
        response = host.dispatch("codex.worktree.remove.perform", plan["perform_arguments"])
        error = response.get("structuredContent", {}).get("error", {})
        message = error.get("message", "")
        reply_lost = (response.get("isError") and error.get("code") == "gateway.execution_failed"
                      and (message.startswith("[mcp.request_cancelled]")
                           or message == "MCP server 'codex' request timed out."))
        if not reply_lost:
            removed = unwrap(response, indirect=True)
        host.select_project("primary")
        if reply_lost:
            removal_id = None

            def observe_removal():
                nonlocal removal_id
                observation = host.raw("codex.worktree.managed.read", selector, gateway_envelope=True)
                removal_id, completed = observe_worktree_removal(observation, worktree_id, project, removal_id)
                return completed

            removed = wait_until(observe_removal, self.options.timeout_seconds, "Host removal observation")
            self.record("interrupted-removal-reply-recovered-without-replaying")
        require(removed["state"] == "removed" and removed["host_state"] == "completed"
                and removed["operation_id"] != worktree["operation_id"], removed)
        operation = removed["host_response"]["structuredContent"]["result"]
        require(operation["project_id"] == project and operation["result"]["oid"] == tip
                and operation["result"]["worktree_id"] == worktree["resolved"]["worktree_id"], operation)
        require(not path.exists(), f"Host still has the removed checkout: {path}")
        wait_until(lambda: all(exited(pid) for pid in [peer["pid"], *child_pids[:2]]), 15,
                   "Removed worktree still has its vendor or supervisor")
        source = host.call("codex.worktree.managed.read", selector)
        require(source["state"] == "removed" and source["operation_id"] == removed["operation_id"], source)
        recovery = self.root / "worktree-recovery"
        repositories = [entry.parent for entry in recovery.rglob("HEAD") if (entry.parent / "objects").is_dir()]
        require(any(subprocess.run(
            ["/usr/bin/git", "--git-dir", str(repository), "cat-file", "-e", tip + "^{commit}"],
            env=self.environment, capture_output=True, timeout=10).returncode == 0
                    for repository in repositories), "Host recovery storage lacks the removed commit")
        require(not self.git(["status", "--porcelain"]), "Source checkout changed")
        host.call("codex.worktree.leases.release", {"lease_id": parent["id"],
                  "expected_revision": parent["revision"], "reason": "Fixture worktree removed"})
        self.record("host-restarted-edited-retained-and-removed-worktree")

    def vendor_receipt(self):
        receipt = json.loads((self.home / "vendor.json").read_text())
        self.pids.add(receipt["pid"])
        return receipt

    def clear_stale_runtime(self, host, snapshot, prior_runtime, prior_pids):
        persisted = next(row for row in snapshot["persisted_runtimes"] if row["id"] == prior_runtime)
        require(all(exited(pid) for pid in prior_pids), "Previous fixture process still exists")
        require(not any(snapshot[key] for key in ("active_runs", "pending_approvals", "thread_ownership_receipts"))
                and all(row["runtime_id"] != prior_runtime and row["process"] is None
                        and row["connection_id"] is None and row["current_request_count"] == 0
                        and not row["threads"] for row in snapshot["live_runtimes"]["runtimes"]),
                "Restart reported a live peer, request, thread, run or approval")
        preview = host.call("runtimes.cleanup.preview")
        require(persisted["state"] == "running", persisted)
        candidates = preview["candidates"]
        require(preview["signals_sent"] is False and len(candidates) == 1
                and candidates[0]["runtime"]["id"] == prior_runtime
                and candidates[0]["classification"] == "stale_record"
                and candidates[0]["cleanup_ready"] and not candidates[0]["directory_active"]
                and not candidates[0]["process_active"], preview)
        cleanup = host.call("runtimes.cleanup.perform", {"confirm_cleanup": True})
        require(cleanup["signals_sent"] is False and cleanup["watchdog_pending"] == []
                and [(row["id"], row["state"], row["currentRequestState"]) for row in cleanup["cleaned"]]
                == [(prior_runtime, "cleaned", "idle")], cleanup)
        require(host.call("runtimes.cleanup.preview")["candidates"] == [], "Stale runtime remained actionable")
        self.record("restarted-without-live-runtime-authority-or-reported-work")

    def revoke(self, role):
        trigger = self.root / f"revoke-{role}"
        trigger.touch()
        receipt_path = trigger.with_suffix(".json")
        wait_until(receipt_path.exists, self.options.timeout_seconds, f"{role} revocation receipt")
        receipt = json.loads(receipt_path.read_text())
        require("error" not in receipt, receipt)
        require(receipt["before_revision"] < receipt["after_revision"] and receipt["executions"]
                and receipt["epoch"] == self.container["authorization_epoch"], receipt)
        self.authorization[role] = receipt

    def assert_revoked(self, host, code, message=None):
        result = host.dispatch("codex.app.thread.loaded.list")
        error = result.get("structuredContent", {}).get("error", {})
        require(result.get("isError") is True and error.get("code") == code
                and (message is None or error.get("message") == message), result)

    def registered_revocation(self, caller, worktree):
        require(caller.call("thread.loaded.list")["data"] == [], "Unexpected fixture threads")
        caller_pids = caller.processes()
        observer = Host(self, streams=caller.observer_streams)
        scope = observer.call("codex.diagnostics.snapshot")["scope"]
        require(scope["principal_id"] == "registered-codex-observer"
                and scope["profile_id"] == "observer" and scope["project_id"] == "primary", scope)
        refused = observer.raw("codex.worktree.managed.read", {"managed_worktree_id": worktree["id"]})
        require(refused.get("isError") is True and "Unknown Computer MCP-managed worktree" in json.dumps(refused),
                refused)
        require(observer.call("thread.loaded.list")["data"] == [], "Unexpected fixture threads")
        observer_peer = self.vendor_receipt()
        observer_pids = observer.processes()
        require(caller_pids[0] != observer_pids[0] == observer_peer["pid"], observer_peer)
        self.revoke("acceptance")
        wait_until(lambda: all(exited(pid) for pid in caller_pids[:2]), 15, "Revoked caller process exit")
        self.assert_revoked(caller, "permission.denied")
        require(observer.call("thread.loaded.list")["data"] == [] and not exited(observer_pids[0])
                and observer.processes() == observer_pids, "Unrelated caller lost its live runtime")
        self.revoke("observer")
        wait_until(lambda: all(exited(pid) for pid in observer_pids[:2]), 15, "Revoked provider process exit")
        self.assert_revoked(observer, "permission.unavailable", "invalidBinding")
        observer.close()
        caller.close()
        require(self.vendor_receipt() == observer_peer, "Revocation relaunched the vendor")
        self.record("caller-revocation-isolated-and-durable-provider-revocation-terminated-peer")

    def registered_container(self):
        marker = "caller project fixture\n"
        sibling = "sibling project fixture\n"
        (self.root / "other/product.txt").write_text(sibling)
        vendor_receipt = self.home / "vendor.json"
        prior_vendor = None
        for generation in (1, 2):
            host = Host(self)
            initial = host.call("codex.diagnostics.snapshot")
            require(initial["host_diagnostics_available"] and initial["persistence_available"], initial)
            require(initial["state_storage"]["scope"] == "authorization_subject", initial)
            require(initial["scope"]["project_id"] == "primary"
                    and initial["scope"]["principal_id"] == "registered-codex-fixture", initial)
            if prior_vendor:
                self.clear_stale_runtime(host, initial, prior_runtime, prior_pids)
            require(not vendor_receipt.exists() or json.loads(vendor_receipt.read_text()) == prior_vendor,
                    "Catalog or diagnostics launched the peer")

            request_id = 900 + generation
            arguments = {"path": "product.txt"}
            if generation == 2:
                arguments["project_id"] = "other"
            request = {"id": request_id, "method": "item/tool/call", "params": {
                "namespace": "computer-mcp", "tool": "file.read", "arguments": arguments,
                "callId": f"fixture-read-{generation}", "threadId": "fixture-thread", "turnId": "fixture-turn"}}
            (self.home / "queued.json").write_text(json.dumps(request))
            loaded = host.call("thread.loaded.list")
            require(loaded["data"] == [], loaded)
            vendor = self.vendor_receipt()
            response = json.loads((self.home / f"callback-{request_id}.json").read_text())
            require(response["id"] == request_id and "error" not in response, response)
            callback = response["result"]
            require(callback["success"] is (generation == 1), callback)
            content = json.loads(callback["contentItems"][0]["text"])
            if generation == 1:
                require(unwrap(content)["content"] == marker, content)
                execution = content["structuredContent"]["gateway_execution"]
                require(all(execution[key] == initial["scope"][key]
                            for key in ("project_id", "profile_id", "caller", "socket_connection_id")), execution)
            else:
                require("bound connection scope" in content["error"] and sibling not in json.dumps(content), content)

            require(vendor["count"] == generation and vendor["codex_home"] == str(self.home), vendor)
            require(all(vendor[key] == self.container[key] for key in ("home", "cache", "state")), vendor)
            require(not vendor["inherited_host_env"] and not vendor["inherited_host_socket"], vendor)
            require(prior_vendor is None or vendor["pid"] != prior_vendor["pid"], vendor)
            pids = host.processes()
            snapshot = host.call("codex.diagnostics.snapshot")
            if generation == 1:
                reads = [row for row in snapshot["recent_tool_audits"]
                         if row["capability_id"] == "file.read" and row["request_id"] == execution["request_id"]]
                require(any(row["decision"] == "allowed"
                            and row["socket_connection_id"] == execution["socket_connection_id"]
                            for row in reads), reads)
            (self.root / f"vendor-{generation}.json").write_text(json.dumps(vendor, indent=2) + "\n")
            if generation == 1:
                worktree, parent = self.provision_worktree(host)
                prior_runtime = host.call("status")["runtime_id"]
                prior_vendor, prior_pids = vendor, pids
                adapter_pid = pids[2]
                require(descendant(adapter_pid, host.process.pid, process_parent)
                        and descendant(vendor["pid"], adapter_pid, process_parent),
                        "Crash target is not the fixture's adapter and vendor lineage")
                os.kill(adapter_pid, signal.SIGKILL)
                host.close()
                wait_until(lambda: all(exited(pid) for pid in prior_pids), 15, "Previous fixture process exit")
            else:
                self.remove_worktree(host, worktree, parent)
                host.close()
        self.registered_revocation(Host(self, with_observer=True), worktree)
        require(list(Path(self.container["state"]).glob("codex-adapter/subjects/*/codex.sqlite")),
                "Adapter records are missing in the injected state directory")
        self.record("registered-container-vendor-and-adapter-persistence-and-caller-scoped-read")

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
            launches = self.launches
            if launches.exists():
                entries = [json.loads(line) for line in launches.read_text().splitlines()]
                self.pids.update(entry["pid"] for entry in entries)
                roots = {str((self.root / name).resolve()) for name in ("primary", "other")}
                if not all(str(Path(entry["cwd"]).resolve()) in roots for entry in entries):
                    errors.append("Vendor launched outside selected workspaces")
            if self.options.mode == "container" and (self.home / "vendor.json").is_file():
                self.vendor_receipt()
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


def run(options, provenance=None):
    fixture = Fixture(options)
    report = {"schema_version": 1, "mode": options.mode, "passed": False,
              "authenticated_model_verified": False, "steps": fixture.steps,
              "binaries": {key: {"path": str(getattr(options, key)), "sha256": digest(getattr(options, key))}
                           for key in ("host", "adapter", "codex") if getattr(options, key)},
              "fixture_sha256": {source.name: digest(source) for source in (
                  MODEL_SOURCE, REGISTERED_HOST_SOURCE)}}
    if provenance:
        report["source_acceptance"] = provenance
        report["authorization"] = fixture.authorization
    try:
        fixture.setup()
        for key in report["binaries"]:
            result = subprocess.run([str(getattr(options, key)), "--version"], text=True, capture_output=True,
                                    timeout=10, check=True, env=fixture.environment)
            report["binaries"][key]["version"] = result.stdout.strip()
        if options.mode == "container":
            fixture.registered_container()
        else:
            fixture.catalog_and_diagnostics()
            fixture.directories()
            fixture.native_permissions()
            fixture.handoff()
            fixture.sibling_workspace()
            fixture.recovery()
            fixture.app_lifecycle()
            fixture.exec_lifecycle()
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


def main():
    options = parse_arguments()
    try:
        provenance = prepare_pinned_host(options) if options.mode == "container" else None
        return run(options, provenance)
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"Host acceptance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
