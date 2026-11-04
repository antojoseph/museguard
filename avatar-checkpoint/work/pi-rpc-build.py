import subprocess,json,threading,time,sys
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an')
queue=root/'work/pi-steering.jsonl';queue.write_text('')
p=subprocess.Popen(['/Users/x/.local/bin/pi','--session',str(root/'work/plush-pi-session.jsonl'),'--thinking','xhigh','--mode','rpc'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lock=threading.Lock()
def send(d):
 with lock:p.stdin.write(json.dumps(d)+'\n');p.stdin.flush()
def follow():
 with queue.open() as f:
  while p.poll() is None:
   line=f.readline()
   if not line:time.sleep(.3);continue
   try:send(json.loads(line))
   except Exception as e:print(type(e).__name__,flush=True)
threading.Thread(target=follow,daemon=True).start()
send({'type':'prompt','message':Path(sys.argv[1]).read_text()})
for line in p.stdout:
 try:d=json.loads(line)
 except:continue
 t=d.get('type')
 if t=='tool_execution_start':print('TOOL START',d.get('toolName'),flush=True)
 elif t=='tool_execution_end':
  r=d.get('result',{});print('TOOL END',json.dumps({'content':[b for b in r.get('content',[]) if b.get('type')=='text']})[:2000],flush=True)
 elif t=='message_end':
  m=d.get('message',{})
  if m.get('role')=='assistant':
   for b in m.get('content',[]):
    if b.get('type')=='text':print(b.get('text'),flush=True)
   if m.get('errorMessage'):print('ERROR',m['errorMessage'],flush=True)
 elif t=='response' and not d.get('success',True):print('RPC ERROR',d,flush=True)
 elif t=='agent_settled':print('PI IDLE',flush=True)
