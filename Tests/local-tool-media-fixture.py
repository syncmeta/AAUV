"""Synthetic loopback HTTP peer for LocalToolMediaIntegrationTests; no provider access."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import json
import re
import subprocess
import sys
import threading
import traceback

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="
counts = {"parent": 0, "read": 0, "delegate": 0, "override": 0}
failures = []
lock = threading.Lock()


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def text_of(item):
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    return "".join(part.get("text", "") for part in content if part.get("type") in ("input_text", "text"))


def metadata(instructions, name):
    match = re.search(rf"<{name}>\s*(.*?)\s*</{name}>", instructions, re.S)
    assert match, name
    return json.loads(match.group(1))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_events(self, events):
        body = "".join("data: " + encode(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def response(self, text, calls=()):
        output = [{"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                   "content": [{"type": "output_text", "text": text, "annotations": []}]}]
        for index, (call_id, name, args) in enumerate(calls):
            output.append({"type": "function_call", "id": f"fc_{index}", "call_id": call_id,
                           "name": name, "arguments": encode(args), "status": "completed"})
        self.send_events([{"type": "response.output_text.delta", "delta": text},
                          {"type": "response.completed", "response": {"status": "completed", "output": output}}])

    def do_POST(self):
        try:
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            payload = json.loads(raw)
            if self.path == "/other/v1/chat/completions":
                assert self.headers.get("Authorization") == "Bearer media-child-key"
                assert payload["model"] == "media-child"
                assert payload["messages"] == [{"role": "user", "content": "DELEGATE_STANDALONE_ONLY"}]
                assert not payload.get("tools")
                assert b"PARENT_" not in raw and b"TARGET_PROFILE_PRIVATE" not in raw
                with lock:
                    counts["delegate"] += 1
                body = encode({"choices": [{"message": {"role": "assistant", "content": "SPECIALIST_CROSS_ENDPOINT_ANSWER"},
                                             "finish_reason": "stop"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                return
            assert self.path == "/parent/v1/responses", self.path
            assert self.headers.get("Authorization") == "Bearer media-parent-key"
            items = payload["input"]
            if payload["model"] == "media-override":
                assert len(items) == 1 and text_of(items[0]) == "OVERRIDE_STANDALONE_ONLY"
                assert not payload.get("instructions") and not payload.get("tools")
                assert b"PARENT_" not in raw and b"attachment_metadata" not in raw
                with lock:
                    counts["override"] += 1
                self.response("OVERRIDE_ONLY_ANSWER")
                return
            assert payload["model"] == "media-parent"
            if not payload.get("instructions"):
                assert len(items) == 1 and text_of(items[0]) == "ATTACHMENT_QUESTION_ONLY"
                assert not payload.get("tools") and b"PARENT_" not in raw
                files = [part for part in items[0]["content"] if part.get("type") == "input_file"]
                assert len(files) == 1 and files[0]["filename"] == "fixture-source.txt"
                assert base64.b64decode(files[0]["file_data"].split(",", 1)[1]) == b"FILE_CONTENT_SYNTHETIC_ONLY"
                with lock:
                    counts["read"] += 1
                self.response("ATTACHMENT_NATIVE_ANSWER")
                return
            assert "PARENT_SYSTEM_PRIVATE" in payload["instructions"] and b"FOREIGN_PRIVATE" not in raw
            assert {tool.get("name") for tool in payload["tools"] if tool["type"] == "function"} == {
                "search_chat_history", "create_skill", "read_attachment", "delegate_to_specialist", "send_images"}
            assert any(tool["type"] == "web_search" for tool in payload["tools"])
            outputs = [item for item in items if item.get("type") == "function_call_output"]
            with lock:
                counts["parent"] += 1
            if not outputs:
                assert [text_of(item) for item in items] == ["PARENT_HISTORY_PRIVATE", "PARENT_OLD_REPLY_PRIVATE", "PARENT_CURRENT_MAIN"]
                inventory = metadata(payload["instructions"], "aauv_attachment_metadata")
                assert len(inventory) == 1 and inventory[0]["name"] == "fixture-source.txt"
                delegates = metadata(payload["instructions"], "aauv_delegation_metadata")
                target = next(item["model_slug"] for item in delegates if item["model"] == "media-child")
                assert target.startswith("bot:")
                self.response("MEDIA_TOOLS_START", [
                    ("media_read", "read_attachment", {"attachment_id": inventory[0]["attachment_id"], "question": "ATTACHMENT_QUESTION_ONLY"}),
                    ("media_delegate", "delegate_to_specialist", {"model_slug": target, "prompt": "DELEGATE_STANDALONE_ONLY"}),
                    ("media_images", "send_images", {"images": ["data:image/png;base64," + PNG]})])
            else:
                assert len(outputs) == 3
                result = {item["call_id"]: json.loads(item["output"]) for item in outputs}
                assert result["media_read"]["answer"] == "ATTACHMENT_NATIVE_ANSWER"
                assert result["media_delegate"]["answer"] == "SPECIALIST_CROSS_ENDPOINT_ANSWER"
                assert result["media_images"]["sent"] == 1
                self.response("MEDIA_TOOLS_COMPLETE")
        except Exception as error:
            failures.append(traceback.format_exc())
            self.send_error(500, "synthetic assertion failed")

    def do_GET(self):
        failures.append("Unexpected GET; images must use data URLs in this fixture")
        self.send_error(500)


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}"], check=True, timeout=25)
        assert not failures, failures
        assert counts == {"parent": 2, "read": 1, "delegate": 1, "override": 1}, counts
        print("Media HTTP fixture verified isolated read/override requests, configured cross-endpoint delegation and one final media reply.")
    finally:
        server.shutdown()
        worker.join()
        if failures:
            print("\n".join(failures), file=sys.stderr)
