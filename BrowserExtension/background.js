'use strict';
importScripts('shared.js');
const C = MuseGuardCore;
const HOST = 'com.antojoseph.museguard';
const RESUME_ALARM = 'muse-guard-resume';
const PROTECTION_HEARTBEAT_ALARM = 'muse-guard-protection-heartbeat';
const PROTECTION_HEARTBEAT_INTERVAL = 25000;
const CHAT_CONTEXT_POLL_INTERVAL = 1000;
const EXTREME_TTL = C.EXTREME_TTL_MS || 30000;
const MAX_QUEUED = 32;
let port = null, alarmKey = null;
let settingsTail = Promise.resolve();
let protectionGeneration = 0, pumping = false, foregroundBurst = 0, queueSequence = 0;
let activeAutomatic = null;
const pending = new Map(), cache = new Map(), receipts = new Map(), documents = new Map();
const automaticQueue = new Map(), latestSlots = new Map();
const actionEpochs = new Map(), activeActions = new Map();
const monitoringInFlight = new Map();
let openTabsHydration = null;
let heartbeatAlarmKey = null, heartbeatTask = null, heartbeatQueued = false, heartbeatForced = false;
let lastHeartbeatEnabled = null, lastHeartbeatAt = 0, lastHeartbeatSucceeded = false;
let chatContextTimer = null, chatContextFlight = null;
function beginAction(tabId) {
  actionEpochs.set(tabId, (actionEpochs.get(tabId) || 0) + 1);
  activeActions.set(tabId, (activeActions.get(tabId) || 0) + 1);
}
function endAction(tabId) { activeActions.set(tabId, Math.max(0, (activeActions.get(tabId) || 1) - 1)); }
function quietFailure(message) { return { ...C.failure(message), confirmed_extreme: false, retry_after_ms: 15000 }; }

function nativeRequest(payload, timeout = 35000, expectedPort = null, signal = null) {
  return new Promise(resolve => {
    const request = { ...payload, version: 1, id: crypto.randomUUID() };
    let finished = false, sentPort = null;
    const finish = value => {
      if (finished) return;
      finished = true; signal?.removeEventListener('abort', abort);
      clearTimeout(pending.get(request.id)?.timer); pending.delete(request.id); resolve(value);
    };
    const abort = () => {
      if (finished) return;
      finish(quietFailure('This scan was replaced by a newer or higher-priority check.'));
      // Release queued/native model work, not just the eventual local answer.
      if (request.type === 'assess' && sentPort && port === sentPort)
        void nativeRequest({ type: 'cancel', assessment_id: request.id }, 1500, sentPort);
    };
    try {
      if (signal?.aborted) { abort(); return; }
      signal?.addEventListener('abort', abort, { once: true });
      if (expectedPort && port !== expectedPort) { finish(C.failure('The Muse app disconnected.')); return; }
      if (!port) {
        const connected = chrome.runtime.connectNative(HOST);
        port = connected;
        connected.onMessage.addListener(value => { if (value && typeof value.id === 'string') pending.get(value.id)?.finish(value); });
        connected.onDisconnect.addListener(() => {
          if (port !== connected) return;
          const message = chrome.runtime.lastError?.message || 'The Muse app disconnected.';
          port = null; cache.clear(); receipts.clear();
          clearTimeout(chatContextTimer); chatContextTimer = null;
          for (const item of [...pending.values()]) item.finish(C.failure(message));
        });
        scheduleChatContextPoll(connected);
      }
      const timer = setTimeout(() => {
        if (request.type === 'assess') abort();
        else finish(C.failure('The local check timed out. This action has not been cleared.', request.id));
      }, timeout);
      pending.set(request.id, { finish, timer }); sentPort = port; port.postMessage(request);
    } catch (error) { finish(C.failure(error.message, request.id)); }
  });
}
function scheduleChatContextPoll(connected) {
  clearTimeout(chatContextTimer);
  if (port !== connected) return;
  chatContextTimer = setTimeout(() => {
    chatContextTimer = null;
    void pollChatContext(connected).catch(() => {}).finally(() => {
      if (port === connected) scheduleChatContextPoll(connected);
    });
  }, CHAT_CONTEXT_POLL_INTERVAL);
}
function contextOperation(operation, expiresAt, connected) {
  const remaining = expiresAt - Date.now();
  if (remaining <= 0) return Promise.reject(new Error('The Chrome context request expired. Try again.'));
  let timer;
  return Promise.race([Promise.resolve().then(() => {
    if (Date.now() >= expiresAt) throw new Error('The Chrome context request expired. Try again.');
    if (port !== connected) throw new Error('The Muse app disconnected.');
    return operation();
  }), new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('The Chrome context request expired. Try again.')), remaining);
  })]).finally(() => clearTimeout(timer));
}
async function currentChatTab(expiresAt, connected) {
  const tabs = await contextOperation(() => chrome.tabs.query({ active: true, lastFocusedWindow: true }), expiresAt, connected);
  const tab = tabs[0];
  if (!Number.isInteger(tab?.id) || tab.id <= 0 || !Number.isInteger(tab.windowId) || tab.windowId <= 0 ||
      !tab.active || tab.discarded || !C.url(tab.url)) throw new Error('Open a normal website in Chrome and try again.');
  return tab;
}
function sameChatTab(first, next) {
  return first.id === next.id && first.windowId === next.windowId && first.url === next.url && next.active === true;
}
function chatSnapshot(value, tab) {
  if (!value || typeof value.nonce !== 'string' || !/^[a-z0-9-]{1,256}$/i.test(value.nonce) ||
      !Number.isInteger(value.revision) || value.revision < 0 || value.page?.url !== C.url(tab.url) ||
      value.page.url.length > 4096 || typeof value.page.title !== 'string' || typeof value.page.text !== 'string')
    throw new Error('Muse could not read this tab. Refresh it and try again.');
  return { nonce: value.nonce, revision: value.revision,
    page: { url: C.url(tab.url), title: C.cleanText(value.page.title, 250), text: C.cleanText(value.page.text) } };
}
async function freshChatContext(expiresAt, connected) {
  const tab = await currentChatTab(expiresAt, connected);
  if (!await contextOperation(() => ensureTabMonitoring(tab.id), expiresAt, connected))
    throw new Error('Muse could not read this tab. Refresh it and try again.');
  if (!sameChatTab(tab, await currentChatTab(expiresAt, connected)))
    throw new Error('The active tab changed while Muse was reading it. Try again.');
  const first = chatSnapshot(await contextOperation(() => chrome.tabs.sendMessage(tab.id, { type: 'snapshot' }, { frameId: 0 }), expiresAt, connected), tab);
  if (!sameChatTab(tab, await currentChatTab(expiresAt, connected)))
    throw new Error('The active tab changed while Muse was reading it. Try again.');
  const latest = chatSnapshot(await contextOperation(() => chrome.tabs.sendMessage(tab.id, { type: 'snapshot' }, { frameId: 0 }), expiresAt, connected), tab);
  if (first.nonce !== latest.nonce || first.revision !== latest.revision || C.assessmentKey(first.page) !== C.assessmentKey(latest.page))
    throw new Error('The page changed while Muse was reading it. Try again.');
  const live = await contextOperation(() => chrome.tabs.get(tab.id), expiresAt, connected);
  if (!sameChatTab(tab, live) || !sameChatTab(tab, await currentChatTab(expiresAt, connected)))
    throw new Error('The active tab changed while Muse was reading it. Try again.');
  return { page: latest.page, tab_id: tab.id, window_id: tab.windowId, document_id: latest.nonce };
}
function pollChatContext(connected = port) {
  if (!connected || port !== connected) return Promise.resolve();
  if (chatContextFlight) return chatContextFlight;
  const task = (async () => {
    const request = await nativeRequest({ type: 'chat-context-poll', mode: 'text' }, 1500, connected);
    if (port !== connected || request?.ok !== true || typeof request.context_request_id !== 'string' ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.context_request_id) ||
        !Number.isFinite(request.context_expires_at) || request.context_expires_at <= Date.now()) return;
    const expiresAt = Math.min(request.context_expires_at, Date.now() + 5500);
    const payload = { type: 'chat-context-result', mode: 'text', context_request_id: request.context_request_id };
    try { Object.assign(payload, await freshChatContext(expiresAt, connected)); }
    catch (error) {
      const expected = ['The Chrome context request expired. Try again.', 'Open a normal website in Chrome and try again.',
        'Muse could not read this tab. Refresh it and try again.', 'The active tab changed while Muse was reading it. Try again.',
        'The page changed while Muse was reading it. Try again.'];
      payload.context_error = expected.includes(error?.message) ? error.message : 'Muse could not read this tab. Refresh it and try again.';
    }
    if (port === connected && Date.now() < request.context_expires_at)
      await nativeRequest(payload, Math.min(1500, request.context_expires_at - Date.now()), connected);
  })();
  chatContextFlight = task;
  task.finally(() => { if (chatContextFlight === task) chatContextFlight = null; }).catch(() => {});
  return task;
}
async function reconcileAlarm(value) {
  if (!chrome.alarms) return;
  const desired = value.paused && value.pauseUntil > Date.now() ? value.pauseUntil : 0;
  const key = String(desired);
  if (alarmKey === key) return;
  alarmKey = key;
  try {
    const alarm = await chrome.alarms.get(RESUME_ALARM);
    if (desired) {
      if (!alarm || Math.abs(alarm.scheduledTime - desired) > 1000) await chrome.alarms.create(RESUME_ALARM, { when: desired });
    } else if (alarm) await chrome.alarms.clear(RESUME_ALARM);
  } catch { alarmKey = null; }
}
async function reconcileProtectionAlarm(value) {
  if (!chrome.alarms) return;
  const enabled = value.enabled && !value.paused;
  if (heartbeatAlarmKey === enabled) return;
  heartbeatAlarmKey = enabled;
  try {
    const alarm = await chrome.alarms.get(PROTECTION_HEARTBEAT_ALARM);
    if (enabled) {
      if (!alarm || alarm.periodInMinutes !== 0.5) await chrome.alarms.create(PROTECTION_HEARTBEAT_ALARM, { periodInMinutes: 0.5 });
    } else if (alarm) await chrome.alarms.clear(PROTECTION_HEARTBEAT_ALARM);
  } catch { heartbeatAlarmKey = null; }
}
function settingsOperation(operation) {
  const result = settingsTail.then(operation, operation);
  settingsTail = result.then(() => {}, () => {});
  return result;
}
async function readConfig() {
  const saved = await chrome.storage.local.get({ configVersion: 0, enabled: true, paused: false, pauseUntil: 0 });
  const value = { enabled: saved.enabled !== false, paused: saved.paused === true,
    pauseUntil: Number.isFinite(saved.pauseUntil) && saved.pauseUntil > 0 ? saved.pauseUntil : 0 };
  if (!value.paused) value.pauseUntil = 0;
  if (value.paused && value.pauseUntil && value.pauseUntil <= Date.now()) { value.paused = false; value.pauseUntil = 0; }
  if (saved.configVersion !== 2 || saved.enabled !== value.enabled || saved.paused !== value.paused || saved.pauseUntil !== value.pauseUntil)
    await chrome.storage.local.set({ configVersion: 2, ...value });
  await reconcileAlarm(value);
  await reconcileProtectionAlarm(value);
  return { ...value, active: value.enabled && !value.paused };
}
// Migration/expiry and user mutations share one ordered storage lane. A slow
// startup read can never overwrite a later explicit Pause or Resume.
function config() { return settingsOperation(readConfig); }
async function writeConfig(value) {
  return settingsOperation(async () => {
    await chrome.storage.local.set({ configVersion: 2, ...value });
    alarmKey = null;
    heartbeatAlarmKey = null;
    return readConfig();
  });
}
function syncProtectionState(force = false) {
  heartbeatQueued = true; heartbeatForced ||= force;
  if (heartbeatTask) return heartbeatTask;
  const task = (async () => {
    while (heartbeatQueued) {
      heartbeatQueued = false;
      const forced = heartbeatForced; heartbeatForced = false;
      const generation = protectionGeneration, value = await config();
      if (generation !== protectionGeneration) { heartbeatQueued = true; continue; }
      const enabled = value.active, retryInterval = lastHeartbeatSucceeded ? PROTECTION_HEARTBEAT_INTERVAL : 5000;
      if (!forced && enabled === lastHeartbeatEnabled && Date.now() - lastHeartbeatAt < retryInterval) continue;
      lastHeartbeatEnabled = enabled; lastHeartbeatAt = Date.now();
      // This is connection state, never an inference or a page assessment.
      // It contains no URL, page text, screenshot, or browsing history.
      const result = await nativeRequest({ type: 'protection-state', mode: 'text', protection_enabled: enabled }, 3000);
      lastHeartbeatSucceeded = result?.ok === true;
      if (generation !== protectionGeneration) { heartbeatQueued = true; heartbeatForced = true; }
    }
  })();
  heartbeatTask = task;
  task.finally(() => {
    if (heartbeatTask === task) heartbeatTask = null;
    if (heartbeatQueued) void syncProtectionState().catch(() => {});
  }).catch(() => {});
  return task;
}
async function allowed(rawURL) { return !!C.url(rawURL) && (await config()).active; }
function context(sender, nonce) {
  if (sender.id !== chrome.runtime.id || sender.frameId !== 0 || !sender.tab || !C.url(sender.url) || typeof nonce !== 'string') throw new Error('This page is not supported.');
  return { tabId: sender.tab.id, windowId: sender.tab.windowId, rawURL: sender.url, documentId: sender.documentId, nonce };
}
function remember(ctx) { documents.set(ctx.tabId, { documentId: ctx.documentId, nonce: ctx.nonce }); }
async function current(ctx, active = false) {
  try {
    const tab = await chrome.tabs.get(ctx.tabId);
    const focused = !active || (tab.active && (await chrome.windows.get(tab.windowId)).focused);
    const known = documents.get(ctx.tabId);
    return tab.url === ctx.rawURL && focused && known?.nonce === ctx.nonce && (!ctx.documentId || known.documentId === ctx.documentId);
  } catch { return false; }
}
function saveReceipt(id, value) {
  for (const [key, item] of receipts) if (item.expiresAt <= Date.now()) receipts.delete(key);
  const receipt = { ...value, expiresAt: value.expiresAt || Date.now() + (value.presented ? 120000 : 15000) };
  receipts.set(id, receipt);
  setTimeout(() => {
    if (receipts.get(id) === receipt && receipt.expiresAt <= Date.now()) {
      receipts.delete(id); if (receipt.presented) void nativeRequest({ type: 'cancel', assessment_id: id }, 1500);
    }
  }, Math.max(1, receipt.expiresAt - Date.now()));
  if (receipts.size > 128) receipts.delete(receipts.keys().next().value);
  return receipt;
}
async function storeResult(ctx, result) {
  if (!await current(ctx)) return;
  await chrome.storage.session.set({ ['result:' + ctx.tabId]: { checked: result.ok === true, mode: result.mode, timestamp: Date.now() } });
  await chrome.action.setBadgeText({ tabId: ctx.tabId, text: '' });
}
function validatedPayload(message, ctx, allowUnsupported = false) {
  const page = message.page;
  if (!page || page.url !== C.url(ctx.rawURL) || typeof page.text !== 'string') throw new Error('The page changed before its check.');
  const action = C.normalizeAction(message.action || { kind: 'page' });
  if (!['page', 'link', 'submit'].includes(action.kind)) throw new Error('Unsupported page action.');
  if (action.kind !== 'page' && !action.url && !allowUnsupported) throw new Error('This action has no supported destination.');
  return { type: 'assess', mode: 'text', page: { url: page.url, title: C.cleanText(page.title, 250), text: C.cleanText(page.text) }, action };
}
function proofSignature(message, request, strict = false) {
  if (message.public_signature === undefined && !strict) return C.publicSignature(request.action);
  if (typeof message.public_signature !== 'string' || message.public_signature.length > 4096) throw new Error('This action proof is not valid.');
  let proof; try { proof = JSON.parse(message.public_signature); } catch { throw new Error('This action proof is not valid.'); }
  if (!Array.isArray(proof) || proof.length !== 2 || !Array.isArray(proof[1]) || proof[1].length > 32 ||
      proof[1].some(type => typeof type !== 'string' || !/^[a-z][a-z0-9-]{0,31}$/.test(type)) ||
      JSON.stringify(C.normalizeAction(proof[0])) !== JSON.stringify(request.action)) throw new Error('This action proof changed.');
  return C.publicSignature(request.action, proof[1]);
}
function actionFingerprint(message, strict = false) {
  if (message.action_fingerprint === undefined && !strict) return null;
  if (typeof message.action_fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(message.action_fingerprint)) throw new Error('This local action fingerprint is not valid.');
  return message.action_fingerprint;
}
function exactKey(ctx, request, signature, fingerprint = null) {
  // Full page URL remains local. Query-only SPA routes must not reuse another
  // route's result even though native evidence deliberately redacts queries.
  return JSON.stringify([ctx.tabId, ctx.documentId || null, ctx.nonce, ctx.rawURL, C.assessmentKey(request.page, request.action), signature, fingerprint]);
}
function slotKey(ctx, request, purpose) {
  const lane = request.action.kind === 'page' ? 'page' : request.action.kind === 'submit' && request.action.sensitive ? 'sensitive' : 'intent';
  return JSON.stringify([ctx.tabId, ctx.documentId || null, ctx.nonce, lane]);
}
function cachedResult(key, generation) {
  const saved = cache.get(key);
  if (!saved || saved.generation !== generation || saved.expiresAt <= Date.now()) { cache.delete(key); return null; }
  return { ...saved.result };
}
async function performAssessment(job) {
  if (job.generation !== protectionGeneration || !await allowed(job.ctx.rawURL) || !await current(job.ctx)) return quietFailure('This page check is no longer current.');
  if (job.generation !== protectionGeneration) return quietFailure('Automatic protection was paused.');
  const payload = { ...job.request };
  if (job.explicitPurpose) payload.purpose = job.purpose;
  const raw = await nativeRequest(payload, 35000, null, job.controller.signal), result = C.verdict(raw);
  if (job.controller.signal.aborted) return quietFailure('This scan was replaced by a newer or higher-priority check.');
  if (job.generation !== protectionGeneration || !await allowed(job.ctx.rawURL) || !await current(job.ctx, job.legacyHeld) ||
      latestSlots.get(job.slot) !== job.key) return quietFailure('A newer page or protection setting replaced this check.');
  if (job.legacyHeld === false && job.purpose === 'proactive' && (actionEpochs.get(job.ctx.tabId) || 0) !== job.actionEpoch)
    return quietFailure('A newer action check took priority.');
  if (job.generation !== protectionGeneration) return quietFailure('Protection settings changed during this check.');
  // Never turn a corrected/inconsistent result into a confirmed extreme.
  const extreme = raw?.ok === true && raw.decision === 'block' && raw.risk_level === 'high' && result.ok === true &&
    result.decision === 'block' && typeof result.id === 'string' && result.id.length > 0;
  const expiresAt = Date.now() + (result.risk_level === 'high' ? EXTREME_TTL : C.ASSESSMENT_REUSE_MS);
  const stamped = { ...result, confirmed_extreme: extreme, expires_at: expiresAt };
  if (result.id) saveReceipt(result.id, { ctx: job.ctx, result: stamped, kind: job.request.action.kind, manual: false,
    purpose: job.explicitPurpose ? job.purpose : null, extreme, key: job.key, signature: job.signature,
    time: Date.now(), expiresAt: extreme ? expiresAt : Date.now() + 15000, generation: job.generation });
  if (result.ok === true) {
    cache.set(job.key, { result: stamped, expiresAt, generation: job.generation });
    if (cache.size > 64) cache.delete(cache.keys().next().value);
  }
  await storeResult(job.ctx, stamped);
  if (job.generation !== protectionGeneration) return quietFailure('Protection settings changed during this check.');
  return stamped;
}
function sensitiveIntent(job) { return job?.purpose === 'intent' && job.request.action.kind === 'submit' && job.request.action.sensitive; }
async function preemptForSensitiveIntent(job) {
  const candidate = activeAutomatic;
  if (!sensitiveIntent(job) || !candidate || candidate.legacyHeld || sensitiveIntent(candidate) ||
      job.generation !== protectionGeneration || automaticQueue.get(job.slot) !== job) return;
  const focused = await current(job.ctx, true);
  // The focus query yields to Pause, navigation, queue replacement and native
  // completion. Only this still-owned intent may interrupt the captured job.
  if (focused && job.generation === protectionGeneration && automaticQueue.get(job.slot) === job &&
      latestSlots.get(job.slot) === job.key && activeAutomatic === candidate)
    candidate.controller.abort();
}
async function enqueueAssessment(job) {
  const earlier = automaticQueue.get(job.slot);
  latestSlots.set(job.slot, job.key);
  const saved = cachedResult(job.key, job.generation);
  if (saved) {
    if (earlier && earlier.key !== job.key) { automaticQueue.delete(job.slot); earlier.resolve(quietFailure('A newer snapshot replaced this queued check.')); }
    return Promise.resolve(saved);
  }
  if (activeAutomatic?.key === job.key && activeAutomatic.generation === job.generation) {
    if (earlier && earlier.key !== job.key) { automaticQueue.delete(job.slot); earlier.resolve(quietFailure('A newer snapshot replaced this queued check.')); }
    return activeAutomatic.promise;
  }
  if (earlier?.key === job.key && earlier.generation === job.generation) {
    // A real focus/press can promote its already-queued form preflight without
    // duplicating the same model request or allowing incidental hover to win.
    if (sensitiveIntent(job)) { earlier.purpose = 'intent'; earlier.explicitPurpose = true; }
    await preemptForSensitiveIntent(earlier);
    return earlier.promise;
  }
  if (earlier) earlier.resolve(quietFailure('A newer snapshot replaced this queued check.'));
  job.sequence = ++queueSequence;
  job.controller = new AbortController();
  job.promise = new Promise(resolve => { job.resolve = resolve; });
  automaticQueue.set(job.slot, job); latestSlots.set(job.slot, job.key);
  if (automaticQueue.size > MAX_QUEUED) {
    const oldest = [...automaticQueue.values()].sort((a,b) => a.sequence-b.sequence)[0];
    automaticQueue.delete(oldest.slot); oldest.resolve(quietFailure('The local queue is full. Muse will retry quietly.'));
  }
  if (activeAutomatic && (activeAutomatic.slot === job.slot && activeAutomatic.key !== job.key ||
      activeAutomatic.ctx.tabId === job.ctx.tabId && (activeAutomatic.ctx.rawURL !== job.ctx.rawURL ||
        activeAutomatic.ctx.nonce !== job.ctx.nonce || activeAutomatic.ctx.documentId !== job.ctx.documentId))) activeAutomatic.controller.abort();
  await preemptForSensitiveIntent(job);
  void pumpAutomatic(); return job.promise;
}
async function pickNext() {
  let focused = new Set();
  try { focused = new Set((await chrome.tabs.query({ active: true, lastFocusedWindow: true })).filter(tab => tab.active).map(tab => tab.id)); } catch {}
  const jobs = [...automaticQueue.values()];
  const sensitive = jobs.filter(job => sensitiveIntent(job) && focused.has(job.ctx.tabId));
  if (sensitive.length) return sensitive.sort((a,b) => a.sequence-b.sequence)[0];
  const background = jobs.filter(job => job.purpose === 'proactive' && !focused.has(job.ctx.tabId));
  const foreground = jobs.filter(job => job.purpose === 'intent' || focused.has(job.ctx.tabId));
  let pool;
  if (background.length && (foregroundBurst >= 3 || !foreground.length)) { pool = background; foregroundBurst = 0; }
  else { pool = foreground.length ? foreground : background; foregroundBurst++; }
  return pool.sort((a,b) => {
    const score = job => (job.purpose === 'intent' ? 4 : 0) + (focused.has(job.ctx.tabId) ? 2 : 0) + (job.request.action.sensitive ? 1 : 0);
    return pool === background ? a.sequence-b.sequence : score(b)-score(a) || a.sequence-b.sequence;
  })[0];
}
async function pumpAutomatic() {
  if (pumping) return; pumping = true;
  try {
    while (automaticQueue.size) {
      const job = await pickNext();
      if (!job || automaticQueue.get(job.slot) !== job) continue;
      automaticQueue.delete(job.slot); activeAutomatic = job;
      try { job.resolve(await performAssessment(job)); }
      catch { job.resolve(quietFailure('Muse could not finish this page check.')); }
      finally { activeAutomatic = null; }
    }
  } finally { pumping = false; if (automaticQueue.size) void pumpAutomatic(); }
}
async function assessPage(message, sender) {
  const ctx = context(sender, message.nonce); remember(ctx);
  void syncProtectionState().catch(() => {});
  if (!await allowed(ctx.rawURL)) return quietFailure('Automatic protection is paused.');
  if (message.purpose !== undefined && !['proactive', 'intent'].includes(message.purpose)) throw new Error('Unsupported check purpose.');
  const request = validatedPayload(message, ctx), signature = proofSignature(message, request, message.purpose !== undefined),
    fingerprint = actionFingerprint(message, message.purpose !== undefined);
  const purpose = message.purpose || (request.action.kind === 'page' ? 'proactive' : 'intent');
  const legacyHeld = message.purpose === undefined && request.action.kind !== 'page';
  if (legacyHeld) beginAction(ctx.tabId);
  const job = { ctx, request, signature, purpose, explicitPurpose: message.purpose !== undefined, legacyHeld,
    generation: protectionGeneration, actionEpoch: actionEpochs.get(ctx.tabId) || 0 };
  job.key = exactKey(ctx, request, signature, fingerprint); job.slot = slotKey(ctx, request, purpose);
  try {
    if (!await current(ctx, legacyHeld)) return quietFailure('The active page changed.');
    if (job.generation !== protectionGeneration || !await allowed(ctx.rawURL)) return quietFailure('Automatic protection was paused.');
    return await enqueueAssessment(job);
  } finally { if (legacyHeld) endAction(ctx.tabId); }
}
async function present(id, ctx) {
  const generation = protectionGeneration, receipt = receipts.get(id);
  if (!receipt || receipt.presented || receipt.expiresAt <= Date.now() || receipt.ctx.tabId !== ctx.tabId ||
      receipt.ctx.nonce !== ctx.nonce || !await current(ctx, true)) return C.failure('That page check is no longer current.');
  const held = ['link', 'submit'].includes(receipt.kind);
  if (receipt.purpose && !receipt.extreme && !receipt.forcePresent && !receipt.manual) return { ok: false };
  if (!receipt.forcePresent && !held && !C.canPresent(receipt.result, receipt.kind, receipt.manual)) return { ok: false };
  if (!await allowed(ctx.rawURL) || generation !== protectionGeneration || receipts.get(id) !== receipt) return C.failure('Automatic protection is paused.');
  receipt.presented = true; receipt.expiresAt = Date.now() + 120000;
  const response = await nativeRequest({ type: 'present', mode: receipt.result.mode || 'text', assessment_id: id }, 3000);
  if (generation !== protectionGeneration) { void nativeRequest({ type: 'cancel', assessment_id: id }, 1500); return { ok: false, action_state: 'expired' }; }
  if (!held && !receipt.progress && !receipt.extreme) receipts.delete(id);
  else saveReceipt(id, receipt);
  return response;
}
async function presentBlock(message, sender) {
  const generation = protectionGeneration, ctx = context(sender, message.nonce), receipt = receipts.get(message.assessment_id);
  if (!receipt?.extreme || receipt.generation !== protectionGeneration || receipt.expiresAt <= Date.now() ||
      receipt.ctx.tabId !== ctx.tabId || receipt.ctx.nonce !== ctx.nonce || !C.isConfirmedExtreme(receipt.result) || !await current(ctx, true) || !await allowed(ctx.rawURL)) return { ok: false, action_state: 'expired' };
  const request = validatedPayload(message, ctx), signature = proofSignature(message, request, true), fingerprint = actionFingerprint(message, true);
  if (exactKey(ctx, request, signature, fingerprint) !== receipt.key) return { ok: false, action_state: 'expired' };
  if (generation !== protectionGeneration || receipts.get(message.assessment_id) !== receipt) return { ok: false, action_state: 'expired' };
  const response = await nativeRequest({ type: 'present-block', mode: 'text', assessment_id: message.assessment_id }, 3000);
  if (!await current(ctx, true) || !await allowed(ctx.rawURL) || generation !== protectionGeneration) {
    if (response.id) void nativeRequest({ type: 'cancel', assessment_id: response.id }, 1500);
    return { ok: false, action_state: 'expired' };
  }
  if (response.id && response.id !== message.assessment_id && response.ok === true) saveReceipt(response.id, {
    ctx, result: response, kind: receipt.kind, manual: false, presented: true, time: Date.now(), generation,
    expiresAt: Date.now() + 120000, displayId: response.id });
  return response;
}
async function notice(message, sender) {
  const generation = protectionGeneration, ctx = context(sender, message.nonce); remember(ctx);
  if (!['checking', 'unavailable', 'changed', 'unsupported', 'open_failed'].includes(message.reason) || !await current(ctx, true) || !await allowed(ctx.rawURL)) return C.failure('This page notice is no longer current.');
  if (generation !== protectionGeneration) return C.failure('Automatic protection is paused.');
  const request = validatedPayload(message, ctx, message.reason === 'unsupported'); request.type = 'notice'; request.reason = message.reason;
  const result = C.verdict(await nativeRequest(request, message.reason === 'checking' ? 1200 : 3000));
  if (result.id && generation === protectionGeneration && await current(ctx)) saveReceipt(result.id, { ctx, result, kind: request.action.kind, manual: false,
    forcePresent: true, progress: message.reason === 'checking', time: Date.now() });
  return result;
}
async function actionState(message, sender) {
  const generation = protectionGeneration, ctx = context(sender, message.nonce), id = message.assessment_id, receipt = receipts.get(id);
  if (!receipt || receipt.ctx.tabId !== ctx.tabId || receipt.ctx.nonce !== ctx.nonce || !receipt.presented || receipt.expiresAt <= Date.now() || !await current(ctx)) return { ok: false, action_state: 'expired' };
  const result = await nativeRequest({ type: 'decision', assessment_id: id }, 3000);
  if (generation !== protectionGeneration || receipts.get(id) !== receipt) return { ok: false, action_state: 'expired' };
  if (result.action_state === 'continue' && (!await current(ctx, true) || !await allowed(ctx.rawURL))) {
    receipts.delete(id); void nativeRequest({ type: 'cancel', assessment_id: id }, 1500); return { ok: false, action_state: 'expired' };
  }
  if (['continue', 'stay', 'expired'].includes(result.action_state)) receipts.delete(id);
  return result;
}
async function cancelAction(message, sender) {
  const ctx = context(sender, message.nonce), id = message.assessment_id, receipt = receipts.get(id);
  if (!receipt || receipt.ctx.tabId !== ctx.tabId || receipt.ctx.nonce !== ctx.nonce) return { ok: false };
  receipts.delete(id); return nativeRequest({ type: 'cancel', assessment_id: id }, 1500);
}
async function finishChecking(message, sender) {
  const ctx = context(sender, message.nonce), id = message.assessment_id, receipt = receipts.get(id);
  if (!receipt || !receipt.progress || !receipt.presented || receipt.ctx.tabId !== ctx.tabId || receipt.ctx.nonce !== ctx.nonce || !await current(ctx)) return { ok: false, action_state: 'expired' };
  const result = await nativeRequest({ type: 'finish-checking', assessment_id: id }, 2000); receipts.delete(id); return result;
}
async function activeTab() { return (await chrome.tabs.query({ active: true, currentWindow: true }))[0] || null; }
function fromPopup(sender) { return sender.id === chrome.runtime.id && sender.url === chrome.runtime.getURL('popup.html') && !sender.tab; }
async function ensureTabMonitoring(tabId) {
  if (!Number.isInteger(tabId) || tabId < 0) return false;
  if (monitoringInFlight.has(tabId)) return monitoringInFlight.get(tabId);
  const task = (async () => {
    try {
      const tab = await chrome.tabs.get(tabId);
      if (!C.url(tab.url) || tab.discarded) return false;
      try {
        const ready = await chrome.tabs.sendMessage(tabId, { type: 'monitor-ready' }, { frameId: 0 });
        if (ready?.ready === true) return true;
      } catch { /* An already-open document may not have a listener yet. */ }
      // Declarative content scripts cover new navigations. Attach to existing
      // HTTP(S) documents as well, without reloading any of the user's tabs.
      await chrome.scripting.executeScript({ target: { tabId, frameIds: [0] },
        files: ['shared.js', 'content.js'], world: 'ISOLATED', injectImmediately: true });
      return true;
    } catch { return false; } // Restricted, closed, suspended or withheld tabs.
  })();
  monitoringInFlight.set(tabId, task);
  try { return await task; }
  finally { if (monitoringInFlight.get(tabId) === task) monitoringInFlight.delete(tabId); }
}
async function activateTabMonitoring(tabId) {
  if (await ensureTabMonitoring(tabId))
    await chrome.tabs.sendMessage(tabId, { type: 'monitor-activated' }, { frameId: 0 });
}
function hydrateOpenTabs() {
  if (openTabsHydration) return openTabsHydration;
  const task = (async () => {
    const tabs = await chrome.tabs.query({});
    await Promise.allSettled(tabs.map(tab => ensureTabMonitoring(tab.id)));
  })();
  openTabsHydration = task;
  task.finally(() => { if (openTabsHydration === task) openTabsHydration = null; }).catch(() => {});
  return task;
}
async function restoreMonitoring() {
  alarmKey = null; heartbeatAlarmKey = null;
  await config();
  void syncProtectionState(true).catch(() => {});
  await hydrateOpenTabs();
  await broadcastConfiguration();
}
async function broadcastConfiguration() {
  for (const tab of await chrome.tabs.query({})) if (tab.id && C.url(tab.url)) chrome.tabs.sendMessage(tab.id, { type: 'configuration-changed' }, { frameId: 0 }).catch(() => {});
}
function clearAutomaticState(message = 'Protection settings changed.') {
  protectionGeneration++; cache.clear(); latestSlots.clear();
  activeAutomatic?.controller.abort();
  for (const job of automaticQueue.values()) job.resolve(quietFailure(message));
  automaticQueue.clear();
  for (const [id, receipt] of [...receipts].sort((a,b) => b[1].time-a[1].time)) if (receipt.presented) void nativeRequest({ type: 'cancel', assessment_id: id }, 1500);
  receipts.clear();
}
async function protectionChanged() {
  clearAutomaticState(); alarmKey = null; heartbeatAlarmKey = null; await config();
  void syncProtectionState(true).catch(() => {});
  await broadcastConfiguration();
}
async function changePause(duration) {
  if (![0,1800000].includes(duration)) throw new Error('Unsupported pause duration.');
  clearAutomaticState('Automatic protection is paused.');
  await writeConfig({ enabled: true, paused: true, pauseUntil: duration ? Date.now()+duration : 0 });
  void syncProtectionState(true).catch(() => {});
  await broadcastConfiguration(); return { ok: true };
}
async function resumeProtection() {
  clearAutomaticState(); await writeConfig({ enabled: true, paused: false, pauseUntil: 0 });
  void syncProtectionState(true).catch(() => {});
  await broadcastConfiguration(); return { ok: true };
}
async function handle(message, sender) {
  if (!message || typeof message.type !== 'string') return C.failure('Unsupported request.');
  if (message.type === 'configuration') {
    const ctx = context(sender, message.nonce); remember(ctx); const value = await config();
    void syncProtectionState().catch(() => {});
    return { ...value, supported: true, origin: C.origin(ctx.rawURL), approved: value.active };
  }
  if (message.type === 'assess') return assessPage(message, sender);
  if (message.type === 'present') return present(message.assessment_id, context(sender, message.nonce));
  if (message.type === 'present-block') return presentBlock(message, sender);
  if (message.type === 'notice') return notice(message, sender);
  if (message.type === 'decision') return actionState(message, sender);
  if (message.type === 'cancel') return cancelAction(message, sender);
  if (message.type === 'finish-checking') return finishChecking(message, sender);
  if (message.type === 'open-link') {
    const ctx = context(sender, message.nonce);
    if (!await current(ctx, true) || !C.url(message.url)) throw new Error('The page changed before opening the link.');
    if (message.newWindow) await chrome.windows.create({ url: message.url });
    else await chrome.tabs.create({ url: message.url, windowId: ctx.windowId, active: message.active !== false });
    return { ok: true };
  }
  if (!fromPopup(sender)) return C.failure('This request must come from Muse Guard.');
  if (message.type === 'popup-state') {
    const tab = await activeTab(), value = await config(); const supported = !!tab?.id && !!C.url(tab.url);
    return { ...value, supported, origin: supported ? C.origin(tab.url) : null,
      result: supported ? (await chrome.storage.session.get('result:'+tab.id))['result:'+tab.id] : undefined };
  }
  if (message.type === 'status') return nativeRequest({ type: 'status', mode: 'text' }, 3500);
  if (message.type === 'pause') return changePause(message.duration_ms);
  if (message.type === 'resume') return resumeProtection();
  if (message.type === 'set-enabled') {
    if (message.enabled === true) return resumeProtection();
    clearAutomaticState(); await writeConfig({ enabled: false, paused: false, pauseUntil: 0 });
    void syncProtectionState(true).catch(() => {});
    await broadcastConfiguration(); return { ok: true };
  }
  return C.failure('Unsupported request.');
}
chrome.runtime.onMessage.addListener((message, sender, reply) => { handle(message, sender).then(reply).catch(error => reply(C.failure(error.message))); return true; });
chrome.storage.onChanged.addListener((_, area) => { if (area === 'local') void protectionChanged(); });
function forget(tabId) {
  documents.delete(tabId); actionEpochs.delete(tabId); activeActions.delete(tabId);
  if (activeAutomatic?.ctx.tabId === tabId) activeAutomatic.controller.abort();
  for (const [slot, job] of automaticQueue) if (job.ctx.tabId === tabId) { automaticQueue.delete(slot); latestSlots.delete(slot); job.resolve(quietFailure('The tab navigated.')); }
  for (const [id, receipt] of receipts) if (receipt.ctx.tabId === tabId) { receipts.delete(id); if (receipt.presented) void nativeRequest({ type: 'cancel', assessment_id: id }, 1500); }
  for (const key of cache.keys()) { try { if (JSON.parse(key)[0] === tabId) cache.delete(key); } catch { cache.delete(key); } }
  chrome.storage.session.remove('result:'+tabId).catch(() => {});
}
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url || change.status === 'loading') forget(tabId);
  if (change.status === 'complete') void ensureTabMonitoring(tabId);
});
chrome.tabs.onRemoved.addListener(forget);
chrome.tabs.onActivated?.addListener(info => {
  void pumpAutomatic();
  void syncProtectionState().catch(() => {});
  void activateTabMonitoring(info?.tabId).catch(() => {});
});
chrome.windows.onFocusChanged?.addListener(windowId => {
  if (!Number.isInteger(windowId) || windowId < 0) return;
  void syncProtectionState().catch(() => {});
  void chrome.tabs.query({ active: true, windowId }).then(tabs =>
    Promise.allSettled(tabs.map(tab => activateTabMonitoring(tab.id)))).catch(() => {});
});
chrome.alarms?.onAlarm.addListener(alarm => {
  if (alarm.name === RESUME_ALARM) { alarmKey = null; void protectionChanged(); }
  if (alarm.name === PROTECTION_HEARTBEAT_ALARM) void syncProtectionState(true).catch(() => {});
});
chrome.runtime.onStartup?.addListener(() => { void restoreMonitoring().catch(() => {}); });
chrome.runtime.onInstalled?.addListener(() => { void restoreMonitoring().catch(() => {}); });
// Reconcile stored timestamps on every worker start; alarms are not assumed to
// survive a browser restart on the minimum supported Chrome version.
void restoreMonitoring().catch(() => {});
chrome.tabs.query({}).then(tabs => { for (const tab of tabs) if (tab.id) chrome.action.setBadgeText({ tabId: tab.id, text: '' }).catch(() => {}); }).catch(() => {});
