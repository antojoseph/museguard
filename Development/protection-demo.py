#!/usr/bin/env python3
"""Loopback-only, disposable protection fixtures. No submitted body is retained."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

HTML = '''<!doctype html><html><head><meta charset="utf-8"><title>Muse protection test</title>
<style>body{font:17px system-ui;max-width:850px;margin:70px auto;padding:20px;color:#182234;background:#f3f6fa}section{background:white;border-radius:18px;padding:25px;margin:24px 0}a,button{margin:8px 15px 8px 0}textarea{display:block;width:95%;height:95px;margin:15px 0;padding:12px;font:16px system-ui}code{overflow-wrap:anywhere}footer{height:800px}</style></head>
<body><h1>Muse protection test</h1><p>Harmless local simulation. All values and files are disposable test fixtures.</p>
<nav aria-label="Demo scenes"><a href="/guide">Customer guide</a><a href="/phishing">Staged sign-in</a></nav>
<section><h2>Secret paste</h2><p>Use the public BIP39 test phrase: eleven copies of <code>abandon</code>, followed by <code>about</code>. This is not a real wallet.</p><button id="copy-test" type="button">Copy public test phrase</button><form action="/submitted" method="post"><label for="secret">Test message</label><textarea id="secret" name="test" placeholder="Paste the public test phrase here"></textarea><button>Send test message</button></form><p id="events">Page paste events: 0 · submitted: no</p></section>
<section><h2>Downloads</h2><a href="/files/muse-benign.txt">Download ordinary text</a><a href="/files/invoice.pdf.command">Download suspicious filename</a><a href="/files/muse-eicar-test.txt">Download harmless antivirus test</a><p>Files are never executed. Chrome may independently stop the antivirus test; keep its own protection enabled.</p></section>
<section><h2>Pointer freshness</h2><p>After Muse points at the input, scroll, resize or switch tabs. The outline must disappear; the warning remains until Got it.</p><a href="/ordinary">Open ordinary reference</a></section><footer></footer>
<script>document.getElementById("copy-test").addEventListener("click",()=>navigator.clipboard.writeText(Array(11).fill("abandon").concat("about").join(" ")));let events=0;document.addEventListener('paste',()=>{document.getElementById('events').textContent='Page paste events: '+(++events)+' · submitted: no'});document.querySelector('form').addEventListener('submit',event=>{event.preventDefault();document.getElementById('events').textContent='Page paste events: '+events+' · submitted: yes';fetch('/submitted',{method:'POST',body:'synthetic-event-only'})});</script></body></html>'''
def demo_page(title, content):
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; font: 17px/1.55 system-ui; color: #192b42; background: #eef3fa; }}
  header, main {{ max-width: 760px; margin: 0 auto; }}
  header {{ display: flex; flex-wrap: wrap; gap: 8px 20px; align-items: center; padding: 24px; }}
  header strong {{ color: #3b5c84; font-size: 13px; letter-spacing: .04em; }}
  main {{ background: #fff; padding: clamp(24px, 5vw, 42px); border: 1px solid #d4deeb; border-radius: 24px; }}
  h1 {{ font-size: clamp(26px, 5vw, 36px); margin: 0 0 14px; line-height: 1.2; }}
  h2 {{ font-size: 20px; margin-bottom: 6px; }}
  p {{ margin: 0 0 12px; }}
  a {{ color: #285c91; }}
  nav {{ display: flex; flex-wrap: wrap; gap: 12px; margin-top: 22px; }}
  label {{ display: block; margin-top: 12px; font-weight: 600; }}
  input, button {{ font: inherit; border-radius: 8px; padding: 8px 12px; }}
  input {{ display: block; width: min(100%, 380px); border: 1px solid #97aac4; }}
  button {{ margin-top: 16px; color: #fff; background: #234fb2; border: 0; cursor: pointer; }}
  a.action {{ display: inline-block; border-radius: 8px; padding: 8px 12px; color: #fff; background: #234fb2; }}
</style></head><body>
<header data-muse-private><strong>MUSE GUARD DEMO</strong> <span>Local simulation. Use no real credentials.</span></header>
<main>{content}</main></body></html>'''


GUIDE = demo_page('Harbor returns · FAQ', '''
<h1>Harbor customer guide</h1>
<p>These answers describe our fictional shop's return policy.</p>
<section><h2>How long do I have to return an item?</h2>
<p>Returns are accepted within <strong>30 days of delivery</strong>. Keep the receipt and original packaging.</p></section>
<section><h2>When will a refund arrive?</h2>
<p>Approved refunds take <strong>5 business days</strong>.</p></section>
<section><h2>Can I exchange a color?</h2>
<p>Yes. Choose another in-stock color at no extra shipping cost.</p></section>
<nav aria-label="Demo scenes" data-muse-private><a href="/phishing">Staged sign-in</a><a href="/">Secret-paste test</a></nav>''')

INBOX = demo_page('Inbox · Microsoft 365 account deletion', '''
<h1>Inbox</h1>
<article aria-label="Email">
<h2>Urgent: Microsoft 365 account deletion</h2>
<p>From: Microsoft 365 Security &lt;security@m365-account-review.example.test&gt;</p>
<p>Your account will be deleted in 10 minutes. To cancel deletion, open the verification form and enter your email password and current six-digit authenticator code.</p>
<a id="verify-account" class="action" href="/phishing?from=inbox">Verify your account</a>
</article>''')

# The password and OTP types give the extension realistic action metadata.
# The inputs have no names, so the browser never includes their values in POST.
PHISHING = demo_page('Microsoft 365 Security', '''
<h1>Microsoft 365 Security</h1>
<h2>Your account will be deleted in 10 minutes</h2>
<p>Verify your email password and current six-digit authenticator code below to prevent deletion.</p>
<form action="/collect" method="post" autocomplete="off">
<label>Email<input type="email"></label>
<label>Password<input type="password" autocomplete="current-password"></label>
<label>Authenticator code<input inputmode="numeric" autocomplete="one-time-code"></label>
<button type="submit">Verify now</button>
</form>
<nav aria-label="Demo scenes" data-muse-private><a href="/guide">Back to the customer guide</a><a href="/">Secret-paste test</a></nav>''')

ARRIVAL = demo_page('Fixture submission reached', '''
<h1>Fixture submission reached</h1>
<p>The demo server received a submission. The form sent no field values.</p>
<a href="/phishing">Return to the staged sign-in</a>''')

COUNTERS = {'submitted': 0, 'downloads': 0, 'link_arrivals': 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def send_fixture(self, data, content='text/html; charset=utf-8', name=None):
        self.send_response(200)
        self.send_header('Content-Type', content)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; "
                         "script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; "
                         "base-uri 'none'; frame-ancestors 'none'")
        if name:
            self.send_header('Content-Disposition', f'attachment; filename="{name}"')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/metrics':
            self.send_fixture(json.dumps(COUNTERS).encode(), content='application/json')
        elif self.path == '/phishing?from=inbox':
            COUNTERS['link_arrivals'] += 1
            self.send_fixture(PHISHING.encode())
        elif self.path.startswith('/files/'):
            name=self.path.rsplit('/',1)[-1]
            if name == 'muse-benign.txt': data=b'Ordinary harmless Muse download fixture.\n'
            elif name == 'invoice.pdf.command': data=b'#!/bin/sh\n# Harmless static test fixture. Never execute.\n'
            elif name == 'muse-eicar-test.txt': data=b'X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
            else: self.send_error(404); return
            COUNTERS['downloads'] += 1
            self.send_fixture(data, content='application/octet-stream', name=name)
        else:
            page = {'/': HTML, '/guide': GUIDE, '/ordinary': GUIDE, '/inbox': INBOX, '/phishing': PHISHING}.get(self.path)
            if page is None:
                self.send_error(404)
            else:
                self.send_fixture(page.encode())

    def do_POST(self):
        if self.path not in {'/submitted', '/collect'}:
            self.send_error(404)
            return
        try:
            count = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self.send_error(400)
            return
        if not 0 <= count <= 4096:
            self.send_error(413)
            return
        self.rfile.read(count) # Drop bytes immediately; do not log fields or body.
        COUNTERS['submitted'] += 1
        if self.path == '/collect':
            self.send_fixture(ARRIVAL.encode())
        else:
            self.send_response(204)
            self.end_headers()


if __name__ == '__main__': ThreadingHTTPServer(('127.0.0.1',8767),Handler).serve_forever()
