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
  const sent = [], onNative = [], onDisconnect = [], opened = [], writes = [], badges = [], tabMessages = [], injections = [];
  const local = { configVersion: 2, enabled: true, paused: false, pauseUntil: 0, ...settings }, session = {};
  const tab = { id: 7, windowId: 2, active: true, url: 'https://shop.example.test/account?session=secret' };
  const tabs = new Map([[7, tab], ...(options.tabs || []).map(value => [value.id, value])]), alarms = new Map(), events = {};
  const monitoringTabs = new Set(options.readyTabs || []), injectionFailures = new Set(options.injectionFailures || []);
  const snapshot = { nonce: 'nonce-a', page: { url: 'https://shop.example.test/account', title: 'Shop', text: 'Visible original context' } };
  let focused = true, now = Date.now(), nextGetGate = null, sessionSetGate = null, injectionGate = null;
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
      connectNative(name) { assert.equal(name, 'com.antojoseph.museguard'); return {
        postMessage(value) { sent.push(value); }, onMessage: { addListener: fn => onNative.push(fn) }, onDisconnect: { addListener: fn => onDisconnect.push(fn) }
      }; }, onMessage: listen('message'), onStartup: listen('startup'), onInstalled: listen('installed') },
    storage: { local: storage(local, 'local'), session: storage(session, 'session'), onChanged: listen('storage') },
    tabs: { async get(id) { if (!tabs.has(id)) throw new Error('Missing tab'); return { ...tabs.get(id) }; },
      async query(query = {}) { return [...tabs.values()].filter(value => !query.active || value.active).map(value => ({ ...value })); },
      async sendMessage(id, message) { tabMessages.push({ tabId: id, ...message });
        if (message.type === 'monitor-ready') return { ready: monitoringTabs.has(id) };
        return structuredClone(snapshot); },
      async create(value) { opened.push(value); }, onUpdated: listen('updated'), onRemoved: listen('removed'), onActivated: listen('activated') },
    windows: { async get() { return { focused }; }, async create(value) { opened.push(value); } },
    alarms: { async get(name) { return alarms.get(name); }, async create(name, value) { alarms.set(name, { name, scheduledTime: value.when }); },
      async clear(name) { return alarms.delete(name); }, onAlarm: listen('alarm') },
    action: { async setBadgeText(value) { badges.push(structuredClone(value)); } }
  };
  chrome.scripting = { async executeScript(value) {
    injections.push(structuredClone(value));
    if (injectionFailures.has(value.target.tabId)) throw new Error('Chrome withheld this page.');
    if (injectionGate) await injectionGate;
    monitoringTabs.add(value.target.tabId); return [{ frameId: 0 }];
  } };
  const sandbox = vm.createContext({ chrome, crypto: { randomUUID }, URL, console, structuredClone,
    Date: class extends Date { static now() { return now; } },
    setTimeout: (fn, time) => { const handle = setTimeout(fn, time); handle.unref(); return handle; }, clearTimeout });
  sandbox.importScripts = file => vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(root, 'background.js'), 'utf8'), sandbox);
  const api = vm.runInContext('({handle, documents, pending, forget, config, cache, receipts, automaticQueue, ensureTabMonitoring, hydrateOpenTabs, restoreMonitoring, core:C, getActive:()=>activeAutomatic})', sandbox);
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
  return { api, sent, tab, tabs, sender, senderFor, popup, local, snapshot, writes, badges, opened, pageRequest, automatic, answer, tabMessages, session, alarms, events, injections, monitoringTabs,
    focus: value => { focused = value; }, advance: value => { now += value; },
    addTab(id, active = false) { const value = { id, active, windowId: 2, url: 'https://tab'+id+'.test/page' }; tabs.set(id, value); return value; },
    blockNextRead() { let release; nextGetGate = new Promise(resolve => { release = resolve; }); return release; },
    blockNextSessionWrite() { let release; sessionSetGate = new Promise(resolve => { release = resolve; }); return release; },
    blockInjections() { let release; injectionGate = new Promise(resolve => { release = () => { injectionGate = null; resolve(); }; }); return release; },
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
  assert.equal(h.local.paused, false); assert.equal(h.alarms.size, 0);
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
  const fresh = await automaticResult(h,request); assert.equal(fresh.confirmed_extreme, true); assert.equal(h.sent.length,2);
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

test('latest queued snapshot replaces its slot while returning to the active snapshot reuses it', async () => {
  const h=harness(), first=h.automatic();
  const a=h.api.handle(first,h.sender); await sentCount(h,1);
  const changed=structuredClone(first); changed.page.text='New public copy';
  const b=h.api.handle(changed,h.sender); await until(()=>h.api.automaticQueue.size===1);
  const again=h.api.handle(first,h.sender); await until(()=>h.api.automaticQueue.size===0);
  const superseded=await b; assert.equal(superseded.confirmed_extreme,false); assert.equal(superseded.retry_after_ms,15000);
  h.answer(h.sent[0]); const [ra,rr]=await Promise.all([a,again]);
  assert.equal(ra.id,rr.id); assert.equal(ra.confirmed_extreme,true); assert.equal(h.sent.length,1);
});

test('the automatic queue remains bounded and keeps separate page, sensitive-form and hover slots', async () => {
  const h=harness(), jobs=[];
  jobs.push(h.api.handle(h.automatic(),h.sender)); await sentCount(h,1);
  const sensitive=h.automatic('submit'); sensitive.action.sensitive=true;
  sensitive.public_signature=h.api.core.publicSignature(sensitive.action,['password']);
  jobs.push(h.api.handle(sensitive,h.sender)); jobs.push(h.api.handle(h.automatic('link'),h.sender));
  const newer=h.automatic(); newer.page.text='Latest page'; jobs.push(h.api.handle(newer,h.sender));
  await until(()=>h.api.automaticQueue.size===3);
  for(let id=8;id<43;id++){ h.addTab(id); jobs.push(h.api.handle(h.automatic('page','proactive',id),h.senderFor(id))); }
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
