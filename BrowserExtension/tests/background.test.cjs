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
  const sent = [], predictions = [], heartbeats = [], contextPolls = [], contextResults = [], contextRequests = [], onNative = [], onDisconnect = [], opened = [], writes = [], badges = [], tabMessages = [], injections = [], downloadOps = [], monitoringCommands = [], timers = [];
  const local = { configVersion: 2, enabled: true, paused: false, pauseUntil: 0, ...settings }, session = {};
  const monitoring = { paused: settings.paused === true || settings.enabled === false, pause_until: settings.pauseUntil || 0, revision: 1 };
  const monitoringRequests = [];
  const tab = { id: 7, windowId: 2, active: true, url: 'https://shop.example.test/account?session=secret' };
  const tabs = new Map([[7, tab], ...(options.tabs || []).map(value => [value.id, value])]), alarms = new Map(), events = {};
  const monitoringTabs = new Set(options.readyTabs || []), injectionFailures = new Set(options.injectionFailures || []);
  const snapshot = { nonce: 'nonce-a', revision: 0, page: { url: 'https://shop.example.test/account', title: 'Shop', text: 'Visible original context' } };
  let focused = true, now = Date.now(), nextGetGate = null, sessionSetGate = null, injectionGate = null, windowReadGate = null;
  let autoHeartbeatReply = options.autoHeartbeatReply !== false;
  let lastFocusedWindow = options.lastFocusedWindow || 2, snapshotReply = null, connections = 0;
  const listen = name => ({ addListener(fn) { events[name] = fn; }, removeListener(fn) { if (events[name] === fn) delete events[name]; } });
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
          if (value.type === 'prediction-update') {
            predictions.push(structuredClone(value));
            queueMicrotask(() => { for (const listener of onNative) listener({ version: 1, id: value.id, ok: true }); });
            return;
          }
          if (['monitoring-state', 'monitoring-control'].includes(value.type)) {
            monitoringRequests.push(value);
            const conflict = value.type === 'monitoring-control' && value.monitoring_revision && value.monitoring_revision !== monitoring.revision;
            if (value.type === 'monitoring-control' && !conflict) {
              monitoring.paused = value.monitoring_command === 'pause';
              monitoring.pause_until = monitoring.paused && value.pause_duration_ms ? now + value.pause_duration_ms : 0;
              monitoring.revision++;
            }
            if (monitoring.paused && monitoring.pause_until > 0 && monitoring.pause_until <= now) {
              monitoring.paused = false; monitoring.pause_until = 0; monitoring.revision++;
            }
            const response = { version: 1, id: value.id, ok: options.monitoringUnavailable !== true && !conflict, ...(options.monitoringUnavailable ? {} : { monitoring: { ...monitoring }, download_commands: structuredClone(monitoringCommands) }) };
            queueMicrotask(() => { for (const listener of onNative) listener(response); });
            return;
          }
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
      async getZoom() { return options.zoom || 1; },
      async query(query = {}) { return [...tabs.values()].filter(value => (!query.active || value.active) &&
        (query.windowId === undefined || query.windowId === value.windowId) &&
        (!query.lastFocusedWindow || value.windowId === lastFocusedWindow)).map(value => ({ ...value })); },
      async sendMessage(id, message) { tabMessages.push({ tabId: id, ...message });
        if (message.type === 'monitor-ready') return { ready: monitoringTabs.has(id) };
        if (['snapshot', 'target-state'].includes(message.type) && snapshotReply) return snapshotReply(id);
        return structuredClone(snapshot); },
      async create(value) { opened.push(value); }, onUpdated: listen('updated'), onRemoved: listen('removed'), onActivated: listen('activated'), onZoomChange: listen('zoom'), onDetached: listen('detached') },
    windows: { async get(id = 2) {
      if (windowReadGate) { const gate=windowReadGate; windowReadGate=null; gate.entered(); await gate.wait; }
      return { id, focused, left: 80, top: 30, width: 1200, height: 900 };
    }, async create(value) { opened.push(value); }, onFocusChanged: listen('window-focused'), onBoundsChanged: listen('window-bounds') },
    alarms: { async get(name) { return alarms.get(name); }, async create(name, value) { alarms.set(name, { name, scheduledTime: value.when, periodInMinutes: value.periodInMinutes }); },
      async clear(name) { return alarms.delete(name); }, onAlarm: listen('alarm') },
    action: { async setBadgeText(value) { badges.push(structuredClone(value)); } }
  };
  const downloadItems = new Map((options.downloads || []).map(item => [item.id, { ...item }]));
  if (options.downloads) chrome.downloads = {
    async search(query) { return [...downloadItems.values()].filter(item => (query.id === undefined || item.id === query.id) && (!query.state || item.state === query.state)).map(item => ({ ...item })); },
    async pause(id) { downloadOps.push(['pause', id]); downloadItems.get(id).paused = true; },
    async resume(id) { downloadOps.push(['resume', id]); downloadItems.get(id).paused = false; },
    async cancel(id) { downloadOps.push(['cancel', id]); downloadItems.get(id).state = 'interrupted'; },
    async show(id) { downloadOps.push(['show', id]); },
    onCreated: listen('download-created'), onChanged: listen('download-changed'), onErased: listen('download-erased')
  };
  chrome.scripting = { async executeScript(value) {
    injections.push(structuredClone(value));
    if (injectionFailures.has(value.target.tabId)) throw new Error('Chrome withheld this page.');
    if (injectionGate) await injectionGate;
    monitoringTabs.add(value.target.tabId); return [{ frameId: 0 }];
  } };
  const sandbox = vm.createContext({ chrome, crypto: { randomUUID }, URL, console, structuredClone, AbortController,
    Date: class extends Date { static now() { return now; } },
    setTimeout: (fn, time) => { const handle = setTimeout(fn, time); handle.unref(); timers.push({ fn, time, handle }); return handle; }, clearTimeout });
  sandbox.importScripts = file => vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(root, 'background.js'), 'utf8'), sandbox);
  const api = vm.runInContext('({handle, documents, pending, forget, config, cache, receipts, automaticQueue, ensureTabMonitoring, hydrateOpenTabs, restoreMonitoring, syncProtectionState, pollChatContext, pollMonitoringState, applyMonitoringState, processDownloadCommands, publishSelectedPrediction, predictionSources, downloadGuard, core:C, getActive:()=>activeAutomatic, hasContextTimer:()=>chatContextTimer!==null})', sandbox);
  const senderFor = id => { const value = tabs.get(id); return { id: 'extension-id', frameId: 0, documentId: 'document-'+id,
    url: value.url, tab: { ...value } }; };
  const sender = { ...senderFor(7), documentId: 'document-a' };
  const popup = { id: 'extension-id', url: 'chrome-extension://extension-id/popup.html', documentId: 'popup-a' };
  const pageRequest = (kind = 'link') => {
    const action = { kind, url: 'https://destination.test/path?private=token', label: 'Continue' };
    return { type: 'assess', nonce: 'nonce-a', purpose: kind === 'page' ? 'proactive' : 'intent', page: structuredClone(snapshot.page), action,
      public_signature: api.core.publicSignature(action), action_fingerprint: 'a'.repeat(64) };
  };
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
  return { api, monitoring, monitoringRequests, monitoringCommands, downloadItems, downloadOps, timers, now: () => now, sent, predictions, heartbeats, contextPolls, contextResults, tab, tabs, sender, senderFor, popup, local, snapshot, writes, badges, opened, pageRequest, automatic, answer, tabMessages, session, alarms, events, injections, monitoringTabs,
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
test('global protection ignores the legacy site allowlist and preserves explicit disable', async () => {
  const h = harness({ configVersion: 0, sites: [] });
  const { result } = await nativeCall(h, h.pageRequest());
  assert.equal(result.risk_level, 'high'); assert.equal(h.local.configVersion, 2);
  const disabled = harness({ configVersion: 0, enabled: false, sites: ['https://shop.example.test'] });
  const skipped = await disabled.api.handle(disabled.pageRequest(), disabled.sender);
  assert.equal(skipped.ok, false); assert.equal(disabled.sent.length, 0);
});

test('native checks receive bounded redacted evidence without storing browser check history', async () => {
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
  assert.deepEqual(h.session, {});
  const stored = JSON.stringify(h.writes);
  for (const secret of ['Visible original context', 'session=secret', 'Concrete concern', 'risk_level', 'data:image']) assert.ok(!stored.includes(secret));
  assert.ok(h.badges.every(value => value.text === ''), 'Warnings belong to the avatar, not risk badges.');
});

test('page/link requests use canonical GET and form methods retain their meaning', async () => {
  for (const [kind, method, expected] of [['page', undefined, 'GET'], ['link', undefined, 'GET'], ['submit', 'post', 'POST'], ['submit', undefined, 'GET']]) {
    const h = harness(), request = h.pageRequest(kind); request.action.method = method;
    request.public_signature = h.api.core.publicSignature(request.action);
    const { request: native } = await nativeCall(h, request);
    assert.equal(native.action.method, expected, kind);
  }
});

test('retired held-action and navigation routes are rejected without native calls', async () => {
  for (const type of ['present', 'notice', 'decision', 'finish-checking', 'open-link']) {
    const h = harness();
    for (const sender of [h.sender, h.popup]) {
      const result = await h.api.handle({ type, nonce: 'nonce-a', assessment_id: 'old-receipt',
        url: 'https://destination.test/path', reason: 'checking' }, sender);
      assert.equal(result.ok, false, type);
    }
    assert.equal(h.sent.length, 0, type); assert.equal(h.opened.length, 0, type);
  }
});

test('automatic assessments require the current purpose and exact local proof', async () => {
  for (const missing of ['purpose', 'public_signature', 'action_fingerprint']) {
    const h = harness(), request = h.pageRequest(); delete request[missing];
    await assert.rejects(h.api.handle(request, h.sender), /purpose|proof|fingerprint/);
    assert.equal(h.sent.length, 0, missing);
  }
});

test('an in-flight old-page result cannot approve or record the newly navigated page', async () => {
  const h = harness();
  const pending = h.api.handle(h.pageRequest(), h.sender); await sentCount(h, 1);
  h.tab.url = 'https://shop.example.test/other'; h.answer(h.sent[0], { risk_level: 'safe' });
  const value = await pending;
  assert.equal(value.ok, false); assert.equal(value.decision, 'review'); assert.equal(h.writes.length, 0);
});

test('background assessments may finish while unfocused but cannot present a warning', async () => {
  const h = harness(), request = h.automatic();
  const pending = h.api.handle(request, h.sender); await sentCount(h, 1);
  h.focus(false); h.tab.active = false; h.answer(h.sent[0]);
  const finding = await pending; assert.equal(finding.ok, true);
  const count = h.sent.length;
  assert.equal((await h.api.handle(blockMessage(request, finding.id), h.sender)).ok, false);
  assert.equal(h.sent.length, count);
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
function measuredEvidence(value = {}) {
  return { version: 1, primary_text_characters: 80, visible_text_characters: 120, substantial_visuals: 0,
    requires_visual: false, truncated: false, visual_revision: 0, ...value };
}
function currentMeasuredPage(h) {
  h.snapshot.page.evidence = measuredEvidence();
  const request = h.automatic();
  // Match the production page action, rather than the link-shaped historical
  // harness default: exact coverage cannot be earned by a different intent.
  request.action = h.api.core.normalizeAction({ kind: 'page' });
  request.public_signature = h.api.core.publicSignature(request.action);
  return request;
}
async function contextReply(h) {
  const before = h.contextResults.length;
  h.requestContext(); await h.api.pollChatContext();
  assert.equal(h.contextResults.length, before + 1, 'The request must receive a new context reply.');
  return h.contextResults.at(-1);
}

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
  h.advance(7200000); assert.equal((await h.api.config()).paused, true); assert.equal(h.alarms.has('muse-guard-resume'), false);
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
  jobs.push(h.api.handle(h.automatic('link','intent'),h.sender));
  const form=h.automatic('submit','proactive'); form.action.sensitive=true;
  form.public_signature=h.api.core.publicSignature(form.action,['password']);
  jobs.push(h.api.handle(form,h.sender));
  await until(()=>h.api.automaticQueue.size===3);
  for(let n=0;n<4;n++){
    await sentCount(h,n+1); h.answer(h.sent[n],{risk_level:'safe'});
  }
  await Promise.all(jobs);
  const dispatched=h.sent.map(value=>value.page.url);
  assert.equal(h.sent[1].action.kind,'link');
  assert.equal(dispatched[1],h.snapshot.page.url);
  assert.ok(dispatched.indexOf('https://tab8.test/page')<=3,'Background work gets a turn after at most three foreground jobs.');
});

test('the current page outranks stale intents from inactive tabs and other Chrome windows', async () => {
  for (const otherWindow of [false,true]) {
    const h=harness(), jobs=[]; h.addTab(8);
    jobs.push(h.api.handle(h.automatic('page','proactive',8),h.senderFor(8))); await sentCount(h,1);
    for (let id=9;id<12;id++) {
      const tab=h.addTab(id,otherWindow);
      if (otherWindow) tab.windowId=id;
      jobs.push(h.api.handle(h.automatic('link','intent',id),h.senderFor(id)));
    }
    jobs.push(h.api.handle(h.automatic('page','proactive'),h.sender));
    await until(()=>h.api.automaticQueue.size===4);
    assert.equal(h.sent.length,1,'A routine activation preserves the scan already running.');
    for (let n=0;n<5;n++) {
      await sentCount(h,n+1); h.answer(h.sent[n],{risk_level:'safe'});
    }
    await Promise.all(jobs);
    assert.equal(h.sent[1].page.url,h.snapshot.page.url,'Fresh current-page evidence must beat old hover/press intent.');
    assert.deepEqual(h.sent.slice(2).map(value=>value.page.url),[9,10,11].map(id=>'https://tab'+id+'.test/page'),
      'Inactive intents remain covered in bounded background FIFO order.');
  }
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
    await h.api.publishSelectedPrediction();
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
  const first=await nativeCall(h,blockMessage(request,finding.id),{});
  assert.equal(first.request.type,'present-block'); assert.equal(first.request.assessment_id,finding.id);
  assert.deepEqual(Object.keys(first.request).sort(),['assessment_id','document_id','id','mode','page_revision','tab_id','type','version','window_id']);
  assert.notEqual(first.result.id,finding.id); assert.equal(h.api.receipts.get(first.result.id).presented,true);
  const second=await nativeCall(h,blockMessage(request,finding.id),{});
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

test('medium concerns earn a warning receipt without gaining high-risk blocking authority', async () => {
  const h = harness(), request = h.automatic(), finding = await automaticResult(h, request, { risk_level: 'medium', decision: 'review' });
  assert.equal(finding.confirmed_extreme, false);
  assert.equal(finding.warning_eligible, true);
  assert.ok(finding.warning_expires_at > h.now() && finding.warning_expires_at <= h.now() + 30000);
  assert.equal(h.api.core.isPresentableWarning(finding, h.now()), true);
  assert.equal(h.api.core.isConfirmedExtreme(finding, h.now()), false);
  const before = h.sent.length;
  assert.equal((await h.api.handle(blockMessage(request, finding.id), h.sender)).ok, false);
  assert.equal(h.sent.length, before, 'A medium caution cannot invoke the browser blocking route.');
  const warning = { ...blockMessage(request, finding.id), type: 'present-warning' };
  const shown = await nativeCall(h, warning, { risk_level: 'medium', decision: 'review' });
  assert.equal(shown.request.type, 'present-warning');
  assert.equal(shown.request.assessment_id, finding.id);
  assert.equal(shown.result.ok, true);
  assert.ok(!('page' in shown.request) && !('action' in shown.request), 'Presentation uses the exact native receipt without resending evidence.');
  const high = harness(), highRequest = high.automatic(), highFinding = await automaticResult(high, highRequest);
  const highCount = high.sent.length;
  assert.equal((await high.api.handle({ ...blockMessage(highRequest, highFinding.id), type: 'present-warning' }, high.sender)).ok, false);
  assert.equal(high.sent.length, highCount, 'A high finding retains its separate blocking presentation route.');
});

test('medium warning presentation rejects stale, changed, paused, unfocused and mismatched evidence', async () => {
  for (const change of ['expired', 'text', 'fingerprint', 'signature', 'nonce', 'rawRoute', 'focus', 'pause']) {
    const h = harness(), request = h.automatic(), finding = await automaticResult(h, request, { risk_level: 'medium', decision: 'review' });
    const message = { ...blockMessage(request, finding.id), type: 'present-warning' };
    let sender = h.sender;
    if (change === 'expired') h.advance(30001);
    if (change === 'text') message.page.text = 'A replacement message with a different destination.';
    if (change === 'fingerprint') message.action_fingerprint = 'b'.repeat(64);
    if (change === 'signature') message.public_signature = h.api.core.publicSignature(message.action, ['password']);
    if (change === 'nonce') message.nonce = 'replacement-document';
    if (change === 'rawRoute') { h.tab.url += '#another-email'; sender = { ...sender, url: h.tab.url, tab: { ...h.tab } }; }
    if (change === 'focus') h.focus(false);
    if (change === 'pause') await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
    const count = h.sent.length, response = await h.api.handle(message, sender);
    assert.equal(response.ok, false, change);
    assert.equal(h.sent.length, count, 'No native presentation for ' + change);
  }
});

test('inconsistent or failed medium responses never acquire warning eligibility', async () => {
  for (const value of [{ decision: 'allow' }, { decision: 'block' }, { decision: 'review', ok: false }]) {
    const h = harness(), request = h.automatic();
    const result = await automaticResult(h, request, { risk_level: 'medium', ...value });
    assert.equal(result.warning_eligible, false, JSON.stringify(value));
    assert.equal(result.confirmed_extreme, false);
    assert.equal(h.api.core.isPresentableWarning(result, h.now()), false);
    const count = h.sent.length;
    assert.equal((await h.api.handle({ ...blockMessage(request, result.id), type: 'present-warning' }, h.sender)).ok, false);
    assert.equal(h.sent.length, count);
  }
});

test('typed page quality is validated and preserved while visual revision ends exact cached reuse', async () => {
  const h = harness(), request = currentMeasuredPage(h);
  request.page.evidence.extra_private_field = 'MUST_NOT_PASS';
  const first = await nativeCall(h, request, { risk_level: 'safe' });
  assert.deepEqual(structuredClone(first.request.page.evidence), measuredEvidence());
  assert.ok(!JSON.stringify(first.request).includes('MUST_NOT_PASS'));
  const before = h.sent.length;
  assert.equal((await h.api.handle(request, h.sender)).id, first.result.id);
  assert.equal(h.sent.length, before, 'Unchanged typed evidence reuses the exact completed assessment.');
  const changed = structuredClone(request); changed.page.evidence.visual_revision++;
  assert.notEqual(h.api.core.assessmentKey(changed.page), h.api.core.assessmentKey(request.page));
  const second = await nativeCall(h, changed, { risk_level: 'safe' });
  assert.notEqual(second.result.id, first.result.id);
  assert.equal(second.request.page.evidence.visual_revision, 1);
  for (const invalid of [
    { version: 2 }, { primary_text_characters: -1 }, { primary_text_characters: 121 },
    { visible_text_characters: 8001 }, { substantial_visuals: 65 }, { requires_visual: 'yes' },
    { truncated: 1 }, { visual_revision: -1 }, { visual_revision: 2147483648 }
  ]) {
    const bad = structuredClone(request); bad.page.evidence = measuredEvidence(invalid);
    const count = h.sent.length;
    await assert.rejects(h.api.handle(bad, h.sender), /read this tab/);
    assert.equal(h.sent.length, count, JSON.stringify(invalid));
  }
});

test('navigation cancels the fresh display ID and a pause during presentation discards it', async () => {
  const h=harness(), request=h.automatic(), finding=await automaticResult(h,request);
  const shown=await nativeCall(h,blockMessage(request,finding.id),{});
  const before=h.sent.length; h.api.forget(7); await sentCount(h,before+1);
  assert.equal(h.sent[before].assessment_id,shown.result.id);
  const next=harness(), payload=next.automatic(), high=await automaticResult(next,payload);
  const waiting=next.api.handle(blockMessage(payload,high.id),next.sender); await sentCount(next,2);
  await next.api.handle({type:'pause',duration_ms:0},next.popup); await next.api.handle({type:'resume'},next.popup);
  next.answer(next.sent[1],{}); const result=await waiting;
  assert.equal(result.ok,false); await sentCount(next,3);
  assert.equal(next.sent[2].type,'cancel'); assert.equal(next.sent[2].assessment_id,next.sent[1].id);
  assert.equal(next.api.receipts.size,0);
});

test('the manifest covers new HTTP(S) documents and permits attaching to already-open tabs', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  assert.ok(manifest.permissions.includes('scripting'));
  assert.ok(manifest.permissions.includes('downloads'));
  assert.deepEqual(manifest.host_permissions, ['http://*/*', 'https://*/*']);
  assert.deepEqual(manifest.content_scripts[0].matches, ['http://*/*', 'https://*/*']);
  assert.equal(manifest.content_scripts[0].run_at, 'document_start');
  assert.deepEqual(manifest.content_scripts[0].js, ['shared.js', 'targets.js', 'secrets.js', 'content.js']);
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
    assert.deepEqual(injection.files, ['shared.js', 'targets.js', 'secrets.js', 'content.js']);
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

test('Pause and Resume publish the final global state and retired Disable is rejected', async () => {
  const h = harness(); await h.api.syncProtectionState();
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup); await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, false);
  assert.equal(h.alarms.has('muse-guard-protection-heartbeat'), false);
  await h.api.handle({ type: 'resume' }, h.popup); await h.api.syncProtectionState();
  assert.equal(h.heartbeats.at(-1).protection_enabled, true);
  assert.equal(h.alarms.get('muse-guard-protection-heartbeat').periodInMinutes, 0.5);
  const retired = await h.api.handle({ type: 'set-enabled', enabled: false }, h.popup);
  assert.equal(retired.ok, false);
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
  const h = harness(); await h.api.restoreMonitoring(); await h.api.syncProtectionState();
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

test('fresh context gains completed browser coverage only after the exact current page was assessed', async () => {
  const h = harness({}, { readyTabs: [7] }), request = currentMeasuredPage(h);
  await h.api.syncProtectionState();
  const unassessed = await contextReply(h);
  assert.equal(unassessed.context_error, undefined);
  assert.equal(unassessed.browser_coverage, undefined, 'A readable responding document alone does not establish analysis coverage.');
  assert.deepEqual(structuredClone(unassessed.page.evidence), measuredEvidence());
  const finding = await automaticResult(h, request, { risk_level: 'safe' });
  const completed = await contextReply(h);
  assert.equal(completed.browser_coverage.state, 'completed');
  assert.equal(completed.browser_coverage.assessment_id, finding.id);
  assert.equal(completed.browser_coverage.checked_at, h.now());
  assert.equal(completed.browser_coverage.expires_at, finding.expires_at);
  assert.deepEqual(Object.keys(completed.browser_coverage).sort(), ['assessment_id', 'checked_at', 'expires_at', 'state']);
  h.advance(300001);
  assert.equal((await contextReply(h)).browser_coverage, undefined, 'Expired page work is not fresh coverage.');
});

test('queued and in-flight page checks have bounded checking coverage without claiming completion', async () => {
  for (const queued of [false, true]) {
    const h = harness({}, { readyTabs: [7] }), request = currentMeasuredPage(h), jobs = [];
    await h.api.syncProtectionState();
    if (queued) {
      h.addTab(8); jobs.push(h.api.handle(h.automatic('page', 'proactive', 8), h.senderFor(8)));
      await sentCount(h, 1);
    }
    jobs.push(h.api.handle(request, h.sender));
    if (queued) await until(() => h.api.automaticQueue.size === 1);
    else await sentCount(h, 1);
    const pending = await contextReply(h), proof = pending.browser_coverage;
    assert.equal(proof.state, 'checking', queued ? 'queued' : 'in-flight');
    assert.match(proof.assessment_id, /^[a-f0-9-]{36}$/i);
    assert.equal(proof.checked_at, h.now());
    assert.equal(proof.expires_at - proof.checked_at, 35000);
    h.advance(35001);
    assert.equal((await contextReply(h)).browser_coverage, undefined, 'A stalled check cannot indefinitely suppress a fallback.');
    if (queued) { h.answer(h.sent[0], { risk_level: 'safe' }); await sentCount(h, 2); }
    h.answer(h.sent.at(-1), { risk_level: 'safe' }); await Promise.all(jobs);
  }
});

test('a completed concern earns coverage only after its avatar warning was delivered', async () => {
  for (const risk of ['medium', 'high']) {
    const h = harness({}, { readyTabs: [7] }), request = currentMeasuredPage(h);
    const finding = await automaticResult(h, request, { risk_level: risk });
    assert.equal((await contextReply(h)).browser_coverage.state, 'checking', 'Give the display request a short grace period.');
    h.advance(3001);
    assert.equal((await contextReply(h)).browser_coverage, undefined, 'A silently undelivered finding must allow native recovery.');
    await nativeCall(h, { ...blockMessage(request, finding.id), type: risk === 'medium' ? 'present-warning' : 'present-block' },
      { risk_level: risk });
    assert.equal((await contextReply(h)).browser_coverage.state, 'completed');
  }
});

test('unknown, failed and action-only assessments cannot establish completed page coverage', async () => {
  for (const kind of ['unknown', 'failed', 'link']) {
    const h = harness({}, { readyTabs: [7] }), page = currentMeasuredPage(h);
    await h.api.syncProtectionState();
    const request = kind === 'link' ? { ...page, action: h.api.core.normalizeAction({ kind: 'link', url: 'https://destination.test/' }) } : page;
    request.public_signature = h.api.core.publicSignature(request.action);
    const value = kind === 'unknown' ? { risk_level: 'unknown', decision: 'review' } :
      kind === 'failed' ? { risk_level: 'unknown', decision: 'review', ok: false } : { risk_level: 'safe' };
    await automaticResult(h, request, value);
    assert.equal((await contextReply(h)).browser_coverage, undefined, kind);
  }
});

test('page and source changes never borrow coverage from an earlier exact assessment', async () => {
  for (const change of ['visualRevision', 'quality', 'title', 'text', 'nonce', 'document', 'rawRoute']) {
    const h = harness({}, { readyTabs: [7] }), request = currentMeasuredPage(h);
    await automaticResult(h, request, { risk_level: 'safe' });
    const initial = await contextReply(h);
    assert.equal(initial.browser_coverage.state, 'completed', 'Fixture initially has exact coverage.');
    assert.match(initial.prediction_source_id, /^[0-9a-f-]{36}$/i);
    if (change === 'visualRevision') h.snapshot.page.evidence.visual_revision++;
    if (change === 'quality') h.snapshot.page.evidence.requires_visual = true;
    if (change === 'title') h.snapshot.page.title = 'Another opened message';
    if (change === 'text') h.snapshot.page.text = 'An unrelated message with a new instruction.';
    if (change === 'nonce') h.snapshot.nonce = 'replacement-content-document';
    if (change === 'document') h.api.documents.get(h.tab.id).documentId = 'replacement-browser-document';
    if (change === 'rawRoute') h.tab.url += '#new-email';
    const result = await contextReply(h);
    assert.equal(result.context_error, undefined, 'The changed page still supplies fresh context: ' + change);
    assert.equal(result.browser_coverage, undefined, 'The changed source needs its own assessment: ' + change);
    assert.notEqual(result.prediction_source_id, initial.prediction_source_id,
      'Every exact document, route or normalized evidence change rotates the attribution epoch: ' + change);
  }
});

test('fresh context and current prediction pushes share one epoch even without completed coverage', async () => {
  const h = harness({}, { readyTabs: [7] }), request = currentMeasuredPage(h);
  await until(() => h.heartbeats.length > 0); await h.api.pollMonitoringState();
  await automaticResult(h, request, { risk_level: 'unknown', decision: 'review' });
  const first = await contextReply(h);
  assert.equal(first.browser_coverage, undefined);
  await h.api.publishSelectedPrediction();
  assert.equal(h.predictions.at(-1).prediction.source_id, first.prediction_source_id);
  const again = await contextReply(h);
  assert.equal(again.prediction_source_id, first.prediction_source_id, 'Stable page identity survives repeated context requests.');
  h.tab.url += '#same-title-and-body-message';
  const newRoute = await contextReply(h); await h.api.publishSelectedPrediction();
  assert.notEqual(newRoute.prediction_source_id, first.prediction_source_id);
  assert.equal(h.predictions.at(-1).prediction.source_id, newRoute.prediction_source_id);
  assert.equal(h.sent.filter(value => value.type === 'assess').length, 1, 'Source alignment never adds inference.');
});

test('Pause and native disconnect remove old page coverage without removing explicit context', async () => {
  for (const change of ['pause', 'disconnect']) {
    const h = harness({}, { readyTabs: [7] }), request = currentMeasuredPage(h);
    await automaticResult(h, request, { risk_level: 'safe' });
    assert.equal((await contextReply(h)).browser_coverage.state, 'completed');
    if (change === 'pause') await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
    else { h.disconnect(); await h.api.syncProtectionState(true); }
    const result = await contextReply(h);
    assert.equal(result.context_error, undefined);
    assert.equal(result.browser_coverage, undefined, change);
    assert.ok(result.page.text, 'Explicit context remains available.');
  }
});

test('measured context permits cosmetic DOM revisions but rejects actual quality or visual changes', async () => {
  for (const change of ['cosmetic', 'visual', 'quality', 'legacy']) {
    const h = harness({}, { readyTabs: [7] });
    if (change !== 'legacy') await automaticResult(h, currentMeasuredPage(h), { risk_level: 'safe' });
    await h.api.syncProtectionState();
    let reads = 0;
    h.setSnapshotReply(() => {
      const value = structuredClone(h.snapshot);
      if (++reads === 2) {
        value.revision++;
        if (change === 'visual') value.page.evidence.visual_revision++;
        if (change === 'quality') value.page.evidence.requires_visual = true;
      }
      return value;
    });
    const result = await contextReply(h);
    if (change === 'cosmetic') {
      assert.equal(result.context_error, undefined);
      assert.deepEqual(structuredClone(result.page.evidence), measuredEvidence());
      assert.equal(result.browser_coverage.state, 'completed', 'A cosmetic revision does not discard exact completed work.');
    } else {
      assert.ok(result.context_error, change);
      assert.equal(result.page, undefined, 'Changed or legacy revision evidence is not sent to native.');
      assert.equal(result.browser_coverage, undefined);
    }
  }
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

test('native Pause cancels in-flight inference and clears all-tab decisions before its acknowledgement', async () => {
  const h = harness({}, { tabs: [{ id: 8, windowId: 2, url: 'https://second.test/', active: false }] });
  await h.api.syncProtectionState();
  const pending = h.api.handle(h.automatic(), h.sender); await sentCount(h, 1);
  h.monitoring.paused = true; h.monitoring.pause_until = 0; h.monitoring.revision = 50;
  await h.api.pollMonitoringState();
  const config = await h.api.config();
  assert.equal(config.active, false); assert.equal(config.monitoringRevision, 50);
  assert.equal(h.api.cache.size, 0); assert.equal(h.api.receipts.size, 0);
  assert.ok(h.sent.some(value => value.type === 'cancel' && value.assessment_id === h.sent[0].id));
  for (const id of [7, 8]) assert.ok(h.tabMessages.some(value => value.tabId === id && value.type === 'configuration-changed'));
  h.answer(h.sent[0]); const obsolete = await pending;
  assert.equal(obsolete.confirmed_extreme, false);
  await h.api.pollMonitoringState();
  assert.equal(h.monitoringRequests.at(-1).monitoring_revision, 50);
});

test('revision ordering prevents a late native Pause from reverting a later Resume', async () => {
  const h = harness(); await h.api.config();
  await Promise.all([
    h.api.applyMonitoringState({ paused: true, pause_until: 0, revision: 20 }),
    h.api.applyMonitoringState({ paused: false, pause_until: 0, revision: 21 }),
    h.api.applyMonitoringState({ paused: true, pause_until: 0, revision: 19 })
  ]);
  const state = await h.api.config();
  assert.equal(state.monitoringRevision, 21); assert.equal(state.active, true);
});

test('a disconnected native app never receives a falsely successful global pause result', async () => {
  const h = harness({}, { monitoringUnavailable: true }); await h.api.config();
  const result = await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  assert.equal(result.ok, false); assert.match(result.error, /Chrome is paused.*desktop checks/);
  assert.equal((await h.api.config()).active, false);
});

test('metadata reconnect remains active while paused and retrieves a native Resume after disconnect', async () => {
  const h = harness({ paused: true }); await h.api.restoreMonitoring(); await h.api.pollMonitoringState();
  assert.equal(h.alarms.get('muse-guard-monitoring-sync').periodInMinutes, 0.5);
  h.disconnect(); h.monitoring.paused = false; h.monitoring.pause_until = 0; h.monitoring.revision = 90;
  h.events.alarm({ name: 'muse-guard-monitoring-sync' });
  await until(() => h.local.monitoringRevision === 90);
  assert.equal((await h.api.config()).active, true); assert.ok(h.connectionCount() >= 2);
});

test('overlapping popup Pause and Resume mutations are serialized and acknowledge the latest applied state', async () => {
  const h = harness(); await h.api.restoreMonitoring(); await h.api.pollMonitoringState();
  const [pause, resume] = await Promise.all([
    h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup),
    h.api.handle({ type: 'resume' }, h.popup)
  ]);
  assert.equal(pause.ok, true); assert.equal(resume.ok, true);
  const commands = h.monitoringRequests.filter(value => value.type === 'monitoring-control');
  assert.deepEqual(commands.map(value => value.monitoring_command), ['pause', 'resume']);
  assert.equal(commands[1].monitoring_revision, commands[0].monitoring_revision + 1);
  assert.equal((await h.api.config()).active, true);
});

test('a late Chrome pause cannot overwrite a newer native Resume', async () => {
  const h = harness(); await h.api.syncProtectionState();
  await h.api.applyMonitoringState({ paused: false, pause_until: 0, revision: 5 });
  Object.assign(h.monitoring, { paused: false, pause_until: 0, revision: 6 });
  const late = await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  assert.equal(late.ok, false); assert.match(late.error, /newer setting/);
  assert.equal(h.monitoring.revision, 6); assert.equal(h.monitoring.paused, false);
  assert.equal((await h.api.config()).active, true);
});

function targetMeasurement(h, revision = 0) {
  return { version: 1, document_id: 'nonce-a', revision, measured_at: h.now(),
    rect: { x: 40, y: 80, width: 180, height: 42 },
    viewport: { width: 1000, height: 700, scroll_x: 0, scroll_y: 0, device_pixel_ratio: 2,
      visual_scale: 1, offset_x: 0, offset_y: 0 } };
}
async function lease(h) {
  await h.api.handle({ type: 'configuration', nonce: 'nonce-a' }, h.sender);
  await until(() => h.heartbeats.length > 0);
  await h.api.pollMonitoringState();
}
function secretMessage() {
  return { type: 'secret-paste', nonce: 'nonce-a', document_id: 'nonce-a', page_revision: 0,
    page: { title: 'Checkout', text: 'RAW_VALUE_MUST_NOT_PASS' },
    secret: { category: 'github_token', count: 1, categories: ['github_token'], phase: 'paste',
      value: 'RAW_VALUE_MUST_NOT_PASS', label: 'RAW_VALUE_MUST_NOT_PASS' } };
}
test('native availability expires and failed secret delivery revokes interception until a successful poll', async () => {
  const h = harness(); await lease(h);
  assert.ok((await h.api.handle({ type: 'configuration', nonce: 'nonce-a' }, h.sender)).native_available_until > h.now());
  h.advance(4501);
  assert.equal((await h.api.handle(secretMessage(), h.sender)).ok, false);
  await h.api.pollMonitoringState();
  const { result, request } = await nativeCall(h, secretMessage(), { ok: false });
  assert.equal(result.ok, false);
  assert.deepEqual(JSON.parse(JSON.stringify(request.secret)), { category: 'github_token', count: 1, categories: ['github_token'], phase: 'paste' });
  assert.equal(request.page.text, ''); assert.equal(request.page.url, 'https://shop.example.test/account');
  assert.ok(!JSON.stringify(request).includes('RAW_VALUE_MUST_NOT_PASS'));
  const before = h.sent.length;
  assert.equal((await h.api.handle(secretMessage(), h.sender)).ok, false); assert.equal(h.sent.length, before);
  assert.ok(h.tabMessages.some(value => value.type === 'native-availability' && value.available_until === 0));
});
test('secret warnings require the focused original document, global monitoring and valid static categories', async () => {
  for (const issue of ['hidden', 'document', 'pause', 'category']) {
    const h = harness(); await lease(h); const message = secretMessage();
    if (issue === 'hidden') h.focus(false);
    if (issue === 'document') h.api.documents.set(7, { nonce: 'replacement', documentId: 'replacement' });
    if (issue === 'pause') await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
    if (issue === 'category') message.secret.categories.push('arbitrary_private_text');
    const before = h.sent.length;
    if (issue === 'category') await assert.rejects(h.api.handle(message, h.sender));
    else assert.equal((await h.api.handle(message, h.sender)).ok, false, issue);
    assert.equal(h.sent.length, before, issue);
  }
});
test('precise warning targets bind current content geometry to trusted Chrome window and zoom', async () => {
  const h = harness({}, { zoom: 1.25 }), request = h.automatic('link'), finding = await automaticResult(h, request);
  const message = { ...blockMessage(request, finding.id), document_id: 'nonce-a', page_revision: 0,
    target: { ...targetMeasurement(h), browser_window: { id: 999, tab_id: 999, left: 9999 }, raw: 'PRIVATE' } };
  const { request: native } = await nativeCall(h, message);
  assert.equal(native.target.browser_window.id, 2); assert.equal(native.target.browser_window.tab_id, 7);
  assert.equal(native.target.browser_window.zoom, 1.25); assert.equal(native.target.browser_window.left, 80);
  assert.equal(native.target.viewport.device_pixel_ratio, 2); assert.ok(!JSON.stringify(native).includes('PRIVATE'));
  assert.equal(native.document_id, 'nonce-a'); assert.equal(native.tab_id, 7); assert.equal(native.window_id, 2);
});
test('changed or stale layout falls back to a warning without claiming an element target', async () => {
  for (const issue of ['revision', 'document', 'age', 'offscreen']) {
    const h = harness(), request = h.automatic('link'), finding = await automaticResult(h, request);
    const message = { ...blockMessage(request, finding.id), document_id: 'nonce-a', page_revision: 0, target: targetMeasurement(h) };
    if (issue === 'revision') h.snapshot.revision++;
    if (issue === 'document') h.snapshot.nonce = 'replacement';
    if (issue === 'age') message.target.measured_at -= 2501;
    if (issue === 'offscreen') message.target.rect.x = 1100;
    const { request: native } = await nativeCall(h, message);
    assert.equal(native.type, 'present-block'); assert.equal(native.target, undefined, issue);
  }
});
test('target invalidation carries source identity only and cannot be issued by a foreign document', async () => {
  const h = harness(); await lease(h);
  const { request } = await nativeCall(h, { type: 'target-invalidated', nonce: 'nonce-a', page_revision: 12, target: { raw: 'PRIVATE' } });
  assert.equal(request.document_id, 'nonce-a'); assert.equal(request.page_revision, 12); assert.equal(request.target, undefined);
  const before = h.sent.length;
  assert.equal((await h.api.handle({ type: 'target-invalidated', nonce: 'replacement', page_revision: 12 }, h.sender)).ok, false);
  assert.equal(h.sent.length, before);
});
test('download lifecycle reaches native inspection and repeated commands execute once with exact acknowledgements', async () => {
  const item = { id: 41, state: 'in_progress', paused: false, danger: 'safe', url: 'https://files.test/tool.dmg?token=PRIVATE', filename: '/tmp/tool.dmg' };
  const h = harness({}, { downloads: [item] });
  await sentCount(h, 1);
  const inspection = h.sent.find(value => value.type === 'download-inspect'); assert.ok(inspection);
  assert.equal(inspection.download.url, 'https://files.test/tool.dmg'); assert.ok(!JSON.stringify(inspection).includes('PRIVATE'));
  h.answer(inspection, { risk_level: 'high', decision: 'block' });
  await until(() => h.api.downloadGuard.pending().length === 1);
  const hold = h.api.downloadGuard.pending()[0], command = { command_id: 'command-1', ...hold, action: 'resume' };
  const first = h.api.processDownloadCommands([command]);
  await until(() => h.sent.some(value => value.type === 'download-command-result'));
  h.answer(h.sent.find(value => value.type === 'download-command-result')); await first;
  const second = h.api.processDownloadCommands([command]);
  await until(() => h.sent.filter(value => value.type === 'download-command-result').length === 2);
  h.answer(h.sent.filter(value => value.type === 'download-command-result').at(-1)); await second;
  assert.deepEqual(h.downloadOps, [['pause', 41], ['resume', 41]]);
  const ack = h.sent.filter(value => value.type === 'download-command-result').at(-1).download_command;
  assert.deepEqual(JSON.parse(JSON.stringify(ack)), { command_id: 'command-1', download_id: 41, hold_id: hold.hold_id, action: 'resume', ok: true });
});
test('popup download health exposes wiring and work counters without download identities', async () => {
  const missing = harness(); await missing.api.restoreMonitoring();
  const unavailable = await missing.api.handle({ type: 'popup-state' }, missing.popup);
  assert.deepEqual(JSON.parse(JSON.stringify(unavailable.downloads)), { available: false, started: false, paused: false, processing: 0, pending: 0 });
  const item = { id: 45, state: 'complete', exists: true, fileSize: 6, endTime: new Date().toISOString(), danger: 'safe', filename: '/tmp/PRIVATE.txt' };
  const h = harness({}, { downloads: [item] }); await sentCount(h, 1);
  const working = await h.api.handle({ type: 'popup-state' }, h.popup);
  assert.deepEqual(JSON.parse(JSON.stringify(working.downloads)), { available: true, started: true, paused: false, processing: 1, pending: 1 });
  assert.ok(!JSON.stringify(working.downloads).includes('PRIVATE'));
  assert.equal(h.heartbeats.length > 0, true, 'A file scan cannot hold the browser startup heartbeat.');
  h.answer(h.sent.find(value => value.type === 'download-inspect'), { risk_level: 'low', download_inspection: { status: 'scanned', scan_status: 'clean' } });
  await until(() => h.api.downloadGuard.status().processing === 0);
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  const paused = await h.api.handle({ type: 'popup-state' }, h.popup);
  assert.equal(paused.downloads.paused, true); assert.equal(paused.downloads.processing, 0);
});
test('MV3 download wake-up listeners register before asynchronous configuration startup', async () => {
  const h = harness({}, { downloads: [] });
  assert.equal(typeof h.events['download-created'], 'function');
  assert.equal(typeof h.events['download-changed'], 'function');
  assert.equal(h.api.downloadGuard.status().started, true);
  const item = { id: 46, state: 'complete', exists: true, fileSize: 6, endTime: new Date().toISOString(), danger: 'safe', filename: '/tmp/wake-up.txt' };
  h.downloadItems.set(46, item); h.events['download-created'](item);
  await sentCount(h, 1); assert.equal(h.sent[0].download.phase, 'complete');
  h.answer(h.sent[0], { risk_level: 'low', download_inspection: { status: 'scanned', scan_status: 'clean' } });
});
test('Pause cancels the original native download task and a late finding gains no hold or receipt', async () => {
  const item = { id: 47, state: 'complete', exists: true, fileSize: 6, endTime: new Date().toISOString(), danger: 'safe', filename: '/tmp/pause.txt' };
  const h = harness({}, { downloads: [item] }); await sentCount(h, 1);
  const inspection = h.sent.find(value => value.type === 'download-inspect');
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  const cancel = h.sent.find(value => value.type === 'cancel'); assert.ok(cancel);
  assert.equal(cancel.assessment_id, inspection.id); assert.notEqual(cancel.id, inspection.id);
  h.answer(cancel, { risk_level: 'unknown' }); h.answer(inspection, { risk_level: 'high', decision: 'block' });
  await until(() => h.api.downloadGuard.status().processing === 0);
  assert.equal(h.api.downloadGuard.pending().length, 0); assert.equal(h.api.receipts.size, 0); assert.equal(h.api.cache.size, 0);
  await h.api.downloadGuard.stop();
});
test('download timeout cancels the matching native task rather than leaving its scanner running', async () => {
  const item = { id: 48, state: 'complete', exists: true, fileSize: 6, endTime: new Date().toISOString(), danger: 'safe', filename: '/tmp/timeout.txt' };
  const h = harness({}, { downloads: [item] }); await sentCount(h, 1);
  const inspection = h.sent.find(value => value.type === 'download-inspect');
  const timer = h.timers.find(value => value.time === 75000); assert.ok(timer); timer.fn();
  await until(() => h.sent.some(value => value.type === 'cancel'));
  const cancel = h.sent.find(value => value.type === 'cancel'); assert.equal(cancel.assessment_id, inspection.id);
  h.answer(cancel, { risk_level: 'unknown' }); h.answer(inspection, { risk_level: 'high', decision: 'block' });
  await until(() => h.api.downloadGuard.status().processing === 0);
  assert.equal(h.api.downloadGuard.pending().length, 0); assert.equal(h.api.receipts.size, 0);
  await h.api.downloadGuard.stop();
});
test('tab activation, window movement and zoom invalidate only a previously bound target', async () => {
  for (const event of ['activated', 'window-bounds', 'zoom', 'detached']) {
    const h = harness(), request = h.automatic('link'), finding = await automaticResult(h, request);
    const message = { ...blockMessage(request, finding.id), document_id: 'nonce-a', page_revision: 0, target: targetMeasurement(h) };
    await nativeCall(h, message);
    const before = h.sent.length;
    h.events[event](event === 'window-bounds' ? { id: 2 } : event === 'detached' ? 7 : { tabId: 7 });
    await until(() => h.sent.length > before);
    const invalidation = h.sent.slice(before).find(value => value.type === 'target-invalidated'); assert.ok(invalidation, event);
    assert.equal(invalidation.tab_id, 7); assert.equal(invalidation.window_id, 2); assert.equal(invalidation.document_id, 'nonce-a');
    assert.ok(h.api.receipts.has(finding.id), 'Geometry invalidation does not clear the underlying warning.');
  }
});
test('global Pause releases guardian-owned download holds and pauses both page and download monitoring', async () => {
  const item = { id: 42, state: 'in_progress', paused: false, danger: 'safe', url: 'https://files.test/tool.dmg', filename: '/tmp/tool.dmg' };
  const h = harness({}, { downloads: [item] }); await sentCount(h, 1);
  h.answer(h.sent.find(value => value.type === 'download-inspect'), { risk_level: 'high', decision: 'block' });
  await until(() => h.api.downloadGuard.pending().length === 1);
  assert.equal((await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup)).ok, true);
  assert.deepEqual(h.downloadOps, [['pause', 42], ['resume', 42]]); assert.equal(h.api.downloadGuard.pending().length, 0);
  h.downloadItems.set(43, { ...item, id: 43 }); h.events['download-created'](h.downloadItems.get(43)); await turn(); await turn();
  assert.equal(h.sent.filter(value => value.type === 'download-inspect').length, 1);
});
test('monitoring polls deliver download commands and acknowledge execution without opening a file', async () => {
  const item = { id: 44, state: 'in_progress', paused: false, danger: 'safe', url: 'https://files.test/tool.dmg', filename: '/tmp/tool.dmg' };
  const h = harness({}, { downloads: [item] }); await sentCount(h, 1);
  h.answer(h.sent.find(value => value.type === 'download-inspect'), { risk_level: 'high', decision: 'block' });
  await until(() => h.api.downloadGuard.pending().length === 1);
  const hold = h.api.downloadGuard.pending()[0];
  h.monitoringCommands.push({ command_id: randomUUID(), download_id: hold.download_id, hold_id: hold.hold_id, action: 'cancel' });
  const poll = h.api.pollMonitoringState();
  await until(() => h.sent.some(value => value.type === 'download-command-result'));
  const ack = h.sent.find(value => value.type === 'download-command-result'); h.answer(ack); await poll;
  assert.equal(ack.download_command.ok, true); assert.deepEqual(h.downloadOps, [['pause', 44], ['cancel', 44]]);
  assert.equal(h.opened.length, 0);
});
test('target renewal cannot create a warning and carries fresh bound geometry only for the original active document', async () => {
  const h = harness(); await lease(h);
  const update = { type: 'target-update', nonce: 'nonce-a', document_id: 'nonce-a', page_revision: 0, target: targetMeasurement(h) };
  assert.equal((await h.api.handle(update, h.sender)).ok, false);
  const request = h.automatic('link'), finding = await automaticResult(h, request);
  await nativeCall(h, { ...blockMessage(request, finding.id), ...update, type: 'present-block' });
  h.advance(1000); update.target = targetMeasurement(h);
  const { request: native, result } = await nativeCall(h, update);
  assert.equal(result.ok, true); assert.equal(native.type, 'target-update'); assert.ok(native.target);
  assert.equal(native.page, undefined); assert.equal(native.action, undefined); assert.equal(native.assessment_id, undefined);
  assert.equal(native.target.browser_window.tab_id, 7); assert.equal(native.target.measured_at, h.now());
  h.snapshot.revision++;
  const before = h.sent.length;
  assert.equal((await h.api.handle(update, h.sender)).ok, false); assert.equal(h.sent.length, before);
});
test('Muse overlay focus loss permits only native-verified renewal, never a new secret intervention', async () => {
  const h = harness(); await lease(h);
  const request = h.automatic('link'), finding = await automaticResult(h, request);
  const geometry = { document_id: 'nonce-a', page_revision: 0, target: targetMeasurement(h) };
  await nativeCall(h, { ...blockMessage(request, finding.id), ...geometry });
  h.focus(false);
  const before = h.sent.length;
  h.events['window-focused'](-1); await turn();
  assert.equal(h.sent.length, before, 'WINDOW_ID_NONE alone cannot declare unchanged geometry stale.');
  const update = { type: 'target-update', nonce: 'nonce-a', ...geometry };
  const renewed = await nativeCall(h, update, { ok: true }); assert.equal(renewed.result.ok, true);
  const secretBefore = h.sent.length;
  assert.equal((await h.api.handle(secretMessage(), h.sender)).ok, false);
  assert.equal(h.sent.length, secretBefore, 'New interventions still require a focused Chrome window.');
  const rejected = await nativeCall(h, update, { ok: false }); assert.equal(rejected.result.ok, false, 'Native source rejection is final.');
  h.tab.active = false;
  const inactiveBefore = h.sent.length;
  assert.equal((await h.api.handle(update, h.sender)).ok, false); assert.equal(h.sent.length, inactiveBefore);
});
test('a real Chrome window focus change invalidates targets from other windows only', async () => {
  const h = harness(); await lease(h);
  const request = h.automatic('link'), finding = await automaticResult(h, request);
  await nativeCall(h, { ...blockMessage(request, finding.id), document_id: 'nonce-a', page_revision: 0, target: targetMeasurement(h) });
  const before = h.sent.length;
  h.events['window-focused'](2); await turn(); await turn();
  assert.equal(h.sent.slice(before).some(value => value.type === 'target-invalidated'), false);
  h.events['window-focused'](3);
  await until(() => h.sent.slice(before).some(value => value.type === 'target-invalidated'));
  assert.equal(h.sent.filter(value => value.type === 'target-invalidated').at(-1).window_id, 2);
});

test('prediction metadata follows selected tabs before inference and ignores background completions', async () => {
  const h = harness(); h.tab.title = 'Shop'; const other = h.addTab(8); other.title = 'Tab 8';
  await until(() => h.heartbeats.length > 0); await h.api.pollMonitoringState(); await turn();
  const first = h.api.handle(h.automatic('page', 'proactive'), h.sender); await sentCount(h, 1);
  await until(() => h.predictions.some(value => value.prediction.phase === 'checking'));
  const firstRequest = h.sent[0], firstSource = h.predictions.at(-1).prediction.source_id;
  assert.equal(h.predictions.at(-1).prediction.assessment_id, firstRequest.id);
  h.tab.active = false; other.active = true; h.events.activated({ tabId: 8 });
  await until(() => h.predictions.at(-1)?.prediction.tab_id === 8);
  const switchedAt = h.predictions.length - 1;
  assert.equal(h.predictions.at(-1).prediction.phase, 'waiting');
  assert.notEqual(h.predictions.at(-1).prediction.source_id, firstSource);
  const second = h.api.handle(h.automatic('page', 'proactive', 8), h.senderFor(8));
  h.answer(firstRequest, { risk_level: 'high' }); await first; await sentCount(h, 2);
  const secondRequest = h.sent.find(value => value.type === 'assess' && value.id !== firstRequest.id);
  await until(() => h.predictions.at(-1)?.prediction.assessment_id === secondRequest.id);
  h.answer(secondRequest, { risk_level: 'safe' }); await second;
  await until(() => h.predictions.at(-1)?.prediction.phase === 'completed');
  assert.equal(h.predictions.at(-1).prediction.assessment_id, secondRequest.id);
  h.answer(firstRequest, { risk_level: 'high' }); await turn();
  assert.ok(h.predictions.slice(switchedAt).every(value => value.prediction.tab_id === 8),
    'A late background result must never change the foreground source.');
  const metadata = JSON.stringify(h.predictions);
  assert.ok(!metadata.includes('session=secret') && !metadata.includes('Visible original context'));
  for (const { prediction } of h.predictions) {
    assert.match(prediction.source_id, /^[0-9a-f-]{36}$/i);
    assert.equal('risk_level' in prediction, false); assert.equal('summary' in prediction, false);
    assert.equal('url' in prediction, false); assert.equal('text' in prediction, false);
    assert.ok(prediction.expires_at > h.now() && prediction.expires_at <= h.now() + 10000);
  }
  assert.ok(h.predictions.every((value, index) => index === 0 ||
    value.prediction.expires_at > h.predictions[index - 1].prediction.expires_at),
    'Native can reject reordered updates even when phase changes share one millisecond.');
  assert.equal(h.sent.filter(value => value.type === 'assess').length, 2);
});

test('prediction source epochs rotate for routes, exact document evidence and nonce changes', async () => {
  const h = harness(); h.tab.title = 'Shop';
  await until(() => h.heartbeats.length > 0); await h.api.pollMonitoringState(); await turn();
  const initial = await automaticResult(h, h.automatic('page', 'proactive'), { risk_level: 'safe' });
  await until(() => h.predictions.at(-1)?.prediction.assessment_id === initial.id && h.predictions.at(-1)?.prediction.phase === 'completed');
  const before = h.predictions.at(-1).prediction.source_id;
  h.tab.url += '#another-message'; h.events.updated(7, { url: h.tab.url });
  await until(() => h.predictions.at(-1)?.prediction.source_id !== before);
  assert.equal(h.predictions.at(-1).prediction.phase, 'waiting');
  assert.equal(h.sent.filter(value => value.type === 'assess').length, 1, 'Attribution itself performs no inference.');
  let previous = h.predictions.at(-1).prediction.source_id;
  const sender = h.senderFor(7), request = h.automatic('page', 'proactive');
  for (const change of ['text', 'quality', 'document']) {
    const next = structuredClone(request);
    if (change === 'text') next.page.text = 'A newly selected public message asks a different question.';
    if (change === 'quality') next.page.evidence = { version: 1, primary_text_characters: 40,
      visible_text_characters: 40, substantial_visuals: 1, requires_visual: true, truncated: false, visual_revision: 1 };
    if (change === 'document') next.nonce = 'replacement-document';
    const result = await automaticResult(h, next, { risk_level: 'safe' }, sender);
    await until(() => h.predictions.at(-1)?.prediction.assessment_id === result.id && h.predictions.at(-1)?.prediction.phase === 'completed');
    assert.notEqual(h.predictions.at(-1).prediction.source_id, previous, change);
    previous = h.predictions.at(-1).prediction.source_id;
  }
});

test('prediction leases reuse cached native IDs and pause or disconnect never reconnect for attribution', async () => {
  const h = harness(); h.tab.title = 'Shop';
  await until(() => h.heartbeats.length > 0); await h.api.pollMonitoringState(); await turn();
  const request = h.automatic('page', 'proactive');
  const first = await automaticResult(h, request, { risk_level: 'safe' });
  await until(() => h.predictions.at(-1)?.prediction.phase === 'completed');
  const originalSource = h.predictions.at(-1).prediction.source_id;
  const calls = h.sent.filter(value => value.type === 'assess').length;
  const snapshots = h.tabMessages.filter(value => value.type === 'snapshot').length;
  const hit = await h.api.handle(request, h.sender); assert.equal(hit.id, first.id);
  await h.api.publishSelectedPrediction();
  assert.equal(h.predictions.at(-1).prediction.assessment_id, first.id);
  const updates = h.predictions.length;
  await h.api.pollMonitoringState(); await h.api.publishSelectedPrediction({ heartbeat: true });
  assert.equal(h.predictions.length, updates, 'An unchanged lease is renewed at most once every two seconds.');
  h.advance(2001); await h.api.pollMonitoringState();
  await until(() => h.predictions.length === updates + 1);
  assert.equal(h.predictions.at(-1).prediction.source_id, originalSource);
  assert.equal(h.sent.filter(value => value.type === 'assess').length, calls);
  assert.equal(h.tabMessages.filter(value => value.type === 'snapshot').length, snapshots, 'Metadata does not perform additional DOM extraction.');
  await h.api.handle({ type: 'pause', duration_ms: 0 }, h.popup);
  const pausedCount = h.predictions.length;
  h.advance(5000); await h.api.publishSelectedPrediction(); assert.equal(h.predictions.length, pausedCount);
  await h.api.handle({ type: 'resume' }, h.popup); await h.api.publishSelectedPrediction();
  assert.equal(h.predictions.at(-1).prediction.phase, 'waiting');
  assert.notEqual(h.predictions.at(-1).prediction.source_id, originalSource);
  h.disconnect(); const connections = h.connectionCount(), disconnectedCount = h.predictions.length;
  h.advance(5000); await h.api.publishSelectedPrediction();
  assert.equal(h.connectionCount(), connections); assert.equal(h.predictions.length, disconnectedCount);
});

test('a deferred prediction focus check cannot restore the previously selected tab', async () => {
  const h = harness(); h.tab.title = 'Shop'; const other = h.addTab(8); other.title = 'Second tab';
  await until(() => h.heartbeats.length > 0); await h.api.pollMonitoringState();
  await h.api.publishSelectedPrediction(); await turn();
  const blocked = h.blockNextWindowRead();
  const obsolete = h.api.publishSelectedPrediction({ tabID: 7, forceWaiting: true }); await blocked.began;
  h.tab.active = false; other.active = true; h.events.activated({ tabId: 8 });
  await until(() => h.predictions.at(-1)?.prediction.tab_id === 8);
  const count = h.predictions.length;
  blocked.release(); await obsolete; await turn();
  assert.equal(h.predictions.at(-1).prediction.tab_id, 8);
  assert.ok(h.predictions.slice(count).every(value => value.prediction.tab_id === 8));
  const focusedCount = h.predictions.length;
  h.focus(false); h.advance(5000); await h.api.publishSelectedPrediction();
  assert.equal(h.predictions.length, focusedCount, 'Unfocused Chrome does not renew the source lease.');
  assert.equal(h.sent.filter(value => value.type === 'assess').length, 0);
});
