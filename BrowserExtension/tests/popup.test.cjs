'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const turn = () => new Promise(resolve => setImmediate(resolve));
async function harness(options = {}) {
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'popup.html'), 'utf8'), { url: 'chrome-extension://test-id/popup.html', runScripts: 'outside-only' });
  const w = dom.window, messages = [], intervals = [], cleared = [];
  let now = 2_000_000_000_000;
  const state = { active: true, paused: false, pauseUntil: 0, supported: true, readable: true, monitoringConfirmed: true, ...options };
  const health = { ok: true, model_ready: true };
  w.Date.now = () => now;
  w.setInterval = (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; };
  w.clearInterval = id => cleared.push(id);
  let failCommand = false;
  w.chrome = { runtime: { async sendMessage(message) {
    messages.push(message);
    if (message.type === 'popup-state') return { ...state };
    if (message.type === 'status') return { ...health };
    if (failCommand) return { ok: false, error: 'Chrome is paused. Open Muse Guard to pause desktop checks too.' };
    if (message.type === 'pause') { state.paused = true; state.active = false; state.pauseUntil = message.duration_ms ? now + message.duration_ms : 0; return { ok: true }; }
    if (message.type === 'resume') { state.paused = false; state.active = true; state.pauseUntil = 0; return { ok: true }; }
    throw new Error('Unexpected popup request.');
  } } };
  w.eval(fs.readFileSync(path.join(root, 'popup.js'), 'utf8')); await turn();
  return { w, messages, state, health, intervals, cleared,
    fail() { failCommand = true; },
    async tick() { for (const timer of intervals) timer.fn(); await turn(); await turn(); },
    async click(id) { w.document.getElementById(id).click(); await turn(); await turn(); },
    close() { w.dispatchEvent(new w.Event('pagehide')); w.close(); } };
}
test('popup is automatic-only and never exposes capture, manual assessment or model risk text', async () => {
  const h = await harness(); try {
    for (const id of ['text-check','vision-check','summary','result','site-toggle']) assert.equal(h.w.document.getElementById(id), null);
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Active');
    assert.match(h.w.document.body.textContent, /Chrome tabs automatically/);
    assert.match(h.w.document.body.textContent, /browser protection and desktop screen checks together/);
    assert.ok(h.messages.every(message => ['popup-state','status'].includes(message.type)));
  } finally { h.close(); }
});
test('one pause control supports 30 minutes and until-resumed, then Resume', async () => {
  const h = await harness(); try {
    await h.click('pause');
    assert.equal(h.messages.find(message => message.type === 'pause').duration_ms, 1800000);
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    assert.match(h.w.document.getElementById('protection-detail').textContent, /30 more minutes/);
    await h.click('resume');
    h.w.document.getElementById('pause-duration').value = '0';
    await h.click('pause');
    assert.equal(h.messages.filter(message => message.type === 'pause').at(-1).duration_ms, 0);
    assert.match(h.w.document.getElementById('protection-detail').textContent, /until you resume/);
  } finally { h.close(); }
});
test('connection health refreshes and enabled preference never masquerades as active protection while unavailable', async () => {
  const h = await harness(); try {
    h.health.ok = false; h.health.model_ready = false; await h.tick();
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Unavailable');
    assert.equal(h.w.document.getElementById('connection').textContent, 'Open the Muse Guard app');
    h.health.ok = true; await h.tick();
    assert.equal(h.w.document.getElementById('connection').textContent, 'Muse is getting ready');
    h.health.model_ready = true; await h.tick();
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Active');
  } finally { h.close(); }
});
test('an external native pause or resume appears without reopening the popup', async () => {
  const h = await harness(); try {
    h.state.paused = true; h.state.active = false; await h.tick();
    assert.equal(h.w.document.getElementById('resume').hidden, false);
    h.state.paused = false; h.state.active = true; await h.tick();
    assert.equal(h.w.document.getElementById('resume').hidden, true);
  } finally { h.close(); }
});
test('failed global pause acknowledgement is explained without claiming global success', async () => {
  const h = await harness(); try {
    h.fail(); await h.click('pause');
    assert.match(h.w.document.getElementById('notice').textContent, /Open Muse Guard to pause desktop checks too/);
  } finally { h.close(); }
});
test('restricted tabs report unreadable while global pause stays usable', async () => {
  const h = await harness({ supported: false, readable: false }); try {
    assert.equal(h.w.document.getElementById('tab-detail').textContent, 'Chrome does not allow Muse to read this tab.');
    assert.equal(h.w.document.getElementById('pause').disabled, false);
    await h.click('pause');
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Paused');
    assert.ok(!h.w.document.body.textContent.includes('Other supported tabs stay protected'));
  } finally { h.close(); }
});
test('closing popup only clears status refresh; there is no popup-owned model job', async () => {
  const h = await harness(); h.close(); assert.deepEqual(h.cleared, [1]);
});


test('a partial Chrome-only pause is never labelled all monitoring paused and can be retried', async () => {
  const h = await harness({ paused: true, active: false, monitoringConfirmed: false }); try {
    assert.equal(h.w.document.getElementById('protection-status').textContent, 'Pause pending');
    assert.match(h.w.document.getElementById('protection-detail').textContent, /Desktop monitoring has not confirmed/);
    assert.equal(h.w.document.getElementById('pause-controls').hidden, false);
    assert.ok(!h.w.document.getElementById('protection-detail').textContent.includes('All monitoring is paused'));
  } finally { h.close(); }
});
