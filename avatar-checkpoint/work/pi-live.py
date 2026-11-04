from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import json
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an')
page='''<!doctype html><meta charset="utf-8"><title>Pi · Live Blender build</title><style>body{background:#101419;color:#e8edf2;font:15px system-ui;margin:32px}header{display:flex;gap:24px;align-items:center}h1{margin:0}small{color:#9cabb8}img{width:380px;border-radius:12px}article{border:1px solid #33404d;border-radius:12px;margin:16px 0;padding:18px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px monospace;color:#bfe3ca}aside{position:fixed;right:24px;top:110px;width:380px}main{margin-right:420px}.status{color:#b4e5bd}</style><header><h1>Pi → Muse Spark → Blender</h1><span class="status">● Live activity</span></header><p><small>Watch Blender alongside this window. Completed tool calls and results appear automatically. Reasoning is hidden.</small></p><aside><img src="/reference"><p>Target: cream plush mascot</p></aside><main id="events"></main><script>let last='';async function refresh(){try{let r=await fetch('/events');let t=await r.text();if(t!==last){last=t;let es=JSON.parse(t);let box=document.getElementById('events');box.replaceChildren();for(let e of es){let a=document.createElement('article');let h=document.createElement('strong');h.textContent=e.title;a.append(h);let p=document.createElement('pre');p.textContent=e.text;a.append(p);box.append(a)}}}catch(e){}}setInterval(refresh,1200);refresh();</script>'''
class H(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  if self.path=='/reference':data=(root/'outputs/plush-character/reference.png').read_bytes();mime='image/png'
  elif self.path=='/events':
   es=[];p=root/'work/plush-pi-session.jsonl'
   if p.exists():
    for line in p.read_text().splitlines():
     try:d=json.loads(line)
     except:continue
     m=d.get('message',{});role=m.get('role')
     if role=='assistant':
      for b in m.get('content',[]):
       if b.get('type')=='toolCall':es.append({'title':'Pi calls '+b.get('name','tool'),'text':json.dumps(b.get('arguments',{}),indent=2)})
       elif b.get('type')=='text':es.append({'title':'Pi','text':b.get('text','')})
     elif role=='toolResult':es.append({'title':'Blender result · '+m.get('toolName','tool'),'text':'\n'.join(b.get('text','') for b in m.get('content',[]) if b.get('type')=='text')[:7000]})
   data=json.dumps(es[-30:]).encode();mime='application/json'
  elif self.path=='/':data=page.encode();mime='text/html'
  else:self.send_error(404);return
  self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
ThreadingHTTPServer(('127.0.0.1',8768),H).serve_forever()
