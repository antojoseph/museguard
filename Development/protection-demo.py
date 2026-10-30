#!/usr/bin/env python3
"""Loopback-only, disposable protection fixtures. No submitted body is retained."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

HTML = '''<!doctype html><html><head><meta charset="utf-8"><title>Muse protection test</title>
<style>body{font:17px system-ui;max-width:850px;margin:70px auto;padding:20px;color:#182234;background:#f3f6fa}section{background:white;border-radius:18px;padding:25px;margin:24px 0}a,button{margin:8px 15px 8px 0}textarea{display:block;width:95%;height:95px;margin:15px 0;padding:12px;font:16px system-ui}code{overflow-wrap:anywhere}footer{height:800px}</style></head>
<body><h1>Muse protection test</h1><p>Harmless local simulation. All values and files are disposable test fixtures.</p>
<section><h2>Secret paste</h2><p>Use the public BIP39 test phrase: eleven copies of <code>abandon</code>, followed by <code>about</code>. This is not a real wallet.</p><button id="copy-test" type="button">Copy public test phrase</button><form action="/submitted" method="post"><label for="secret">Test message</label><textarea id="secret" name="test" placeholder="Paste the public test phrase here"></textarea><button>Send test message</button></form><p id="events">Page paste events: 0 · submitted: no</p></section>
<section><h2>Downloads</h2><a href="/files/muse-benign.txt">Download ordinary text</a><a href="/files/invoice.pdf.command">Download suspicious filename</a><a href="/files/muse-eicar-test.txt">Download harmless antivirus test</a><p>Files are never executed. Chrome may independently stop the antivirus test; keep its own protection enabled.</p></section>
<section><h2>Pointer freshness</h2><p>After Muse points at the input, scroll, resize or switch tabs. The outline must disappear; the warning remains until Got it.</p><a href="/ordinary">Open ordinary reference</a></section><footer></footer>
<script>document.getElementById("copy-test").addEventListener("click",()=>navigator.clipboard.writeText(Array(11).fill("abandon").concat("about").join(" ")));let events=0;document.addEventListener('paste',()=>{document.getElementById('events').textContent='Page paste events: '+(++events)+' · submitted: no'});document.querySelector('form').addEventListener('submit',event=>{event.preventDefault();document.getElementById('events').textContent='Page paste events: '+events+' · submitted: yes';fetch('/submitted',{method:'POST',body:'synthetic-event-only'})});</script></body></html>'''
COUNTERS = {'submitted': 0, 'downloads': 0}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == '/metrics':
            data = json.dumps(COUNTERS).encode(); content='application/json'; name=None
        elif self.path.startswith('/files/'):
            name=self.path.rsplit('/',1)[-1]
            if name == 'muse-benign.txt': data=b'Ordinary harmless Muse download fixture.\n'
            elif name == 'invoice.pdf.command': data=b'#!/bin/sh\n# Harmless static test fixture. Never execute.\n'
            elif name == 'muse-eicar-test.txt': data=b'X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
            else: self.send_error(404); return
            COUNTERS['downloads']+=1;content='application/octet-stream'
        else:
            data=HTML.encode();content='text/html; charset=utf-8';name=None
        self.send_response(200); self.send_header('Content-Type',content);self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store')
        if name: self.send_header('Content-Disposition',f'attachment; filename="{name}"')
        self.end_headers();self.wfile.write(data)
    def do_POST(self):
        count=min(int(self.headers.get('Content-Length','0')),4096)
        self.rfile.read(count) # Drop bytes immediately; do not log fields or body.
        COUNTERS['submitted']+=1;self.send_response(204);self.end_headers()
if __name__ == '__main__': ThreadingHTTPServer(('127.0.0.1',8767),Handler).serve_forever()
