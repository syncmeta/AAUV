#!/usr/bin/python3
import json,sys,threading,time
inp,out=sys.stdin.buffer,sys.stdout.buffer
lock=threading.Lock()
names=[];session=None;model='';pending=None;results=set();round_two=False
args={
 'search_chat_history':{'query':'fixture','since':None,'until':None,'limit':10},
 'create_skill':{'name':'fixture-skill','description':'fixture','body':'synthetic'},
 'read_attachment':{'attachment_id':'11111111','question':'fixture'},
 'send_images':{'images':['https://example.invalid/synthetic.png']},
 'delegate_to_specialist':{'model_slug':'fixture','prompt':'synthetic'}
}
def emit(value):
 data=json.dumps(value,separators=(',',':')).encode()
 with lock:out.write(('Content-Length: %d\r\n\r\n'%len(data)).encode()+data);out.flush()
def reply(call,value):emit({'jsonrpc':'2.0','id':call['id'],'result':value})
def event(kind,data,key):emit({'jsonrpc':'2.0','method':'session.event','params':{'sessionId':session,'event':{'id':key,'timestamp':'2026-11-05T00:00:00Z','type':kind,'data':data}}})
def tool(name,key):event('external_tool.requested',{'requestId':key,'sessionId':session,'toolCallId':'tc-'+key,'toolName':name,'arguments':args[name]},'event-'+key)
def finish(text='tools complete',aborted=False,no_message=False):
 event('session.idle',{},'idle')
 response={'id':'assistant','timestamp':'2026-11-05T00:00:00Z','type':'assistant.message','data':{'messageId':'reply','content':text,'toolRequests':[]}}
 reply(pending,{'response':None if no_message else response,'completionEventId':'idle','aborted':aborted})
def cancel_tool():
 time.sleep(.2);event('external_tool.completed',{'requestId':'cancel-tool'},'cancelled');time.sleep(.05);finish('cancel complete')
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
  session=p['sessionId'];model=p['model'];names=[t['name'] for t in p['tools']]
  assert p['availableTools']==['custom:'+n for n in names] and set(names)==set(args)
  assert all(t.get('skipPermission') is True and t.get('defer')=='never' for t in p['tools'])
  assert p['enableConfigDiscovery'] is False and p['enableSkills'] is False and p['enableFileHooks'] is False
  reply(call,{'sessionId':session})
 elif method=='session.options.update':assert p['installedPlugins']==[];reply(call,{})
 elif method=='session.tools.getCurrentMetadata':reply(call,{'tools':[{'name':n,'description':'fixture','input_schema':{'type':'object'},'deferLoading':False} for n in names]})
 elif method=='session.sendAndWait':
  pending=call
  if model=='ordinary-empty':finish('')
  elif model.startswith('image-'):tool('send_images','image-final')
  elif model in ('swift-parent-cancel','swift-error','swift-stale'):tool('delegate_to_specialist','single')
  elif model=='swift-cancel-tool':tool('read_attachment','cancel-tool');threading.Thread(target=cancel_tool,daemon=True).start()
  else:
   for n in names:tool(n,n)
 elif method=='session.tools.handlePendingToolCall':
  key=p['requestId'];assert key not in results;results.add(key)
  if model.startswith('image-'):
   assert p['result']['resultType']=='success' and json.loads(p['result']['textResultForLlm'])['sent']==1
   reply(call,{'success':True})
   if model=='image-eof':sys.exit(0)
   finish('',aborted=model=='image-cancelled',no_message=model=='image-no-message')
   continue
  elif model=='swift-error':assert p['result']['resultType']=='failure' and p['result']['error']=='failed' and 'PRIVATE' not in p['result']['textResultForLlm']
  else:assert p['result']['resultType']=='success' and p['result']['textResultForLlm']=='synthetic-result'
  reply(call,{'success':True})
  if model=='swift-error':finish('error handled')
  elif len(results)==len(names) and not round_two:round_two=True;tool('search_chat_history','second-round')
  elif round_two and 'second-round' in results:finish()
 else:reply(call,{})
