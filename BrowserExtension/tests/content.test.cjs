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
  let deferredConfigs = options.deferredConfigs === true, presentResponse, secretResponse, targetResponse;
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
    if (message.type === 'configuration') return deferredConfigs ? new Promise((resolve, reject) => configs.push({ resolve, reject })) : Promise.resolve(config);
    if (message.type === 'assess') return new Promise(resolve => checks.push({ message, resolve }));
    if (message.type === 'present-block') return presentResponse ? presentResponse(message) : Promise.resolve({ ok: true, id: 'ui-' + messages.length, action_state: 'pending' });
    if (message.type === 'secret-paste') return secretResponse ? secretResponse(message) : Promise.resolve({ ok: true, decision: 'block' });
    if (message.type === 'target-update') return targetResponse ? targetResponse(message) : Promise.resolve({ ok: true });
    return Promise.resolve({ ok: true });
  } }; }
  w.chrome = { runtime: makeRuntime() };
  w.eval(fs.readFileSync(path.join(root, 'shared.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(root, 'targets.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(root, 'secrets.js'), 'utf8'));
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
    setSecretResponse(fn) { secretResponse = fn; },
    setTargetResponse(fn) { targetResponse = fn; },
    async reinject() { w.eval(fs.readFileSync(path.join(root, 'shared.js'), 'utf8')); w.eval(fs.readFileSync(path.join(root, 'content.js'), 'utf8')); await settle(); },
    invalidate() { w.chrome.runtime.id = undefined; },
    replaceRuntime() { w.chrome.runtime.id = undefined; w.chrome.runtime = makeRuntime(); },
    listenerCount(type) { return (listeners[type] || []).length; },
    receiverCount() { return receivers.size; },
    async foreground(value = true) { hidden = !value; w.document.dispatchEvent(new w.Event('visibilitychange')); await settle(); },
    setHidden(value) { hidden = value; },
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
    assert.equal(h.listenerCount('click'), 2); assert.equal(h.listenerCount('paste'), 1); assert.equal(h.receiverCount(), 1); assert.equal(h.intervals.size, 1);
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
    assert.equal(h.receiverCount(), 1); assert.equal(h.listenerCount('click'), 2); assert.equal(h.listenerCount('paste'), 1); assert.equal(h.intervals.size, 1);
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
test('only a consistent stamped high/block can interrupt automatically', () => {
  assert.equal(core.url('https://user:secret@example.test/path?otp=123#seed'), 'https://example.test/path');
  assert.equal(core.cleanText('Go https://user:secret@example.test/path?otp=123#seed now'), 'Go https://example.test/path now');
  const now = Date.now();
  assert.equal(core.isConfirmedExtreme(result('high', { confirmed_extreme: true, expires_at: now + 1 }), now), true);
  for (const value of [null, result('high'), result('medium', { confirmed_extreme: true, expires_at: now + 1 }),
    result('high', { ok: false, confirmed_extreme: true, expires_at: now + 1 }), result('high', { confirmed_extreme: true, expires_at: now })]) assert.equal(core.isConfirmedExtreme(value, now), false);
  assert.equal(core.verdict(result('high', { decision: 'allow', confirmed_extreme: true, expires_at: now + 1 })).decision, 'review');
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
    const link = h.w.document.getElementById('go'), first = await preflight(h, link, result('unknown', { ok: false }));
    const again = await preflight(h, link, result('unknown', { ok: false }));
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
test('successful unchanged pages do not poll the model; queue-pressure failures still retry', async () => {
  for (const first of ['high','unknown','pressure']) {
    const h = await harness('<p>Unchanged page context</p>');
    try {
      await h.advance(100); assert.equal(h.checks.length, 1);
      h.checks[0].resolve(first === 'high' ? h.extreme() : first === 'pressure' ? result('unknown', { ok: false, retry_after_ms: 15000 }) : result('unknown')); await h.settle();
      await h.advance(first === 'pressure' ? 14999 : 300000); assert.equal(h.checks.length, 1, first);
      if (first === 'pressure') { await h.advance(1); assert.equal(h.checks.length, 2, first); }
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
test('an expired hidden high finding refreshes on activation instead of disappearing into the scheduling cache', async () => {
  const h = await harness('<p>Suspicious public page</p>', { hidden:true });
  try {
    await h.advance(100); h.checks[0].resolve(h.extreme()); await h.settle();
    await h.advance(60000); assert.equal(h.checks.length,1,'A hidden unchanged page does not run recurring inference.');
    await h.foreground(); await h.advance(100);
    assert.equal(h.checks.length,2,'Activation refreshes a high finding whose warning receipt expired.');
    assert.equal(h.messages.some(item=>item.type==='present-block'),false,'The expired receipt is never presented.');
    h.checks[1].resolve(h.extreme({id:'refreshed-high'})); await h.settle();
    assert.equal(h.messages.filter(item=>item.type==='present-block').length,1);
  } finally { h.close(); }
});
test('explicit tab activation recovers a live listener after its initial configuration request failed', async () => {
  const h = await harness('<p>A page opened during a worker restart</p>', { deferredConfigs: true });
  try {
    h.configs[0].reject(new Error('The worker was unavailable')); await h.settle();
    await h.advance(1000); assert.equal(h.checks.length, 0);
    assert.equal((await h.message({ type: 'monitor-ready' })).ready, true);
    h.setDeferredConfigs(false);
    assert.deepEqual(structuredClone(await h.message({ type: 'monitor-activated' })), { ok: true, active: true });
    await h.advance(100);
    assert.equal(h.checks.length, 1);
    assert.ok(h.checks[0].message.page.text.includes('worker restart'));
  } finally { h.close(); }
});
test('explicit tab activation reconciles a missed global Pause and Resume without reviving older findings', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link);
    assert.equal(h.trigger(link).defaultPrevented, true);
    h.setConfig({ active: false, paused: true });
    assert.deepEqual(structuredClone(await h.message({ type: 'monitor-activated' })), { ok: true, active: false });
    const before = h.checks.length;
    assert.equal(h.trigger(link).defaultPrevented, false);
    await h.advance(1000); assert.equal(h.checks.length, before);
    h.setConfig({ active: true, paused: false });
    assert.deepEqual(structuredClone(await h.message({ type: 'monitor-activated' })), { ok: true, active: true });
    assert.equal(h.trigger(link).defaultPrevented, false, 'Resume cannot restore an older high finding.');
    await h.advance(100); assert.equal(h.checks.length, before + 1);
  } finally { h.close(); }
});
test('switching monitored tabs preserves checks without periodically repeating unchanged model work', async () => {
  const first = await harness('<p>Public content in the first tab</p>');
  const second = await harness('<p>Public content in the second tab</p>', { hidden: true });
  try {
    await first.advance(100); await second.advance(100);
    assert.equal(first.checks.length, 1); assert.equal(second.checks.length, 1);
    assert.notEqual(first.checks[0].message.nonce, second.checks[0].message.nonce);
    first.setHidden(true); second.setHidden(false);
    assert.equal((await second.message({ type: 'monitor-activated' })).active, true);
    await second.advance(100);
    assert.equal(second.checks.length, 1, 'Activation must reuse the current in-flight check.');
    first.checks[0].resolve(result('safe')); second.checks[0].resolve(result('safe'));
    await first.settle(); await second.settle();
    assert.equal(first.messages.some(message => message.type === 'cancel'), false);
    await first.advance(30000); await second.advance(30000);
    assert.equal(first.checks.length, 1, 'A hidden tab stays watched without repeating unchanged inference.');
    assert.equal(second.checks.length, 1);
    first.w.document.querySelector('p').textContent = 'Changed public content in the first tab';
    second.w.document.querySelector('p').textContent = 'Changed public content in the second tab';
    await first.settle(); await second.settle(); await first.advance(1200); await second.advance(1200);
    assert.equal(first.checks.length, 2, 'Relevant hidden-tab changes still get a fresh assessment.');
    assert.equal(second.checks.length, 2);
    assert.ok(first.checks[1].message.page.text.includes('first tab'));
    assert.ok(second.checks[1].message.page.text.includes('second tab'));
    first.noWarning(); second.noWarning();
  } finally { first.close(); second.close(); }
});
test('explicit tab activation keeps a fresh exact action finding without renewing its expiry', async () => {
  const h = await harness('<a id="go" href="https://destination.test/">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link);
    const before = h.checks.length;
    h.elapse(20000);
    assert.equal((await h.message({ type: 'monitor-activated' })).active, true);
    assert.equal(h.trigger(link).defaultPrevented, true, 'A configuration refresh alone does not invalidate current findings.');
    h.elapse(10001);
    assert.equal(h.trigger(link).defaultPrevented, false, 'Activation cannot extend a completed finding beyond its original TTL.');
    assert.equal(h.checks.length, before);
  } finally { h.close(); }
});
test('successful unchanged intent evidence is reused without turning an old finding into a block', async () => {
  const h = await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('go'); await preflight(h, link, result('unknown'));
    h.trigger(link, 'pointerdown'); await h.settle();
    assert.equal(h.checks.length, 1, 'Repeated exact intent reuses the completed non-high assessment.');
    assert.equal(h.trigger(link).defaultPrevented, false);
    h.elapse(core.ASSESSMENT_REUSE_MS + 1);
    const next = await preflight(h, link, h.extreme());
    assert.equal(h.checks.length, 2); assert.equal(h.trigger(link).defaultPrevented, true);
    h.elapse(30001); assert.equal(h.trigger(link).defaultPrevented, false);
    h.trigger(link, 'pointerdown'); await h.settle();
    assert.equal(h.checks.length, 3, 'High-risk action findings are never reused past thirty seconds.');
    assert.notEqual(next.message.action.kind, 'page');
  } finally { h.close(); }
});
test('content reuse cannot renew an older worker assessment beyond its original expiry', async () => {
  const h=await harness('<a id="go" href="https://destination.test/path">Continue</a>');
  try {
    const link=h.w.document.getElementById('go');
    await preflight(h,link,result('safe',{expires_at:h.now()+1000}));
    h.elapse(1001); h.trigger(link,'pointerdown'); await h.settle();
    assert.equal(h.checks.length,2,'Local reuse must honor the remaining lifetime of a worker cache hit.');
  } finally { h.close(); }
});
test('unchanged page reuse expires only on a later event and changed public content refreshes immediately', async () => {
  const h = await harness('<p>First public state</p>');
  try {
    await h.advance(100); h.checks[0].resolve(result('safe')); await h.settle();
    await h.advance(core.ASSESSMENT_REUSE_MS + 1000); assert.equal(h.checks.length, 1);
    await h.message({ type: 'monitor-activated' }); await h.advance(100);
    assert.equal(h.checks.length, 2, 'A later activation may refresh an old unchanged assessment.');
    h.checks[1].resolve(result('safe')); await h.settle();
    h.w.document.querySelector('p').textContent = 'Second public state'; await h.settle(); await h.advance(1200);
    assert.equal(h.checks.length, 3); assert.ok(h.checks[2].message.page.text.includes('Second public state'));
  } finally { h.close(); }
});
test('scrolling into different visible content triggers inference while repeated same-view scroll events reuse it', async () => {
  const h = await harness('<section id="first"><p>First viewport</p></section><section id="second"><p>Second viewport</p></section>');
  try {
    let shown = 'first';
    h.w.HTMLElement.prototype.getBoundingClientRect = function () {
      const section = this.closest('#first,#second');
      return section && section.id !== shown ? { top:-200,bottom:-100,left:0,right:200,width:200,height:100 } :
        { top:0,bottom:100,left:0,right:200,width:200,height:100 };
    };
    await h.advance(100); h.checks[0].resolve(result('safe')); await h.settle();
    h.w.dispatchEvent(new h.w.Event('scroll')); await h.advance(400); assert.equal(h.checks.length, 1);
    shown = 'second'; h.w.dispatchEvent(new h.w.Event('scroll')); await h.advance(400);
    assert.equal(h.checks.length, 2); assert.ok(h.checks[1].message.page.text.includes('Second viewport'));
    assert.ok(!h.checks[1].message.page.text.includes('First viewport'));
  } finally { h.close(); }
});
test('automatic form prefetch and sensitive hover stay background; a real visible press or focus is intent', async () => {
  for (const event of ['pointerover','pointerdown','focusin']) {
    const h = await harness('<form action="https://signin.test/check"><input id="field" type="email"><button>Sign in</button></form>');
    try {
      const field = h.w.document.getElementById('field'); field.type = 'password'; h.trigger(field, event); await h.settle();
      if (event === 'pointerover') await h.advance(200);
      const formCheck = h.checks.find(item => item.message.action.kind === 'submit');
      assert.ok(formCheck, event); assert.equal(formCheck.message.purpose, event === 'pointerover' ? 'proactive' : 'intent', event);
    } finally { h.close(); }
  }
  const hidden = await harness('<form action="https://signin.test/check"><input id="field" type="password"><button>Sign in</button></form>', { hidden:true });
  try {
    hidden.trigger(hidden.w.document.getElementById('field'), 'focusin'); await hidden.settle();
    assert.ok(hidden.checks.filter(item => item.message.action.kind === 'submit').every(item => item.message.purpose === 'proactive'));
  } finally { hidden.close(); }
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
test('bounded snapshots reject retired capture messages and introduce no risk DOM', async () => {
  const h = await harness('<p>' + 'Visible public content '.repeat(700) + '</p><a href="javascript:alert(1)">Script action</a>');
  try {
    const snap = await h.message({ type: 'snapshot' }); assert.ok(snap.page.text.length <= 6000); assert.equal('captureSupport' in snap, false);
    for (const type of ['prepare-capture', 'restore-capture', 'manual-result']) {
      assert.equal((await h.message({ type, nonce: snap.nonce })).ok, false);
    }
    assert.equal(h.trigger(h.w.document.querySelector('a')).defaultPrevented, false); h.noWarning();
  } finally { h.close(); }
});
test('long article snapshots reserve space for visible form safety metadata after many link destinations', async () => {
  const links = Array.from({ length: 12 }, (_, i) => '<a href="https://destination.test/' + i + '/' + 'long-path-'.repeat(24) + '">Read source ' + i + '</a>').join('');
  const h = await harness('<article><p>' + 'Public article copy '.repeat(300) + '</p>' + links +
    '<form action="https://signin.test/verify?token=FORM_URL_SECRET" method="post"><input type="password" value="PASSWORD_SECRET"><button>Verify account</button></form></article>');
  try {
    const { page } = await h.message({ type: 'snapshot' });
    assert.ok(page.text.length <= 6000);
    assert.ok(page.text.includes('Public article copy'));
    assert.ok(page.text.includes('https://destination.test/0/'));
    assert.ok(page.text.includes('Read source 11'), 'Each selected visible link retains a label despite long earlier destinations.');
    assert.ok(page.text.includes('Form destination: https://signin.test/verify'), 'Long visible article/link text must not erase the visible form destination.');
    assert.ok(page.text.includes('field types: password'));
    assert.ok(page.text.includes('sensitive fields: true'));
    assert.ok(!page.text.includes('PASSWORD_SECRET') && !page.text.includes('FORM_URL_SECRET'));
  } finally { h.close(); }
});
test('snapshot budgets preserve three visible forms and bounded complete origins on crowded pages', async () => {
  const links = Array.from({ length: 12 }, (_, i) => '<a href="https://source' + i + '.test/' + 'path/'.repeat(200) + '?token=LINK_SECRET">Source ' + i + '</a>').join('');
  const longHost = 'a'.repeat(200) + '.test';
  const forms = '<form method="post" action="https://first.test/' + 'login/'.repeat(200) + '?token=FIRST_SECRET"><input type="email" value="EMAIL_SECRET"><input type="password" value="PASSWORD_SECRET"></form>' +
    '<form method="post" action="https://second.test/' + 'verify/'.repeat(200) + '?token=SECOND_SECRET"><input type="number" autocomplete="one-time-code" value="OTP_SECRET"></form>' +
    '<form method="get" action="https://' + longHost + '/search?token=THIRD_SECRET"><textarea>TEXTAREA_SECRET</textarea></form>';
  const h = await harness('<article>' + '<p>Public article copy.</p>'.repeat(300) + links + forms + '</article>');
  try {
    const { page } = await h.message({ type: 'snapshot' });
    assert.ok(page.text.length <= 6000);
    assert.equal((page.text.match(/Form destination:/g) || []).length, 3);
    for (let i = 0; i < 12; i++) assert.ok(page.text.includes('https://source' + i + '.test/'), 'Visible source ' + i);
    assert.ok(page.text.includes('Form destination: https://first.test/'));
    assert.ok(page.text.includes('Form destination: https://second.test/'));
    assert.ok(page.text.includes('Form destination: [destination too long]'));
    assert.ok(!page.text.includes('https://' + 'a'.repeat(100)), 'A shortened address must never invent a partial hostname.');
    assert.equal((page.text.match(/sensitive fields: true/g) || []).length, 2);
    assert.equal((page.text.match(/sensitive fields: false/g) || []).length, 1);
    assert.ok(page.text.includes('field types: email, password') && page.text.includes('field types: number') && page.text.includes('field types: textarea'));
    for (const secret of ['LINK_SECRET', 'FIRST_SECRET', 'EMAIL_SECRET', 'PASSWORD_SECRET', 'SECOND_SECRET', 'OTP_SECRET', 'THIRD_SECRET', 'TEXTAREA_SECRET']) assert.ok(!JSON.stringify(page).includes(secret), secret);
  } finally { h.close(); }
});
test('scrolled snapshots describe the current viewport and replace earlier text and destinations', async () => {
  const h = await harness('<section id="top"><h1>Top of guide</h1><a href="https://top.test/start">Top source</a></section><section id="bottom"><h2>Pay periods</h2><p>US bi-weekly. UK monthly.</p><a href="https://bottom.test/payroll?token=URL_SECRET">Payroll details</a></section>');
  try {
    let position = 'top';
    h.w.HTMLElement.prototype.getBoundingClientRect = function () {
      const section = this.closest('#top,#bottom');
      return section && section.id !== position ? { top: -500, bottom: -400, left: 0, right: 200, width: 200, height: 100 } :
        { top: 10, bottom: 60, left: 0, right: 200, width: 200, height: 50 };
    };
    const first = await h.message({ type: 'snapshot' });
    assert.ok(first.page.text.includes('Top of guide') && first.page.text.includes('https://top.test/start'));
    assert.ok(!first.page.text.includes('Pay periods') && !first.page.text.includes('https://bottom.test'));
    position = 'bottom';
    const next = await h.message({ type: 'snapshot' });
    assert.equal(next.nonce, first.nonce);
    assert.ok(next.page.text.includes('US bi-weekly. UK monthly.') && next.page.text.includes('https://bottom.test/payroll'));
    assert.ok(!next.page.text.includes('Top of guide') && !next.page.text.includes('https://top.test'));
    assert.ok(!JSON.stringify(next).includes('URL_SECRET'));
  } finally { h.close(); }
});
test('fresh SPA snapshots replace old route facts and preserve redacted route identity', async () => {
  const h = await harness('<main><h1>Product A</h1><p>Ships Monday.</p><a href="https://docs.test/product-a">Read A</a></main>');
  try {
    const before = await h.message({ type: 'snapshot' });
    h.w.history.pushState({}, '', '/product-b?session=NEW_ROUTE_SECRET#private');
    h.w.document.title = 'Product B';
    h.w.document.querySelector('main').innerHTML = '<h1>Product B</h1><p>Ships Friday.</p><a href="https://docs.test/product-b?token=DESTINATION_SECRET">Read B</a>';
    await h.settle();
    const after = await h.message({ type: 'snapshot' });
    assert.equal(after.nonce, before.nonce);
    assert.equal(after.page.url, 'https://shop.example.test/product-b');
    assert.equal(after.page.title, 'Product B');
    assert.ok(after.page.text.includes('Ships Friday.') && after.page.text.includes('https://docs.test/product-b'));
    for (const stale of ['Product A', 'Ships Monday.', 'product-a', 'NEW_ROUTE_SECRET', 'DESTINATION_SECRET']) assert.ok(!JSON.stringify(after).includes(stale), stale);
  } finally { h.close(); }
});
test('nested article, table, FAQ and navigation snapshots retain readable facts in order', async () => {
  const h = await harness('<nav><a href="https://guide.test/start">Guide home</a></nav><main><article><header><h1>Employee guide</h1></header><section><details open><summary>When am I paid?</summary><div><table><thead><tr><th>Region</th><th>Schedule</th></tr></thead><tbody><tr><td>US</td><td>Bi-weekly</td></tr><tr><td>UK</td><td>Monthly</td></tr></tbody></table></div></details></section></article></main>');
  try {
    const { page } = await h.message({ type: 'snapshot' });
    assert.ok(page.text.includes('Employee guide When am I paid? Region Schedule US Bi-weekly UK Monthly'));
    assert.ok(page.text.includes('Guide home → https://guide.test/start'));
    h.noWarning();
  } finally { h.close(); }
});
test('chat snapshots exclude hidden and private subtrees, entered fields and URL secrets across layouts', async () => {
  const h = await harness('<main><h1>Visible account help</h1><div hidden>HIDDEN_SECRET<a href="https://hidden.test">Hidden target</a></div><div aria-hidden="true">ARIA_SECRET</div><div data-muse-private>MARKED_SECRET</div><div style="visibility:hidden">INVISIBLE_SECRET</div><div style="opacity:0">TRANSPARENT_SECRET</div><form action="https://user:FORM_CREDENTIAL_SECRET@service.test/login?token=FORM_QUERY_SECRET" method="post"><label>Password<input type="password" value="INPUT_SECRET"></label><textarea>TEXTAREA_SECRET</textarea><select><option>OPTION_SECRET</option></select><div contenteditable="true">EDITOR_SECRET</div><button>Sign in</button></form><a href="https://user:LINK_CREDENTIAL_SECRET@service.test/help?token=LINK_QUERY_SECRET#LINK_FRAGMENT_SECRET">Read help</a></main>');
  try {
    const { page } = await h.message({ type: 'snapshot' });
    assert.ok(page.text.includes('Visible account help') && page.text.includes('Password'));
    assert.ok(page.text.includes('Read help → https://service.test/help'));
    assert.ok(page.text.includes('Form destination: https://service.test/login'));
    assert.ok(page.text.includes('field types: password, textarea, select-one'));
    for (const secret of ['HIDDEN_SECRET', 'ARIA_SECRET', 'MARKED_SECRET', 'INVISIBLE_SECRET', 'TRANSPARENT_SECRET', 'INPUT_SECRET', 'TEXTAREA_SECRET', 'OPTION_SECRET', 'EDITOR_SECRET', 'FORM_CREDENTIAL_SECRET', 'FORM_QUERY_SECRET', 'LINK_CREDENTIAL_SECRET', 'LINK_QUERY_SECRET', 'LINK_FRAGMENT_SECRET', 'https://hidden.test']) assert.ok(!JSON.stringify(page).includes(secret), secret);
  } finally { h.close(); }
});
test('pages with no readable text expose no invented evidence or private control contents', async () => {
  const h = await harness('<canvas>CANVAS_FALLBACK_SECRET</canvas><svg><text>SVG_SECRET</text></svg><iframe title="frame"></iframe><input type="text" value="INPUT_SECRET"><div hidden>HIDDEN_SECRET</div>');
  try {
    const snap = await h.message({ type: 'snapshot' });
    assert.equal(snap.page.text, 'Visible link destinations: Visible forms:');
    assert.equal('captureSupport' in snap, false);
    assert.ok(!JSON.stringify(snap).includes('_SECRET'));
    h.noWarning();
  } finally { h.close(); }
});

const secretToken = 'ghp_AbCdEf0123456789GhIjKlMnOpQrStUvWxYz';
function pasteEvent(text = secretToken) { return { cancelable: true, clipboardData: { getData: () => text } }; }
async function grantNativeLease(h) {
  await h.message({ type: 'native-availability', available_until: h.now() + 4500 });
}
test('integrated secret guard stops a trusted paste synchronously with metadata-only avatar delivery', async () => {
  const h = await harness('<h1>Checkout</h1><input id="secret" aria-label="Private value">');
  try {
    await grantNativeLease(h);
    const event = h.trigger(h.w.document.getElementById('secret'), 'paste', pasteEvent());
    assert.equal(event.defaultPrevented, true); assert.equal(event.stopped, true);
    assert.equal(h.messages.some(value => value.type === 'secret-paste'), false, 'The hold happens before asynchronous delivery.');
    await h.settle();
    const message = h.messages.find(value => value.type === 'secret-paste'); assert.ok(message);
    assert.deepEqual(JSON.parse(JSON.stringify(message.secret)), { category: 'github_token', count: 1, categories: ['github_token'], phase: 'paste' });
    assert.equal(message.page.text, ''); assert.equal(message.page.url, 'https://shop.example.test/account');
    assert.equal(message.document_id, message.nonce); assert.ok(message.target);
    assert.ok(!JSON.stringify(h.messages).includes(secretToken));
    h.noWarning();
  } finally { h.close(); }
});
test('secret protection requires a fresh lease and never traps ordinary, synthetic, paused or unavailable pastes', async () => {
  for (const issue of ['unavailable', 'expired', 'password', 'synthetic', 'paused', 'hidden']) {
    const h = await harness('<input id="field">');
    try {
      if (issue !== 'unavailable') await grantNativeLease(h);
      if (issue === 'expired') h.elapse(4501);
      if (issue === 'paused') { h.setConfig({ active: false, paused: true }); await h.message({ type: 'configuration-changed' }); }
      if (issue === 'hidden') h.setHidden(true);
      const event = h.trigger(h.w.document.getElementById('field'), 'paste', { ...pasteEvent(issue === 'password' ? 'ordinary password' : secretToken),
        ...(issue === 'synthetic' ? { isTrusted: false } : {}) });
      assert.equal(event.defaultPrevented, false, issue); await h.settle();
      assert.equal(h.messages.some(value => value.type === 'secret-paste'), false, issue);
    } finally { h.close(); }
  }
});
test('failed secret delivery invalidates the lease, never inserts text and a retry needs a new lease', async () => {
  const h = await harness('<textarea id="field"></textarea>');
  try {
    let attempts = 0;
    h.setSecretResponse(() => { attempts++; return Promise.resolve({ ok: false }); });
    await grantNativeLease(h); const field = h.w.document.getElementById('field');
    assert.equal(h.trigger(field, 'paste', pasteEvent()).defaultPrevented, true); await h.settle();
    assert.equal(h.trigger(field, 'paste', pasteEvent()).defaultPrevented, false); await h.settle(); assert.equal(attempts, 1);
    await grantNativeLease(h);
    assert.equal(h.trigger(field, 'paste', pasteEvent()).defaultPrevented, true); await h.settle(); assert.equal(attempts, 2);
    assert.equal(field.textContent, ''); assert.ok(!h.w.document.body.textContent.includes(secretToken));
  } finally { h.close(); }
});
test('precise element pointers invalidate after scroll, layout movement and document visibility changes', async () => {
  for (const issue of ['scroll', 'layout', 'visibility']) {
    const h = await harness('<a id="link" href="https://destination.test/path">Continue</a>');
    try {
      const link = h.w.document.getElementById('link'); await preflight(h, link);
      const shown = h.messages.find(value => value.type === 'present-block'); assert.ok(shown.target);
      if (issue === 'scroll') h.trigger(link, 'scroll');
      if (issue === 'layout') { link.getBoundingClientRect = () => ({ x: 30, y: 20, left: 30, top: 20, right: 230, bottom: 70, width: 200, height: 50 }); await h.advance(150); }
      if (issue === 'visibility') await h.foreground(false);
      await h.settle();
      const invalidated = h.messages.find(value => value.type === 'target-invalidated'); assert.ok(invalidated, issue);
      assert.equal(invalidated.document_id, shown.document_id); assert.ok(invalidated.page_revision > shown.page_revision);
      assert.equal(invalidated.target, undefined); h.noWarning();
    } finally { h.close(); }
  }
});
test('unchanged warning elements renew their geometry lease without repeating inference or moving the avatar', async () => {
  const h = await harness('<a id="link" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('link'); await preflight(h, link);
    const original = h.messages.find(value => value.type === 'present-block');
    await h.advance(3500);
    const updates = h.messages.filter(value => value.type === 'target-update'); assert.ok(updates.length >= 3);
    for (const update of updates) {
      assert.equal(update.document_id, original.document_id); assert.equal(update.page_revision, original.page_revision);
      assert.ok(update.target.measured_at > original.target.measured_at);
      assert.deepEqual(update.target.rect, original.target.rect); assert.equal(update.page, undefined); assert.equal(update.action, undefined);
    }
    assert.equal(h.messages.filter(value => value.type === 'present-block').length, 1);
    h.trigger(link, 'scroll'); await h.settle(); const before = updates.length;
    await h.advance(2000); assert.equal(h.messages.filter(value => value.type === 'target-update').length, before);
  } finally { h.close(); }
});
test('dismissed native warnings and paused content stop geometry renewal without reviving a stale target', async () => {
  for (const issue of ['dismissed', 'pause']) {
    const h = await harness('<a id="link" href="https://destination.test/path">Continue</a>');
    try {
      let resolve;
      h.setTargetResponse(() => issue === 'dismissed' ? Promise.resolve({ ok: false }) : new Promise(done => { resolve = done; }));
      await preflight(h, h.w.document.getElementById('link')); await h.advance(1100);
      if (issue === 'pause') {
        assert.ok(resolve); h.setConfig({ active: false, paused: true }); await h.message({ type: 'configuration-changed' });
        resolve({ ok: true }); await h.settle();
      }
      const before = h.messages.filter(value => value.type === 'target-update').length;
      await h.advance(4000); assert.equal(h.messages.filter(value => value.type === 'target-update').length, before, issue);
      assert.ok(h.messages.some(value => value.type === 'target-invalidated'));
    } finally { h.close(); }
  }
});
test('input and DOM changes invalidate targets while preserving a fresh trusted viewport calibration', async () => {
  for (const issue of ['input', 'dom']) {
    const h = await harness('<a id="link" href="https://destination.test/path">Continue</a><input id="field"><p id="status">Ready</p>');
    try {
      const link = h.w.document.getElementById('link'), field = h.w.document.getElementById('field');
      h.trigger(link, 'pointermove', { clientX: 100, clientY: 30, screenX: 140, screenY: 174 });
      await preflight(h, link);
      const original = h.messages.find(value => value.type === 'present-block'); assert.ok(original.target.pointer);
      if (issue === 'input') h.trigger(field, 'input');
      if (issue === 'dom') h.w.document.getElementById('status').textContent = 'Updated';
      await h.settle();
      assert.ok(h.messages.some(value => value.type === 'target-invalidated'), issue);
      await grantNativeLease(h);
      assert.equal(h.trigger(field, 'paste', pasteEvent()).defaultPrevented, true); await h.settle();
      const message = h.messages.find(value => value.type === 'secret-paste'); assert.ok(message.target.pointer, issue);
      assert.deepEqual(message.target.pointer, original.target.pointer, issue);
      assert.ok(message.target.revision > original.target.revision, 'The old element geometry is not reused.');
    } finally { h.close(); }
  }
});
test('nonactivating overlay blur and focus preserve unchanged element targeting and its renewal', async () => {
  const h = await harness('<a id="link" href="https://destination.test/path">Continue</a>');
  try {
    const link = h.w.document.getElementById('link'); await preflight(h, link);
    const revision = (await h.message({ type: 'target-state' })).revision;
    const before = h.messages.filter(value => value.type === 'target-invalidated').length;
    h.trigger(link, 'blur'); h.trigger(link, 'focus'); await h.settle();
    assert.equal((await h.message({ type: 'target-state' })).revision, revision);
    assert.equal(h.messages.filter(value => value.type === 'target-invalidated').length, before);
    await h.advance(1100); assert.ok(h.messages.some(value => value.type === 'target-update'));
  } finally { h.close(); }
});
test('preserved pointer calibration is omitted after window movement, viewport resize or its expiry', async () => {
  for (const issue of ['window', 'viewport', 'age']) {
    const h = await harness('<input id="field">');
    try {
      const field = h.w.document.getElementById('field');
      h.trigger(field, 'pointermove', { clientX: 100, clientY: 30, screenX: 140, screenY: 174 });
      h.trigger(field, 'input');
      if (issue === 'window') Object.defineProperty(h.w, 'screenX', { value: h.w.screenX + 40, configurable: true });
      if (issue === 'viewport') Object.defineProperty(h.w, 'innerHeight', { value: h.w.innerHeight - 40, configurable: true });
      if (issue === 'age') h.elapse(12001);
      await grantNativeLease(h);
      h.trigger(field, 'paste', pasteEvent()); await h.settle();
      const message = h.messages.find(value => value.type === 'secret-paste'); assert.ok(message.target);
      assert.equal(message.target.pointer, undefined, issue);
    } finally { h.close(); }
  }
});
