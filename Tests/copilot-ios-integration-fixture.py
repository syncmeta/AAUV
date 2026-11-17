import base64
import json
import subprocess
import sys
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = Counter()
errors = []
release = threading.Event()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def route(self):
        scenario, host, tail = self.path.strip('/').split('/', 2)
        seen[(scenario, self.command, tail)] += 1
        expected = 'Bearer gho_SYNTHETIC_' + scenario + ('_RENEWED' if scenario == 'renewal' else '')
        if scenario == 'resume-rotation':
            assert self.headers['Authorization'] in [expected, expected + '_RENEWED']
        else:
            assert self.headers['Authorization'] == expected
        assert self.headers['User-Agent'] == ('AAUV' if tail == 'user' else 'AAUV/0.1')
        assert not any(any(x in h.lower() for x in ['editor', 'plugin', 'integration']) for h in self.headers)
        return scenario, host, tail

    def answer(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            scenario, host, tail = self.route()
            if tail == 'user':
                assert scenario in ['imported', 'legacy-nil-cid'] and host == 'api.github.com'
                return self.answer(200, {'id': 123, 'login': 'synthetic-user'})
            if tail == 'copilot_internal/user':
                assert host == 'api.github.com'
                return self.answer(200, {'login': 'synthetic-user', 'endpoints': {'api': 'https://api.individual.githubcopilot.com'}})
            assert tail == 'models' and host == 'api.individual.githubcopilot.com'
            model = {'id': 'model', 'name': 'Synthetic model', 'is_chat_default': True, 'policy': {'state': 'enabled'},
                     'capabilities': {'type': 'chat', 'supports': {'streaming': True, 'vision': True, 'tool_calls': True}},
                     'supported_endpoints': ['/responses', '/chat/completions']}
            if scenario == 'responses-no-tools':
                model['capabilities']['supports']['tool_calls'] = False
            models = [model]
            if scenario == 'chat':
                model['supported_endpoints'] = ['/chat/completions']
            if scenario == 'no-default':
                model['is_chat_default'] = False
            if scenario == 'real-default':
                model['id'] = 'catalog-default'
                models.append({**model, 'id': 'expensive-explicit', 'is_chat_default': False})
            if scenario == 'multiple-defaults':
                models.append({**model, 'id': 'second-default'})
            if scenario == 'disabled-default':
                model['policy'] = {'state': 'disabled'}
                models.append({**model, 'id': 'enabled-nondefault', 'policy': {'state': 'enabled'}, 'is_chat_default': False})
            if scenario == 'unknown-default':
                model.pop('supported_endpoints')
            if scenario == 'messages-only-default':
                model['supported_endpoints'] = ['/v1/messages']
            if scenario == 'disabled-explicit':
                models.append({**model, 'id': 'disabled', 'policy': {'state': 'disabled'}})
            self.answer(200, {'data': models})
        except Exception as error:
            errors.append(type(error).__name__)
            self.answer(500, {'error': 'synthetic_fixture_failure'})

    def do_POST(self):
        try:
            scenario, host, tail = self.route()
            raw = self.rfile.read(int(self.headers['Content-Length']))
            body = json.loads(raw)
            assert host == 'api.individual.githubcopilot.com'
            assert body['model'] == ('catalog-default' if scenario == 'real-default' else 'model')
            if scenario == 'chat':
                assert tail == 'chat/completions' and 'tools' not in body and 'input' not in body
                assert 'CONVERSATION_TOOL_INSTRUCTIONS' not in json.dumps(body)
                if body['messages'][-1]['content'] == 'SUMMARY_STANDALONE':
                    assert len(body['messages']) == 1
                return self.answer(200, {'choices': [{'finish_reason': 'stop', 'message': {'content': 'Synthetic chat'}}],
                                         'usage': {'prompt_tokens': 7, 'completion_tokens': 3}})
            assert tail == 'responses' and body['stream'] is True and body['store'] is False
            if scenario == 'responses-no-tools':
                assert 'tools' not in body and 'CONVERSATION_TOOL_INSTRUCTIONS' not in json.dumps(body)
            if scenario == 'forbidden':
                return self.answer(403, {'error': {'message': 'PRIVATE_SYNTHETIC_ERROR'}})
            user = next(i for i in body['input'] if i.get('role') == 'user')
            content = user['content']
            prompt = content if isinstance(content, str) else next(p['text'] for p in content if p['type'] == 'input_text')
            if prompt in ['TITLE_STANDALONE', 'READ_STANDALONE', 'DELEGATE_STANDALONE']:
                assert 'instructions' not in body and 'tools' not in body
                assert len(body['input']) == 1 and 'PARENT_HISTORY' not in json.dumps(body)
            if scenario == 'main' and prompt in ['PARENT_HISTORY', 'READ_STANDALONE']:
                file = next(p for p in content if p['type'] == 'input_file')
                assert base64.b64decode(file['file_data'].split(',', 1)[1]) == b'SYNTHETIC_ATTACHMENT'
            output = [{'type': 'message', 'id': 'msg_synthetic', 'role': 'assistant', 'status': 'completed',
                       'content': [{'type': 'output_text', 'text': 'Synthetic reply'}]}]
            events = [{'type': 'response.output_text.delta', 'delta': 'Synthetic reply'}]
            if scenario == 'vault-unrelated' and not any(i.get('type') == 'function_call_output' for i in body['input']):
                output = [{'type': 'function_call', 'id': 'fc_vault', 'call_id': 'call_vault', 'name': 'delegate_to_specialist',
                           'arguments': '{"model_slug":"synthetic-plan","prompt":"standalone"}', 'status': 'completed'}]
                events = []
            if scenario == 'main' and prompt == 'PARENT_HISTORY':
                outputs = [i for i in body['input'] if i.get('type') == 'function_call_output']
                if not outputs:
                    assert body['instructions'] == 'PARENT_INSTRUCTIONS\n\nCONVERSATION_TOOL_INSTRUCTIONS'
                    names = ['search_chat_history', 'create_skill', 'read_attachment', 'send_images', 'delegate_to_specialist']
                    assert {t['name'] for t in body['tools']} == set(names)
                    arguments = [{'query': 'synthetic', 'since': None, 'until': None, 'limit': 10},
                                 {'name': 'synthetic', 'description': 'synthetic', 'body': 'synthetic'},
                                 {'attachment_id': '11111111-1111-4111-8111-000000000001', 'question': 'read'},
                                 {'images': ['data:image/png;base64,iVBORw==']},
                                 {'model_slug': 'model', 'prompt': 'delegate'}]
                    output = [{'type': 'reasoning', 'encrypted_content': 'SYNTHETIC_OPAQUE', 'summary': [], 'large_integer': 9007199254740993}]
                    output += [{'type': 'function_call', 'id': 'fc_' + str(i), 'call_id': 'call_' + str(i), 'name': name,
                                'arguments': json.dumps(arguments[i]), 'status': 'completed'} for i, name in enumerate(names)]
                else:
                    assert len(outputs) == 5 and b'9007199254740993' in raw
                    output = []  # Successful image-only final after local files.
                events = []
            if scenario not in ['cancel', 'signout']:
                usage = {'provider_specific': True} if scenario == 'usage-unknown' else {'input_tokens': 10, 'output_tokens': 1}
                events.append({'type': 'response.completed', 'response': {'status': 'completed', 'output': output, 'usage': usage}})
            data = ''.join('data: ' + json.dumps(e, separators=(',', ':')) + '\n\n' for e in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data) + (100 if scenario in ['cancel', 'signout'] else 0)))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
            if scenario in ['cancel', 'signout']:
                release.wait(timeout=30)
                self.close_connection = True
        except Exception as error:
            errors.append(type(error).__name__)
            self.close_connection = True


with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([sys.argv[1], 'http://127.0.0.1:%d' % server.server_port], timeout=75)
        print(json.dumps({'observed': [{'scenario': k[0], 'method': k[1], 'path': k[2], 'count': v} for k, v in seen.items()], 'fixtureErrorCategories': errors}))
        assert result.returncode == 0 and not errors
        assert seen[('imported', 'GET', 'user')] == 1
        assert seen[('main', 'POST', 'responses')] == 5  # parent2 + child2 + independent title
        assert seen[('chat', 'POST', 'chat/completions')] == 3  # basic + ordinary default-tools CC + summary, not explicit tools
        assert seen[('responses-no-tools', 'POST', 'responses')] == 1
        for scenario in ['no-default', 'disabled-default', 'multiple-defaults', 'messages-only-default', 'unknown-default', 'disabled-explicit']:
            assert seen[(scenario, 'POST', 'responses')] == 0
        for action in ['token', 'subject', 'client', 'epoch', 'route', 'context', 'will-send']:
            assert seen[('stale-' + action, 'POST', 'responses')] == 0
        assert seen[('vault-unrelated', 'POST', 'responses')] == 2
        assert seen[('legacy-nil-cid', 'GET', 'user')] == 1 and seen[('legacy-nil-cid', 'POST', 'responses')] == 1
        assert seen[('stale-cid-appeared', 'POST', 'responses')] == 0
        assert not any(k[0] == 'legacy-expired' for k in seen)
        assert seen[('resume-rotation', 'POST', 'responses')] == 0, 'native refresh completed between fresh read and resume; stale token POST reached fixture'
        assert seen[('forbidden', 'POST', 'responses')] == 1 and seen[('forbidden', 'POST', 'chat/completions')] == 0
        print(json.dumps({'success': True, 'requestCount': sum(seen.values()), 'liveAccountUsed': False, 'mainChain': 'ModelSession iOS branch + CopilotSession + pinned PreviewSession'}))
    finally:
        release.set()
        server.shutdown()
