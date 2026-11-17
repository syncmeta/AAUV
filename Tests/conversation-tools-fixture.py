"""Loopback-only Responses peer for ConversationLocalToolsTests.

No provider, credentials, proxy core or production database is used. The optional
second argument is an evidence JSON destination; normal test runners need only
pass the compiled Swift executable.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import sys
import threading

INTEGER = b'9007199254740993'
DECIMAL = b'0.123456789012345678901234567890123456789'
TEXTS = ['已检索', '已创建', '再次检索', '全部完成']
CALLS = [
    ('call_search_first', 'search_chat_history', {'query': 'needle', 'since': None, 'until': None, 'limit': 10}),
    ('call_create', 'create_skill', {'name': 'fixture-conversation-skill', 'description': 'Fixture description', 'body': 'SKILL_BODY_FIXTURE'}),
    ('call_search_second', 'search_chat_history', {'query': 'needle', 'since': None, 'until': None, 'limit': 10}),
]
requests = []
failures = []


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def output_for(round_number):
    # Construct opaque numbers as JSON tokens, not Python floats. Every next
    # request must retain the full integer and fractional digits exactly.
    reasoning = (b'{"type":"reasoning","id":"rs_' + str(round_number).encode() +
                 b'","summary":[],"encrypted_content":"opaque_round_' + str(round_number).encode() +
                 b'","precise_integer":' + INTEGER + b',"precise_decimal":' + DECIMAL + b'}')
    message = encoded({'type': 'message', 'id': f'msg_{round_number}', 'role': 'assistant',
                       'phase': 'commentary' if round_number < 3 else 'final_answer',
                       'content': [{'type': 'output_text', 'text': TEXTS[round_number], 'annotations': []}]})
    items = [reasoning, message]
    if round_number < 3:
        call_id, name, arguments = CALLS[round_number]
        items.append(encoded({'type': 'function_call', 'id': f'fc_{round_number}', 'call_id': call_id,
                              'name': name, 'arguments': encoded(arguments).decode(), 'status': 'completed'}))
    return b'[' + b','.join(items) + b']'


def verify_request(raw, body, round_number):
    assert body['model'] == 'fixture-model'
    assert body['store'] is False and body['stream'] is True
    assert 'previous_response_id' not in body
    assert body['instructions'].count('GLOBAL_PROMPT_ONCE') == 1
    assert 'SKILL_BODY_FIXTURE' not in body['instructions'], 'New skill must start with the next user request'
    assert body['include'] == ['reasoning.encrypted_content']
    definitions = body['tools']
    assert all(tool['type'] == 'function' and tool['strict'] is True for tool in definitions)
    names = {tool['name'] for tool in definitions}
    assert {'search_chat_history', 'create_skill'} <= names <= {
        'search_chat_history', 'create_skill', 'read_attachment', 'send_images', 'delegate_to_specialist'}
    assert len(names) == len(definitions)
    items = body['input']
    assert len(items) == 3 + round_number * 4
    assert items[0]['content'] == 'needle CURRENT_CONVERSATION_ONLY'
    assert items[1]['content'] == '先前回复' and items[2]['content'] == '请完成测试工具循环。'
    assert b'OTHER_CONVERSATION_PRIVATE' not in raw
    assert raw.count(INTEGER) == round_number, 'Opaque integer was rounded, omitted or duplicated'
    assert raw.count(DECIMAL) == round_number, 'Opaque decimal was rounded, omitted or duplicated'
    outputs = [item for item in items if item.get('type') == 'function_call_output']
    assert len(outputs) == round_number
    for previous in range(round_number):
        reasoning = items[3 + previous * 4]
        message = items[4 + previous * 4]
        call = items[5 + previous * 4]
        result = items[6 + previous * 4]
        expected_id, expected_name, _ = CALLS[previous]
        assert reasoning['type'] == 'reasoning' and reasoning['encrypted_content'] == f'opaque_round_{previous}'
        assert message['phase'] == 'commentary' and message['role'] == 'assistant'
        assert call['type'] == 'function_call' and call['call_id'] == expected_id and call['name'] == expected_name
        assert result['type'] == 'function_call_output' and result['call_id'] == expected_id
        decoded = json.loads(result['output'])
        assert 'error' not in decoded, (previous, decoded)
        if expected_name == 'search_chat_history':
            assert len(decoded['results']) == 1, decoded
            assert decoded['results'][0]['content'] == 'needle CURRENT_CONVERSATION_ONLY'
            assert decoded['results'][0]['speaker'] == 'them'
            assert isinstance(decoded['results'][0]['when'], str)
        else:
            assert decoded['name'] == 'fixture-conversation-skill' and decoded['subscribed'] is True
            assert re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', decoded['skill_id'])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            assert self.path == '/four-rounds/v1/responses', self.path
            assert self.headers.get('Authorization') == 'Bearer local-tools-fixture-key'
            count = int(self.headers['Content-Length'])
            assert 0 < count <= 1024 * 1024
            raw = self.rfile.read(count)
            body = json.loads(raw)
            round_number = len(requests)
            assert round_number < 4, 'Unexpected fifth HTTP request'
            verify_request(raw, body, round_number)
            requests.append({'round': round_number, 'bytes': count, 'opaque_history_items': round_number,
                             'function_results': round_number})
            delta = b'data: ' + encoded({'type': 'response.output_text.delta', 'delta': TEXTS[round_number]}) + b'\r\n\r\n'
            terminal = (b'data: {"type":"response.completed","response":{"id":"resp_' +
                        str(round_number).encode() + b'","status":"completed","output":' + output_for(round_number) + b'}}\r\n\r\n')
            payload = delta + terminal
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            # Split even inside UTF-8 scalars and JSON tokens to exercise the
            # real URLSession byte stream and the shared SSE parser.
            for start in range(0, len(payload), 7):
                self.wfile.write(payload[start:start + 7])
                self.wfile.flush()
        except Exception as error:
            failures.append(f'{type(error).__name__}: {error}')
            try:
                payload = encoded({'error': {'code': 'fixture_assertion', 'message': 'Synthetic fixture assertion failed'}})
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except OSError:
                pass


with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    child = subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}'], timeout=40)
    server.shutdown()
    assert not failures, failures
    assert child.returncode == 0, {'exit': child.returncode, 'validated_rounds': len(requests)}
    assert len(requests) == 4, requests
    evidence = {'status': 'passed', 'scope': 'loopback HTTP + ModelSession + ChatClient + temporary SQLite',
                'rounds': requests, 'opaque_integer': INTEGER.decode(), 'opaque_decimal': DECIMAL.decode(),
                'call_order': [item[1] for item in CALLS], 'child_exit': child.returncode}
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    print('Conversation tool HTTP fixture: four rounds preserved opaque reasoning/phase/numbers and current-conversation-only results.')
