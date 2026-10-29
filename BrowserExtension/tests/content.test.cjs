'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const { webcrypto } = require('node:crypto');
const root = path.resolve(__dirname, '..');
const core = require('../shared.js');
const turn = () => new Promise(resolve => setImmediate(resolve));
function result(risk = 'safe', extra = {}) {
  return { version: 1, id: 'assessment-1', ok: true, decision: risk === 'high' ? 'block' : 'allow', risk_level: risk,
    summary: 'Native risk explanation only', guidance: 'Native guidance only', categories: [], mode: 'text', duration_ms: 12, ...extra };
}
async function harness(html, options = {}) {
  const dom = new JSDOM(html, { url: 'https://shop.example.test/account?session=private#token', runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window, listeners = {}, observers = [], messages = [], checks = [], timers = new Map(), intervals = new Map(), configs = [], hashes = new Set(), receivers = new Set();
  let clock = 1000000, nextTimer = 0, receiver, hidden = options.hidden === true;
  let config = { enabled: true, active: true, supported: true, paused: false };
  let deferredConfigs = options.deferredConfigs === true, presentResponse;
  Object.defineProperty(w.document, 'visibilityState', { get: () => hidden ? 'hidden' : 'visible' });
  w.Date.now = () => clock;
  w.TextEncoder = TextEncoder;
  Object.defineProperty(w.crypto, 'subtle', { configurable: true, value: options.noSubtle ? undefined : options.digest ? { digest: options.digest } : {
    digest(...args) { const pending = webcrypto.subtle.digest(...args); hashes.add(pending); pending.finally(() => hashes.delete(pending)); return pending; }
  } });
  w.HTMLElement.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, bottom: 50, right: 200, width: 200, height: 50 });
  const computed = w.getComputedStyle.bind(w);
  w.getComputedStyle = element => { const s = computed(element); return { display: s.display || 'block', visibility: s.visibility || 'visible', opacity: s.opacity || '1' }; };
  for (const kind of ['HTMLInputElement', 'HTMLTextAreaElement', 'HTMLSelectElement']) Object.defineProperty(w[kind].prototype, 'value', {
    configurable: true, get() { throw new Error('Form value read'); }, set() { throw new Error('Form value write'); }
  });
  const on = w.addEventListener.bind(w);
  w.addEventListener = (type, fn, opts) => { (listeners[type] ||= []).push(fn); on(type, fn, opts); };
  const off = w.removeEventListener.bind(w);
  w.removeEventListener = (type, fn, opts) => { const list = listeners[type]; if (list?.includes(fn)) list.splice(list.indexOf(fn), 1); off(type, fn, opts); };
  const Observer = w.MutationObserver;
  w.MutationObserver = class extends Observer { constructor(fn) { super(fn); observers.push(this); } };
  w.setTimeout = (fn, delay = 0, ...args) => { const id = ++nextTimer; timers.set(id, { fn: () => fn(...args), at: clock + Math.max(0, delay), delay }); return id; };
  w.clearTimeout = id => timers.delete(id);
  w.setInterval = fn => { const id = ++nextTimer; intervals.set(id, fn); return id; }; w.clearInterval = id => intervals.delete(id);
  function makeRuntime() { return { id: 'extension-id', onMessage: {
    addListener(fn) { receiver = fn; receivers.add(fn); },
    removeListener(fn) { receivers.delete(fn); receiver = [...receivers].at(-1); }
  }, sendMessage(message) {
    messages.push(message);
    if (message.type === 'configuration') return deferredConfigs ? new Promise(resolve => configs.push({ resolve })) : Promise.resolve(config);
    if (message.type === 'assess') return new Promise(resolve => checks.push({ message, resolve }));
    if (message.type === 'present-block') return presentResponse ? presentResponse(message) : Promise.resolve({ ok: true, id: 'ui-' + messages.length, action_state: 'pending' });
    return Promise.resolve({ ok: true });
  } }; }
  w.chrome = { runtime: makeRuntime() };
  w.eval(fs.readFileSync(path.join(root, 'shared.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(root, 'content.js'), 'utf8'));
  async function settle() { await turn(); await Promise.all([...hashes]); await turn(); }
  await settle();
  function trigger(element, type = 'click', extra = {}) {
    const chain = [element]; for (let p = element.parentElement; p; p = p.parentElement) chain.push(p);
    const e = { type, target: element, isTrusted: true, defaultPrevented: false, button: 0, composedPath: () => [...chain, w.document, w],
      preventDefault() { this.defaultPrevented = true; }, stopImmediatePropagation() { this.stopped = true; }, ...extra };
    for (const listener of listeners[type] || []) { listener(e); if (e.stopped) break; }
    return e;
  }
  return { w, messages, checks, timers, intervals, configs, trigger, settle,
    now: () => clock,
    extreme: (extra = {}) => result('high', { confirmed_extreme: true, expires_at: clock + 30000, ...extra }),
    async advance(ms) {
      const target = clock + ms; let runs = 0;
      while (true) {
        const entries = [...timers].filter(([, v]) => v.at <= target).sort((a, b) => a[1].at - b[1].at);
        if (!entries.length) break;
        assert.ok(++runs < 100, 'Timer loop');
        const [id, task] = entries[0]; timers.delete(id); clock = task.at; task.fn(); await settle();
      }
      clock = target; await settle();
    },
    elapse(ms) { clock += ms; },
    setConfig(value) { config = { ...config, ...value }; },
    setDeferredConfigs(value) { deferredConfigs = value; },
    setPresent(fn) { presentResponse = fn; },
    async reinject() { w.eval(fs.readFileSync(path.join(root, 'shared.js'), 'utf8')); w.eval(fs.readFileSync(path.join(root, 'content.js'), 'utf8')); await settle(); },
    invalidate() { w.chrome.runtime.id = undefined; },
    replaceRuntime() { w.chrome.runtime.id = undefined; w.chrome.runtime = makeRuntime(); },
    listenerCount(type) { return (listeners[type] || []).length; },
    receiverCount() { return receivers.size; },
    async foreground(value = true) { hidden = !value; w.document.dispatchEvent(new w.Event('visibilitychange')); await settle(); },
    message: message => new Promise(resolve => receiver(message, { id: 'extension-id' }, resolve)),
    noWarning() { assert.equal(w.document.querySelector('muse-guard-panel,[role="alertdialog"],dialog'), null); assert.ok(!w.document.body.textContent.includes('Native risk explanation only')); },
    close() { observers.forEach(x => x.disconnect()); w.dispatchEvent(new w.Event('pagehide')); w.close(); }
  };
}
async function preflight(h, element, verdict) {
  const before = h.checks.length;
  h.trigger(element, 'pointerdown'); await h.settle();
  const check = h.checks.slice(before).find(x => x.message.action.kind !== 'page');
  assert.ok(check, 'Intent preflight requested'); check.resolve(verdict || h.extreme()); await h.settle(); return check;
}
test('existing-tab reinjection reuses one live monitor and preserves its document identity', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const first = await h.message({ type: 'snapshot' });
    assert.equal((await h.message({ type: 'monitor-ready' })).ready, true);
    await h.reinject(); await h.reinject();
    assert.equal(h.messages.filter(message => message.type === 'configuration').length, 1);
    assert.equal(h.listenerCount('click'), 1); assert.equal(h.receiverCount(), 1); assert.equal(h.intervals.size, 1);
    assert.equal((await h.message({ type: 'snapshot' })).nonce, first.nonce);
    await preflight(h, h.w.document.getElementById('go'));
    const before = h.messages.filter(message => message.type === 'present-block').length;
    assert.equal(h.trigger(h.w.document.getElementById('go')).defaultPrevented, true); await h.settle();
    assert.equal(h.messages.filter(message => message.type === 'present-block').length, before + 1);
    assert.equal(h.checks.length, 1);
  } finally { h.close(); }
});
test('invalidated extension contexts stop cached blockers and detach their listeners and timers', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link);
    h.invalidate();
    assert.equal(h.trigger(link).defaultPrevented, false, 'An invalid extension context cannot keep blocking old findings.');
    assert.equal(h.listenerCount('click'), 0); assert.equal(h.listenerCount('pointerdown'), 0);
    assert.equal(h.receiverCount(), 0); assert.equal(h.intervals.size, 0); assert.equal(h.timers.size, 0);
    const before = h.messages.length;
    h.trigger(link, 'pointerdown'); await h.advance(60000);
    assert.equal(h.messages.length, before, 'A disposed content world cannot send checks or warnings.');
  } finally { h.close(); }
});
test('reloaded extension replaces a stale monitor without reusing its cached high or paused state', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'), first = await h.message({ type: 'snapshot' });
    await preflight(h, link);
    h.setConfig({ active: false, paused: true }); h.replaceRuntime(); await h.reinject();
    assert.equal(h.receiverCount(), 1); assert.equal(h.listenerCount('click'), 1); assert.equal(h.intervals.size, 1);
    assert.equal((await h.message({ type: 'monitor-ready' })).ready, true);
    assert.notEqual((await h.message({ type: 'snapshot' })).nonce, first.nonce);
    assert.equal(h.trigger(link).defaultPrevented, false);
    const before = h.checks.length; h.trigger(link, 'pointerdown'); await h.advance(1000);
    assert.equal(h.checks.length, before, 'Hydration must respect the saved global pause.');
    h.setConfig({ active: true, paused: false }); await h.message({ type: 'configuration-changed' });
    h.trigger(link, 'pointerdown'); await h.settle(); assert.equal(h.checks.length, before + 1);
    h.checks.at(-1).resolve(h.extreme()); await h.settle(); assert.equal(h.trigger(link).defaultPrevented, true);
  } finally { h.close(); }
});
test('a restored back/forward-cache page reconciles a pause made while it was frozen', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link);
    h.w.dispatchEvent(new h.w.Event('pagehide'));
    h.setConfig({ active: false, paused: true });
    h.w.dispatchEvent(new h.w.PageTransitionEvent('pageshow', { persisted: true })); await h.settle();
    const before = h.checks.length;
    h.trigger(link, 'pointerdown'); await h.advance(1000);
    assert.equal(h.checks.length, before); assert.equal(h.trigger(link).defaultPrevented, false);
    h.setConfig({ active: true, paused: false });
    h.w.dispatchEvent(new h.w.PageTransitionEvent('pageshow', { persisted: true })); await h.settle();
    h.trigger(link, 'pointerdown'); await h.settle(); assert.equal(h.checks.length, before + 1);
  } finally { h.close(); }
});
test('only a consistent stamped high/block can interrupt automatically; explicit checks retain avatar presentation', () => {
  assert.equal(core.url('https://user:secret@example.test/path?otp=123#seed'), 'https://example.test/path');
  assert.equal(core.cleanText('Go https://user:secret@example.test/path?otp=123#seed now'), 'Go https://example.test/path now');
  const now = Date.now();
  assert.equal(core.isConfirmedExtreme(result('high', { confirmed_extreme: true, expires_at: now + 1 }), now), true);
  for (const value of [null, result('high'), result('medium', { confirmed_extreme: true, expires_at: now + 1 }),
    result('high', { ok: false, confirmed_extreme: true, expires_at: now + 1 }), result('high', { confirmed_extreme: true, expires_at: now })]) assert.equal(core.isConfirmedExtreme(value, now), false);
  assert.equal(core.verdict(result('high', { decision: 'allow', confirmed_extreme: true, expires_at: now + 1 })).decision, 'review');
  assert.equal(core.canPresent(result('high'), 'page', true), true);
  assert.equal(core.canPresent(result('medium'), 'page', true), true);
  assert.equal(core.canPresent(result('safe'), 'page', true), false);
  assert.equal(core.canPresent(result('high')), false);
  const publicSignature = core.publicSignature({ kind: 'link', url: 'https://user:secret@target.test/path?otp=secret', method: '', label: 'Open' }, ['PASSWORD']);
  assert.ok(!publicSignature.includes('secret')); assert.ok(publicSignature.includes('password')); assert.equal(JSON.parse(publicSignature)[0].method, 'GET');
});
test('unassessed links and forms proceed immediately without querying or showing a checking notice', async () => {
  const h = await harness('<a id="go" href="https://destination.test/pay">Continue</a><form id="f" action="https://destination.test/post" method="post"><input><button id="b">Send</button></form>');
  try {
    for (const [id, type] of [['go','click'], ['go','auxclick'], ['b','click'], ['f','submit']]) {
      const e = h.trigger(h.w.document.getElementById(id), type, type === 'auxclick' ? { button: 1 } : {});
      assert.equal(e.defaultPrevented, false); assert.equal(e.stopped, undefined);
    }
    assert.equal(h.checks.length, 0); assert.equal(h.messages.some(x => ['notice','decision','open-link'].includes(x.type)), false); h.noWarning();
  } finally { h.close(); }
});
test('visible text and intent metadata exclude private fields, nested text and URL secrets', async () => {
  const h = await harness('<p>Public notice</p><input value="INPUT_SECRET"><textarea>TEXTAREA_SECRET</textarea><select><option>SELECT_SECRET</option></select><div contenteditable>EDITABLE_SECRET</div><div data-private>PRIVATE_SECRET</div><div style="opacity:0"><span>OPACITY_SECRET</span></div><a id="go" href="https://destination.test/pay?token=actual-secret">Continue<span hidden>NESTED_SECRET</span><span style="display:none">STYLE_SECRET</span><span data-private>NESTED_PRIVATE_SECRET</span><span contenteditable>CHILD_EDIT_SECRET</span></a>');
  try {
    await preflight(h, h.w.document.getElementById('go'), result('unknown'));
    const payload = JSON.stringify(h.checks[0].message);
    for (const secret of ['INPUT_SECRET','TEXTAREA_SECRET','SELECT_SECRET','EDITABLE_SECRET','PRIVATE_SECRET','OPACITY_SECRET','NESTED_SECRET','STYLE_SECRET','NESTED_PRIVATE_SECRET','CHILD_EDIT_SECRET','actual-secret','?session']) assert.ok(!payload.includes(secret), secret);
    assert.equal(h.checks[0].message.purpose, 'intent'); assert.equal(h.checks[0].message.action.method, 'GET'); h.noWarning();
  } finally { h.close(); }
});
test('confirmed extreme exact-link cache stops only that action; bogus native Continue never replays it', async () => {
  const h = await harness('<a id="go" target="_blank" href="https://evil.test/login">Verify account</a><a id="other" href="https://safe.test/">Other</a>');
  try {
    h.setPresent(() => Promise.resolve({ ok: true, id: 'ui-high', action_state: 'continue' }));
    await preflight(h, h.w.document.getElementById('go'));
    const before = h.checks.length;
    assert.equal(h.trigger(h.w.document.getElementById('go')).defaultPrevented, true);
    assert.equal(h.trigger(h.w.document.getElementById('other')).defaultPrevented, false); await h.settle();
    assert.equal(h.checks.length, before); assert.equal(h.messages.some(x => x.type === 'open-link' || x.type === 'decision'), false);
    assert.ok(h.messages.some(x => x.type === 'present-block' && x.assessment_id === 'assessment-1')); h.noWarning();
  } finally { h.close(); }
});
test('medium, unknown, failed, unmarked high and expired findings never hold an action or warn automatically', async () => {
  for (const verdict of [result('medium'), result('unknown'), result('unknown', { ok: false }), result('high')]) {
    const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
    try {
      await preflight(h, h.w.document.getElementById('go'), verdict);
      assert.equal(h.trigger(h.w.document.getElementById('go')).defaultPrevented, false);
      assert.equal(h.messages.some(x => x.type === 'present-block'), false); h.noWarning();
    } finally { h.close(); }
  }
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    await preflight(h, h.w.document.getElementById('go'));
    h.elapse(30001); assert.equal(h.trigger(h.w.document.getElementById('go')).defaultPrevented, false);
  } finally { h.close(); }
});
test('in-progress preflight never delays a click and late results cannot replay a previous action', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); h.trigger(link, 'pointerdown'); await h.settle();
    assert.equal(h.checks.length, 1); assert.equal(h.trigger(link).defaultPrevented, false);
    h.checks[0].resolve(h.extreme()); await h.settle();
    assert.equal(h.messages.some(x => x.type === 'open-link'), false); assert.equal(h.trigger(link).defaultPrevented, true);
  } finally { h.close(); }
});
test('raw destination, raw SPA URL, label and page changes invalidate cached high immediately', async () => {
  for (const change of ['destination-query','page-query','label','text']) {
    const h = await harness('<p id="copy">Page context</p><a id="go" href="https://destination.test/path?route=first">Continue</a>');
    try {
      const link = h.w.document.getElementById('go'); await preflight(h, link);
      if (change === 'destination-query') link.href = 'https://destination.test/path?route=second';
      if (change === 'page-query') h.w.history.pushState({}, '', '?session=second');
      if (change === 'label') link.textContent = 'Different intent';
      if (change === 'text') h.w.document.getElementById('copy').textContent = 'Different page';
      assert.equal(h.trigger(link).defaultPrevented, false, change);
    } finally { h.close(); }
  }
});
test('private action fingerprints prevent query-only link/form changes from reusing a redacted background finding', async () => {
  for (const kind of ['link', 'submit']) {
    const h = await harness(kind === 'link' ? '<a id="go" href="https://destination.test/path?token=first-secret">Continue</a>' :
      '<form id="f" action="https://destination.test/path?token=first-secret"><button id="go">Continue</button></form>');
    try {
      const element = h.w.document.getElementById('go'), first = await preflight(h, element);
      assert.match(first.message.action_fingerprint, /^[0-9a-f]{64}$/);
      if (kind === 'link') element.href = 'https://destination.test/path?token=second-secret';
      else element.form.action = 'https://destination.test/path?token=second-secret';
      assert.equal(h.trigger(element).defaultPrevented, false);
      const second = await preflight(h, element, result('unknown'));
      assert.equal(first.message.public_signature, second.message.public_signature);
      assert.notEqual(first.message.action_fingerprint, second.message.action_fingerprint);
      assert.equal(h.trigger(element).defaultPrevented, false);
      assert.ok(!JSON.stringify(h.messages).includes('first-secret')); assert.ok(!JSON.stringify(h.messages).includes('second-secret'));
      const presentation = h.messages.find(x => x.type === 'present-block'); assert.equal(presentation.action_fingerprint, first.message.action_fingerprint);
    } finally { h.close(); }
  }
});
test('HTTP documents without SubtleCrypto use a stable opaque token for each exact local intent', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path?token=first">Continue</a>', { noSubtle: true });
  try {
    const link = h.w.document.getElementById('go'), first = await preflight(h, link, result('unknown'));
    const again = await preflight(h, link, result('unknown'));
    assert.match(first.message.action_fingerprint, /^[0-9a-f]{64}$/); assert.equal(first.message.action_fingerprint, again.message.action_fingerprint);
    link.href = 'https://destination.test/path?token=second';
    const second = await preflight(h, link, result('unknown')); assert.notEqual(second.message.action_fingerprint, first.message.action_fingerprint);
  } finally { h.close(); }
});
test('pause or changed intent while an async fingerprint is computing prevents assessment transmission', async () => {
  for (const change of ['pause', 'destination']) {
    let finish;
    const h = await harness('<a id="go" href="https://destination.test/path?token=first">Continue</a>', { digest: () => new Promise(resolve => { finish = resolve; }) });
    try {
      const link = h.w.document.getElementById('go'); h.trigger(link, 'pointerdown'); await h.settle(); assert.ok(finish); assert.equal(h.checks.length, 0);
      if (change === 'pause') { h.setConfig({ active: false, paused: true }); await h.message({ type: 'configuration-changed' }); }
      else link.href = 'https://destination.test/path?token=second';
      finish(new Uint8Array(32).buffer); await h.settle(); assert.equal(h.checks.length, 0); assert.equal(h.trigger(link).defaultPrevented, false);
    } finally { h.close(); }
  }
});
test('equivalent replacement nodes may reuse a still-exact public and local finding', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link);
    const replacement = link.cloneNode(true); link.replaceWith(replacement);
    assert.equal(h.trigger(replacement).defaultPrevented, true); await h.settle();
    assert.ok(h.messages.filter(x => x.type === 'present-block').length >= 2);
  } finally { h.close(); }
});
test('sensitive form metadata preflights without values; editing values preserves risk but method/type/target changes invalidate it', async () => {
  for (const change of ['input','method','type','target','destination-query']) {
    const h = await harness('<form id="f" action="https://destination.test/login?token=first" method="post"><input id="password" type="password" value="PASSWORD_SECRET"><button id="b">Sign in</button></form>');
    try {
      const form = h.w.document.getElementById('f'), button = h.w.document.getElementById('b');
      const check = h.checks.find(x => x.message.action.kind === 'submit'); assert.ok(check);
      assert.equal(check.message.action.sensitive, true); assert.ok(check.message.public_signature.includes('password'));
      assert.ok(!JSON.stringify(check.message).includes('PASSWORD_SECRET')); check.resolve(h.extreme()); await h.settle();
      if (change === 'input') h.trigger(h.w.document.getElementById('password'), 'input');
      if (change === 'method') form.method = 'get';
      if (change === 'type') h.w.document.getElementById('password').type = 'text';
      if (change === 'target') form.target = '_blank';
      if (change === 'destination-query') form.action = 'https://destination.test/login?token=second';
      assert.equal(h.trigger(button).defaultPrevented, change === 'input', change);
      assert.equal(h.trigger(form, 'submit', { submitter: button }).defaultPrevented, change === 'input', change); h.noWarning();
    } finally { h.close(); }
  }
});
test('focusing form fields and right/middle button clicks never become submissions even with a matching high finding', async () => {
  const h = await harness('<form id="f" action="https://destination.test/login"><input id="p" type="password"><button id="b">Sign in</button></form>');
  try {
    h.checks.find(x => x.message.action.kind === 'submit').resolve(h.extreme()); await h.settle();
    assert.equal(h.trigger(h.w.document.getElementById('p')).defaultPrevented, false);
    for (const [type, button] of [['click',2],['auxclick',1],['auxclick',2]]) assert.equal(h.trigger(h.w.document.getElementById('b'), type, { button }).defaultPrevented, false);
    assert.equal(h.trigger(h.w.document.getElementById('b')).defaultPrevented, true);
  } finally { h.close(); }
});
test('form prefetch is bounded and typed content/private editable mutations never cause input reads', async () => {
  const h = await harness(Array.from({ length: 8 }, (_, i) => '<form action="https://destination.test/' + i + '"><input type="password"><button>Send</button></form>').join(''));
  try { assert.equal(h.checks.filter(x => x.message.action.kind === 'submit').length, 2); await h.advance(100); assert.ok(h.checks.length <= 3); }
  finally { h.close(); }
});
test('hover and focus preflight wait for dwell, while leaving cancels the pending read', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); h.trigger(link, 'pointerover'); await h.advance(199);
    assert.equal(h.checks.filter(x => x.message.action.kind === 'link').length, 0);
    h.trigger(link, 'pointerout'); await h.advance(2);
    assert.equal(h.checks.filter(x => x.message.action.kind === 'link').length, 0);
    h.trigger(link, 'focusin'); await h.advance(200);
    assert.equal(h.checks.filter(x => x.message.action.kind === 'link').length, 1);
  } finally { h.close(); }
});
test('pausing invalidates pending preflights and late high cannot rehydrate the cache; resume starts fresh', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); h.trigger(link, 'pointerdown'); await h.settle(); const pending = h.checks[0];
    h.setConfig({ active: false, paused: true, pauseUntil: h.now() + 1800000 }); await h.message({ type: 'configuration-changed' });
    pending.resolve(h.extreme()); await h.settle();
    const count = h.checks.length; h.trigger(link, 'pointerdown'); await h.advance(1000);
    assert.equal(h.checks.length, count); assert.equal(h.trigger(link).defaultPrevented, false); assert.equal(h.messages.some(x => x.type === 'present-block'), false);
    h.setConfig({ active: true, paused: false, pauseUntil: null }); await h.message({ type: 'configuration-changed' }); await h.advance(100);
    assert.ok(h.checks.length > count); assert.equal(h.trigger(link).defaultPrevented, false);
  } finally { h.close(); }
});
test('out-of-order configuration responses cannot undo a newer Pause', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a>', { deferredConfigs: true });
  try {
    assert.equal(h.configs.length, 1); const paused = h.message({ type: 'configuration-changed' });
    h.configs[1].resolve({ enabled: true, supported: true, active: false, paused: true }); await paused;
    h.configs[0].resolve({ enabled: true, supported: true, active: true, paused: false }); await h.settle();
    h.trigger(h.w.document.getElementById('go'), 'pointerdown'); await h.advance(1000); assert.equal(h.checks.length, 0);
  } finally { h.close(); }
});
test('rapid Pause/Resume invalidates local findings even when both configuration reads already report active', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a><a id="next" href="https://other.test/">Other</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link); assert.equal(h.trigger(link).defaultPrevented, true);
    h.trigger(h.w.document.getElementById('next'), 'pointerdown'); await h.settle(); const late = h.checks.at(-1);
    h.setDeferredConfigs(true);
    const pauseNotice = h.message({ type: 'configuration-changed' }), resumeNotice = h.message({ type: 'configuration-changed' });
    assert.equal(h.trigger(link).defaultPrevented, false);
    h.configs[1].resolve({ enabled: true, supported: true, active: true, paused: false }); await resumeNotice;
    h.configs[0].resolve({ enabled: true, supported: true, active: true, paused: false }); await pauseNotice;
    late.resolve(h.extreme({ id: 'pre-pause-late' })); await h.settle();
    assert.equal(h.trigger(link).defaultPrevented, false); assert.equal(h.trigger(h.w.document.getElementById('next')).defaultPrevented, false);
  } finally { h.close(); }
});
test('a native presentation completing after Pause is immediately cancelled', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a>');
  try {
    let finish; h.setPresent(() => new Promise(resolve => { finish = resolve; }));
    await preflight(h, h.w.document.getElementById('go')); assert.ok(finish);
    h.setConfig({ active: false, paused: true }); await h.message({ type: 'configuration-changed' });
    finish({ ok: true, id: 'late-ui', action_state: 'pending' }); await h.settle();
    assert.ok(h.messages.some(x => x.type === 'cancel' && x.assessment_id === 'late-ui'));
  } finally { h.close(); }
});
test('unchanged page findings refresh after TTL; queue-pressure failures retry using the bounded hint', async () => {
  for (const first of ['high','unknown','pressure']) {
    const h = await harness('<p>Unchanged page context</p>');
    try {
      await h.advance(100); assert.equal(h.checks.length, 1);
      h.checks[0].resolve(first === 'high' ? h.extreme() : first === 'pressure' ? result('unknown', { ok: false, retry_after_ms: 15000 }) : result('unknown')); await h.settle();
      await h.advance(first === 'pressure' ? 14999 : 29999); assert.equal(h.checks.length, 1, first);
      await h.advance(first === 'pressure' ? 1 : 12); assert.equal(h.checks.length, 2, first);
    } finally { h.close(); }
  }
});
test('hidden tabs are scanned quietly and a fresh page-high warns on activation without a new model request', async () => {
  const h = await harness('<p>Suspicious public page</p>', { hidden: true });
  try {
    await h.advance(100); assert.equal(h.checks.length, 1);
    h.checks[0].resolve(h.extreme()); await h.settle(); assert.equal(h.messages.some(x => x.type === 'present-block'), false);
    await h.foreground(); assert.equal(h.messages.filter(x => x.type === 'present-block').length, 1);
    await h.advance(100); assert.equal(h.checks.length, 1);
  } finally { h.close(); }
});
test('a rejected native warning is retried on focus using the same fresh high finding', async () => {
  const h = await harness('<p>Suspicious public page</p>');
  try {
    let attempts = 0;
    h.setPresent(() => Promise.resolve(++attempts === 1 ? { ok: false, action_state: 'expired' } : { ok: true, id: 'accepted-ui', action_state: 'pending' }));
    await h.advance(100); h.checks[0].resolve(h.extreme()); await h.settle();
    assert.equal(attempts, 1);
    await h.foreground();
    assert.equal(attempts, 2); assert.equal(h.checks.length, 1);
    const warnings = h.messages.filter(x => x.type === 'present-block');
    assert.equal(warnings[0].assessment_id, warnings[1].assessment_id);
    await h.foreground(); assert.equal(attempts, 2);
  } finally { h.close(); }
});
test('a page-high warning cannot blanket-block an unassessed link', async () => {
  const h = await harness('<p>Public page context</p><a id="go" href="https://destination.test/">Continue</a>');
  try {
    await h.advance(100); h.checks.find(x => x.message.action.kind === 'page').resolve(h.extreme()); await h.settle();
    assert.equal(h.trigger(h.w.document.getElementById('go')).defaultPrevented, false); h.noWarning();
  } finally { h.close(); }
});
test('snapshots and screenshot preparation remain bounded and introduce no risk DOM', async () => {
  const h = await harness('<p>' + 'Visible public content '.repeat(700) + '</p><a href="javascript:alert(1)">Script action</a>');
  try {
    const snap = await h.message({ type: 'snapshot' }); assert.ok(snap.page.text.length <= 6000); assert.equal(snap.captureSupport, 2);
    assert.equal((await h.message({ type: 'prepare-capture', nonce: snap.nonce })).ok, true);
    assert.equal((await h.message({ type: 'prepare-capture', nonce: 'wrong' })).ok, false);
    assert.equal(h.trigger(h.w.document.querySelector('a')).defaultPrevented, false); h.noWarning();
  } finally { h.close(); }
});
