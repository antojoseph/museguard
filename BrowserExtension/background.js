'use strict';
importScripts('shared.js');
importScripts('targets.js');
importScripts('downloads.js');
const C = MuseGuardCore;
const T = MuseGuardTargets;
const HOST = 'com.antojoseph.museguard';
const RESUME_ALARM = 'muse-guard-resume';
const MONITORING_SYNC_ALARM = 'muse-guard-monitoring-sync';
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
const monitoringInFlight = new Map();
let openTabsHydration = null;
let heartbeatAlarmKey = null, heartbeatTask = null, heartbeatQueued = false, heartbeatForced = false;
let lastHeartbeatEnabled = null, lastHeartbeatAt = 0, lastHeartbeatSucceeded = false;
let chatContextTimer = null, chatContextFlight = null, monitoringFlight = null, monitoringTimer = null;
let monitoringAvailable = false, commandTail = Promise.resolve();
let monitoringTail = Promise.resolve(), monitoringAppliedRevision = 0;
const NATIVE_AVAILABILITY_MS = 4500;
let nativeAvailableUntil = 0, lastAvailabilityBroadcast = 0;
const downloadCommands = new Map();
const downloadGuard = MuseGuardDownloads.create({ chrome, nativeRequest,
  isEnabled: async () => (await config()).active });
// MV3 must register wake-up listeners during initial script evaluation, before
// any configuration read. Each event still checks the persisted Pause state.
void downloadGuard.start().catch(() => {});
function quietFailure(message) { return { ...C.failure(message), confirmed_extreme: false, retry_after_ms: 15000 }; }

async function setNativeAvailability(available) {
  const hadLease = nativeAvailableUntil > 0;
  nativeAvailableUntil = available ? Date.now() + NATIVE_AVAILABILITY_MS : 0;
  if ((available && Date.now() - lastAvailabilityBroadcast < 2000) || (!available && !hadLease)) return;
  lastAvailabilityBroadcast = Date.now();
  const tabs = await chrome.tabs.query({});
  await Promise.allSettled(tabs.filter(tab => tab.id && C.url(tab.url)).map(tab =>
    chrome.tabs.sendMessage(tab.id, { type: 'native-availability', available_until: nativeAvailableUntil }, { frameId: 0 })));
}
async function processDownloadCommands(commands) {
  if (!Array.isArray(commands)) return;
  for (const value of commands.slice(0, 32)) {
    if (!value || typeof value.command_id !== 'string' || !/^[a-z0-9-]{1,128}$/i.test(value.command_id) ||
        !Number.isSafeInteger(value.download_id) || value.download_id < 0 || typeof value.hold_id !== 'string' ||
        !/^[a-z0-9-]{1,128}$/i.test(value.hold_id) || !['resume', 'cancel', 'show'].includes(value.action)) continue;
    const command = { command_id: value.command_id, download_id: value.download_id, hold_id: value.hold_id, action: value.action };
    // A repeated native poll can carry the same command until its ack arrives.
    // Execute it once, including when two polls overlap.
    const key = command.command_id;
    if (!downloadCommands.has(key)) {
      const task = Promise.resolve().then(() => downloadGuard.handleCommand(command)).catch(() => ({ ok: false }));
      downloadCommands.set(key, { signature: JSON.stringify(command), task });
      if (downloadCommands.size > 128) downloadCommands.delete(downloadCommands.keys().next().value);
    }
    const saved = downloadCommands.get(key);
    if (saved.signature !== JSON.stringify(command)) continue;
    const result = await saved.task;
    await nativeRequest({ type: 'download-command-result', mode: 'text',
      download_command: { ...command, ok: result?.ok === true } }, 1500);
  }
}

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
      if (['assess', 'download-inspect'].includes(request.type) && sentPort && port === sentPort)
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
          clearTimeout(monitoringTimer); monitoringTimer = null; monitoringAvailable = false;
          void setNativeAvailability(false).catch(() => {});
          for (const item of [...pending.values()]) item.finish(C.failure(message));
        });
        scheduleChatContextPoll(connected);
        scheduleMonitoringPoll(connected);
      }
      const timer = setTimeout(() => {
        if (['assess', 'download-inspect'].includes(request.type)) abort();
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
function scheduleMonitoringPoll(connected) {
  clearTimeout(monitoringTimer);
  if (port !== connected) return;
  monitoringTimer = setTimeout(() => {
    monitoringTimer = null;
    void pollMonitoringState(connected).catch(() => {}).finally(() => {
      if (port === connected) scheduleMonitoringPoll(connected);
    });
  }, CHAT_CONTEXT_POLL_INTERVAL);
}
function validMonitoring(value) {
  return value && typeof value.paused === 'boolean' && Number.isSafeInteger(value.revision) && value.revision > 0 &&
    Number.isSafeInteger(value.pause_until) && value.pause_until >= 0 && (value.paused || value.pause_until === 0);
}
function applyMonitoringState(value, fromCommand = false) {
  const result = monitoringTail.then(() => applyMonitoringStateOrdered(value, fromCommand), () => applyMonitoringStateOrdered(value, fromCommand));
  monitoringTail = result.catch(() => {});
  return result;
}
async function applyMonitoringStateOrdered(value, fromCommand) {
  if (!validMonitoring(value)) throw new Error('Update the Muse Guard app to synchronize monitoring.');
  const current = await config();
  if (value.revision < current.monitoringRevision) return false;
  if (current.monitoringPending && value.revision === current.monitoringRevision && !fromCommand) return false;
  if (value.revision === current.monitoringRevision && current.enabled && current.paused === value.paused && current.pauseUntil === value.pause_until && monitoringAppliedRevision === value.revision && !current.monitoringPending) return true;
  clearAutomaticState(value.paused ? 'All monitoring is paused.' : 'Monitoring resumed with fresh checks.');
  await writeConfig({ enabled: true, paused: value.paused, pauseUntil: value.pause_until, monitoringRevision: value.revision, monitoringPending: false });
  await downloadGuard.setPaused(value.paused);
  const applied = await broadcastConfiguration();
  if (applied) monitoringAppliedRevision = value.revision;
  return applied;
}
function pollMonitoringState(connected = port) {
  if (!connected || port !== connected) return Promise.resolve();
  if (monitoringFlight) return monitoringFlight;
  const task = (async () => {
    const value = await config();
    let result = await nativeRequest({ type: 'monitoring-state', monitoring_revision: monitoringAppliedRevision || undefined }, 1500, connected);
    // Preserve a user's old explicit pause once when upgrading a native app
    // that has never owned a monitoring setting. Later native changes win.
    if (port === connected && value.monitoringRevision === 0 && (!value.enabled || value.paused) && result?.monitoring?.revision === 1)
      result = await nativeRequest({ type: 'monitoring-control', monitoring_command: 'pause', pause_duration_ms: value.pauseUntil > Date.now() ? 1800000 : 0 }, 1500, connected);
    if (port === connected) {
      monitoringAvailable = result?.ok === true && validMonitoring(result.monitoring);
      await setNativeAvailability(monitoringAvailable);
      if (monitoringAvailable) {
        await applyMonitoringState(result.monitoring);
        await processDownloadCommands(result.download_commands);
      }
    }
  })();
  monitoringFlight = task;
  task.finally(() => { if (monitoringFlight === task) monitoringFlight = null; }).catch(() => {});
  return task;
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
  const saved = await chrome.storage.local.get({ configVersion: 0, enabled: true, paused: false, pauseUntil: 0, monitoringRevision: 0, monitoringPending: false });
  const value = { enabled: saved.enabled !== false, paused: saved.paused === true,
    pauseUntil: Number.isFinite(saved.pauseUntil) && saved.pauseUntil > 0 ? saved.pauseUntil : 0,
    monitoringRevision: Number.isSafeInteger(saved.monitoringRevision) && saved.monitoringRevision > 0 ? saved.monitoringRevision : 0,
    monitoringPending: saved.monitoringPending === true };
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
  if (sender.id !== chrome.runtime.id || sender.frameId !== 0 || !Number.isInteger(sender.tab?.id) ||
      !Number.isInteger(sender.tab?.windowId) || !C.url(sender.url) || typeof nonce !== 'string' ||
      !/^[a-z0-9-]{1,256}$/i.test(nonce)) throw new Error('This page is not supported.');
  return { tabId: sender.tab.id, windowId: sender.tab.windowId, rawURL: sender.url, documentId: sender.documentId, nonce };
}
function remember(ctx) {
  const previous = documents.get(ctx.tabId);
  documents.set(ctx.tabId, { ...(previous?.nonce === ctx.nonce ? previous : {}), documentId: ctx.documentId, nonce: ctx.nonce, windowId: ctx.windowId });
}
async function current(ctx, active = false) {
  try {
    const tab = await chrome.tabs.get(ctx.tabId);
    const focused = !active || (tab.active && (await chrome.windows.get(tab.windowId)).focused);
    const known = documents.get(ctx.tabId);
    return tab.url === ctx.rawURL && tab.windowId === ctx.windowId && focused && known?.nonce === ctx.nonce && (!ctx.documentId || known.documentId === ctx.documentId);
  } catch { return false; }
}
function sourceFields(ctx, revision) {
  return { document_id: ctx.nonce, page_revision: revision, tab_id: ctx.tabId, window_id: ctx.windowId };
}
async function boundTarget(message, ctx, allowUnfocused = false) {
  if (!message.target || !Number.isSafeInteger(message.page_revision) || message.page_revision < 0 ||
      message.document_id !== ctx.nonce) return undefined;
  try {
    const [tab, window, zoom, state] = await Promise.all([
      chrome.tabs.get(ctx.tabId), chrome.windows.get(ctx.windowId), chrome.tabs.getZoom(ctx.tabId),
      chrome.tabs.sendMessage(ctx.tabId, { type: 'target-state' }, { frameId: 0 })
    ]);
    if (tab.url !== ctx.rawURL || tab.windowId !== ctx.windowId || !tab.active || (!allowUnfocused && !window.focused) ||
        state?.nonce !== ctx.nonce || state.revision !== message.page_revision || !await current(ctx, !allowUnfocused)) return undefined;
    const result = T.bind(message.target, { tabID: ctx.tabId, windowID: ctx.windowId, window, zoom },
      { documentID: ctx.nonce, revision: state.revision }) || undefined;
    if (result) Object.assign(documents.get(ctx.tabId), { target: true, revision: state.revision });
    return result;
  } catch { return undefined; }
}
async function invalidateTarget(message, sender) {
  const ctx = context(sender, message.nonce), known = documents.get(ctx.tabId);
  if (known?.nonce !== ctx.nonce || !Number.isSafeInteger(message.page_revision) || message.page_revision < 0) return { ok: false };
  known.target = false; known.revision = message.page_revision;
  // No availability reconnect just to erase a pointer. Native also expires its
  // geometry; a navigation or worker disconnect must never preserve precision.
  if (!port) return { ok: true };
  return nativeRequest({ type: 'target-invalidated', mode: 'text', ...sourceFields(ctx, message.page_revision) }, 1500, port);
}
async function updateTarget(message, sender) {
  const ctx = context(sender, message.nonce), generation = protectionGeneration, connected = port;
  if (!connected || documents.get(ctx.tabId)?.target !== true || !await current(ctx) || !await allowed(ctx.rawURL)) return { ok: false };
  // A nonactivating Muse overlay may temporarily remove Chrome's key-window
  // focus. Renew only its existing active tab; native still verifies that the
  // same Chrome app/window is foreground before accepting this geometry.
  const target = await boundTarget(message, ctx, true);
  if (!target || generation !== protectionGeneration || connected !== port || !await current(ctx) || !await allowed(ctx.rawURL)) return { ok: false };
  const response = await nativeRequest({ type: 'target-update', mode: 'text', ...sourceFields(ctx, message.page_revision), target }, 1500, connected);
  return { ok: response?.ok === true && generation === protectionGeneration && connected === port && await current(ctx) };
}
function clearTabTarget(tabID) {
  const known = documents.get(tabID);
  if (!known?.target || !port) return;
  known.target = false;
  void nativeRequest({ type: 'target-invalidated', mode: 'text', document_id: known.nonce,
    page_revision: known.revision || 0, tab_id: tabID, window_id: known.windowId }, 1500, port);
}
const SECRET_CATEGORIES = new Set(['private_key', 'wallet_seed', 'github_token', 'openai_key', 'anthropic_key',
  'stripe_secret_key', 'slack_token', 'aws_credentials']);
function safeSecret(value) {
  if (!value || !SECRET_CATEGORIES.has(value.category) || !Number.isInteger(value.count) || value.count < 1 || value.count > 8 ||
      !Array.isArray(value.categories) || value.categories.length < 1 || value.categories.length > 8 ||
      value.categories.some(category => !SECRET_CATEGORIES.has(category)) || !value.categories.includes(value.category) ||
      !['paste', 'submit'].includes(value.phase)) throw new Error('Unsupported secret warning.');
  return { category: value.category, count: value.count, categories: [...new Set(value.categories)], phase: value.phase };
}
async function secretPaste(message, sender) {
  const ctx = context(sender, message.nonce), stamp = protectionGeneration, connected = port;
  const secret = safeSecret(message.secret);
  if (!connected || nativeAvailableUntil <= Date.now() || !Number.isSafeInteger(message.page_revision) || message.page_revision < 0 ||
      message.document_id !== ctx.nonce || !await allowed(ctx.rawURL) || !await current(ctx, true)) return { ok: false };
  const target = await boundTarget(message, ctx);
  if (stamp !== protectionGeneration || port !== connected || nativeAvailableUntil <= Date.now() || !await allowed(ctx.rawURL) || !await current(ctx, true)) return { ok: false };
  const response = await nativeRequest({ type: 'secret-paste', mode: 'text', secret,
    page: { url: C.url(ctx.rawURL), title: C.cleanText(message.page?.title, 250), text: '' },
    ...sourceFields(ctx, message.page_revision), ...(target ? { target } : {}) }, 2000, connected);
  const sourceCurrent = stamp === protectionGeneration && port === connected && await allowed(ctx.rawURL) && await current(ctx, true);
  const delivered = response?.ok === true && response?.decision === 'block' && sourceCurrent;
  if (!sourceCurrent && response?.id) void nativeRequest({ type: 'cancel', assessment_id: response.id }, 1500);
  if (!delivered) await setNativeAvailability(false);
  return { ok: delivered, decision: delivered ? 'block' : 'review' };
}
function saveReceipt(id, value) {
  for (const [key, item] of receipts) if (item.expiresAt <= Date.now()) receipts.delete(key);
  const receipt = { ...value };
  receipts.set(id, receipt);
  setTimeout(() => {
    if (receipts.get(id) === receipt && receipt.expiresAt <= Date.now()) {
      receipts.delete(id); if (receipt.presented) void nativeRequest({ type: 'cancel', assessment_id: id }, 1500);
    }
  }, Math.max(1, receipt.expiresAt - Date.now()));
  if (receipts.size > 128) receipts.delete(receipts.keys().next().value);
  return receipt;
}
function validatedPayload(message, ctx) {
  const page = message.page;
  if (!page || page.url !== C.url(ctx.rawURL) || typeof page.text !== 'string') throw new Error('The page changed before its check.');
  const action = C.normalizeAction(message.action || { kind: 'page' });
  if (!['page', 'link', 'submit'].includes(action.kind)) throw new Error('Unsupported page action.');
  if (action.kind !== 'page' && !action.url) throw new Error('This action has no supported destination.');
  return { type: 'assess', mode: 'text', page: { url: page.url, title: C.cleanText(page.title, 250), text: C.cleanText(page.text) }, action };
}
function proofSignature(message, request) {
  if (typeof message.public_signature !== 'string' || message.public_signature.length > 4096) throw new Error('This action proof is not valid.');
  let proof; try { proof = JSON.parse(message.public_signature); } catch { throw new Error('This action proof is not valid.'); }
  if (!Array.isArray(proof) || proof.length !== 2 || !Array.isArray(proof[1]) || proof[1].length > 32 ||
      proof[1].some(type => typeof type !== 'string' || !/^[a-z][a-z0-9-]{0,31}$/.test(type)) ||
      JSON.stringify(C.normalizeAction(proof[0])) !== JSON.stringify(request.action)) throw new Error('This action proof changed.');
  return C.publicSignature(request.action, proof[1]);
}
function actionFingerprint(message) {
  if (typeof message.action_fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(message.action_fingerprint)) throw new Error('This local action fingerprint is not valid.');
  return message.action_fingerprint;
}
function exactKey(ctx, request, signature, fingerprint = null) {
  // Full page URL remains local. Query-only SPA routes must not reuse another
  // route's result even though native evidence deliberately redacts queries.
  return JSON.stringify([ctx.tabId, ctx.documentId || null, ctx.nonce, ctx.rawURL, C.assessmentKey(request.page, request.action), signature, fingerprint]);
}
function slotKey(ctx, request) {
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
  const payload = { ...job.request, purpose: job.purpose };
  const raw = await nativeRequest(payload, 35000, null, job.controller.signal), result = C.verdict(raw);
  if (job.controller.signal.aborted) return quietFailure('This scan was replaced by a newer or higher-priority check.');
  if (job.generation !== protectionGeneration || !await allowed(job.ctx.rawURL) || !await current(job.ctx) ||
      latestSlots.get(job.slot) !== job.key) return quietFailure('A newer page or protection setting replaced this check.');
  if (job.generation !== protectionGeneration) return quietFailure('Protection settings changed during this check.');
  // Never turn a corrected/inconsistent result into a confirmed extreme.
  const extreme = raw?.ok === true && raw.decision === 'block' && raw.risk_level === 'high' && result.ok === true &&
    result.decision === 'block' && typeof result.id === 'string' && result.id.length > 0;
  const expiresAt = Date.now() + (result.risk_level === 'high' ? EXTREME_TTL : C.ASSESSMENT_REUSE_MS);
  const stamped = { ...result, confirmed_extreme: extreme, expires_at: expiresAt };
  if (extreme) saveReceipt(result.id, { ctx: job.ctx, result: stamped, extreme, key: job.key,
    time: Date.now(), expiresAt, generation: job.generation });
  if (result.ok === true) {
    cache.set(job.key, { result: stamped, expiresAt, generation: job.generation });
    if (cache.size > 64) cache.delete(cache.keys().next().value);
  }
  return stamped;
}
function sensitiveIntent(job) { return job?.purpose === 'intent' && job.request.action.kind === 'submit' && job.request.action.sensitive; }
async function preemptForSensitiveIntent(job) {
  const candidate = activeAutomatic;
  if (!sensitiveIntent(job) || !candidate || sensitiveIntent(candidate) ||
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
    if (sensitiveIntent(job)) earlier.purpose = 'intent';
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
  if (!['proactive', 'intent'].includes(message.purpose)) throw new Error('Unsupported check purpose.');
  const request = validatedPayload(message, ctx), signature = proofSignature(message, request),
    fingerprint = actionFingerprint(message);
  const job = { ctx, request, purpose: message.purpose, generation: protectionGeneration };
  job.key = exactKey(ctx, request, signature, fingerprint); job.slot = slotKey(ctx, request);
  if (!await current(ctx)) return quietFailure('The active page changed.');
  if (job.generation !== protectionGeneration || !await allowed(ctx.rawURL)) return quietFailure('Automatic protection was paused.');
  return enqueueAssessment(job);
}
async function presentBlock(message, sender) {
  const generation = protectionGeneration, ctx = context(sender, message.nonce), receipt = receipts.get(message.assessment_id);
  if (!receipt?.extreme || receipt.generation !== protectionGeneration || receipt.expiresAt <= Date.now() ||
      receipt.ctx.tabId !== ctx.tabId || receipt.ctx.nonce !== ctx.nonce || !C.isConfirmedExtreme(receipt.result) || !await current(ctx, true) || !await allowed(ctx.rawURL)) return { ok: false };
  const request = validatedPayload(message, ctx), signature = proofSignature(message, request), fingerprint = actionFingerprint(message);
  if (exactKey(ctx, request, signature, fingerprint) !== receipt.key) return { ok: false };
  if (generation !== protectionGeneration || receipts.get(message.assessment_id) !== receipt) return { ok: false };
  const target = await boundTarget(message, ctx);
  if (generation !== protectionGeneration || !await current(ctx, true) || !await allowed(ctx.rawURL)) return { ok: false };
  const response = await nativeRequest({ type: 'present-block', mode: 'text', assessment_id: message.assessment_id,
    ...sourceFields(ctx, Number.isSafeInteger(message.page_revision) ? message.page_revision : 0), ...(target ? { target } : {}) }, 3000);
  if (!await current(ctx, true) || !await allowed(ctx.rawURL) || generation !== protectionGeneration) {
    if (response.id) void nativeRequest({ type: 'cancel', assessment_id: response.id }, 1500);
    return { ok: false };
  }
  if (response.id && response.id !== message.assessment_id && response.ok === true) saveReceipt(response.id, {
    ctx, presented: true, time: Date.now(), generation,
    expiresAt: Date.now() + 120000 });
  return response;
}
async function cancelAction(message, sender) {
  const ctx = context(sender, message.nonce), id = message.assessment_id, receipt = receipts.get(id);
  if (!receipt || receipt.ctx.tabId !== ctx.tabId || receipt.ctx.nonce !== ctx.nonce) return { ok: false };
  receipts.delete(id); return nativeRequest({ type: 'cancel', assessment_id: id }, 1500);
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
        files: ['shared.js', 'targets.js', 'secrets.js', 'content.js'], world: 'ISOLATED', injectImmediately: true });
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
  if (chrome.alarms) await chrome.alarms.create(MONITORING_SYNC_ALARM, { periodInMinutes: 0.5 });
  alarmKey = null; heartbeatAlarmKey = null;
  const value = await config();
  await downloadGuard.setPaused(!value.active);
  // Recovered file inspections must not delay browser monitoring startup.
  void downloadGuard.start().catch(() => {});
  void syncProtectionState(true).catch(() => {});
  await hydrateOpenTabs();
  await broadcastConfiguration();
}
async function broadcastConfiguration() {
  const tabs = await chrome.tabs.query({});
  const results = await Promise.all(tabs.filter(tab => tab.id && C.url(tab.url)).map(async tab => {
    let timer;
    try {
      // A missing listener cannot retain a blocking cache. A live but stalled
      // listener must not hold the worker forever or earn a false native ack.
      return await Promise.race([
        chrome.tabs.sendMessage(tab.id, { type: 'configuration-changed' }, { frameId: 0 }).then(() => true, () => true),
        new Promise(resolve => { timer = setTimeout(() => resolve(false), 1200); })
      ]);
    } finally { clearTimeout(timer); }
  }));
  return results.every(Boolean);
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
  clearAutomaticState(); alarmKey = null; heartbeatAlarmKey = null;
  const value = await config(); await downloadGuard.setPaused(!value.active);
  void syncProtectionState(true).catch(() => {});
  await broadcastConfiguration();
}
function changeMonitoring(command, duration) {
  const result = commandTail.then(() => changeMonitoringOrdered(command, duration), () => changeMonitoringOrdered(command, duration));
  commandTail = result.catch(() => {});
  return result;
}
async function changeMonitoringOrdered(command, duration) {
  if (command === 'pause' && ![0, 1800000].includes(duration)) throw new Error('Unsupported pause duration.');
  const before = await config();
  // Stop browser work immediately while the native app applies the same switch
  // to desktop checks. A transport failure must never be called global success.
  if (command === 'pause') {
    monitoringAppliedRevision = 0;
    clearAutomaticState('Monitoring is being paused.');
    await writeConfig({ enabled: true, paused: true, pauseUntil: duration ? Date.now() + duration : 0, monitoringPending: true });
    await downloadGuard.setPaused(true);
    await broadcastConfiguration();
  }
  const result = await nativeRequest({ type: 'monitoring-control', monitoring_command: command,
    pause_duration_ms: command === 'pause' ? duration : undefined, monitoring_revision: before.monitoringRevision || undefined }, 3500);
  if (result?.ok === false && validMonitoring(result.monitoring)) {
    monitoringAvailable = true; await applyMonitoringState(result.monitoring, true);
    return { ok: false, error: 'Monitoring changed elsewhere. The newer setting was kept; try again.' };
  }
  if (result?.ok !== true || !validMonitoring(result.monitoring)) { monitoringAvailable = false; return { ok: false,
    error: command === 'pause' ? 'Chrome is paused. Open Muse Guard to pause desktop checks too.' : 'Open Muse Guard to resume monitoring.' }; }
  monitoringAvailable = true;
  const applied = await applyMonitoringState(result.monitoring, true);
  if (!applied) return { ok: false, error: 'Monitoring changed. A Chrome tab has not responded yet; Muse will keep trying.' };
  // The acknowledgement follows cache cancellation and all-tab configuration
  // delivery, so native controls do not claim Chrome applied an unseen state.
  await nativeRequest({ type: 'monitoring-state', monitoring_revision: result.monitoring.revision }, 1500);
  void syncProtectionState(true).catch(() => {});
  return { ok: true };
}
async function handle(message, sender) {
  if (!message || typeof message.type !== 'string') return C.failure('Unsupported request.');
  if (message.type === 'configuration') {
    const ctx = context(sender, message.nonce); remember(ctx); const value = await config();
    void syncProtectionState().catch(() => {});
    return { ...value, supported: true, origin: C.origin(ctx.rawURL), approved: value.active,
      native_available_until: value.active && nativeAvailableUntil > Date.now() ? nativeAvailableUntil : 0 };
  }
  if (message.type === 'assess') return assessPage(message, sender);
  if (message.type === 'present-block') return presentBlock(message, sender);
  if (message.type === 'secret-paste') return secretPaste(message, sender);
  if (message.type === 'target-invalidated') return invalidateTarget(message, sender);
  if (message.type === 'target-update') return updateTarget(message, sender);
  if (message.type === 'cancel') return cancelAction(message, sender);
  if (!fromPopup(sender)) return C.failure('This request must come from Muse Guard.');
  if (message.type === 'popup-state') {
    await pollMonitoringState();
    const tab = await activeTab(), value = await config(); const supported = !!tab?.id && !!C.url(tab.url);
    return { ...value, monitoringConfirmed: monitoringAvailable && !value.monitoringPending && monitoringAppliedRevision === value.monitoringRevision, supported, origin: supported ? C.origin(tab.url) : null,
      readable: supported ? await ensureTabMonitoring(tab.id) : false, downloads: downloadGuard.status() };
  }
  if (message.type === 'status') return nativeRequest({ type: 'status', mode: 'text' }, 3500);
  if (message.type === 'pause') return changeMonitoring('pause', message.duration_ms);
  if (message.type === 'resume') return changeMonitoring('resume');
  return C.failure('Unsupported request.');
}
chrome.runtime.onMessage.addListener((message, sender, reply) => { handle(message, sender).then(reply).catch(error => reply(C.failure(error.message))); return true; });
chrome.storage.onChanged.addListener((_, area) => { if (area === 'local') void protectionChanged(); });
function forget(tabId) {
  clearTabTarget(tabId);
  documents.delete(tabId);
  if (activeAutomatic?.ctx.tabId === tabId) activeAutomatic.controller.abort();
  for (const [slot, job] of automaticQueue) if (job.ctx.tabId === tabId) { automaticQueue.delete(slot); latestSlots.delete(slot); job.resolve(quietFailure('The tab navigated.')); }
  for (const [id, receipt] of receipts) if (receipt.ctx.tabId === tabId) { receipts.delete(id); if (receipt.presented) void nativeRequest({ type: 'cancel', assessment_id: id }, 1500); }
  for (const key of cache.keys()) { try { if (JSON.parse(key)[0] === tabId) cache.delete(key); } catch { cache.delete(key); } }
}
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url || change.status === 'loading') forget(tabId);
  if (change.status === 'complete') void ensureTabMonitoring(tabId);
});
chrome.tabs.onRemoved.addListener(forget);
chrome.tabs.onActivated?.addListener(info => {
  for (const tabID of documents.keys()) clearTabTarget(tabID);
  void pumpAutomatic();
  void syncProtectionState().catch(() => {});
  void activateTabMonitoring(info?.tabId).catch(() => {});
});
chrome.windows.onFocusChanged?.addListener(windowId => {
  if (!Number.isInteger(windowId) || windowId < 0) return;
  // WINDOW_ID_NONE also occurs while Muse's nonactivating panel owns key
  // focus. Native foreground validation handles real app switches; another
  // Chrome window invalidates only targets belonging to the previous one.
  for (const [tabID, known] of documents) if (known.windowId !== windowId) clearTabTarget(tabID);
  void syncProtectionState().catch(() => {});
  void chrome.tabs.query({ active: true, windowId }).then(tabs =>
    Promise.allSettled(tabs.map(tab => activateTabMonitoring(tab.id)))).catch(() => {});
});
chrome.tabs.onZoomChange?.addListener(info => clearTabTarget(info.tabId));
chrome.tabs.onDetached?.addListener(tabID => clearTabTarget(tabID));
chrome.windows.onBoundsChanged?.addListener(window => {
  for (const [tabID, known] of documents) if (known.windowId === window.id) clearTabTarget(tabID);
});
chrome.alarms?.onAlarm.addListener(alarm => {
  if (alarm.name === MONITORING_SYNC_ALARM) void nativeRequest({ type: 'monitoring-state', monitoring_revision: monitoringAppliedRevision || undefined }, 1500).then(result => {
    if (result?.ok === true) return applyMonitoringState(result.monitoring);
  }).catch(() => {});
  if (alarm.name === RESUME_ALARM) { alarmKey = null; void protectionChanged(); }
  if (alarm.name === PROTECTION_HEARTBEAT_ALARM) void syncProtectionState(true).catch(() => {});
});
chrome.runtime.onStartup?.addListener(() => { void restoreMonitoring().catch(() => {}); });
chrome.runtime.onInstalled?.addListener(() => { void restoreMonitoring().catch(() => {}); });
// Reconcile stored timestamps on every worker start; alarms are not assumed to
// survive a browser restart on the minimum supported Chrome version.
void restoreMonitoring().catch(() => {});
chrome.tabs.query({}).then(tabs => { for (const tab of tabs) if (tab.id) chrome.action.setBadgeText({ tabId: tab.id, text: '' }).catch(() => {}); }).catch(() => {});
