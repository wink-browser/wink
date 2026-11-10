#!/usr/bin/env python3
"""Agents driving a headless Wink, end to end, the way an MCP client does.

    python3 -I Tests/agent_e2e.py path/to/Wink.app [exported-tests-dir]

Starts `wink-mcp --headless` (a private, invisible Wink with a throwaway
profile), serves Tests/fixtures on 127.0.0.1:8765, and walks through forms, a
mocked API, offline mode, page dialogs, a re-rendering list, drag and drop,
storage and a trace. Every check must pass. The Playwright tests Wink exports
along the way are written to the second argument (CI runs them in Chromium,
Firefox and WebKit on Linux).
"""
import http.server
import json
import os
import re
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "..", "build", "Wink.app")
EXPORTS = sys.argv[2] if len(sys.argv) > 2 else None
BASE = "http://127.0.0.1:8765/"


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(ROOT, "fixtures"), **kwargs)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 8765), Quiet)
threading.Thread(target=server.serve_forever, daemon=True).start()

import tempfile
downloads = tempfile.mkdtemp(prefix="wink-e2e-")  # traces land here, not in ~/Downloads
bridge = subprocess.Popen([os.path.join(APP, "Contents", "MacOS", "wink-mcp"), "--headless"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          env=dict(os.environ, WINK_DEBUG_DOWNLOADS=downloads))
counter = 0
failures = []


def rpc(method, params):
    global counter
    counter += 1
    bridge.stdin.write((json.dumps({"jsonrpc": "2.0", "id": counter, "method": method, "params": params}) + "\n").encode())
    bridge.stdin.flush()
    while True:
        line = bridge.stdout.readline()
        if not line:
            sys.exit("wink-mcp exited")
        message = json.loads(line)
        if message.get("id") == counter:
            return message


def tool(tool_name, **arguments):
    result = rpc("tools/call", {"name": tool_name, "arguments": arguments})["result"]
    return result.get("isError", False), "\n".join(c.get("text", "") for c in result["content"])


def check(label, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + label + ("" if condition else f"\n     {detail[:400]}"))
    if not condition:
        failures.append(label)


def ref(text, label):
    match = re.search(r'"' + re.escape(label) + r'[^"]*" \[ref=(e\d+)\]', text)
    if not match:
        raise SystemExit(f"no ref for {label!r} in:\n{text}")
    return match.group(1)


def export(name, *expect):
    error, text = tool("export_test", name=name, expect=list(expect))
    check(f"export {name}", not error and "```ts" in text, text)
    if EXPORTS and "```ts" in text:
        os.makedirs(EXPORTS, exist_ok=True)
        code = text.split("```ts")[1].split("```")[0]
        with open(os.path.join(EXPORTS, re.sub(r"[^a-z0-9]+", "-", name.lower()) + ".spec.ts"), "w") as f:
            f.write(code)


init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "wink-e2e", "version": "1"}})
check("handshake", init["result"]["serverInfo"]["name"] == "wink", init)
tools = [t["name"] for t in rpc("tools/list", {})["result"]["tools"]]
check("tools listed", {"click", "fill_form", "mock_network", "export_test", "trace"} <= set(tools), tools)

# A form whose API fails, then the same form with the API mocked.
tool("tab_open", url=BASE + "signup.html")
tool("trace", action="start")
_, snap = tool("snapshot")
fields = [{"ref": ref(snap, "Full name"), "value": "Ada Lovelace"}, {"ref": ref(snap, "Email"), "value": "ada@example.com"},
          {"ref": ref(snap, "Plan"), "value": "Pro"}, {"ref": ref(snap, "I accept the terms"), "value": "true"}]
error, text = tool("fill_form", fields=fields)
check("fill_form", not error and "Ada Lovelace" in text, text)
error, text = tool("click", text="Create account")
check("failing API shows an error", "Something went wrong" in text, text)
_, text = tool("console_logs", level="error")
check("console error", "Cannot read properties of undefined" in text, text)
_, text = tool("network_requests", url="api/v2/signup")
check("request in full", "404" in text and "Response body" in text, text)
export("signup shows an error", {"text": "Something went wrong"})
error, text = tool("trace", action="stop")
check("trace saved", not error and ".html" in text, text)
if not error:
    path = re.search(r"Saved (.*\.html)", text).group(1)
    check("trace has screenshots", "data:image/jpeg" in open(path).read(), path)
    os.remove(path)

tool("tab_open", url=BASE + "signup.html")
tool("mock_network", url="api/v2/signup", status=200, body='{"user":{"name":"Ada"}}')
_, snap = tool("snapshot")
tool("fill_form", fields=[{"ref": ref(snap, "Full name"), "value": "Ada Lovelace"}, {"ref": ref(snap, "Email"), "value": "ada@example.com"},
                          {"ref": ref(snap, "I accept the terms"), "value": "true"}])
_, text = tool("click", text="Create account")
check("mocked API", "Welcome, Ada!" in text, text)
export("mocked signup", {"text": "Welcome, Ada!"})

# A whole flow in one batch, by CSS selector and field label, no lookups.
tool("tab_open", url=BASE + "signup.html")
error, text = tool("batch", steps=[
    {"action": "type", "label": "Full name", "text": "Grace Hopper"},
    {"action": "type", "selector": "input[name=email]", "text": "grace@example.com"},
    {"action": "select_option", "label": "Plan", "value": "Team"},
    {"action": "click", "selector": "input[name=terms]"},
    {"action": "click", "text": "Create account"},
    {"action": "wait_for", "text": "Welcome"},
])
check("batch by selector and label", not error and "Welcome, Ada!" in text, text)

# Offline and back.
tool("tab_open", url=BASE + "status.html")
tool("mock_network", offline=True)
_, text = tool("click", text="Refresh")
check("offline", "You are offline" in text, text)
tool("mock_network", offline=False)
_, text = tool("click", text="Refresh")
check("back online", "operational" in text, text)
export("offline then online", {"text": "All systems operational"})

# A list that re-renders: refs survive, changes are reported, not re-listed.
tool("tab_open", url=BASE + "todo.html")
_, found = tool("find", text="New todo")
box = ref(found, "New todo")
error, text = tool("batch", steps=[{"action": "type", "ref": box, "text": t, "submit": True} for t in ["buy milk", "write report", "call mom"]])
check("batch typing", not error and "3 items left" in text, text)
_, found = tool("find", text="write report", role="checkbox")
_, text = tool("click", ref=ref(found, "write report"))
check("state change reported", "[checked]" in text and "new:" not in text, text)
_, found = tool("find", text="Delete buy milk")
_, text = tool("click", ref=ref(found, "Delete buy milk"))
check("removal reported", "gone:" in text and "1 item left" in text, text)
tool("click", text="Active")
error, text = tool("verify", expect=[{"text": "1 item left"}])
check("verify", "1 of 1 passed" in text, text)
export("todo flow", {"text": "1 item left"})

# JavaScript dialogs wait for the agent.
tool("tab_open", url=BASE + "dialog.html")
_, text = tool("click", text="Delete Alpha")
check("confirm held for the agent", "confirm is open" in text, text)
_, text = tool("handle_dialog", accept=True)
check("confirm answered", "Alpha deleted" in text, text)
tool("click", text="Rename list")
_, text = tool("handle_dialog", accept=True, prompt_text="Groceries")
check("prompt answered", "Groceries" in text, text)
export("dialogs", {"text": "Alpha deleted"}, {"text": "Groceries"})

# Drag and drop, both kinds.
tool("tab_open", url=BASE + "dnd.html")
_, text = tool("drag", from_text="Write tests", to_text="Done")
check("HTML5 drag and drop", "to Done" in text, text)
_, text = tool("drag", from_text="Volume knob", to_text="Rail end")
check("pointer drag", "Knob at" in text and "Knob at 20" not in text, text)
export("board", {"text": "Moved"})

# Storage on localhost shows values.
tool("tab_open", url=BASE + "prefs.html")
_, found = tool("find", text="Dark theme")
tool("click", ref=ref(found, "Dark theme"))
_, text = tool("storage")
check("storage", 'theme = "dark"' in text and "seen" in text, text)

bridge.stdin.close()
bridge.wait(timeout=30)
server.shutdown()
print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
