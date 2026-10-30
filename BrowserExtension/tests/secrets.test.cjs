const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const S = require('../secrets.js');
const token = 'ghp_' + 'aB3dE5gH7jK9mN2pQ4sT6vW8xY0zC1fR3uV5';
const seed = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const turn = () => new Promise(resolve => setImmediate(resolve));

function harness(options = {}) {
  const dom = new JSDOM('<form action="/collect"><input id="field"><button>Send</button></form><div id="chat" contenteditable="true"></div>',
    { url: options.url || 'https://untrusted.example.test/message' });
  const w = dom.window, notifications = [], failures = [];
  let active = true, available = true;
  const guard = S.createGuard({ window: w, isActive: () => active, isAvailable: () => available,
    contextForTarget: target => ({ pageURL: w.location.href, destinationURL: target.form?.action }),
    notify(metadata, target) { notifications.push({ metadata, target }); return options.notify ? options.notify(metadata, target) : true; },
    onUnavailable(metadata) { available = false; failures.push(metadata); }, deliveryTimeoutMS: 250 });
  function paste(text = token, target = w.document.getElementById('field'), extra = {}) {
    const event = { target, isTrusted: true, cancelable: true, defaultPrevented: false,
      clipboardData: { getData: format => format === 'text/plain' ? text : '' }, composedPath: () => [target, w.document, w],
      preventDefault() { this.defaultPrevented = true; }, stopImmediatePropagation() { this.stopped = true; }, ...extra };
    const blocked = guard.paste(event);
    return { event, blocked };
  }
  return { w, guard, paste, notifications, failures, setActive: value => active = value,
    setAvailable: value => available = value, close() { guard.dispose(); w.close(); } };
}

test('checksum-valid BIP39 English phrases use the pinned unchanged 2048-word list', () => {
  const file = fs.readFileSync(path.join(__dirname, '../../Sources/SentinelPet/Secrets/bip39-english.txt'), 'utf8');
  assert.equal(crypto.createHash('sha256').update(file).digest('hex'), '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda');
  assert.deepEqual(S.englishWords(), file.trim().split('\n'));
  assert.equal(S.validMnemonic(seed), true);
  assert.equal(S.detect(seed).category, 'wallet_seed');
  assert.equal(S.validMnemonic('abandon '.repeat(12)), false);
  assert.equal(S.validMnemonic('ordinary words about the weather and a friendly lunch with coworkers today'), false);
  const words = S.englishWords();
  for (const size of [16, 20, 24, 28, 32]) {
    for (let count = 0; count < 40; count++) {
      const entropy = crypto.randomBytes(size), checksum = crypto.createHash('sha256').update(entropy).digest();
      const bits = [...entropy].map(x => x.toString(2).padStart(8, '0')).join('') + checksum[0].toString(2).padStart(8, '0').slice(0, size / 4);
      const mnemonic = bits.match(/.{11}/g).map(group => words[parseInt(group, 2)]).join(' ');
      assert.equal(S.validMnemonic(mnemonic), true, `Independent SHA-256 entropy vector of ${size} bytes`);
    }
  }
});
test('recognizes strong provider formats without returning raw values or fingerprints', () => {
  const fixtures = [
    [token, 'github_token'], ['github_pat_' + 'aB3dE5gH7jK9mN2pQ4sT6vW8xY0zC1fR'.repeat(3), 'github_token'],
    ['sk-proj-' + 'aB3dE5gH7jK9mN2pQ4sT6vW8xY0zC1fR'.repeat(2), 'openai_key'],
    ['sk-ant-api03-' + 'aB3dE5gH7jK9mN2pQ4sT6vW8xY0zC1fR'.repeat(2), 'anthropic_key'],
    ['sk_live_' + 'aB3dE5gH7jK9mN2pQ4sT6vW8', 'stripe_secret_key'],
    ['xoxb-' + '1234567890-2345678901-aB3dE5gH7jK9mN2pQ4sT6vW8', 'slack_token'],
    ['aws_access_key_id=AKIA1234567890ABCDEF\naws_secret_access_key=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd', 'aws_credentials']
  ];
  for (const [value, category] of fixtures) {
    const result = S.detect(value);
    assert.equal(result?.category, category);
    assert.deepEqual(Object.keys(result).sort(), ['categories', 'category', 'count', 'label']);
    const metadata = JSON.stringify(result);
    assert.ok(!metadata.includes(value) && !metadata.includes('aB3dE5gH'));
    assert.ok(!metadata.includes('fingerprint') && !metadata.includes('sha256'));
  }
  assert.equal(S.detect(('ghp_' + 'x'.repeat(36) + '\n').repeat(10) + token)?.category, 'github_token',
    'Placeholder prefixes cannot hide a later real-looking credential.');
});
test('validates private key containers and ignores malformed/public/example values', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 1024 });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const pub = publicKey.export({ type: 'spki', format: 'pem' }).toString();
  assert.equal(S.detect(pem)?.category, 'private_key');
  assert.equal(S.detect(pub), null);
  assert.equal(S.detect('-----BEGIN PRIVATE KEY-----\n' + Buffer.from('not a valid private key container').toString('base64') + '\n-----END PRIVATE KEY-----'), null);
  for (const value of ['ordinary-password!123', '654321', 'AKIA1234567890ABCDEF', 'aws_secret_access_key=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd',
    'ghp_' + 'x'.repeat(36), 'github_pat_' + 'x'.repeat(80), 'sk-ant-api03-' + 'A'.repeat(64),
    'sk-proj-' + 'A'.repeat(64), 'sk_test_' + 'AbCdEf0123456789'.repeat(3),
    'AIza' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7R', '0x' + 'abcdef0123456789'.repeat(4),
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.aSignatureThatMayBeAPublicExample', 'x'.repeat(65537)]) {
    assert.equal(S.detect(value), null, `Not a secret detector match: ${value.slice(0, 24)}`);
  }
});
test('same-origin login is untouched; trusted credential settings require an exact origin and route', () => {
  assert.equal(S.shouldBlock(S.detect(token), { pageURL: 'https://github.com/acme/app/settings/secrets/actions/new', destinationURL: 'https://github.com/acme/app/settings/secrets/actions' }), false);
  assert.equal(S.shouldBlock(S.detect(token), { pageURL: 'https://github.com.evil.test/acme/app/settings/secrets/actions/new' }), true);
  assert.equal(S.shouldBlock(S.detect(token), { pageURL: 'https://github.com/acme/app/issues/123' }), true);
  assert.equal(S.shouldBlock(S.detect(token), { pageURL: 'https://github.com/acme/app/settings/secrets/actions/new', destinationURL: 'https://evil.test/collect' }), true);
  assert.equal(S.shouldBlock(S.detect(seed), { pageURL: 'https://github.com/acme/app/settings/secrets/actions/new' }), true);
  assert.equal(S.shouldBlock(S.detect('ordinary-password')), false);
});
test('trusted paste is stopped synchronously before insertion; only safe categories reach notify', async () => {
  const h = harness();
  try {
    for (const target of [h.w.document.getElementById('field'), h.w.document.getElementById('chat')]) {
      const { event, blocked } = h.paste(token, target);
      assert.equal(blocked, true); assert.equal(event.defaultPrevented, true); assert.equal(event.stopped, true);
      assert.equal(h.notifications.length, target.id === 'field' ? 0 : 1, 'Blocking precedes async notification.');
      await turn();
      const notice = h.notifications.at(-1);
      assert.equal(notice.target, target); assert.equal(notice.metadata.phase, 'paste');
      assert.ok(!JSON.stringify(notice.metadata).includes(token));
      assert.equal(target.value || target.textContent, '', 'Acknowledge/notification never inserts content.');
    }
  } finally { h.close(); }
});
test('pause, unavailable app, synthetic events, read-only fields and ordinary passwords do not trap paste', async () => {
  const h = harness();
  try {
    h.setActive(false); assert.equal(h.paste().blocked, false);
    h.setActive(true); h.setAvailable(false); assert.equal(h.paste().blocked, false);
    h.setAvailable(true); assert.equal(h.paste(token, undefined, { isTrusted: false }).blocked, false);
    assert.equal(h.paste('ordinary-password!123').blocked, false);
    const field = h.w.document.getElementById('field'); field.readOnly = true; assert.equal(h.paste().blocked, false);
    await turn(); assert.equal(h.notifications.length, 0);
  } finally { h.close(); }
});
test('failed avatar delivery never replays the secret and invalidates availability for a user retry', async () => {
  const h = harness({ notify: () => false });
  try {
    assert.equal(h.paste().blocked, true); await turn();
    assert.equal(h.failures.length, 1); assert.equal(h.w.document.getElementById('field').value, '');
    assert.equal(h.paste().blocked, false, 'Known-unavailable protection does not silently trap repeated attempts.');
    assert.ok(!JSON.stringify(h.failures).includes(token));
  } finally { h.close(); }
});
test('late notification and disposed contexts cannot revive stale warnings or insert secret text', async () => {
  let release;
  const h = harness({ notify: () => new Promise(resolve => release = resolve) });
  try {
    assert.equal(h.paste().blocked, true); await turn(); h.guard.dispose(); release(false); await turn();
    assert.equal(h.failures.length, 0); assert.equal(h.w.document.getElementById('field').value, '');
    assert.equal(h.paste().blocked, false);
  } finally { h.close(); }
  const h2 = harness();
  try { h2.paste(); h2.guard.dispose(); await turn(); assert.equal(h2.notifications.length, 0); }
  finally { h2.close(); }
});
test('form submission inspection reads values locally and never serializes them', async () => {
  const h = harness();
  try {
    const form = h.w.document.querySelector('form'); h.w.document.getElementById('field').value = token;
    const event = { target: form, isTrusted: true, cancelable: true, preventDefault() { this.defaultPrevented = true; }, stopImmediatePropagation() {} };
    assert.equal(h.guard.submit(event), true); assert.equal(event.defaultPrevented, true); await turn();
    assert.equal(h.notifications[0].metadata.phase, 'submit');
    assert.ok(!JSON.stringify(h.notifications[0].metadata).includes(token));
  } finally { h.close(); }
});
