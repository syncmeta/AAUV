import base64
import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="


class ModelHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/responses"
        assert self.headers["Authorization"] == "Bearer fixture-key"
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert payload["tools"] == [{"type": "image_generation", "output_format": "png"}]
        assert payload["store"] is False and payload["stream"] is True
        output = [{"type": "image_generation_call", "status": "completed", "output_format": "png", "result": PNG}]
        if payload["model"] == "fixture-mixed-images":
            output += [
                {"type": "image_generation_call", "result": "invalid-base64"},
                {"type": "image_generation_call", "result": base64.b64encode(b"not an image").decode()},
                {"type": "message", "content": [{"type": "output_text", "text": "Picture and file", "annotations": [
                    {"type": "container_file_citation", "container_id": "cntr_fixture", "file_id": "file_fixture", "filename": "data.bin"}
                ]}]},
            ]
        events = [{"type": "response.image_generation_call." + stage, "item_id": "ig_fixture"}
                  for stage in ("in_progress", "generating", "completed")]
        if payload["model"] != "fixture-incomplete-image":
            events.append({"type": "response.completed", "response": {"status": "completed", "output": output}})
        else:
            events.append({"type": "response.output_item.done", "item": output[0]})
        body = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        assert self.path == "/v1/containers/cntr_fixture/files/file_fixture/content"
        assert self.headers["Authorization"] == "Bearer fixture-key"
        body = bytes([0, 255, 12])
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


with ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}/v1"], check=True, timeout=20)
    finally:
        server.shutdown()
        thread.join()
