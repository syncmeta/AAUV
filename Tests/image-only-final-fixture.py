"""Synthetic loopback Responses peer for successful image-only final replies."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import sys
import threading

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="
counts = {}
failures = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            mode = self.path.split("/")[1]
            assert self.path == "/" + mode + "/v1/responses"
            assert self.headers.get("Authorization") == "Bearer synthetic-image-final-key"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body["model"] == mode
            count = counts.get(mode, 0)
            counts[mode] = count + 1
            output = []
            if count == 0 and mode != "ordinary":
                output = [{"type": "function_call", "id": "fc_image", "call_id": "call_image", "name": "send_images",
                           "arguments": json.dumps({"images": ["data:image/png;base64," + PNG]}), "status": "completed"}]
            elif count == 1:
                results = [item for item in body["input"] if item.get("type") == "function_call_output"]
                assert len(results) == 1 and json.loads(results[0]["output"])["sent"] == 1
            else:
                assert mode == "ordinary" and count == 0
            if count == 1 and mode == "missing":
                payload = b'data: {"type":"response.in_progress","response":{"status":"in_progress"}}\n\n'
            else:
                status = mode if count == 1 and mode in ("cancelled", "incomplete") else "completed"
                payload = ("data: " + json.dumps({"type": "response.completed", "response": {"status": status, "output": output}}) + "\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as error:
            failures.append(str(error))
            self.send_error(500)


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    before = "--before" in sys.argv[2:]
    child = subprocess.run([sys.argv[1], "http://127.0.0.1:" + str(server.server_port)] + (["--before"] if before else []), timeout=35)
    server.shutdown()
    assert not failures, failures
    assert child.returncode == (1 if before else 0), child.returncode
    expected = {"image": 2} if before else {"image": 2, "ordinary": 1, "missing": 2, "cancelled": 2, "incomplete": 2, "stale": 1}
    assert counts == expected, counts
    print("Image-only Responses HTTP " + ("before failure reproduced" if before else "success/negative terminal cases passed") + ": " + json.dumps(counts))
