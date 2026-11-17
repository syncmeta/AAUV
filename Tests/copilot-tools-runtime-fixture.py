#!/usr/bin/python3
import json,sys
inp,out=sys.stdin.buffer,sys.stdout.buffer
names=['search_chat_history','create_skill','read_attachment','send_images','delegate_to_specialist']
session_id=None
pending=None
done=set()
permission=False
def emit(value):
    data=json.dumps(value,separators=(',',':')).encode()
    out.write(('Content-Length: %d\r\n\r\n'%len(data)).encode()+data);out.flush()
def reply(call,result):emit({'jsonrpc':'2.0','id':call['id'],'result':result})
def event(kind,data,key,agent=None):
    payload={'id':key,'timestamp':'2026-11-05T00:00:00Z','type':kind,'data':data}
    if agent is not None:payload['agentId']=agent
    emit({'jsonrpc':'2.0','method':'session.event','params':{'sessionId':session_id,'event':payload}})
def finish():
    global pending
    if pending and len(done)==5 and permission:
        event('session.idle',{},'idle-normal')
        reply(pending,{'response':{'id':'assistant','timestamp':'2026-11-05T00:00:00Z','type':'assistant.message','data':{'messageId':'reply','content':'done','toolRequests':[]}},'completionEventId':'idle-normal','aborted':False});pending=None
while True:
    headers={}
    while True:
        line=inp.readline()
        if not line:sys.exit(0)
        if line in (b'\r\n',b'\n'):break
        k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
    call=json.loads(inp.read(int(headers['content-length'])))
    if 'id' not in call:continue
    method,p=call['method'],call.get('params',{})
    if method=='connect':reply(call,{'ok':True,'version':'synthetic','protocolVersion':3})
    elif method=='session.create':
        assert p['availableTools']==['custom:'+n for n in names]
        assert [t['name'] for t in p['tools']]==names
        assert all(t.get('skipPermission') is True and t.get('defer')=='never' and not t.get('overridesBuiltInTool') and 'handler' not in t for t in p['tools'])
        for key in ['enableConfigDiscovery','enableFileHooks','enableHostGitOperations','enableSkills','enableSessionStore']:assert p[key] is False
        assert not p.get('mcpServers') and not p.get('pluginDirectories') and not p.get('hooks')
        session_id=p['sessionId'];reply(call,{'sessionId':session_id})
    elif method=='session.options.update':
        assert p['installedPlugins']==[] and p['includedBuiltinSkills']==[];reply(call,{})
    elif method=='session.tools.getCurrentMetadata':reply(call,{'tools':[{'name':n,'namespacedName':n,'description':'synthetic','input_schema':{'type':'object'},'deferLoading':False} for n in names]})
    elif method=='session.sendAndWait':
        if p['prompt']=='normal':
            pending=call
            for i,n in enumerate(names):event('external_tool.requested',{'requestId':'req-'+n,'sessionId':session_id,'toolCallId':'tc-'+n,'toolName':n,'arguments':{'probe':True}},'event-'+n)
            event('permission.requested',{'requestId':'denied-shell','permissionRequest':{'kind':'shell','fullCommandText':'DO_NOT_EXECUTE','intention':'synthetic rejection','commands':[],'possiblePaths':[],'possibleUrls':[],'canOfferSessionApproval':False,'hasWriteFileRedirection':False}},'permission')
        else:
            assert p['prompt']=='cancel'
            event('external_tool.requested',{'requestId':'blocked','sessionId':session_id,'toolCallId':'blocked-tc','toolName':names[0],'arguments':{'block':True}},'blocked')
    elif method=='session.tools.handlePendingToolCall':
        assert p['requestId'].startswith('req-')
        n=p['requestId'][4:];assert n in names and n not in done
        assert p['result']['textResultForLlm']=='synthetic-result' and p['result']['resultType']=='success'
        done.add(n);reply(call,{'success':True});finish()
    elif method=='session.permissions.handlePendingPermissionRequest':
        assert p['requestId']=='denied-shell' and p['result']['kind']=='reject'
        permission=True;reply(call,{'success':True});finish()
    elif method=='session.abort':
        event('external_tool.completed',{'requestId':'blocked'},'blocked-done');reply(call,{})
    else:reply(call,{})
