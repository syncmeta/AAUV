"""Loopback-only WebSocket peer for the native RealtimeVoice wire regression."""
from base64 import b64encode
from hashlib import sha1
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading
import traceback


failures = []
completed = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def exact(self, count):
        data = self.rfile.read(count)
        if len(data) != count:
            raise EOFError("Synthetic WebSocket peer closed early")
        return data

    def send_frame(self, payload, opcode=1):
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([length])
        elif length < 65536:
            header += bytes([126]) + struct.pack("!H", length)
        else:
            header += bytes([127]) + struct.pack("!Q", length)
        self.wfile.write(header + payload)
        self.wfile.flush()

    def emit(self, value):
        self.send_frame(json.dumps(value, separators=(",", ":")).encode())

    def receive(self):
        collected = bytearray()
        started = False
        while True:
            first, second = self.exact(2)
            assert not first & 0x70, "Extensions are not negotiated"
            final, opcode = bool(first & 0x80), first & 0x0F
            assert second & 0x80, "Client frames must be masked"
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self.exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.exact(8))[0]
            assert length <= 1024 * 1024 and len(collected) + length <= 1024 * 1024
            mask = self.exact(4)
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(self.exact(length)))
            if opcode == 9:
                assert final and length <= 125
                self.send_frame(payload, opcode=10)
                continue
            if opcode == 10:
                continue
            if opcode == 8:
                self.send_frame(payload, opcode=8)
                raise EOFError("Client closed before expected event")
            assert opcode == (0 if started else 1)
            started = True
            collected.extend(payload)
            if final:
                return json.loads(collected.decode("utf-8"))

    def do_GET(self):
        try:
            self.connection.settimeout(8)
            assert self.path == "/v1/realtime?model=test-model"
            assert self.headers.get("Authorization") == "Bearer fixture-key"
            assert self.headers.get("Upgrade", "").lower() == "websocket"
            assert self.headers.get("Sec-WebSocket-Version") == "13"
            key = self.headers["Sec-WebSocket-Key"]
            accept = b64encode(sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            update = self.receive()
            assert update["type"] == "session.update"
            session = update["session"]
            assert session["type"] == "realtime" and session["instructions"] == "Local prompt"
            assert session["tool_choice"] == "auto" and session["output_modalities"] == ["audio"]
            assert [tool["name"] for tool in session["tools"]] == ["hang_up"]
            function = session["tools"][0]
            assert function["type"] == "function" and function["parameters"]["type"] == "object"
            assert function["parameters"]["properties"] == {} and function["parameters"]["additionalProperties"] is False
            assert session["audio"]["input"]["format"] == {"type": "audio/pcm", "rate": 24000}
            self.emit({"type": "session.created", "session": {"id": "synthetic-session"}})
            self.emit({"type": "session.updated", "session": {"id": "synthetic-session"}})
            history = self.receive()
            assert history == {"type": "conversation.item.create", "item": {
                "type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Previous reply"}]}}
            capture = self.receive()
            assert capture == {"type": "input_audio_buffer.append", "audio": "AAABAA=="}
            self.emit({"type": "response.output_audio.delta", "item_id": "wire-item", "content_index": 0,
                       "delta": b64encode(bytes([1, 0, 255, 255])).decode()})
            truncate = self.receive()
            assert truncate == {"type": "conversation.item.truncate", "item_id": "wire-item", "content_index": 0,
                                "audio_end_ms": 1250}
            self.emit({"type": "response.done", "response": {"id": "synthetic-response", "status": "cancelled", "output": [],
                       "usage": {"input_tokens": 12, "output_tokens": 3, "total_tokens": 15}}})
            self.emit({"type": "error", "error": {"message": "Synthetic fixture-key error detail"}})
            completed.append(True)
        except Exception:
            failures.append(traceback.format_exc())
        finally:
            self.close_connection = True


with TemporaryDirectory(prefix="aauv-realtime-wire-") as temporary, ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {"PATH": os.defpath, "HOME": temporary, "TMPDIR": temporary,
           "AAUV_VOICE_FIXTURE_PORT": str(server.server_port)}
    child = subprocess.run([str(Path(sys.argv[1]).resolve())], env=env, timeout=25)
    server.shutdown()
    assert not failures, failures
    assert child.returncode == 0 and completed == [True], (child.returncode, completed)
    print("Realtime loopback WebSocket verified the fixed hang_up schema, configure handshake, history, PCM bytes, truncation, usage and error redaction without microphone or provider access.")
