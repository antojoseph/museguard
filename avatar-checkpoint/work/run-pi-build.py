import subprocess,json,sys
from pathlib import Path
prompt=Path(sys.argv[1]).read_text()
cmd=['/Users/x/.local/bin/pi','--session','/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/plush-pi-session.jsonl','--thinking','xhigh','--mode','json','@/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/reference.png',prompt]
p=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
for line in p.stdout:
 try:d=json.loads(line)
 except:continue
 t=d.get('type')
 if t=='tool_execution_start': print('TOOL START',d.get('toolName'),flush=True)
 elif t=='tool_execution_end':
  r=d.get('result',{})
  print('TOOL END','error='+str(d.get('isError')),json.dumps({'content':[b for b in r.get('content',[]) if b.get('type')=='text']})[:1800],flush=True)
 elif t=='message_end':
  m=d.get('message',{})
  if m.get('role')=='assistant':
   for b in m.get('content',[]):
    if b.get('type')=='text': print(b.get('text'),flush=True)
    elif b.get('type')=='toolCall':
     args=b.get('arguments',{})
     if isinstance(args,dict) and args.get('code'):Path('work/pi-last-code.py').write_text(args['code'])
   if m.get('errorMessage'):print('ERROR',m['errorMessage'],flush=True)
print('EXIT',p.wait(),flush=True)
e=p.stderr.read()
if e:print(e[-2000:])
