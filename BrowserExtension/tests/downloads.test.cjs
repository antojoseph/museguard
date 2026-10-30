const test = require('node:test');
const assert = require('node:assert/strict');
const {create,safeURL,metadata} = require('../downloads.js');
function event() { const handlers=new Set(); return { addListener:fn=>handlers.add(fn),removeListener:fn=>handlers.delete(fn),emit:value=>{for(const fn of [...handlers]) fn(structuredClone(value));},clear:()=>handlers.clear() }; }
async function until(predicate) { for(let i=0;i<1000;i++){if(predicate())return; await new Promise(resolve=>setImmediate(resolve));} assert.ok(predicate(),'asynchronous state did not settle'); }
function result(high=false,phase='metadata') {return {ok:true,decision:high?'block':'review',risk_level:high?'high':'unknown',download_inspection:{status:phase==='metadata'?'metadata_only':'scanned',scan_status:phase==='metadata'?'unavailable':'clean'}};}
function harness(options={}) {
 const items=new Map(),records={},calls=[],requests=[],results=[];
 const events={onCreated:event(),onChanged:event(),onErased:event()};
 let enabled=true, responder=async payload=>result(false,payload.download.phase),pauseGate=null;
 const chrome={downloads:{...events,
  async search(query){return [...items.values()].filter(item=>query.id===undefined||item.id===query.id).filter(item=>!query.state||item.state===query.state).map(item=>structuredClone(item));},
  async pause(id){calls.push(['pause',id]);if(pauseGate)await pauseGate;const item=items.get(id);if(item.state!=='in_progress')throw Error('inactive');item.paused=true;queueMicrotask(()=>events.onChanged.emit({id,paused:{current:true}}));},
  async resume(id){calls.push(['resume',id]);items.get(id).paused=false;queueMicrotask(()=>events.onChanged.emit({id,paused:{current:false}}));},
  async cancel(id){calls.push(['cancel',id]);items.get(id).state='interrupted';},
  async show(id){calls.push(['show',id]);}},storage:{session:{async get(defaults){return {...defaults,...structuredClone(records)};},async set(value){Object.assign(records,structuredClone(value));}}}};
 let serial=0;
 const guard=create({...options,chrome,isEnabled:async()=>enabled,uuid:()=>`hold-${++serial}`,nativeRequest:async(payload,timeout,port,signal)=>{
  requests.push(structuredClone(payload));
  return responder(payload,signal,timeout);
 },onResult:async(item,value)=>results.push({item,value})});
 function add(value={}){const item={id:1,url:'https://example.test/file.zip?private=secret',finalUrl:'https://cdn.example.test/file.zip#secret',filename:'/Users/test/Downloads/file.zip',mime:'application/zip',state:'in_progress',paused:false,danger:'safe',fileSize:-1,totalBytes:-1,exists:true,...value};items.set(item.id,item);events.onCreated.emit(item);return item;}
 return {chrome,guard,items,records,calls,requests,results,events,add,setEnabled:value=>{enabled=value;},setResponder:fn=>{responder=fn;},setPauseGate:promise=>{pauseGate=promise;}};
}

test('download metadata strips URL credentials/query/fragment and never carries data URL payloads',()=>{
 assert.equal(safeURL('https://user:secret@example.test/file?a=secret#fragment'),'https://example.test/file');
 assert.equal(safeURL('blob:https://example.test/private-object'),'https://example.test/');
 assert.equal(safeURL('data:application/octet-stream;base64,SECRET'),undefined);
 assert.equal(safeURL('file:///Users/test/private'),undefined);
 const value=metadata({id:1,url:'data:text/plain,PRIVATE',finalUrl:'blob:https://example.test/PRIVATE',filename:'/Users/private/Downloads/report.pdf',mime:'application/pdf',state:'complete'},'metadata','hold');
 assert.equal(value.filename,'report.pdf');assert.equal(value.url,undefined);assert.equal(value.final_url,'https://example.test/');assert.ok(!JSON.stringify(value).includes('PRIVATE'));
});

test('ordinary download pauses only for metadata, resumes, then scans the completed file',async()=>{
 const h=harness();await h.guard.start();const item=h.add();await until(()=>h.calls.some(x=>x[0]==='resume'));
 assert.equal(item.paused,false);assert.equal(h.requests[0].download.phase,'metadata');assert.equal(h.requests[0].download.owned_pause,true);
 assert.equal(h.requests[0].download.filename,'file.zip');assert.ok(!JSON.stringify(h.requests[0]).includes('secret'));
 item.state='complete';item.fileSize=42;item.endTime='now';h.events.onChanged.emit({id:1,state:{current:'complete'}});
 await until(()=>h.results.length===2);assert.equal(h.requests[1].download.phase,'complete');assert.equal(h.requests[1].download.filename,'/Users/test/Downloads/file.zip');
 assert.deepEqual(h.calls.map(x=>x[0]),['pause','resume']);await h.guard.stop();
});

test('confirmed high metadata remains paused until an exact explicit command; acknowledgment cannot resume it',async()=>{
 const h=harness();h.setResponder(async payload=>result(true,payload.download.phase));await h.guard.start();const item=h.add();await until(()=>h.guard.pending().length===1);
 const hold=h.guard.pending()[0];assert.equal(item.paused,true);assert.equal(h.calls.some(x=>x[0]==='resume'),false);
 assert.equal((await h.guard.handleCommand({...hold,hold_id:'stale',action:'resume'})).ok,false);
 assert.equal((await h.guard.handleCommand({...hold,action:'resume'})).ok,true);assert.equal(item.paused,false);assert.equal(h.guard.pending().length,0);await h.guard.stop();
});

test('user/Chrome-paused downloads are never resumed by the guardian; cancel is explicit',async()=>{
 const h=harness();h.setResponder(async()=>result(true));await h.guard.start();h.add({paused:true,danger:'url'});await until(()=>h.guard.pending().length===1);
 const hold=h.guard.pending()[0];assert.equal(hold.owned_pause,false);
 assert.equal((await h.guard.handleCommand({...hold,action:'resume'})).ok,false);
 await h.guard.setPaused(true);assert.equal(h.calls.some(x=>x[0]==='resume'),false);
 assert.equal((await h.guard.handleCommand({...hold,action:'cancel'})).ok,true);assert.equal(h.items.get(1).state,'interrupted');await h.guard.stop();
});

test('native unavailability releases an ordinary transfer without calling it clean',async()=>{
 const h=harness();h.setResponder(async()=>({ok:false,decision:'review',risk_level:'unknown',error:'app disconnected'}));await h.guard.start();h.add();await until(()=>h.calls.some(x=>x[0]==='resume'));
 assert.equal(h.results[0].value.ok,false);assert.equal(h.results[0].value.download_inspection,undefined);await h.guard.stop();
});

test('a small already-complete download is inspected without trying to pause or open it',async()=>{
 const h=harness();await h.guard.start();h.add({state:'complete',fileSize:6,endTime:'now'});await until(()=>h.results.length===1);
 assert.equal(h.requests[0].download.phase,'complete');assert.deepEqual(h.calls,[]);
 const token=h.requests[0].download.hold_id;assert.equal((await h.guard.handleCommand({download_id:1,hold_id:token,action:'show'})).ok,true);
 assert.deepEqual(h.calls,[['show',1]]);await h.guard.stop();
});

test('Pause cancels pending inspection and releases only guardian-owned pauses; late high does not rehold',async()=>{
 const h=harness();let release;
 h.setResponder((payload,signal)=>new Promise(resolve=>{release=()=>resolve(result(true));signal.addEventListener('abort',()=>resolve({ok:false}),{once:true});}));
 await h.guard.start();const item=h.add();await until(()=>h.requests.length===1);await h.guard.setPaused(true);release();await until(()=>!item.paused);
 assert.equal(h.guard.pending().length,0);assert.equal(h.results.length,0);await h.guard.stop();
});

test('Pause while Chrome pause() is unresolved cannot strand a new transfer',async()=>{
 const h=harness();let release;h.setPauseGate(new Promise(resolve=>{release=resolve;}));await h.guard.start();const item=h.add();await until(()=>h.calls.some(x=>x[0]==='pause'));
 await h.guard.setPaused(true);release();await until(()=>h.calls.some(x=>x[0]==='resume'));
 assert.equal(item.paused,false);assert.equal(h.requests.length,0);await h.guard.stop();
});

test('new Chrome danger information is inspected again after a previously ordinary metadata result',async()=>{
 const h=harness();await h.guard.start();const item=h.add();await until(()=>h.calls.some(x=>x[0]==='resume'));
 h.setResponder(async()=>result(true));item.danger='url';h.events.onChanged.emit({id:1,danger:{current:'url'}});
 await until(()=>h.guard.pending().length===1);assert.equal(h.requests.length,2);assert.equal(item.paused,false);
 assert.equal(h.guard.pending()[0].owned_pause,false,'Chrome danger must not acquire an extra silent Muse pause');
 assert.equal((await h.guard.handleCommand({...h.guard.pending()[0],action:'resume'})).ok,false,'Chrome danger is not bypassed');
 await h.guard.handleCommand({...h.guard.pending()[0],action:'cancel'});await h.guard.stop();
});

test('service-worker hydration restores an owned hold token, not a generic user pause',async()=>{
 const h=harness();h.items.set(5,{id:5,state:'in_progress',paused:true,danger:'safe',url:'https://example.test/a',filename:'/Users/test/Downloads/a'});
 h.records.museDownloadHoldsV1=[{download_id:5,hold_id:'restored-token',owned_pause:true,created:1}];h.setResponder(async()=>result(true));await h.guard.start();
 await until(()=>h.guard.pending().length===1);assert.equal(h.guard.pending()[0].hold_id,'restored-token');assert.equal(h.guard.pending()[0].owned_pause,true);
 assert.equal((await h.guard.handleCommand({download_id:5,hold_id:'restored-token',action:'cancel'})).ok,true);await h.guard.stop();
});

test('an unavailable completed scan retries with a bound and Pause cancels scheduled retries',async()=>{
 const scheduled=new Map();let sequence=0;
 const h=harness({schedule:(fn,delay)=>{const token=++sequence;scheduled.set(token,{fn,delay});return token;},clearScheduled:token=>scheduled.delete(token)});
 h.setResponder(async()=>({ok:true,decision:'review',risk_level:'unknown',download_inspection:{status:'unavailable',scan_status:'unavailable'}}));
 await h.guard.start();h.add({state:'complete',fileSize:6,endTime:'now'});await until(()=>scheduled.size===1);
 assert.equal(h.records.museDownloadHoldsV1[0].needs_complete,true);
 const [token,first]=[...scheduled][0];scheduled.delete(token);assert.equal(first.delay,15000);first.fn();await until(()=>h.requests.length===2&&scheduled.size===1);
 await h.guard.setPaused(true);assert.equal(scheduled.size,0);assert.equal(h.calls.some(x=>x[0]==='resume'),false);
 await h.guard.stop();
});

test('a terminal Chrome event recovers a small download whose creation event was missed',async()=>{
 const h=harness();await h.guard.start();
 h.items.set(8,{id:8,state:'complete',exists:true,fileSize:6,endTime:'now',danger:'safe',filename:'/Users/test/Downloads/tiny.txt'});
 h.events.onChanged.emit({id:8,state:{current:'complete'}});
 await until(()=>h.requests.some(value=>value.download.download_id===8));
 assert.equal(h.requests[0].download.phase,'complete');assert.deepEqual(h.calls,[]);await h.guard.stop();
});

test('worker startup attaches recent completed downloads as well as active transfers',async()=>{
 const h=harness();
 h.items.set(9,{id:9,state:'complete',exists:true,fileSize:6,endTime:new Date().toISOString(),danger:'safe',filename:'/Users/test/Downloads/recent.txt'});
 await h.guard.start();await until(()=>h.requests.length===1);assert.equal(h.requests[0].download.phase,'complete');
 assert.equal(h.requests[0].download.download_id,9);assert.deepEqual(h.calls,[]);await h.guard.stop();
});

test('download health is content-free and startup returns before recovered inspections complete',async()=>{
 const h=harness();let finish;
 h.items.set(10,{id:10,state:'complete',exists:true,fileSize:6,endTime:new Date().toISOString(),danger:'safe',filename:'/Users/test/Downloads/private-name.txt'});
 h.setResponder(()=>new Promise(resolve=>{finish=resolve;}));
 assert.deepEqual(h.guard.status(),{available:true,started:false,paused:false,processing:0,pending:0});
 await h.guard.start();await until(()=>h.requests.length===1);
 assert.deepEqual(h.guard.status(),{available:true,started:true,paused:false,processing:1,pending:1});
 assert.ok(!JSON.stringify(h.guard.status()).includes('private-name'));
 finish(result(false,'complete'));await until(()=>h.guard.status().processing===0);
 assert.equal(h.guard.status().pending,0);await h.guard.stop();assert.equal(h.guard.status().started,false);
 const unavailable=create({chrome:{},nativeRequest:async()=>result()});await unavailable.start();
 assert.deepEqual(unavailable.status(),{available:false,started:false,paused:false,processing:0,pending:0});
});
