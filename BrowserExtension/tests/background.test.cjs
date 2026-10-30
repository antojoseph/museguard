'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const root = path.resolve(__dirname, '..');
const turn = () => new Promise(resolve => setImmediate(resolve));

function harness(settings = {}, options = {}) {
  const sent = [], heartbeats = [], contextPolls = [], contextResults = [], contextRequests = [], onNative = [], onDisconnect = [], opened = [], writes = [], badges = [], tabMessages = [], injections = [];
  const local = { configVersion: 2, enabled: true, paused: false, pauseUntil: 0, ...settings }, session = {};
  const tab = { id: 7, windowId: 2, active: true, url: 'https://shop.example.test/account?session=secret' };
  const tabs = new Map([[7, tab], ...(options.tabs || []).map(value => [value.id, value])]), alarms = new Map(), events = {};
  const monitoringTabs = new Set(options.readyTabs || []), injectionFailures = new Set(options.injectionFailures || []);
  const snapshot = { nonce: 'nonce-a', revision: 0, page: { url: 'https://shop.example.test/account', title: 'Shop', text: 'Visible original context' } };
  let focused = true, now = Date.now(), nextGetGate = null, sessionSetGate = null, injectionGate = null, windowReadGate = null;
  let autoHeartbeatReply = options.autoHeartbeatReply !== false;
  let lastFocusedWindow = options.lastFocusedWindow || 2, snapshotReply = null, connections = 0;
  const listen = name => ({ addListener(fn) { events[name] = fn; } });
  const storage = (target, area) => ({
    async get(value) {
      const result = typeof value === 'string' ? { [value]: target[value] } : { ...value, ...target };
      if (area === 'local' && nextGetGate) { const gate = nextGetGate; nextGetGate = null; await gate; }
      return result;
    },
    async set(value) { Object.assign(target, value); writes.push({ area, value: JSON.parse(JSON.stringify(value)) });
      if (area === 'session' && sessionSetGate) { const gate = sessionSetGate; sessionSetGate = null; await gate; } },
    async remove(key) { delete target[key]; }
  });
  const chrome = {
    runtime: { id: 'extension-id', getURL: file => 'chrome-extension://extension-id/' + file,
      connectNative(name) { assert.equal(name, 'com.antojoseph.museguard'); connections++; return {
        postMessage(value) {
          if (value.type === 'chat-context-poll' || value.type === 'chat-context-result') {
            const isPoll = value.type === 'chat-context-poll';
            (isPoll ? contextPolls : contextResults).push(value);
            const response = isPoll ? { version: 1, id: value.id, ok: true, ...(contextRequests.shift() || {}) } : { version: 1, id: value.id, ok: true };
            queueMicrotask(() => { for (const listener of onNative) listener(response); });
            return;
          }
          if (value.type !== 'protection-state') { sent.push(value); return; }
          heartbeats.push(value);
          if (autoHeartbeatReply) queueMicrotask(() => {
            for (const listener of onNative) listener({ version: 1, id: value.id, ok: true, protection_enabled: value.protection_enabled });
          });
        }, onMessage: { addListener: fn => onNative.push(fn) }, onDisconnect: { addListener: fn => onDisconnect.push(fn) }
      }; }, onMessage: listen('message'), onStartup: listen('startup'), onInstalled: listen('installed') },
    storage: { local: storage(local, 'local'), session: storage(session, 'session'), onChanged: listen('storage') },
    tabs: { async get(id) { if (!tabs.has(id)) throw new Error('Missing tab'); return { ...tabs.get(id) }; },
      async query(query = {}) { return [...tabs.values()].filter(value => (!query.active || value.active) &&
        (query.windowId === undefined || query.windowId === value.windowId) &&
        (!query.lastFocusedWindow || value.windowId === lastFocusedWindow)).map(value => ({ ...value })); },
      async sendMessage(id, message) { tabMessages.push({ tabId: id, ...message });
        if (message.type === 'monitor-ready') return { ready: monitoringTabs.has(id) };
        if (message.type === 'snapshot' && snapshotReply) return snapshotReply(id);
        return structuredClone(snapshot); },
      async create(value) { opened.push(value); }, onUpdated: listen('updated'), onRemoved: listen('removed'), onActivated: listen('activated') },
    windows: { async get() {
      if (windowReadGate) { const gate=windowReadGate; windowReadGate=null; gate.entered(); await gate.wait; }
      return { focused };
    }, async create(value) { opened.push(value); }, onFocusChanged: listen('window-focused') },
    alarms: { async get(name) { return alarms.get(name); }, async create(name, value) { alarms.set(name, { name, scheduledTime: value.when, periodInMinutes: value.periodInMinutes }); },
      async clear(name) { return alarms.delete(name); }, onAlarm: listen('alarm') },
    action: { async setBadgeText(value) { badges.push(structuredClone(value)); } }
  };
  chrome.scripting = { async executeScript(value) {
    injections.push(structuredClone(value));
    if (injectionFailures.has(value.target.tabId)) throw new Error('Chrome withheld this page.');
    if (injectionGate) await injectionGate;
    monitoringTabs.add(value.target.tabId); return [{ frameId: 0 }];
  } };
  const sandbox = vm.createContext({ chrome, crypto: { randomUUID }, URL, console, structuredClone, AbortController,
    Date: class extends Date { static now() { return now; } },
    setTimeout: (fn, time) => { const handle = setTimeout(fn, time); handle.unref(); return handle; }, clearTimeout });
  sandbox.importScripts = file => vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(root, 'background.js'), 'utf8'), sandbox);
  const api = vm.runInContext('({handle, documents, pending, forget, config, cache, receipts, automaticQueue, ensureTabMonitoring, hydrateOpenTabs, restoreMonitoring, syncProtectionState, pollChatContext, core:C, getActive:()=>activeAutomatic, hasContextTimer:()=>chatContextTimer!==null})', sandbox);
  const senderFor = id => { const value = tabs.get(id); return { id: 'extension-id', frameId: 0, documentId: 'document-'+id,
    url: value.url, tab: { ...value } }; };
  const sender = { ...senderFor(7), documentId: 'document-a' };
  const popup = { id: 'extension-id', url: 'chrome-extension://extension-id/popup.html', documentId: 'popup-a' };
  const pageRequest = (kind = 'link') => ({ type: 'assess', nonce: 'nonce-a', page: structuredClone(snapshot.page), action: { kind, url: 'https://destination.test/path?private=token', label: 'Continue' } });
  function automatic(kind = 'page', purpose = kind === 'page' ? 'proactive' : 'intent', id = 7) {
    const request = id === 7 ? pageRequest(kind) : { type: 'assess', nonce: 'nonce-'+id,
      page: { url: tabs.get(id).url.split('?')[0], title: 'Tab '+id, text: 'Public tab '+id },
      action: { kind, url: 'https://destination.test/'+id, method: 'GET', label: 'Continue' } };
    request.purpose = purpose;
    request.public_signature = api.core.publicSignature(request.action, kind === 'submit' ? ['password'] : []);
    request.action_fingerprint = 'a'.repeat(64);
    return request;
  }
  function answer(request, value = {}) {
    const risk = value.risk_level || 'high';
    const decision = ['safe', 'low'].includes(risk) ? 'allow' : risk === 'high' ? 'block' : 'review';
    const response = { version: 1, id: request.id, ok: true, decision, risk_level: risk,
      summary: 'Concrete concern', guidance: 'Stay here.', categories: [], mode: request.mode || 'text', duration_ms: 20, ...value };
    for (const listener of onNative) listener(response);
  }
  return { api, sent, heartbeats, contextPolls, contextResults, tab, tabs, sender, senderFor, popup, local, snapshot, writes, badges, opened, pageRequest, automatic, answer, tabMessages, session, alarms, events, injections, monitoringTabs,
    focus: value => { focused = value; }, advance: value => { now += value; },
    addTab(id, active = false) { const value = { id, active, windowId: 2, url: 'https://tab'+id+'.test/page' }; tabs.set(id, value); return value; },
    blockNextRead() { let release; nextGetGate = new Promise(resolve => { release = resolve; }); return release; },
    blockNextSessionWrite() { let release; sessionSetGate = new Promise(resolve => { release = resolve; }); return release; },
    blockNextWindowRead() {
      let release, entered;
      const began=new Promise(resolve=>{ entered=resolve; });
      windowReadGate={wait:new Promise(resolve=>{ release=resolve; }),entered};
      return { began, release };
    },
    blockInjections() { let release; injectionGate = new Promise(resolve => { release = () => { injectionGate = null; resolve(); }; }); return release; },
    heartbeatReplies(value) { autoHeartbeatReply = value; },
    answerHeartbeat(request, value = {}) { for (const listener of onNative) listener({ version: 1, id: request.id, ok: true, protection_enabled: request.protection_enabled, ...value }); },
    requestContext(value = {}) { contextRequests.push({ context_request_id: randomUUID(), context_expires_at: now + 6000, ...value }); },
    setSnapshotReply(value) { snapshotReply = value; },
    lastWindow(value) { lastFocusedWindow = value; },
    connectionCount: () => connections,
    disconnect: () => onDisconnect.forEach(fn => fn()) };
}
async function sentCount(h, count) {
  for (let n = 0; n < 30 && h.sent.length < count; n++) await turn();
  assert.ok(h.sent.length >= count, `Expected ${count} native messages, received ${h.sent.length}`);
}
async function nativeCall(h, message, value = {}, sender = h.sender) {
  const count = h.sent.length;
  const pending = h.api.handle(message, sender);
  await sentCount(h, count + 1);
  const request = h.sent[count];
  h.answer(request, value);
  return { result: await pending, request };
}
async function assessed(h, value = {}, kind = 'link') {
  return (await nativeCall(h, h.pageRequest(kind), value)).result;
}
async function presented(h, id, value = {}) {
  return (await nativeCall(h, { type: 'present', nonce: 'nonce-a', assessment_id: id }, value)).result;
}
async function polled(h, id, value = {}) {
  return (await nativeCall(h, { type: 'decision', nonce: 'nonce-a', assessment_id: id }, value)).result;
}

test('global protection ignores the legacy site allowlist and preserves explicit disable', async () => {
  const h = harness({ configVersion: 0, sites: [] });
  const { result } = await nativeCall(h, h.pageRequest());
  assert.equal(result.risk_level, 'high'); assert.equal(h.local.configVersion, 2);
  const disabled = harness({ configVersion: 0, enabled: false, sites: ['https://shop.example.test'] });
  const skipped = await disabled.api.handle(disabled.pageRequest(), disabled.sender);
  assert.equal(skipped.ok, false); assert.equal(disabled.sent.length, 0);
});

test('native checks receive bounded redacted evidence and session stores completion metadata only', async () => {
  const h = harness(), request = h.pageRequest();
  request.password = 'SHOULD_NOT_PASS'; request.screenshot = 'SHOULD_NOT_PASS';
  request.page.text += ' https://site.test/pay?token=TEXT_SECRET';
  const { result, request: native } = await nativeCall(h, request);
  assert.equal(native.action.url, 'https://destination.test/path');
  assert.equal(native.action.method, 'GET');
  assert.ok(!JSON.stringify(native).includes('SHOULD_NOT_PASS'));
  assert.ok(!JSON.stringify(native).includes('TEXT_SECRET'));
  assert.equal(result.risk_level, 'high');
  assert.ok(h.writes.every(write => write.area !== 'local'));
  assert.deepEqual(Object.keys(h.session['result:7']).sort(), ['checked', 'mode', 'timestamp']);
  assert.equal(h.session['result:7'].checked, true);
  const stored = JSON.stringify(h.writes);
  for (const secret of ['Visible original context', 'session=secret', 'Concrete concern', 'risk_level', 'data:image']) assert.ok(!stored.includes(secret));
  assert.ok(h.badges.every(value => value.text === ''), 'Warnings belong to the avatar, not risk badges.');
});

test('page/link requests use canonical GET and form methods retain their meaning', async () => {
  for (const [kind, method, expected] of [['page', undefined, 'GET'], ['link', undefined, 'GET'], ['submit', 'post', 'POST'], ['submit', undefined, 'GET']]) {
    const h = harness(), request = h.pageRequest(kind); request.action.method = method;
    const { request: native } = await nativeCall(h, request);
    assert.equal(native.action.method, expected, kind);
  }
});

test('assessments require a fresh active-tab acknowledgement before avatar presentation', async () => {
  const h = harness(), value = await assessed(h);
  assert.equal(h.sent.length, 1);
  h.focus(false);
  assert.equal((await h.api.handle({ type: 'present', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).ok, false);
  assert.equal(h.sent.length, 1);
  h.focus(true);
  const { request, result } = await nativeCall(h, { type: 'present', nonce: 'nonce-a', assessment_id: value.id }, { action_state: 'pending' });
  assert.equal(request.type, 'present'); assert.equal(request.assessment_id, value.id);
  assert.ok(!('page' in request)); assert.equal(result.action_state, 'pending');
  const before = h.sent.length;
  assert.equal((await h.api.handle({ type: 'present', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).ok, false);
  assert.equal(h.sent.length, before, 'A receipt may be presented only once.');
});

test('native action decisions remain raw even when a model failure made ok false', async () => {
  const h = harness(), failed = { ok: false, risk_level: 'unknown', decision: 'review', error: 'Model unavailable' };
  const value = await assessed(h, failed);
  const shown = await presented(h, value.id, { ...failed, action_state: 'pending' });
  assert.equal(shown.action_state, 'pending');
  h.focus(false); // Clicking the native avatar must not invalidate a pending poll.
  const pending = await polled(h, value.id, { ...failed, action_state: 'pending' });
  assert.equal(pending.ok, false); assert.equal(pending.action_state, 'pending');
  h.focus(true);
  const continued = await polled(h, value.id, { ...failed, action_state: 'continue' });
  assert.equal(continued.ok, false); assert.equal(continued.action_state, 'continue');
  const count = h.sent.length;
  assert.equal((await h.api.handle({ type: 'decision', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).action_state, 'expired');
  assert.equal(h.sent.length, count, 'Terminal grants are consumed exactly once.');
});

test('a Continue grant cannot pass while Chrome loses focus, the tab changes, or protection is paused', async () => {
  for (const change of ['focus', 'active', 'pause']) {
    const h = harness(), value = await assessed(h, { risk_level: 'unknown', decision: 'review', ok: false });
    await presented(h, value.id, { action_state: 'pending' });
    if (change === 'focus') h.focus(false);
    if (change === 'active') h.tab.active = false;
    if (change === 'pause') h.local.enabled = false;
    const count = h.sent.length;
    const pending = h.api.handle({ type: 'decision', nonce: 'nonce-a', assessment_id: value.id }, h.sender);
    await sentCount(h, count + 1);
    h.answer(h.sent[count], { ok: false, risk_level: 'unknown', decision: 'review', action_state: 'continue' });
    const result = await pending;
    assert.equal(result.action_state, 'expired', change); assert.equal(result.ok, false, change);
    await sentCount(h, count + 2);
    assert.equal(h.sent[count + 1].type, 'cancel', change);
    assert.equal(h.sent[count + 1].assessment_id, value.id);
    h.answer(h.sent[count + 1], { action_state: 'stay' });
  }
});

test('Stay here is terminal and may be received while the native panel has focus', async () => {
  const h = harness(), value = await assessed(h, { risk_level: 'medium', decision: 'review' });
  await presented(h, value.id, { action_state: 'pending' });
  h.focus(false);
  assert.equal((await polled(h, value.id, { action_state: 'stay' })).action_state, 'stay');
  const count = h.sent.length;
  assert.equal((await h.api.handle({ type: 'decision', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).action_state, 'expired');
  assert.equal(h.sent.length, count);
});

test('native notice reasons retain the original action and can present unassessed receipts', async () => {
  for (const reason of ['checking', 'unavailable', 'changed', 'unsupported', 'open_failed']) {
    const h = harness(), message = { ...h.pageRequest(), type: 'notice', reason };
    const failed = { ok: false, risk_level: 'unknown', decision: 'review', error: reason };
    const { result: value, request } = await nativeCall(h, message, failed);
    assert.equal(request.type, 'notice'); assert.equal(request.reason, reason);
    assert.equal(request.action.kind, 'link'); assert.equal(request.action.url, 'https://destination.test/path');
    const shown = await presented(h, value.id, { ...failed, action_state: 'pending' });
    assert.equal(shown.action_state, 'pending', reason);
  }
});

async function checkingReceipt(h) {
  const message = { ...h.pageRequest(), type: 'notice', reason: 'checking' };
  return (await nativeCall(h, message, { risk_level: 'unknown', decision: 'review' })).result;
}

test('finish-checking forwards metadata only and returns the raw prior state exactly once', async () => {
  const h = harness(), progress = await checkingReceipt(h);
  await presented(h, progress.id, { action_state: 'pending' });
  h.focus(false); // Reading/finishing progress is cleanup, not a browser grant.
  const { request, result } = await nativeCall(h, {
    type: 'finish-checking', nonce: 'nonce-a', assessment_id: progress.id,
    page: h.snapshot.page, screenshot: 'PRIVATE_IMAGE', decision: 'continue'
  }, { ok: false, risk_level: 'unknown', decision: 'review', action_state: 'pending', error: 'Prior model status' });
  assert.deepEqual(Object.keys(request).sort(), ['assessment_id', 'id', 'type', 'version']);
  assert.equal(request.type, 'finish-checking'); assert.equal(request.assessment_id, progress.id);
  assert.equal(result.ok, false); assert.equal(result.action_state, 'pending');
  const count = h.sent.length;
  assert.equal((await h.api.handle({ type: 'finish-checking', nonce: 'nonce-a', assessment_id: progress.id }, h.sender)).action_state, 'expired');
  assert.equal(h.sent.length, count, 'Finishing consumes the progress receipt.');
});

test('finish-checking preserves Stay so a late safe assessment cannot erase cancellation', async () => {
  const h = harness(), progress = await checkingReceipt(h);
  await presented(h, progress.id, { action_state: 'pending' });
  const { result } = await nativeCall(h,
    { type: 'finish-checking', nonce: 'nonce-a', assessment_id: progress.id },
    { ok: false, risk_level: 'unknown', decision: 'review', action_state: 'stay' });
  assert.equal(result.ok, false); assert.equal(result.action_state, 'stay');
  const count = h.sent.length;
  assert.equal((await h.api.handle({ type: 'decision', nonce: 'nonce-a', assessment_id: progress.id }, h.sender)).action_state, 'expired');
  assert.equal(h.sent.length, count);
});

test('finish-checking rejects ordinary, unpresented, mismatched and stale receipts', async () => {
  for (const change of ['ordinary', 'unpresented', 'nonce', 'tab', 'navigation', 'document']) {
    const h = harness(), receipt = change === 'ordinary' ? await assessed(h) : await checkingReceipt(h);
    if (change !== 'unpresented') await presented(h, receipt.id, { action_state: 'pending' });
    let nonce = 'nonce-a', sender = h.sender;
    if (change === 'nonce') nonce = 'another-document';
    if (change === 'tab') sender = { ...sender, tab: { ...sender.tab, id: 8 } };
    if (change === 'navigation') h.tab.url = 'https://shop.example.test/other';
    if (change === 'document') h.api.documents.set(7, { nonce: 'nonce-new', documentId: 'document-new' });
    const count = h.sent.length;
    const result = await h.api.handle({ type: 'finish-checking', nonce, assessment_id: receipt.id }, sender);
    assert.equal(result.action_state, 'expired', change); assert.equal(h.sent.length, count, change);
  }
});

test('finishing progress leaves the distinct final assessment available for avatar presentation', async () => {
  const h = harness(), progress = await checkingReceipt(h);
  await presented(h, progress.id, { action_state: 'pending' });
  const final = await assessed(h, { risk_level: 'medium', decision: 'review' });
  await nativeCall(h, { type: 'finish-checking', nonce: 'nonce-a', assessment_id: progress.id }, { action_state: 'pending' });
  const count = h.sent.length;
  const shown = await presented(h, final.id, { action_state: 'pending' });
  assert.equal(h.sent[count].assessment_id, final.id); assert.equal(shown.action_state, 'pending');
  assert.deepEqual(Object.keys(h.session['result:7']).sort(), ['checked', 'mode', 'timestamp']);
});

test('cancellation forwards the exact assessment and removes its local grant', async () => {
  const h = harness(), value = await assessed(h);
  await presented(h, value.id, { action_state: 'pending' });
  h.focus(false);
  const { result, request } = await nativeCall(h, { type: 'cancel', nonce: 'nonce-a', assessment_id: value.id }, { action_state: 'stay' });
  assert.equal(request.type, 'cancel'); assert.equal(request.assessment_id, value.id); assert.equal(result.action_state, 'stay');
  const count = h.sent.length;
  assert.equal((await h.api.handle({ type: 'decision', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).action_state, 'expired');
  assert.equal(h.sent.length, count);
});

test('navigation forgets presented receipts and sends native cancellation', async () => {
  const h = harness(), value = await assessed(h);
  await presented(h, value.id, { action_state: 'pending' });
  const count = h.sent.length;
  h.api.forget(7);
  await sentCount(h, count + 1);
  assert.equal(h.sent[count].type, 'cancel'); assert.equal(h.sent[count].assessment_id, value.id);
  h.answer(h.sent[count], { action_state: 'stay' });
  assert.equal((await h.api.handle({ type: 'decision', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).action_state, 'expired');
  assert.equal(h.session['result:7'], undefined);
});

test('navigation, same-URL document replacement and paused protection suppress stale presentation', async () => {
  for (const change of ['navigation', 'document', 'pause', 'expired']) {
    const h = harness(), value = await assessed(h);
    if (change === 'navigation') h.tab.url = 'https://shop.example.test/other';
    if (change === 'document') h.api.documents.set(7, { nonce: 'nonce-new', documentId: 'document-new' });
    if (change === 'pause') h.local.enabled = false;
    if (change === 'expired') h.advance(30001);
    const count = h.sent.length;
    assert.equal((await h.api.handle({ type: 'present', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).ok, false, change);
    assert.equal(h.sent.length, count, change);
  }
});

test('an in-flight old-page result cannot approve or record the newly navigated page', async () => {
  const h = harness();
  const pending = h.api.handle(h.pageRequest(), h.sender); await sentCount(h, 1);
  h.tab.url = 'https://shop.example.test/other'; h.answer(h.sent[0], { risk_level: 'safe' });
  const value = await pending;
  assert.equal(value.ok, false); assert.equal(value.decision, 'review'); assert.equal(h.writes.length, 0);
});

test('switching tabs or pausing protection prevents delayed safe approval', async () => {
  for (const change of ['focus', 'active', 'pause']) {
    const h = harness(); const pending = h.api.handle(h.pageRequest(), h.sender); await sentCount(h, 1);
    if (change === 'focus') h.focus(false);
    if (change === 'active') h.tab.active = false;
    if (change === 'pause') h.local.enabled = false;
    h.answer(h.sent[0], { risk_level: 'safe' });
    const value = await pending; assert.equal(value.ok, false, change); assert.equal(value.decision, 'review', change);
  }
});

test('all automatic work shares one native slot and later intent discards stale legacy scan metadata', async () => {
  const h = harness();
  const page = h.api.handle(h.pageRequest('page'), h.sender); await sentCount(h, 1);
  const action = h.api.handle(h.pageRequest('submit'), h.sender); await turn();
  assert.equal(h.sent.length, 1, 'No second simultaneous automatic inference.');
  h.answer(h.sent[0], { risk_level: 'unknown' });
  await sentCount(h, 2); h.answer(h.sent[1]);
  const [old, current] = await Promise.all([page, action]);
  assert.equal(old.ok, false); assert.equal(current.risk_level, 'high');
  assert.deepEqual(Object.keys(h.session['result:7']).sort(), ['checked', 'mode', 'timestamp']);
  assert.equal(h.session['result:7'].checked, true);
});

test('passive safe page scans cannot summon the avatar and manual popup routes stay separate', async () => {
  const h = harness(), value = await assessed(h, { risk_level: 'safe' }, 'page');
  const count = h.sent.length;
  assert.equal((await h.api.handle({ type: 'present', nonce: 'nonce-a', assessment_id: value.id }, h.sender)).ok, false);
  assert.equal((await h.api.handle({ type: 'manual-check', mode: 'vision' }, h.popup)).ok, false);
  assert.equal(h.sent.length, count);
});

test('foreign senders and subframes cannot acquire native receipts', async () => {
  for (const sender of [{ id: 'other-extension' }, { frameId: 1 }, { url: 'chrome://settings' }]) {
    const h = harness();
    await assert.rejects(h.api.handle(h.pageRequest(), { ...h.sender, ...sender }), /not supported/);
    assert.equal(h.sent.length, 0);
  }
});

test('native disconnect leaves the action unassessed and never safe', async () => {
  const h = harness(); const pending = h.api.handle(h.pageRequest(), h.sender); await sentCount(h, 1);
  h.disconnect(); const value = await pending;
  assert.equal(value.ok, false); assert.equal(value.decision, 'review');
});

async function until(predicate, message = 'Expected asynchronous state') {
  for (let n=0; n<60; n++) { if (predicate()) return; await turn(); }
  assert.ok(predicate(), message);
}
async function automaticResult(h, request = h.automatic(), value = {}, sender = h.sender) {
  return (await nativeCall(h, request, value, sender)).result;
}
function blockMessage(request, id) { return { ...request, type: 'present-block', assessment_id: id }; }

// Global controls do not depend on a page's URL or a site's old opt-in entry.
test('global pause controls work on internal tabs and expire through a persistent alarm', async () => {
  const h = harness(); h.tab.url = 'chrome://newtab/';
  const state = await h.api.handle({ type: 'popup-state' }, h.popup);
  assert.equal(state.supported, false); assert.equal(state.origin, null); assert.equal(state.active, true);
  await h.api.handle({ type: 'pause', duration_ms: 1800000 }, h.popup);
  const paused = await h.api.handle({ type: 'popup-state' }, h.popup);
  assert.equal(paused.paused, true); assert.equal(paused.active, false);
  assert.equal(h.alarms.get('muse-guard-resume').scheduledTime, paused.pauseUntil);
  h.advance(1800001); h.events.alarm({ name: 'muse-guard-resume' });
  await h.api.config();
  const resumed = await h.api.handle({ type: 'popup-state' }, h.popup);
  assert.equal(resumed.active, true); assert.equal(resumed.paused, false); assert.equal(resumed.pauseUntil, 0);
  assert.equal(h.local.paused, false); assert.equal(h.alarms.has('muse-guard-resume'), false);
  assert.equal(h.alarms.get('muse-guard-protection-heartbeat').periodInMinutes, 0.5);
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  h.advance(7200000); assert.equal((await h.api.config()).paused, true); assert.equal(h.alarms.size, 0);
  await h.api.handle({ type: 'resume' }, h.popup); assert.equal((await h.api.config()).active, true);
});

test('worker startup recreates a missing pause alarm and reconciles an already elapsed pause', async () => {
  const future = Date.now()+100000;
  const h = harness({ paused: true, pauseUntil: future }); await h.api.config();
  assert.equal(h.alarms.get('muse-guard-resume').scheduledTime, future);
  h.alarms.clear(); h.events.startup(); await h.api.config();
  assert.equal(h.alarms.get('muse-guard-resume').scheduledTime, future);
  const expired = harness({ paused: true, pauseUntil: Date.now()-1000 });
  assert.equal((await expired.api.config()).active, true); assert.equal(expired.local.paused, false);
});

test('a delayed startup migration cannot overwrite a later Pause or Resume', async () => {
  for (const operation of ['pause','resume']) {
    const h = harness({ configVersion: 0, enabled: operation !== 'resume', sites: [] });
    const release = h.blockNextRead(); await turn();
    const mutation = h.api.handle(operation === 'pause' ? { type:'pause', duration_ms:0 } : { type:'resume' }, h.popup);
    await turn(); release(); await mutation;
    const state = await h.api.config();
    assert.equal(state.enabled, true); assert.equal(state.paused, operation === 'pause');
    assert.equal(h.local.paused, operation === 'pause'); assert.equal(h.local.configVersion, 2);
    assert.ok(h.tabMessages.some(item => item.type === 'configuration-changed'));
  }
});

test('pause then resume invalidates an in-flight result instead of rehydrating its cache', async () => {
  const h = harness(), request = h.automatic();
  const waiting = h.api.handle(request, h.sender); await sentCount(h,1);
  await h.api.handle({ type:'pause', duration_ms:0 }, h.popup);
  await h.api.handle({ type:'resume' }, h.popup);
  h.answer(h.sent[0]); const result = await waiting;
  assert.equal(result.confirmed_extreme, false); assert.equal(h.api.cache.size, 0); assert.equal(h.api.receipts.size, 0);
  const fresh = await automaticResult(h,request); assert.equal(fresh.confirmed_extreme, true);
  assert.equal(h.sent.filter(value=>value.type==='assess').length,2);
  assert.ok(h.sent.some(value=>value.type==='cancel' && value.assessment_id===h.sent[0].id));
});

test('pause during metadata storage cannot return a late confirmed finding', async () => {
  const h=harness(), release=h.blockNextSessionWrite();
  const waiting=h.api.handle(h.automatic(),h.sender); await sentCount(h,1); h.answer(h.sent[0]);
  await until(()=>h.session['result:7']);
  await h.api.handle({type:'pause',duration_ms:0},h.popup); await h.api.handle({type:'resume'},h.popup);
  release(); const result=await waiting;
  assert.equal(result.confirmed_extreme,false); assert.equal(h.api.cache.size,0); assert.equal(h.api.receipts.size,0);
});

test('automatic jobs deduplicate and one global slot serves both proactive pages and intent', async () => {
  const h=harness(), first=h.automatic(), intent=h.automatic('link');
  const a=h.api.handle(first,h.sender); await sentCount(h,1);
  const duplicate=h.api.handle(first,h.sender), b=h.api.handle(intent,h.sender);
  await until(()=>h.api.automaticQueue.size===1); assert.equal(h.sent.length,1);
  h.answer(h.sent[0],{risk_level:'safe'}); await sentCount(h,2);
  assert.equal(h.sent[0].purpose,'proactive'); assert.equal(h.sent[1].purpose,'intent');
  h.answer(h.sent[1]); const [ra,rd,rb]=await Promise.all([a,duplicate,b]);
  assert.equal(ra.id,rd.id); assert.equal(rb.confirmed_extreme,true);
});

test('a changed active snapshot cancels native work and late completion cannot create a finding', async () => {
  const h=harness(), first=h.automatic();
  const a=h.api.handle(first,h.sender); await sentCount(h,1);
  const changed=structuredClone(first); changed.page.text='New public copy';
  const b=h.api.handle(changed,h.sender); await sentCount(h,3);
  assert.equal(h.sent[1].type,'cancel'); assert.equal(h.sent[1].assessment_id,h.sent[0].id);
  assert.equal(h.sent[2].type,'assess'); assert.equal(h.sent[2].page.text,'New public copy');
  const obsolete=await a; assert.equal(obsolete.confirmed_extreme,false); assert.equal(obsolete.ok,false);
  h.answer(h.sent[0]); await turn(); assert.equal(h.api.receipts.size,0);
  h.answer(h.sent[2]); const replacement=await b; assert.equal(replacement.confirmed_extreme,true);
  assert.equal(h.api.receipts.has(h.sent[0].id),false);
});

test('the automatic queue remains bounded and keeps separate page, sensitive-form and hover slots', async () => {
  const h=harness(), jobs=[]; h.addTab(8);
  jobs.push(h.api.handle(h.automatic('page','proactive',8),h.senderFor(8))); await sentCount(h,1);
  const sensitive=h.automatic('submit','proactive'); sensitive.action.sensitive=true;
  sensitive.public_signature=h.api.core.publicSignature(sensitive.action,['password']);
  jobs.push(h.api.handle(sensitive,h.sender)); jobs.push(h.api.handle(h.automatic('link'),h.sender));
  const newer=h.automatic(); newer.page.text='Latest page'; jobs.push(h.api.handle(newer,h.sender));
  await until(()=>h.api.automaticQueue.size===3);
  for(let id=9;id<44;id++){ h.addTab(id); jobs.push(h.api.handle(h.automatic('page','proactive',id),h.senderFor(id))); }
  await until(()=>h.api.automaticQueue.size===32);
  assert.ok(h.api.automaticQueue.size<=32);
  await h.api.handle({type:'pause',duration_ms:0},h.popup); h.answer(h.sent[0]);
  const values=await Promise.all(jobs); assert.ok(values.every(value=>value.confirmed_extreme===false));
  assert.ok(values.some(value=>value.retry_after_ms===15000)); assert.equal(h.sent.filter(value=>value.type==='assess').length,1);
});

test('foreground intent gets priority while a waiting background page receives a fair turn', async () => {
  const h=harness(), jobs=[]; h.addTab(8);
  jobs.push(h.api.handle(h.automatic(),h.sender)); await sentCount(h,1);
  jobs.push(h.api.handle(h.automatic('page','proactive',8),h.senderFor(8)));
  for(let id=9;id<13;id++){ h.addTab(id); jobs.push(h.api.handle(h.automatic('link','intent',id),h.senderFor(id))); }
  await until(()=>h.api.automaticQueue.size===5);
  for(let n=0;n<6;n++){
    await sentCount(h,n+1); h.answer(h.sent[n],{risk_level:'safe'});
  }
  await Promise.all(jobs);
  const dispatched=h.sent.map(value=>value.page.url);
  assert.equal(dispatched[1],'https://tab9.test/page');
  assert.ok(dispatched.indexOf('https://tab8.test/page')<=3,'Background work gets a turn after at most three foreground jobs.');
});

test('exact cached results retain their original expiry and never authorize a different action', async () => {
  const h=harness(), request=h.automatic(); const first=await automaticResult(h,request);
  h.advance(1000); const hit=await h.api.handle(request,h.sender);
  assert.equal(hit.id,first.id); assert.equal(hit.expires_at,first.expires_at); assert.equal(h.sent.length,1);
  const link=h.automatic('link'); await automaticResult(h,link,{risk_level:'safe'}); assert.equal(h.sent.length,2);
  const newFingerprint={...link,action_fingerprint:'b'.repeat(64)};
  await automaticResult(h,newFingerprint,{risk_level:'safe'}); assert.equal(h.sent.length,3);
  h.tab.url='https://shop.example.test/account?different=route';
  const sender={...h.sender,url:h.tab.url,tab:{...h.tab}};
  await automaticResult(h,request,{},sender); assert.equal(h.sent.length,4);
  h.advance(30001); await automaticResult(h,request,{},sender); assert.equal(h.sent.length,5);
});
test('non-high exact evidence reuses model work for five minutes without gaining blocking authority', async () => {
  const h=harness(), request=h.automatic('link'), first=await automaticResult(h,request,{risk_level:'safe'});
  h.advance(30001);
  const reused=await h.api.handle(request,h.sender);
  assert.equal(reused.id,first.id); assert.equal(h.sent.length,1);
  assert.equal(reused.confirmed_extreme,false); assert.equal(reused.expires_at,first.expires_at);
  assert.equal((await h.api.handle(blockMessage(request,reused.id),h.sender)).ok,false);
  h.advance(h.api.core.ASSESSMENT_REUSE_MS);
  const fresh=await automaticResult(h,request,{risk_level:'safe'});
  assert.notEqual(fresh.id,first.id); assert.equal(h.sent.length,2);
});
test('navigation aborts the active native request and ignores a late high response', async () => {
  const h=harness(), waiting=h.api.handle(h.automatic(),h.sender); await sentCount(h,1);
  const original=h.sent[0]; h.api.forget(7); await sentCount(h,2);
  assert.equal(h.sent[1].type,'cancel'); assert.equal(h.sent[1].assessment_id,original.id);
  assert.deepEqual(Object.keys(h.sent[1]).sort(),['assessment_id','id','type','version']);
  const result=await waiting; assert.equal(result.ok,false); assert.equal(result.confirmed_extreme,false);
  h.answer(original); await turn(); assert.equal(h.api.cache.size,0); assert.equal(h.api.receipts.size,0);
  assert.equal(h.api.pending.has(original.id),false);
});
test('a replacement document cancels an old same-URL scan even without a navigation event', async () => {
  const h=harness(), waiting=h.api.handle(h.automatic(),h.sender); await sentCount(h,1);
  const next=h.automatic(); next.nonce='new-document-nonce';
  const replacement=h.api.handle(next,{...h.sender,documentId:'document-b'}); await sentCount(h,3);
  assert.equal(h.sent[1].type,'cancel'); assert.equal(h.sent[1].assessment_id,h.sent[0].id);
  assert.equal((await waiting).ok,false);
  h.answer(h.sent[0]); await turn(); assert.equal(h.api.receipts.size,0);
  h.answer(h.sent[2],{risk_level:'safe'}); assert.equal((await replacement).risk_level,'safe');
});
test('focused sensitive intent promotes its queued prefetch and cancels unrelated routine work', async () => {
  const h=harness(); h.addTab(8);
  const background=h.api.handle(h.automatic('page','proactive',8),h.senderFor(8)); await sentCount(h,1);
  const prefetch=h.automatic('submit','proactive'); prefetch.action.sensitive=true; prefetch.action.method='POST';
  prefetch.public_signature=h.api.core.publicSignature(prefetch.action,['password']);
  const prefetched=h.api.handle(prefetch,h.sender); await until(()=>h.api.automaticQueue.size===1);
  assert.equal(h.sent.length,1,'Automatic sensitive-form discovery cannot interrupt another scan.');
  const intended=h.api.handle({...prefetch,purpose:'intent'},h.sender); await sentCount(h,3);
  assert.equal(h.sent[1].type,'cancel'); assert.equal(h.sent[1].assessment_id,h.sent[0].id);
  assert.equal(h.sent[2].type,'assess'); assert.equal(h.sent[2].purpose,'intent'); assert.equal(h.sent[2].action.sensitive,true);
  assert.equal((await background).ok,false);
  h.answer(h.sent[0]); await turn(); assert.equal(h.api.receipts.size,0);
  h.answer(h.sent[2]); const [a,b]=await Promise.all([prefetched,intended]);
  assert.equal(a.id,b.id,'Promotion shares one exact model result.');
  assert.equal(h.sent.filter(item=>item.type==='assess').length,2);
});
test('a sensitive intent from an unfocused window cannot preempt routine work', async () => {
  const h=harness(); h.addTab(8); h.focus(false);
  const a=h.api.handle(h.automatic('page','proactive',8),h.senderFor(8)); await sentCount(h,1);
  const intent=h.automatic('submit'); intent.action.sensitive=true; intent.public_signature=h.api.core.publicSignature(intent.action,['password']);
  const b=h.api.handle(intent,h.sender); await until(()=>h.api.automaticQueue.size===1);
  assert.equal(h.sent.length,1); h.answer(h.sent[0],{risk_level:'safe'}); await sentCount(h,2);
  assert.equal(h.sent[1].type,'assess'); h.answer(h.sent[1]); await Promise.all([a,b]);
});
test('an old sensitive intent cannot cancel newer work after a deferred focus query', async () => {
  for (const race of ['pause-resume','forget-reattach']) {
    const h=harness(); h.addTab(8); h.addTab(9);
    const original=h.api.handle(h.automatic('page','proactive',8),h.senderFor(8)); await sentCount(h,1);
    const blocked=h.blockNextWindowRead(), intent=h.automatic('submit');
    intent.action.sensitive=true; intent.public_signature=h.api.core.publicSignature(intent.action,['password']);
    const obsolete=h.api.handle(intent,h.sender); await blocked.began;
    if (race==='pause-resume') {
      await h.api.handle({type:'pause',duration_ms:0},h.popup);
      await h.api.handle({type:'resume'},h.popup);
      assert.equal((await original).ok,false);
    } else {
      h.api.forget(7);
      await h.api.handle({type:'configuration',nonce:'nonce-a'},h.sender);
      h.answer(h.sent[0],{risk_level:'safe'}); await original;
    }
    const newer=h.api.handle(h.automatic('page','proactive',9),h.senderFor(9));
    await until(()=>h.sent.some(item=>item.type==='assess' && item.page.url==='https://tab9.test/page'));
    const active=h.api.getActive(), request=h.sent.find(item=>item.type==='assess' && item.page.url==='https://tab9.test/page');
    const cancellations=h.sent.filter(item=>item.type==='cancel').length;
    blocked.release(); assert.equal((await obsolete).ok,false); await turn();
    assert.equal(h.api.getActive(),active,race);
    assert.equal(active.controller.signal.aborted,false,race);
    assert.equal(h.sent.filter(item=>item.type==='cancel').length,cancellations,race);
    h.answer(request,{risk_level:'safe'}); assert.equal((await newer).ok,true,race);
  }
});

test('action methods, field metadata and public page evidence are part of the exact cache proof', async () => {
  const h=harness(), request=h.automatic('submit'); await automaticResult(h,request);
  for (const change of ['method','fields','text','sensitive','destination']) {
    const next=structuredClone(request);
    if(change==='method')next.action.method='POST';
    if(change==='text')next.page.text='Changed public context';
    if(change==='sensitive')next.action.sensitive=true;
    if(change==='destination')next.action.url='https://new-destination.test/path';
    next.public_signature=h.api.core.publicSignature(next.action,change==='fields'?['password','email']:['password']);
    const count=h.sent.length; await automaticResult(h,next); assert.equal(h.sent.length,count+1,change);
  }
});

test('only a consistent successful high/block result becomes a confirmed extreme', async () => {
  for(const value of [
    {risk_level:'medium',decision:'review'}, {risk_level:'unknown',decision:'review',ok:false},
    {risk_level:'high',decision:'allow'}, {risk_level:'high',decision:'block',ok:false}, {risk_level:'safe',decision:'allow'}
  ]) {
    const h=harness(), result=await automaticResult(h,h.automatic(),value);
    assert.equal(result.confirmed_extreme,false,JSON.stringify(value));
    const count=h.sent.length;
    assert.equal((await h.api.handle(blockMessage(h.automatic(),result.id),h.sender)).ok,false);
    assert.equal(h.sent.length,count,'No automatic warning for unconfirmed results.');
  }
});

test('proof fingerprints are mandatory, bounded and kept out of native evidence', async () => {
  for(const fingerprint of [undefined,'','X'.repeat(64),'a'.repeat(65),'not-a-digest']) {
    const h=harness(), request=h.automatic(); request.action_fingerprint=fingerprint;
    await assert.rejects(h.api.handle(request,h.sender),/fingerprint/); assert.equal(h.sent.length,0);
  }
  const h=harness(), {request}=await nativeCall(h,h.automatic('submit'));
  assert.ok(!('action_fingerprint' in request)); assert.ok(!('public_signature' in request));
  assert.equal(request.purpose,'intent'); assert.ok(!JSON.stringify(request).includes('session=secret'));
});

test('confirmed extremes re-present through fresh native IDs with metadata-only requests', async () => {
  const h=harness(), request=h.automatic('link'), finding=await automaticResult(h,request);
  const first=await nativeCall(h,blockMessage(request,finding.id),{action_state:'pending'});
  assert.equal(first.request.type,'present-block'); assert.equal(first.request.assessment_id,finding.id);
  assert.deepEqual(Object.keys(first.request).sort(),['assessment_id','id','mode','type','version']);
  assert.notEqual(first.result.id,finding.id); assert.equal(h.api.receipts.get(first.result.id).presented,true);
  const second=await nativeCall(h,blockMessage(request,finding.id),{action_state:'pending'});
  assert.notEqual(second.result.id,first.result.id); assert.equal(second.request.assessment_id,finding.id);
  const before=h.sent.length; await h.api.handle({type:'pause',duration_ms:0},h.popup);
  const cancellations=h.sent.slice(before).filter(item=>item.type==='cancel').map(item=>item.assessment_id);
  assert.ok(cancellations.includes(first.result.id)); assert.ok(cancellations.includes(second.result.id));
  assert.ok(!cancellations.includes(finding.id),'Cancel visible native IDs, not just the original finding.');
});

test('present-block rejects stale, changed, hidden and mismatched proof without native presentation', async () => {
  for(const change of ['fingerprint','signature','text','nonce','url','focus','pause','expired']) {
    const h=harness(), request=h.automatic(), finding=await automaticResult(h,request), message=blockMessage(request,finding.id);
    let sender=h.sender;
    if(change==='fingerprint')message.action_fingerprint='b'.repeat(64);
    if(change==='signature')message.public_signature=h.api.core.publicSignature(message.action,['password']);
    if(change==='text')message.page={...message.page,text:'Other content'};
    if(change==='nonce')message.nonce='nonce-new';
    if(change==='url'){h.tab.url+='&new=route';sender={...sender,url:h.tab.url,tab:{...h.tab}};}
    if(change==='focus')h.focus(false);
    if(change==='pause')await h.api.handle({type:'pause',duration_ms:0},h.popup);
    if(change==='expired')h.advance(30001);
    const count=h.sent.length, result=await h.api.handle(message,sender);
    assert.equal(result.ok,false,change); assert.equal(h.sent.length,count,change);
  }
});

test('navigation cancels the fresh display ID and a pause during presentation discards it', async () => {
  const h=harness(), request=h.automatic(), finding=await automaticResult(h,request);
  const shown=await nativeCall(h,blockMessage(request,finding.id),{action_state:'pending'});
  const before=h.sent.length; h.api.forget(7); await sentCount(h,before+1);
  assert.equal(h.sent[before].assessment_id,shown.result.id);
  const next=harness(), payload=next.automatic(), high=await automaticResult(next,payload);
  const waiting=next.api.handle(blockMessage(payload,high.id),next.sender); await sentCount(next,2);
  await next.api.handle({type:'pause',duration_ms:0},next.popup); await next.api.handle({type:'resume'},next.popup);
  next.answer(next.sent[1],{action_state:'pending'}); const result=await waiting;
  assert.equal(result.action_state,'expired'); await sentCount(next,3);
  assert.equal(next.sent[2].type,'cancel'); assert.equal(next.sent[2].assessment_id,next.sent[1].id);
  assert.equal(next.api.receipts.size,0);
});

test('the manifest covers new HTTP(S) documents and permits attaching to already-open tabs', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  assert.ok(manifest.permissions.includes('scripting'));
  assert.deepEqual(manifest.host_permissions, ['http://*/*', 'https://*/*']);
  assert.deepEqual(manifest.content_scripts[0].matches, ['http://*/*', 'https://*/*']);
  assert.equal(manifest.content_scripts[0].run_at, 'document_start');
  assert.deepEqual(manifest.content_scripts[0].js, ['shared.js', 'content.js']);
});

test('worker startup hydrates existing active and background tabs across windows while isolating restricted tabs', async () => {
  const h = harness({}, { readyTabs: [7], injectionFailures: [14], tabs: [
    { id: 8, windowId: 3, active: false, url: 'http://existing.test/page' },
    { id: 9, windowId: 4, active: false, url: 'https://another-window.test/' },
    { id: 10, windowId: 2, active: true, url: 'chrome://extensions/' },
    { id: 11, windowId: 2, active: false, url: 'file:///private/local.html' },
    { id: 12, windowId: 2, active: false, url: 'about:blank' },
    { id: 13, windowId: 2, active: false, discarded: true, url: 'https://sleeping.test/' },
    { id: 14, windowId: 2, active: false, url: 'https://chromewebstore.google.com/' },
    { id: -1, windowId: 2, active: false, url: 'https://invalid-tab.test/' }
  ] });
  await until(() => h.tabMessages.some(value => value.type === 'configuration-changed'));
  assert.deepEqual(h.injections.map(value => value.target.tabId).sort((a,b) => a-b), [8, 9, 14]);
  assert.ok(h.monitoringTabs.has(8) && h.monitoringTabs.has(9));
  assert.equal(h.monitoringTabs.has(14), false);
  assert.equal(h.injections.some(value => value.target.tabId === 7), false, 'A live current instance needs no reinjection.');
  for (const injection of h.injections) {
    assert.deepEqual(injection.target.frameIds, [0]);
    assert.deepEqual(injection.files, ['shared.js', 'content.js']);
    assert.equal(injection.world, 'ISOLATED');
    assert.equal(injection.injectImmediately, true);
  }
  assert.equal(h.sent.length, 0, 'Attaching listeners does not send page evidence itself.');
});

test('install, startup, activation and navigation hydration coalesce instead of duplicating an attachment', async () => {
  const h = harness({}, { readyTabs: [7] });
  await until(() => h.tabMessages.some(value => value.type === 'configuration-changed'));
  h.addTab(8);
  const release = h.blockInjections();
  const first = h.api.ensureTabMonitoring(8), repeated = h.api.ensureTabMonitoring(8), all = h.api.hydrateOpenTabs();
  h.events.installed(); h.events.startup(); h.events.activated({ tabId: 8 }); h.events.updated(8, { status: 'complete' });
  await until(() => h.injections.length === 1);
  await turn(); await turn();
  assert.equal(h.injections.length, 1);
  release();
  assert.deepEqual(await Promise.all([first, repeated]), [true, true]);
  await all; await h.api.restoreMonitoring();
  assert.equal(h.injections.length, 1, 'Subsequent ready replies preserve one content instance.');
});

test('hydrating a paused or explicitly disabled browser preserves the user’s protection setting', async () => {
  for (const settings of [{ paused: true, pauseUntil: 0 }, { enabled: false }]) {
    const h = harness(settings, { tabs: [{ id: 8, windowId: 3, active: false, url: 'https://existing.test/' }] });
    await until(() => h.tabMessages.some(value => value.type === 'configuration-changed'));
    assert.ok(h.monitoringTabs.has(7) && h.monitoringTabs.has(8));
    const state = await h.api.config();
    assert.equal(state.active, false);
    assert.equal(state.paused, settings.paused === true);
    assert.equal(state.enabled, settings.enabled !== false);
    assert.equal(h.sent.length, 0);
  }
});

test('restoring or activating a discarded tab attaches after it becomes available without reloading it', async () => {
  const h = harness({}, { readyTabs: [7], tabs: [{ id: 8, windowId: 3, active: false, discarded: true, url: 'https://restored.test/' }] });
  await until(() => h.tabMessages.some(value => value.type === 'configuration-changed'));
  assert.equal(h.injections.length, 0);
  h.tabs.get(8).discarded = false;
  h.events.updated(8, { status: 'complete' }); h.events.activated({ tabId: 8 });
  await until(() => h.monitoringTabs.has(8));
  assert.equal(h.injections.length, 1);
  assert.equal(h.injections[0].target.tabId, 8);
});

test('protection heartbeats report only global connection state and renew periodically without foreground focus', async () => {
  const h = harness();
  await h.api.syncProtectionState();
  assert.ok(h.heartbeats.length >= 1);
  assert.equal(h.heartbeats.at(-1).protection_enabled, true);
  assert.equal(h.alarms.get('muse-guard-protection-heartbeat').periodInMinutes, 0.5);
  for (const message of h.heartbeats) {
    assert.deepEqual(Object.keys(message).sort(), ['id', 'mode', 'protection_enabled', 'type', 'version']);
    assert.equal(message.type, 'protection-state'); assert.equal(message.mode, 'text');
  }
  h.focus(false); h.tab.url = 'chrome://newtab/';
  const before = h.heartbeats.length;
  h.advance(30000); h.events.alarm({ name: 'muse-guard-protection-heartbeat' });
  await until(() => h.heartbeats.length > before);
  await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, true, 'Protection is global, independent of an active website.');
  assert.equal(h.sent.length, 0, 'A heartbeat never starts model inference.');
  assert.equal(h.api.getActive(), null); assert.equal(h.api.cache.size, 0);
});

test('Pause, Resume, explicit Disable and external settings changes publish the final global state', async () => {
  const h = harness(); await h.api.syncProtectionState();
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup); await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, false);
  assert.equal(h.alarms.has('muse-guard-protection-heartbeat'), false);
  await h.api.handle({ type: 'resume' }, h.popup); await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, true);
  assert.equal(h.alarms.get('muse-guard-protection-heartbeat').periodInMinutes, 0.5);
  await h.api.handle({ type: 'set-enabled', enabled: false }, h.popup); await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, false);
  assert.equal(h.alarms.has('muse-guard-protection-heartbeat'), false);
  Object.assign(h.local, { enabled: true, paused: false, pauseUntil: 0 });
  h.events.storage({}, 'local'); await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, true);
  assert.equal(h.sent.length, 0);
});

test('a pending heartbeat cannot reorder a later Pause and repeated requests share one native flight', async () => {
  const h = harness({}, { autoHeartbeatReply: false });
  await until(() => h.heartbeats.length === 1);
  const first = h.heartbeats[0];
  const waiting = [];
  for (let i = 0; i < 20; i++) waiting.push(h.api.syncProtectionState());
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  await turn(); assert.equal(h.heartbeats.length, 1, 'No second native heartbeat before the first resolves.');
  h.answerHeartbeat(first);
  await until(() => h.heartbeats.length === 2);
  assert.equal(h.heartbeats[1].protection_enabled, false, 'The newest paused state follows the old active response.');
  h.answerHeartbeat(h.heartbeats[1]); await Promise.all(waiting);
  await h.api.syncProtectionState();
  assert.equal(h.heartbeats.length, 2);
  assert.equal(h.alarms.has('muse-guard-protection-heartbeat'), false);
});

test('heartbeat disconnection retries quietly after a cooldown and through the periodic alarm', async () => {
  const h = harness({}, { autoHeartbeatReply: false });
  await until(() => h.heartbeats.length === 1);
  h.disconnect(); await h.api.syncProtectionState();
  const count = h.heartbeats.length;
  await h.api.syncProtectionState(); await turn();
  assert.equal(h.heartbeats.length, count, 'No immediate reconnect loop while the companion is unavailable.');
  h.advance(5001);
  const retry = h.api.syncProtectionState();
  await until(() => h.heartbeats.length === count + 1);
  h.answerHeartbeat(h.heartbeats.at(-1), { ok: false }); await retry;
  h.heartbeatReplies(true); h.advance(30000);
  h.events.alarm({ name: 'muse-guard-protection-heartbeat' });
  await until(() => h.heartbeats.length === count + 2);
  await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, true);
  assert.equal(h.sent.length, 0); assert.equal(h.api.cache.size, 0);
});

test('tab activation explicitly nudges an attached listener and skips a restricted tab', async () => {
  const h = harness({}, { readyTabs: [7] });
  await until(() => h.tabMessages.some(value => value.type === 'configuration-changed'));
  h.events.activated({ tabId: 7 });
  await until(() => h.tabMessages.some(value => value.type === 'monitor-activated' && value.tabId === 7));
  assert.equal(h.injections.length, 0);
  h.tabMessages.length = 0; h.tab.url = 'chrome://settings/';
  h.events.activated({ tabId: 7 }); await turn(); await turn();
  assert.equal(h.tabMessages.some(value => value.type === 'monitor-activated'), false);
});

test('returning to a Chrome window nudges its active tab without requiring a tab change', async () => {
  const h = harness({}, { readyTabs: [7, 8, 9], tabs: [
    { id: 8, windowId: 3, active: true, url: 'https://returned-window.test/' },
    { id: 9, windowId: 3, active: false, url: 'https://background-tab.test/' }
  ] });
  await until(() => h.tabMessages.some(value => value.type === 'configuration-changed'));
  h.tabMessages.length = 0;
  h.events['window-focused'](3);
  await until(() => h.tabMessages.some(value => value.type === 'monitor-activated'));
  assert.deepEqual(h.tabMessages.filter(value => value.type === 'monitor-activated').map(value => value.tabId), [8]);
  h.tabMessages.length = 0;
  h.events['window-focused'](-1); await turn(); await turn();
  assert.equal(h.tabMessages.length, 0, 'Losing Chrome focus must not pretend another tab was activated.');
  assert.equal(h.injections.length, 0);
});

test('configuration and assessment activity refresh an overdue heartbeat without flooding a tab burst', async () => {
  const h = harness(); await h.api.syncProtectionState();
  const count = h.heartbeats.length;
  for (let n = 0; n < 10; n++) await h.api.handle({ type: 'configuration', nonce: 'nonce-a' }, h.sender);
  await h.api.syncProtectionState();
  assert.equal(h.heartbeats.length, count, 'Recent metadata is shared across the burst.');
  h.advance(25001);
  await automaticResult(h, h.automatic(), { risk_level: 'safe' });
  await h.api.syncProtectionState();
  assert.equal(h.heartbeats.length, count + 1);
  assert.equal(h.sent.filter(value => value.type === 'assess').length, 1, 'Only the actual assessment starts inference.');
});

test('chat polling is metadata-only and never reads a page without an explicit pending native request', async () => {
  const h = harness(); await h.api.syncProtectionState();
  await h.api.pollChatContext(); await h.api.pollChatContext();
  assert.equal(h.contextPolls.length, 2);
  for (const poll of h.contextPolls) assert.deepEqual(Object.keys(poll).sort(), ['id', 'mode', 'type', 'version']);
  assert.equal(h.contextResults.length, 0);
  assert.equal(h.tabMessages.filter(value => value.type === 'snapshot').length, 0);
  assert.equal(h.sent.length, 0);
});

test('explicit chat requests get a fresh bounded redacted snapshot even while automatic protection is paused', async () => {
  const h = harness({ paused: true }, { readyTabs: [7] }); await h.api.syncProtectionState();
  h.focus(false); // Muse's native chat may own focus; native validates its Chrome target.
  h.snapshot.page.title = 'T'.repeat(1000);
  h.snapshot.page.text = 'Public https://user:secret@visible.test/path?token=PRIVATE#code ' + 'x'.repeat(9000);
  h.snapshot.password = 'MUST_NOT_TRANSFER'; h.snapshot.page.value = 'MUST_NOT_TRANSFER';
  h.requestContext(); await h.api.pollChatContext();
  assert.equal(h.contextResults.length, 1);
  const result = h.contextResults[0];
  assert.equal(result.type, 'chat-context-result'); assert.equal(result.tab_id, 7); assert.equal(result.window_id, 2);
  assert.equal(result.document_id, h.snapshot.nonce); assert.ok(result.context_request_id);
  assert.equal(result.page.url, 'https://shop.example.test/account');
  assert.equal(result.page.title.length, 250); assert.equal(result.page.text.length, 6000);
  assert.ok(!JSON.stringify(result).includes('PRIVATE')); assert.ok(!JSON.stringify(result).includes('session=secret'));
  assert.ok(!JSON.stringify(result).includes('MUST_NOT_TRANSFER')); assert.ok(!JSON.stringify(result).includes('user:secret'));
  assert.deepEqual(Object.keys(result.page).sort(), ['text', 'title', 'url']);
  assert.equal(h.tabMessages.filter(value => value.type === 'snapshot').length, 2);
  assert.equal((await h.api.config()).active, false); assert.equal(h.sent.length, 0);
});

test('chat requests reject tab, window, raw URL, document, edit and public snapshot changes without leaking evidence', async () => {
  for (const change of ['tab', 'window', 'rawURL', 'nonce', 'revision', 'text']) {
    const h = harness({ paused: true }, { readyTabs: [7] }); await h.api.syncProtectionState();
    let captures = 0;
    h.setSnapshotReply(() => {
      const value = structuredClone(h.snapshot); captures++;
      if (captures === 1 && change === 'tab') { h.tab.active = false; h.addTab(8, true); }
      if (captures === 1 && change === 'window') { h.addTab(8, true).windowId = 3; h.lastWindow(3); }
      if (captures === 1 && change === 'rawURL') h.tab.url += '&changed=PRIVATE';
      if (captures === 2 && change === 'nonce') value.nonce = 'new-document';
      if (captures === 2 && change === 'revision') value.revision++;
      if (captures === 2 && change === 'text') value.page.text = 'Different public page';
      return value;
    });
    h.requestContext(); await h.api.pollChatContext();
    const result = h.contextResults[0];
    assert.ok(result.context_error, change);
    assert.ok(!('page' in result) && !('tab_id' in result) && !('window_id' in result) && !('document_id' in result), change);
    assert.ok(!JSON.stringify(result).includes('PRIVATE'), change);
  }
});

test('unsupported tabs and unavailable listeners return a bounded context error instead of stale content', async () => {
  for (const issue of ['unsupported', 'discarded', 'listener', 'malformed']) {
    const h = harness({ paused: true }, issue === 'listener' ? { injectionFailures: [7] } : { readyTabs: [7] });
    await h.api.syncProtectionState();
    if (issue === 'unsupported') h.tab.url = 'chrome://settings/';
    if (issue === 'discarded') h.tab.discarded = true;
    if (issue === 'malformed') h.setSnapshotReply(() => ({ nonce: 'a', revision: 0, page: { url: 'https://wrong.test/', title: 'Wrong', text: 'STALE' } }));
    h.requestContext(); await h.api.pollChatContext();
    const result = h.contextResults[0];
    assert.ok(result.context_error && result.context_error.length <= 256, issue);
    assert.equal('page' in result, false, issue);
    assert.ok(!JSON.stringify(result).includes('STALE'), issue);
  }
});

test('expired or malformed context leases never cause a page read', async () => {
  const h = harness({ paused: true }); await h.api.syncProtectionState();
  for (const invalid of [{ context_expires_at: 0 }, { context_request_id: '' }, { context_request_id: 'x'.repeat(129) },
    { context_request_id: 'not-a-native-request' }, { context_expires_at: Infinity }]) {
    h.requestContext(invalid); await h.api.pollChatContext();
  }
  assert.equal(h.contextResults.length, 0);
  assert.equal(h.tabMessages.filter(value => value.type === 'snapshot').length, 0);
});

test('one chat context flight is shared and disconnecting stops capture without opening a replacement port', async () => {
  const h = harness({ paused: true }, { readyTabs: [7] }); await h.api.syncProtectionState();
  let release;
  h.setSnapshotReply(() => new Promise(resolve => { release = () => resolve(structuredClone(h.snapshot)); }));
  h.requestContext();
  const first = h.api.pollChatContext(), duplicate = h.api.pollChatContext();
  await until(() => release);
  assert.equal(h.contextPolls.length, 1);
  const connections = h.connectionCount();
  h.disconnect(); assert.equal(h.api.hasContextTimer(), false);
  release(); await Promise.all([first, duplicate]); await h.api.pollChatContext();
  assert.equal(h.contextResults.length, 0);
  assert.equal(h.connectionCount(), connections);
  assert.equal(h.tabMessages.filter(value => value.type === 'snapshot').length, 1);
  await h.api.syncProtectionState(true);
  assert.equal(h.connectionCount(), connections + 1); assert.equal(h.api.hasContextTimer(), true);
});

test('a context request expiring during snapshot collection is dropped before reading or sending another page', async () => {
  const h = harness({ paused: true }, { readyTabs: [7] }); await h.api.syncProtectionState();
  let release;
  h.setSnapshotReply(() => new Promise(resolve => { release = () => resolve(structuredClone(h.snapshot)); }));
  h.requestContext(); const pending = h.api.pollChatContext();
  await until(() => release);
  h.advance(6001); release(); await pending;
  assert.equal(h.contextResults.length, 0);
  assert.equal(h.tabMessages.filter(value => value.type === 'snapshot').length, 1);
});
