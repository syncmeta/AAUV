import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


release_connections = threading.Event()
slow_download_started = threading.Event()


class ModelHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        assert self.path == "/v1/responses"
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert payload["tools"] == [{"type": "web_search"}, {"type": "code_interpreter", "container": {"type": "auto"}}]
        events = [
            {"type": "response.web_search_call.in_progress", "item_id": "ws_one"},
            {"type": "response.web_search_call.searching", "item_id": "ws_two"},
            {"type": "response.code_interpreter_call.interpreting", "item_id": "ci_one"},
            {"type": "response.web_search_call.completed", "item_id": "ws_one"},
            {"type": "response.web_search_call.completed", "item_id": "ws_two"},
            {"type": "response.code_interpreter_call_code.delta", "item_id": "ci_one", "delta": "mock code"},
            {"type": "response.code_interpreter_call.completed", "item_id": "ci_one"},
            {"type": "response.output_text.delta", "delta": "完成"},
            {"type": "response.completed", "response": {"status": "completed", "output": []}},
        ]
        interrupted = payload["model"] == "fixture-interrupted"
        if interrupted:
            events.pop()
        if payload["model"] == "fixture-structured-error":
            events[-1] = {"type": "response.failed", "response": {
                "status": "failed",
                "error": {"code": "subscription_sharing_unsupported_capability", "param": "tools[0]", "message": "private fixture text"},
            }}
        if payload["model"] == "fixture-generated":
            files = [
                {"type": "container_file_citation", "container_id": "cntr_fixture", "file_id": file_id, "filename": name}
                for file_id, name in [("cfile_fast", "complete.bin"), ("cfile_slow", "waiting.bin")]
            ]
            events[-1]["response"]["output"] = [
                {"type": "message", "content": [{"type": "output_text", "text": "完成", "annotations": files}]}
            ]
        body = "".join(f"data: {json.dumps(event)}\n\n" for event in events).encode()
        # Keep successful streams open after their terminal event.
        trailing_bytes = 0 if interrupted else len(b"data: [DONE]\n\n")
        self.send_response(200)
        self.send_header("x-request-id", "req_fixture_response")
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body) + trailing_bytes))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        if not interrupted:
            release_connections.wait(timeout=15)
        self.close_connection = True

    def do_GET(self):
        if self.path == "/v1/fixture-download":
            body = b"1" if slow_download_started.is_set() else b"0"
        elif self.path == "/v1/containers/cntr_fixture/files/cfile_fast/content":
            assert self.headers["Authorization"] == "Bearer fixture-key"
            body = bytes([0, 255, 12])
        else:
            assert self.path == "/v1/containers/cntr_fixture/files/cfile_slow/content"
            assert self.headers["Authorization"] == "Bearer fixture-key"
            self.send_response(200)
            self.send_header("Content-Length", "16")
            self.end_headers()
            self.wfile.flush()
            slow_download_started.set()
            release_connections.wait(timeout=15)
            self.close_connection = True
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()


with ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}/v1"], check=True, timeout=8)
    finally:
        release_connections.set()
        server.shutdown()
        thread.join()
