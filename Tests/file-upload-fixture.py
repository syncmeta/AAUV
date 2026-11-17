import base64
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import sys
import threading
import time

hits = {}


def check_inline_large(part):
    assert part['type'] == 'input_file' and part['filename'] == '测试".uncommon'
    media, encoded = part['file_data'].split(',', 1)
    assert media == 'data:application/octet-stream;base64'
    payload = base64.b64decode(encoded, validate=True)
    assert len(payload) == 11 * 1024 * 1024
    assert payload[:3] == bytes([0, 42, 255]) and payload[-2:] == bytes([255, 9])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def result(self, status, data, media='application/json'):
        if not isinstance(data, bytes):
            data = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', media)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        route, version, op = self.path.strip('/').split('/')
        assert version == 'v1' and self.headers['Authorization'] == 'Bearer fixture-key'
        count = int(self.headers['Content-Length'])
        data = self.rfile.read(count)
        log = hits.setdefault(route, [])
        if op == 'files':
            message = BytesParser(policy=policy.default).parsebytes(
                b'Content-Type: ' + self.headers['Content-Type'].encode() + b'\r\n\r\n' + data
            )
            parts = {p.get_param('name', header='content-disposition'): p for p in message.iter_parts()}
            assert parts['expires_after[anchor]'].get_payload(decode=True) == b'created_at'
            assert parts['expires_after[seconds]'].get_payload(decode=True) == b'3600'
            payload = parts['file'].get_payload(decode=True)
            if parts['file'].get_content_type() == 'image/png':
                assert parts['purpose'].get_payload(decode=True) == b'vision'
                assert payload == b'\x89PNG'
                log.append('upload-image')
                if route in ('mixed-tail', 'model-reject'):
                    return self.result(415, {'error':{'message':'Unsupported mock attachment'}})
                if route == 'rate-limit':
                    return self.result(429, {'error': {'code': 'rate_limit_exceeded', 'message': 'Fixture limit'}})
                return self.result(200, {'id':'file-image'})
            assert parts['purpose'].get_payload(decode=True) == b'user_data'
            assert parts['file'].get_content_type() == 'application/octet-stream'
            assert parts['file'].get_filename().endswith('_.uncommon')
            assert len(payload) == 11 * 1024 * 1024 and payload[:3] == bytes([0, 42, 255]) and payload[-2:] == bytes([255, 9])
            log.append('upload-large')
            if route == 'mixed-head':
                return self.result(422, {'error': {'code': 'unsupported_file_type'}})
            if route == 'expiry':
                return self.result(400, {'error': {'param': 'expires_after[anchor]'}})
            if route == 'missing-endpoint':
                return self.result(404, {'error': {'message': 'No Files endpoint'}})
            return self.result(200, {'id':'file-large'})
        assert op == 'responses'
        log.append('model')
        content = json.loads(data)['input'][-1]['content']
        inline_image = {'type': 'input_image', 'image_url': 'data:image/png;base64,iVBORw=='}
        uploaded_large = {'type': 'input_file', 'file_id': 'file-large'}
        uploaded_image = {'type': 'input_image', 'file_id': 'file-image', 'detail': 'auto'}
        if route == 'inline':
            assert content[1:] == [inline_image]
        elif route == 'mixed-head':
            check_inline_large(content[1])
            assert content[2:] == [uploaded_image]
        elif route in ('mixed-tail', 'model-reject'):
            assert content[1:] == [uploaded_large, inline_image]
        elif route in ('expiry', 'missing-endpoint'):
            check_inline_large(content[1])
            assert content[2:] == [inline_image]
        else:
            assert route != 'rate-limit'
            assert content[1:] == [uploaded_large, uploaded_image]
        if route == 'model-reject':
            return self.result(400, {'error': {'code': 'invalid_file_type', 'message': 'Fixture rejection'}})
        if route == 'cancel':
            delta = 'data: {"type":"response.output_text.delta","delta":"部分"}\n\n'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(delta) + 4096))
            self.end_headers()
            self.wfile.write(delta)
            self.wfile.flush()
            time.sleep(6)
            return
        payload = json.dumps({'type':'response.completed','response':{'status':'completed','output':[
            {'type':'message','content':[{'type':'output_text','text':'文件已接收'}]}
        ]}}, ensure_ascii=False)
        self.result(200, ('data: ' + payload + '\n\n').encode(), 'text/event-stream')
    def do_DELETE(self):
        route, version, files, identifier = self.path.strip('/').split('/')
        assert (version, files) == ('v1', 'files') and self.headers['Authorization'] == 'Bearer fixture-key'
        hits[route].append('delete-' + identifier)
        deleted = not (route == 'warn' and identifier == 'file-large')
        self.result(200, {'id':identifier, 'deleted':deleted})

with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}'], check=True, timeout=40)
    normal = ['upload-large', 'upload-image', 'model', 'delete-file-large', 'delete-file-image']
    assert hits == {'ok': normal, 'warn': normal, 'cancel': normal, 'inline': ['model'],
                    'mixed-head': ['upload-large', 'upload-image', 'model', 'delete-file-image'],
                    'mixed-tail': ['upload-large', 'upload-image', 'model', 'delete-file-large'],
                    'model-reject': ['upload-large', 'upload-image', 'model', 'delete-file-large'],
                    'expiry': ['upload-large', 'model'], 'missing-endpoint': ['upload-large', 'model'],
                    'rate-limit': ['upload-large', 'upload-image', 'delete-file-large'],
                    'guard-cleanup': ['upload-large', 'upload-image', 'model']}, hits
