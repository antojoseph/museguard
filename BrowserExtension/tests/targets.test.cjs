'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const T = require('../targets.js');

function fixture() {
  const dom = new JSDOM('<main><a id="link" href="https://example.test">Continue</a><input id="password" type="password"></main>', { pretendToBeVisual:true, runScripts:'outside-only' });
  const w = dom.window, element = w.document.querySelector('#link');
  let box = { left:100, top:200, right:260, bottom:240, width:160, height:40 }, time = Date.now();
  for (const [key, value] of Object.entries({innerWidth:1000,innerHeight:700,outerWidth:1000,outerHeight:800,screenX:100,screenY:100,devicePixelRatio:2}))
    Object.defineProperty(w, key, {configurable:true,writable:true,value});
  w.Date.now = () => time;
  element.getBoundingClientRect = () => box;
  return {w,element,meta:{documentID:'document-123',revision:7},
    time:()=>time,advance:ms=>{time+=ms;},box:value=>{box=value;},close:()=>dom.window.close(),
    trusted:{tabID:3,windowID:4,zoom:1,window:{id:4,left:100,top:100,width:1000,height:800}}};
}
test('captures only visible clipped geometry and never reads input values or labels',()=>{
  const f=fixture();
  const input=f.w.document.querySelector('#password');
  Object.defineProperty(input,'value',{get(){throw new Error('Secret value read');}});
  input.getBoundingClientRect=f.element.getBoundingClientRect;
  const a=T.capture(input,f.meta);
  assert.equal(a.document_id,'document-123');
  assert.deepEqual(a.rect,{x:100,y:200,width:160,height:40});
  assert.equal(a.viewport.device_pixel_ratio,2);
  assert.equal(a.pointer,undefined);
  assert.ok(!JSON.stringify(a).includes('password'));
  f.box({left:-20,top:680,right:140,bottom:720,width:160,height:40});
  assert.deepEqual(T.capture(f.element,f.meta).rect,{x:0,y:680,width:140,height:20});
  f.close();
});
test('offscreen, disconnected, hidden, invalid metadata and pinch-zoom targets refuse precise placement',()=>{
  const f=fixture();
  f.box({left:100,top:800,right:260,bottom:840,width:160,height:40});
  assert.equal(T.capture(f.element,f.meta),null);
  f.box({left:100,top:200,right:260,bottom:240,width:160,height:40});
  f.element.parentElement.hidden=true;
  assert.equal(T.capture(f.element,f.meta),null);
  f.element.parentElement.hidden=false;
  f.w.visualViewport={scale:2,offsetLeft:0,offsetTop:0};
  assert.equal(T.capture(f.element,f.meta),null);
  f.w.visualViewport={scale:1,offsetLeft:10,offsetTop:0};
  assert.equal(T.capture(f.element,f.meta),null);
  f.w.visualViewport=undefined;
  assert.equal(T.capture(f.element,{documentID:'../bad',revision:7}),null);
  assert.equal(T.capture(f.element,{documentID:'document-123',revision:-1}),null);
  f.element.remove();assert.equal(T.capture(f.element,f.meta),null);
  f.close();
});
test('geometry is revalidated after scroll, layout, zoom, revision or document changes',()=>{
  const f=fixture(), original=T.capture(f.element,f.meta);
  assert.equal(T.revalidate(f.element,original,f.meta),true);
  f.w.scrollY=40;
  assert.equal(T.revalidate(f.element,original,f.meta),false);
  f.w.scrollY=0;
  f.box({left:120,top:200,right:280,bottom:240,width:160,height:40});
  assert.equal(T.revalidate(f.element,original,f.meta),false);
  f.box({left:100,top:200,right:260,bottom:240,width:160,height:40});
  f.w.devicePixelRatio=2.5;
  assert.equal(T.revalidate(f.element,original,f.meta),false);
  f.w.devicePixelRatio=2;
  assert.equal(T.revalidate(f.element,original,{...f.meta,revision:8}),false);
  assert.equal(T.revalidate(f.element,original,{...f.meta,documentID:'another-document'}),false);
  f.advance(T.MAX_AGE_MS+1);
  assert.equal(T.revalidate(f.element,original,f.meta),false);
  f.close();
});
test('pointer origin requires genuine event metadata and is invalidated by window movement or zoom',()=>{
  const f=fixture();
  const event={type:'pointerdown',isTrusted:true,clientX:120,clientY:220,screenX:220,screenY:420};
  assert.equal(T.observeEvent({...event,isTrusted:false},f.w),false);
  assert.equal(T.observeEvent({...event,type:'keydown'},f.w),false);
  assert.equal(T.observeEvent(event,f.w),true);
  assert.equal(T.capture(f.element,f.meta).pointer.screen_x,220);
  f.w.screenX=200;
  assert.equal(T.capture(f.element,f.meta).pointer,undefined);
  f.w.screenX=100;f.w.devicePixelRatio=2.5;
  assert.equal(T.capture(f.element,f.meta).pointer,undefined);
  f.w.devicePixelRatio=2;
  f.advance(T.POINTER_MAX_AGE_MS+1);
  assert.equal(T.capture(f.element,f.meta).pointer,undefined);
  T.observeEvent(event,f.w);T.invalidate(f.w);
  assert.equal(T.capture(f.element,f.meta).pointer,undefined);
  f.close();
});
test('service-worker binding uses trusted window, tab, zoom and document metadata only',()=>{
  const f=fixture(), original=T.capture(f.element,f.meta);
  original.value='SECRET_NEVER_TRANSMIT';original.viewport.value='SECRET_NEVER_TRANSMIT';
  original.browser_window={id:999,left:5000};
  const bound=T.bind(original,f.trusted,f.meta,f.time());
  assert.deepEqual(bound.browser_window,{id:4,tab_id:3,left:100,top:100,width:1000,height:800,zoom:1});
  assert.ok(!JSON.stringify(bound).includes('SECRET_NEVER_TRANSMIT'));
  assert.equal(T.bind(original,{...f.trusted,windowID:9},f.meta,f.time()),null);
  assert.equal(T.bind(original,{...f.trusted,zoom:NaN},f.meta,f.time()),null);
  assert.equal(T.bind(original,f.trusted,{...f.meta,revision:8},f.time()),null);
  assert.equal(T.bind(original,f.trusted,{...f.meta,documentID:'different'},f.time()),null);
  f.advance(T.MAX_AGE_MS+1);
  assert.equal(T.bind(original,f.trusted,f.meta,f.time()),null);
  f.close();
});
