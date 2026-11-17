#!/usr/bin/python3
"""Synthetic Copilot SDK RPC peer for terminal image-only replies; no provider."""
import json
import sys

inp, out = sys.stdin.buffer, sys.stdout.buffer
session = None
model = ""
pending = None
names = []
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="


def emit(value):
    body = json.dumps(value, separators=(",", ":")).encode()
    out.write(("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
    out.flush()


def reply(call, value):
    emit({"jsonrpc": "2.0", "id": call["id"], "result": value})


def event(kind, data, key):
    emit({"jsonrpc": "2.0", "method": "session.event", "params": {"sessionId": session, "event": {
        "id": key, "timestamp": "2026-11-06T00:00:00Z", "type": kind, "data": data}}})


def finish():
    if model == "image-eof":
        sys.exit(0)
    event("session.idle", {}, "idle")
    response = {"id": "assistant", "timestamp": "2026-11-06T00:00:00Z", "type": "assistant.message",
                "data": {"messageId": "reply", "content": "", "toolRequests": []}}
    reply(pending, {"response": None if model == "image-no-message" else response,
                    "completionEventId": "idle", "aborted": model == "image-cancelled"})


while True:
    headers = {}
    while True:
        line = inp.readline()
        if not line:
            sys.exit(0)
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    call = json.loads(inp.read(int(headers["content-length"])))
    if "id" not in call:
        continue
    method, params = call["method"], call.get("params", {})
    if method == "connect":
        reply(call, {"ok": True, "version": "synthetic", "protocolVersion": 3})
    elif method == "session.create":
        session, model = params["sessionId"], params["model"]
        names = [tool["name"] for tool in params.get("tools", [])]
        assert names in (["send_images"], ["search_chat_history"], [])
        assert params.get("availableTools", []) == ["custom:" + name for name in names]
        assert params["enableConfigDiscovery"] is False and params["enableSessionStore"] is False
        reply(call, {"sessionId": session})
    elif method == "session.options.update":
        assert params["installedPlugins"] == []
        reply(call, {})
    elif method == "session.tools.getCurrentMetadata":
        reply(call, {"tools": [{"name": name, "description": "synthetic", "input_schema": {"type": "object"},
                                "deferLoading": False} for name in names]})
    elif method == "session.sendAndWait":
        pending = call
        if model == "ordinary-empty":
            finish()
        else:
            name = names[0]
            arguments = {"images": ["data:image/png;base64," + PNG]} if name == "send_images" else {"probe": True}
            event("external_tool.requested", {"requestId": "image-request", "sessionId": session,
                                              "toolCallId": "image-call", "toolName": name,
                                              "arguments": arguments}, "tool")
    elif method == "session.tools.handlePendingToolCall":
        assert params["requestId"] == "image-request"
        assert params["result"]["resultType"] == "success"
        assert "sent" in json.loads(params["result"]["textResultForLlm"])
        reply(call, {"success": True})
        finish()
    else:
        reply(call, {})
