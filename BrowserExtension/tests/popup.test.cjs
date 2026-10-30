'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const root = path.resolve(__dirname, '..');
const turn = () => new Promise(resolve => setImmediate(resolve));
const privateExplanation = 'MODEL_RISK_EXPLANATION_ONLY_FOR_AVATAR';
async function harness(options = {}) {
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'popup.html'), 'utf8'), { url: 'chrome-extension://test-id/popup.html', runScripts: 'outside-only' });
  const w = dom.window, requests = [], messages = [], events = [], stored = [], worker = [], notices = new Set();
  const tab = { id: 7, windowId: 2, url: 'https://example.test/path?private=secret', active: true };
  const snapshot = { nonce: 'content-a', revision: 0, page: { url: 'https://example.test/path', title: 'Example', text: 'Visible example text' } };
  let focused = true, normalTab = false, capture = async () => 'data:image/jpeg;base64,cmF3', now = 2000000000000;
  const intervals = [], clearedIntervals = [];
  const protection = { enabled: true, paused: false, pauseUntil: 0, active: true, supported: true, origin: 'https://example.test',
    result: { checked: true, risk_level: 'high', summary: privateExplanation, guidance: privateExplanation }, ...options };
  w.Date.now = () => now;
  w.setInterval = (callback, ms) => { intervals.push({ callback, ms }); return intervals.length; };
  w.clearInterval = id => clearedIntervals.push(id);
  Object.defineProperty(w.document, 'visibilityState', { get: () => 'visible' }); w.document.hasFocus = () => focused;
  Object.defineProperty(w.crypto, 'randomUUID', { value: randomUUID }); w.Blob = Blob;
  w.createImageBitmap = async () => ({ width: 3200, height: 2400, close() {} });
  w.OffscreenCanvas = class { constructor(width, height) { assert.equal(width, 1600); assert.equal(height, 1200); this.width = width; this.height = height; } getContext() { return { drawImage() {} }; } async convertToBlob() { return new Blob(['resized']); } };
  w.chrome = { runtime: {
    async sendMessage(message) {
      worker.push(message);
      if (message.type === 'popup-state') {
        if (protection.paused && protection.pauseUntil > 0 && protection.pauseUntil <= now) {
          protection.paused = false; protection.pauseUntil = 0;
        }
        protection.active = protection.enabled && !protection.paused;
        return structuredClone(protection);
      }
      if (message.type === 'pause') {
        assert.ok([0, 1800000].includes(message.duration_ms));
        protection.paused = true; protection.pauseUntil = message.duration_ms ? now + message.duration_ms : 0;
        return { ok: true };
      }
      if (message.type === 'resume') {
        protection.enabled = true; protection.paused = false; protection.pauseUntil = 0;
        return { ok: true };
      }
      if (message.type === 'status') return { ok: true, model_ready: true };
      throw new Error('Manual checks must not use the worker request path.');
    },
    connectNative(host) {
      assert.equal(host, 'com.antojoseph.museguard'); const listeners = [], disconnects = []; let disconnected = false;
      return { onMessage: { addListener: fn => listeners.push(fn) }, onDisconnect: { addListener: fn => disconnects.push(fn) },
        postMessage(request) {
          const entry = { request, reply(risk = 'safe', extra = {}) { listeners.forEach(fn => fn({ version: 1, id: request.id, ok: true, decision: risk === 'high' ? 'block' : 'allow', risk_level: risk, summary: privateExplanation, guidance: privateExplanation, categories: [], mode: request.mode, duration_ms: 12, ...extra })); } };
          requests.push(entry);
          if (request.type === 'notice') { notices.add(request.id); queueMicrotask(() => entry.reply('unknown', { ok: false, decision: 'review' })); }
          if (request.type === 'present' && notices.has(request.assessment_id)) queueMicrotask(() => entry.reply('unknown', { ok: false, decision: 'review' }));
        },
        disconnect() { if (!disconnected) { disconnected = true; disconnects.forEach(fn => fn()); } }
      };
    }
  }, tabs: {
    async getCurrent() { return normalTab ? { id: 99 } : undefined; }, async query() { return [{ ...tab }]; },
    async sendMessage(id, message) { assert.equal(id, 7); messages.push(message); return structuredClone(snapshot); },
    async captureVisibleTab(id) { assert.equal(id, 2); events.push('capture'); return capture(); }
  }, storage: { session: { async set(value) { stored.push(value); } } } };
  w.eval(fs.readFileSync(path.join(root, 'shared.js'), 'utf8')); w.eval(fs.readFileSync(path.join(root, 'popup.js'), 'utf8')); await turn();
  return { w, tab, snapshot, requests, messages, events, stored, worker, protection, intervals, clearedIntervals,
    advance(ms) { now += ms; },
    async tick() { for (const interval of intervals) interval.callback(); await turn(); await turn(); },
    async control(id) { w.document.getElementById(id).click(); await turn(); await turn(); },
    focus(value) { focused = value; }, normalTab(value) { normalTab = value; }, capture(callback) { capture = callback; },
    click(mode) { w.document.getElementById(mode + '-check').click(); },
    noRiskUI() { assert.equal(w.document.getElementById('summary'), null); assert.equal(w.document.getElementById('result'), null); assert.ok(!w.document.body.textContent.includes(privateExplanation)); },
    close() { w.dispatchEvent(new w.Event('pagehide')); w.close(); }
  };
}
async function requestCount(h, count) { for (let n = 0; n < 30 && h.requests.length < count; n++) await turn(); assert.ok(h.requests.length >= count); }
test('popup contains setup/status only and never renders old or new risk verdict explanations', async () => {
  const h = await harness(); try { h.noRiskUI(); h.click('text'); await requestCount(h, 1); h.requests[0].reply(); await turn(); await turn(); h.noRiskUI(); assert.match(h.w.document.getElementById('notice').textContent, /Check complete/); } finally { h.close(); }
});
test('manual vision uses direct native messaging and stores only completion metadata', async () => {
  const h = await harness(); try {
    h.click('vision'); await requestCount(h, 1); assert.equal(h.requests[0].request.mode, 'vision'); assert.equal(h.requests[0].request.action.method, 'GET');
    assert.deepEqual(h.events, ['capture']); assert.ok(h.requests[0].request.screenshot.length < 2_000_000);
    h.requests[0].reply(); await turn(); await turn(); h.noRiskUI();
    assert.ok(!JSON.stringify(h.stored).includes('data:image')); assert.ok(!JSON.stringify(h.stored).includes(privateExplanation)); assert.ok(!JSON.stringify(h.stored).includes('Visible example text'));
  } finally { h.close(); }
});
test('manual high risk and failed assessments are presented through the avatar receipt, not popup text', async () => {
  for (const failed of [false, true]) {
    const h = await harness(); try {
      h.click('text'); await requestCount(h, 1); const id = h.requests[0].request.id;
      h.requests[0].reply(failed ? 'unknown' : 'high', failed ? { ok: false, decision: 'review' } : {}); await requestCount(h, 2);
      assert.equal(h.requests[1].request.type, 'present'); assert.equal(h.requests[1].request.assessment_id, id); h.requests[1].reply('unknown'); await turn(); await turn(); h.noRiskUI();
    } finally { h.close(); }
  }
});
test('capture failure reports check status in popup and routes fixed unavailable notice to Muse', async () => {
  const h = await harness(); let reject; h.capture(() => new Promise((_resolve, fail) => { reject = fail; }));
  try {
    h.click('vision'); await turn(); assert.equal(h.w.document.getElementById('vision-check').disabled, true); reject(new Error('PRIVATE_CAPTURE_FAILURE_DETAIL'));
    await turn(); await turn(); assert.ok(h.requests.some(x => x.request.type === 'notice' && x.request.reason === 'unavailable'));
    h.noRiskUI(); assert.ok(!h.w.document.body.textContent.includes('PRIVATE_CAPTURE_FAILURE_DETAIL')); assert.match(h.w.document.getElementById('notice').textContent, /Check not completed/); assert.equal(h.w.document.getElementById('vision-check').disabled, false);
  } finally { h.close(); }
});
test('focus, URL and form revision changes never present a stale model verdict', async () => {
  for (const change of ['focus', 'revision', 'URL']) {
    const h = await harness(); try {
      h.click('text'); await requestCount(h, 1); const id = h.requests[0].request.id;
      if (change === 'focus') h.focus(false); if (change === 'revision') h.snapshot.revision++; if (change === 'URL') h.tab.url = 'https://example.test/other';
      h.requests[0].reply('high'); await turn(); await turn();
      assert.ok(!h.requests.some(x => x.request.type === 'present' && x.request.assessment_id === id)); assert.equal(h.stored.length, 0); h.noRiskUI();
    } finally { h.close(); }
  }
});
test('opening popup HTML as a normal tab never captures or analyses screen contents', async () => {
  const h = await harness(); h.normalTab(true); try { h.click('vision'); await turn(); await turn(); assert.equal(h.events.length, 0); assert.equal(h.requests.length, 0); h.noRiskUI(); } finally { h.close(); }
});

test('automatic protection covers all websites by default without a site opt-in gate', async () => {
  const h = await harness();
  try {
    assert.match(h.w.document.querySelector('h2').textContent, /All websites/);
    assert.equal(h.w.document.getElementById('site-toggle'), null);
    assert.equal(h.w.document.getElementById('enabled'), null);
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'On');
    assert.match(h.w.document.getElementById('protection-detail').textContent, /automatically.*high-risk/i);
    assert.equal(h.w.document.getElementById('pause-controls').hidden, false);
    assert.equal(h.w.document.getElementById('resume').hidden, true);
    assert.equal(h.w.document.getElementById('text-check').disabled, false);
    h.noRiskUI();
  } finally { h.close(); }
});

test('Pause 30 minutes uses the bounded global pause and displays a friendly countdown', async () => {
  const h = await harness();
  try {
    await h.control('pause-30');
    assert.deepEqual(JSON.parse(JSON.stringify(h.worker.find(message => message.type === 'pause'))), { type: 'pause', duration_ms: 1800000 });
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    assert.match(h.w.document.getElementById('protection-detail').textContent, /30 more minutes.*automatically/);
    assert.ok(!h.w.document.body.textContent.includes(String(h.protection.pauseUntil)));
    assert.equal(h.w.document.getElementById('pause-controls').hidden, true);
    assert.equal(h.w.document.getElementById('resume').hidden, false);
    assert.equal(h.w.document.getElementById('text-check').disabled, false, 'Manual checks remain explicit and available.');
    h.noRiskUI();
  } finally { h.close(); }
});

test('indefinite pause remains paused until the global Resume control is used', async () => {
  const h = await harness();
  try {
    await h.control('pause-until');
    assert.deepEqual(JSON.parse(JSON.stringify(h.worker.find(message => message.type === 'pause'))), { type: 'pause', duration_ms: 0 });
    assert.match(h.w.document.getElementById('protection-detail').textContent, /Paused until you resume/);
    h.advance(86400000); await h.tick();
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    await h.control('resume');
    assert.ok(h.worker.some(message => message.type === 'resume'));
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'On');
    assert.equal(h.w.document.getElementById('pause-controls').hidden, false);
    assert.equal(h.w.document.getElementById('resume').hidden, true);
    assert.equal(h.requests.length, 0, 'Pause controls do not start model inference.');
  } finally { h.close(); }
});

test('a previously disabled global setting is shown as paused and Resume enables it', async () => {
  const h = await harness({ enabled: false });
  try {
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    assert.match(h.w.document.getElementById('protection-detail').textContent, /until you resume/);
    await h.control('resume');
    assert.equal(h.protection.enabled, true);
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'On');
  } finally { h.close(); }
});

test('pause and resume work on an unsupported tab while manual checks stay disabled', async () => {
  const h = await harness({ supported: false, origin: null });
  try {
    assert.equal(h.w.document.getElementById('pause-30').disabled, false);
    assert.equal(h.w.document.getElementById('text-check').disabled, true);
    assert.equal(h.w.document.getElementById('vision-check').disabled, true);
    await h.control('pause-30');
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    await h.control('resume');
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'On');
    h.click('vision'); await turn();
    assert.equal(h.requests.length, 0); assert.equal(h.events.length, 0);
  } finally { h.close(); }
});

test('the open popup refreshes its remaining pause time and reflects automatic expiry', async () => {
  const h = await harness();
  try {
    await h.control('pause-30');
    assert.equal(h.intervals.length, 1); assert.equal(h.intervals[0].ms, 30000);
    h.advance(29 * 60000); await h.tick();
    assert.match(h.w.document.getElementById('protection-detail').textContent, /1 more minute\./);
    h.advance(60001); await h.tick();
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'On');
    assert.equal(h.w.document.getElementById('resume').hidden, true);
    assert.ok(!h.worker.some(message => message.type === 'resume'), 'The background owns timed expiry.');
  } finally { h.close(); }
  assert.deepEqual(h.clearedIntervals, [1]);
});

test('a pause remains available while an explicit manual check is running', async () => {
  const h = await harness();
  try {
    h.click('text'); await requestCount(h, 1);
    assert.equal(h.w.document.getElementById('text-check').disabled, true);
    assert.equal(h.w.document.getElementById('pause-30').disabled, false);
    await h.control('pause-30');
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    assert.equal(h.w.document.getElementById('text-check').disabled, true);
    h.requests[0].reply(); await turn(); await turn();
    assert.equal(h.w.document.getElementById('text-check').disabled, false);
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    h.noRiskUI();
  } finally { h.close(); }
});
