import sys,socket,json
from pathlib import Path
code=Path(sys.argv[1]).read_text()
s=socket.create_connection(('127.0.0.1',9876),timeout=8);s.settimeout(600)
s.sendall(json.dumps({'type':'execute_code','params':{'code':code}}).encode());buf=b''
while True:
 c=s.recv(65536)
 if not c:break
 buf+=c
 try:
  r=json.loads(buf);print(json.dumps(r));break
 except json.JSONDecodeError:pass
s.close()
