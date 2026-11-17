#!/usr/bin/python3
import json
import os
import sys

token = os.environ.get('COPILOT_SDK_AUTH_TOKEN')
inp, out = sys.stdin.buffer, sys.stdout.buffer
def emit(response):
    body = json.dumps(response, separators=(',', ':')).encode()
    out.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
    out.flush()


def event(event_id, kind, data):
    return {'id': event_id, 'timestamp': '2026-11-05T00:00:00Z', 'type': kind, 'data': data}


def notify(session_id, payload):
    emit({'jsonrpc': '2.0', 'method': 'session.event', 'params': {'sessionId': session_id, 'event': payload}})


while True:
    headers = {}
    while True:
        line = inp.readline()
        if not line:
            sys.exit(0)
        if line in (b'\r\n', b'\n'):
            break
        key, value = line.decode().split(':', 1)
        headers[key.lower()] = value.strip()
    call = json.loads(inp.read(int(headers['content-length'])))
    method, params = call.get('method'), call.get('params', {})
    if 'id' not in call:
        continue
    if method == 'connect':
        assert token in ('gho_catalog_fixture','gho_denied_fixture','gho_empty_fixture','gho_reply_fixture')
        result = {'ok': True, 'version': 'fixture', 'protocolVersion': 3}
    elif method == 'auth.getStatus':
        assert token != 'gho_reply_fixture'
        result = {'isAuthenticated': token != 'gho_denied_fixture'}
    elif method == 'models.list':
        assert token in ('gho_catalog_fixture','gho_empty_fixture')
        if token == 'gho_catalog_fixture':
            assert os.environ['HTTPS_PROXY'] == 'http://127.0.0.1:18888'
            result = {'models': [
                {'id':'fast','name':'Fast fixture','policy':{'state':'enabled'}},
                {'id':'restricted','name':'Restricted fixture','policy':{'state':'disabled'}},
                {'id':'default-name','name':'','capabilities':{}},
                {'id':'fast','name':'duplicate'},
                {'id':'','name':'invalid'}
            ]}
        else:
            result = {'models': []}
    elif method == 'session.create':
        assert token == 'gho_reply_fixture'
        assert params.get('availableTools') == [] and params.get('model') in (None, '')
        result = {'sessionId': params.get('sessionId', 'fixture')}
    elif method == 'session.tools.getCurrentMetadata':
        assert token == 'gho_reply_fixture'
        result = {'tools': []}
    elif method == 'session.sendAndWait':
        assert token == 'gho_reply_fixture'
        if params['prompt'] == '请读取附件':
            attachment, = params['attachments']
            assert attachment['type'] == 'blob'
            assert attachment['data'] == 'AP8='
            assert attachment['displayName'] == 'sample.bin'
            assert attachment['mimeType'] == 'application/octet-stream'
            reply = '附件已收到'
        elif params['prompt'] == '取消回复':
            notify(params['sessionId'], event('delta', 'assistant.message_delta',
                                             {'messageId': 'reply', 'deltaContent': '部分回复'}))
            continue
        else:
            assert params['prompt'] == '使用默认模型'
            reply = '默认模型已收到'
        notify(params['sessionId'], event('delta', 'assistant.message_delta',
                                         {'messageId': 'reply', 'deltaContent': reply}))
        notify(params['sessionId'], event('idle', 'session.idle', {}))
        result = {'response': event('reply', 'assistant.message',
                                    {'messageId': 'reply', 'content': reply, 'toolRequests': []}),
                  'completionEventId': 'idle', 'aborted': False}
    else:
        result = {}
    emit({'jsonrpc':'2.0','id':call['id'],'result':result})
