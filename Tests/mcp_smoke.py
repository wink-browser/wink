#!/usr/bin/env python3
"""End-to-end smoke test for Wink's MCP server, through the real wink-mcp bridge.

    python3 -I Tests/mcp_smoke.py [path/to/Wink.app]

Wink asks you to approve the connection the first time (click "Allow"). With a
dev launch (WINK_DEBUG_DIR=<dir>), `echo accept > <dir>/commands.txt && kill
-USR2 $(cat <dir>/pid)` approves it from a script.
"""
import json
import os
import subprocess
import sys
import threading
import time

APP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "Wink.app")
BRIDGE = os.path.join(APP, "Contents", "MacOS", "wink-mcp")
# For a headless test instance, set WINK_MCP_SOCKET to its socket (see docs/ARCHITECTURE.md).

proc = subprocess.Popen([BRIDGE], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
responses, cond, counter = {}, threading.Condition(), [0]


def reader():
    for line in proc.stdout:
        message = json.loads(line)
        with cond:
            responses[message.get("id")] = message
            cond.notify_all()


threading.Thread(target=reader, daemon=True).start()


def rpc(method, params=None, timeout=120):
    counter[0] += 1
    mid = counter[0]
    proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}) + "\n").encode())
    proc.stdin.flush()
    deadline = time.time() + timeout
    with cond:
        while mid not in responses:
            if not cond.wait(deadline - time.time()):
                raise TimeoutError(method)
        return responses.pop(mid)


def tool(name, **arguments):
    started = time.time()
    result = rpc("tools/call", {"name": name, "arguments": arguments})["result"]
    texts = [c["text"] for c in result["content"] if c["type"] == "text"]
    images = sum(1 for c in result["content"] if c["type"] == "image")
    status = "ERROR" if result.get("isError") else "ok"
    print(f"[{status}] {name} ({time.time() - started:.2f}s){' +%d image' % images if images else ''}")
    for text in texts:
        print("    " + text[:400].replace("\n", "\n    "))
    return result


init = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                          "clientInfo": {"name": "wink-smoke-test", "version": "1"}})["result"]
print("server:", init["serverInfo"], "protocol", init["protocolVersion"])
proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
proc.stdin.flush()
print("tools:", ", ".join(t["name"] for t in rpc("tools/list")["result"]["tools"]))

failures = 0
for name, args in [
    ("tabs_list", {}),
    ("tab_open", {"url": "https://example.com"}),
    ("find", {"text": "Learn"}),
    ("snapshot", {"max_lines": 40}),
    ("read_page", {"max_chars": 800}),
    ("screenshot", {"labels": True}),
    ("click", {"text": "Learn more"}),
    ("go_back", {}),
    ("batch", {"steps": [{"action": "scroll", "direction": "down"}, {"action": "scroll", "direction": "top"}]}),
    ("network_requests", {"limit": 5}),
]:
    failures += 1 if tool(name, **args).get("isError") else 0

proc.stdin.close()
print("PASS" if failures == 0 else f"{failures} tool call(s) failed")
sys.exit(1 if failures else 0)
