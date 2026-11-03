#!/usr/bin/env python3
"""One-time: create a non-admin, local-only HA user for the widget, mint a
long-lived token for it and store it in the login Keychain (service
cloud.qoxi.netwidget, account ha). The token is never printed.

env: HA_URL (LAN), HA_MCP_URL (HA-MCP webhook, admin) to create the user; with
HA_CLOUD_URL set the user is not local-only, so the token also works via Nabu Casa."""
import json, os, secrets, subprocess, sys, urllib.parse, urllib.request
import websocket  # websocket-client

HA = os.environ["HA_URL"].rstrip("/")
MCP = os.environ["HA_MCP_URL"]
USERNAME, NAME = "netwidget", "NetWidget"
SERVICE = "cloud.qoxi.netwidget"


def mcp_ws(cmd, data=None):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "ha_call_service", "arguments": {"ws_command": cmd, **({"data": data} if data else {})}}}
    req = urllib.request.Request(MCP, json.dumps(body).encode(), {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    raw = urllib.request.urlopen(req, timeout=60).read().decode()
    msg = [json.loads(l[5:]) for l in raw.splitlines() if l.startswith("data:")][-1]
    res = json.loads("".join(c.get("text", "") for c in msg["result"]["content"]))
    if not res.get("success"):
        sys.exit(f"{cmd}: {res}")
    return res.get("result")


def post(path, payload, form=False):
    data = urllib.parse.urlencode(payload).encode() if form else json.dumps(payload).encode()
    ctype = "application/x-www-form-urlencoded" if form else "application/json"
    req = urllib.request.Request(HA + path, data, {"Content-Type": ctype})
    return json.loads(urllib.request.urlopen(req, timeout=30).read() or b"null")


if any(u.get("username") == USERNAME for u in mcp_ws("config/auth/list")):
    sys.exit(f"user {USERNAME} already exists; delete it in HA (Settings → People → Users) to re-run")

password = secrets.token_urlsafe(32)  # used once below, then forgotten
user = mcp_ws("config/auth/create", {"name": NAME, "group_ids": ["system-users"], "local_only": not os.environ.get("HA_CLOUD_URL")})["user"]
mcp_ws("config/auth_provider/homeassistant/create", {"user_id": user["id"], "username": USERNAME, "password": password})

client = HA + "/"
flow = post("/auth/login_flow", {"client_id": client, "handler": ["homeassistant", None], "redirect_uri": client})
done = post(f"/auth/login_flow/{flow['flow_id']}", {"client_id": client, "username": USERNAME, "password": password})
if done.get("type") != "create_entry":
    sys.exit(f"login failed: {done.get('errors')}")
tokens = post("/auth/token", {"grant_type": "authorization_code", "code": done["result"], "client_id": client}, form=True)

ws = websocket.create_connection(HA.replace("http", "ws", 1) + "/api/websocket", timeout=30)
ws.recv()
ws.send(json.dumps({"type": "auth", "access_token": tokens["access_token"]}))
assert json.loads(ws.recv())["type"] == "auth_ok"
ws.send(json.dumps({"id": 1, "type": "auth/long_lived_access_token", "client_name": "NetWidget (Mac)", "lifespan": 3650}))
res = json.loads(ws.recv())
ws.close()
if not res.get("success"):
    sys.exit(f"long_lived_access_token: {res}")

# the login session was only a means to mint the LLAT
post("/auth/revoke", {"token": tokens["refresh_token"]}, form=True)

# `security -i` reads the command from stdin, so the token never shows up in ps
cmd = f"add-generic-password -U -s {SERVICE} -a ha -l NetWidget -w {res['result']}\n"
subprocess.run(["/usr/bin/security", "-i"], input=cmd.encode(), check=True, capture_output=True)
print(f"user {USERNAME} ({user['id']}) created, token stored in Keychain service {SERVICE}")
