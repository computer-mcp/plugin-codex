#!/usr/bin/env python3
"""Disposable App Server protocol peer for exact native-to-host callback acceptance."""

import json
import os
from pathlib import Path
import stat
import sys
import threading
import time

root = Path(os.environ["CODEX_HOME"])
lock = threading.Lock()


def save(name, value):
    temporary = root / (name + ".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(root / name)


def emit(value):
    with lock:
        print(json.dumps(value), flush=True)


def queued_callbacks():
    while True:
        for path in sorted(root.glob("queued-*.json")):
            value = json.loads(path.read_text())
            path.unlink()
            emit(value)
        time.sleep(0.01)


sockets = []
for descriptor in range(3, 10):
    try:
        if stat.S_ISSOCK(os.fstat(descriptor).st_mode):
            sockets.append(descriptor)
    except OSError:
        pass
save("vendor.json", {"pid": os.getpid(), "inherited_host_socket": bool(sockets),
                     "inherited_host_env": any(key in os.environ for key in
                                               ("COMPUTER_MCP_HOST_FD", "COMPUTER_MCP_HOST_CONTEXT", "CODEX_THREAD_ID"))})
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"codexHome": str(root), "platformFamily": "unix", "platformOs": "macos",
                  "userAgent": "isolated-callback-fixture"}
    elif method == "initialized":
        threading.Thread(target=queued_callbacks, daemon=True).start()
        continue
    elif method == "thread/loaded/list":
        result = {"data": [], "nextCursor": None}
    elif method is None and isinstance(request.get("id"), int) and request["id"] >= 900:
        save("callback-" + str(request["id"]) + ".json", request)
        continue
    elif method == "thread/unsubscribe":
        result = {"status": "unsubscribed"}
    elif "id" not in request:
        continue
    else:
        emit({"id": request["id"], "error": {"code": -32601, "message": "Fixture method not implemented"}})
        continue
    emit({"id": request["id"], "result": result})
