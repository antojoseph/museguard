'use strict';
const C = MuseGuardCore;
const el = id => document.getElementById(id);
const send = value => chrome.runtime.sendMessage(value);
let state = null, busy = false;
const HOST = 'com.antojoseph.museguard';
const nativePorts = new Set();
window.addEventListener('pagehide', () => { for (const port of nativePorts) port.disconnect(); });
function nativeRequest(payload, timeout) {
  return new Promise(resolve => {
    const request = { ...payload, version: 1, id: crypto.randomUUID() };
    let port, timer, finished = false;
    const finish = value => {
      if (finished) return; finished = true; clearTimeout(timer);
      if (port) { nativePorts.delete(port); port.disconnect(); }
      resolve(value);
    };
    try {
      port = chrome.runtime.connectNative(HOST); nativePorts.add(port);
      port.onMessage.addListener(value => { if (value?.id === request.id) finish(value); });
      port.onDisconnect.addListener(() => finish(C.failure(chrome.runtime.lastError?.message || 'The Muse app disconnected.', request.id)));
      timer = setTimeout(() => finish(C.failure('The local check timed out. This page has not been cleared.', request.id)), timeout);
      port.postMessage(request);
    } catch (error) { finish(C.failure(error.message, request.id)); }
  });
}
async function currentPopup(context) {
  if (document.visibilityState !== 'visible' || !document.hasFocus()) throw new Error('Keep the Muse popup open while checking this tab.');
  if (await chrome.tabs.getCurrent()) throw new Error('Open Muse Guard from its Chrome toolbar button.');
  const active = (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  if (!active?.id || !C.url(active.url)) throw new Error('Open a normal website to use Muse Guard.');
  if (context && (active.id !== context.id || active.windowId !== context.windowId || active.url !== context.url)) throw new Error('The active tab changed. Check the current page again.');
  return active;
}
async function fresh(context, original) {
  await currentPopup(context);
  const value = await chrome.tabs.sendMessage(context.id, { type: 'snapshot' }, { frameId: 0 });
  if (value.nonce !== original.nonce || value.revision !== original.revision ||
      C.assessmentKey(value.page) !== C.assessmentKey(original.page)) throw new Error('The page or form changed during this check. Please try again.');
}
async function prepareScreenshot(dataURL) {
  const encoded = dataURL.split(',')[1]; if (!encoded) throw new Error('Chrome could not prepare the screenshot.');
  const raw = Uint8Array.from(atob(encoded), character => character.charCodeAt(0));
  const bitmap = await createImageBitmap(new Blob([raw], { type: 'image/jpeg' }));
  try {
    const scale = Math.min(1, 1600 / Math.max(bitmap.width, bitmap.height));
    const canvas = new OffscreenCanvas(Math.max(1, Math.round(bitmap.width * scale)), Math.max(1, Math.round(bitmap.height * scale)));
    const context = canvas.getContext('2d'); if (!context) throw new Error('Chrome could not resize the screenshot.');
    context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const image = new Uint8Array(await (await canvas.convertToBlob({ type: 'image/jpeg', quality: .7 })).arrayBuffer());
    let binary = ''; for (let offset = 0; offset < image.length; offset += 32768) binary += String.fromCharCode(...image.subarray(offset, offset + 32768));
    const result = 'data:image/jpeg;base64,' + btoa(binary);
    if (result.length > 2_000_000) throw new Error('The screenshot is too large to check locally.');
    return result;
  } finally { bitmap.close(); }
}
async function manualCheck(mode) {
  const tab = await currentPopup();
  const original = await chrome.tabs.sendMessage(tab.id, { type: 'snapshot' }, { frameId: 0 });
  if (!original?.nonce || original.page?.url !== C.url(tab.url)) throw new Error('The page changed before this check.');
  await fresh(tab, original);
  let screenshot;
  if (mode === 'vision') {
    await fresh(tab, original);
    screenshot = await prepareScreenshot(await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'jpeg', quality: 75 }));
    await fresh(tab, original);
  }
  await fresh(tab, original);
  const request = { type: 'assess', mode,
    page: { url: original.page.url, title: C.cleanText(original.page.title, 250), text: C.cleanText(original.page.text) },
    action: { kind: 'page', method: 'GET' } };
  if (screenshot) request.screenshot = screenshot;
  const result = { ...C.verdict(await nativeRequest(request, mode === 'vision' ? 65000 : 35000)), mode };
  await fresh(tab, original);
  await chrome.storage.session.set({ ['result:' + tab.id]: { checked: result.ok === true, mode, timestamp: Date.now() } });
  if (result.id && (!result.ok || C.canPresentManual(result))) {
    await fresh(tab, original);
    await nativeRequest({ type: 'present', mode, assessment_id: result.id }, 3000);
  }
  await fresh(tab, original);
  return result;
}
function showCompletion(checked) {
  el('notice').textContent = checked ? 'Check complete. Muse will speak up if it finds a concern.' : 'Check not completed. See Muse or check the connection above.';
}
async function nativeNotice(reason) {
  try {
    const tab = await currentPopup();
    const original = await chrome.tabs.sendMessage(tab.id, { type: 'snapshot' }, { frameId: 0 });
    if (!original?.nonce || original.page?.url !== C.url(tab.url)) return;
    await fresh(tab, original);
    const result = await nativeRequest({ type: 'notice', mode: 'text', reason,
      page: original.page, action: { kind: 'page', method: 'GET' } }, 2500);
    await fresh(tab, original);
    if (result.id) await nativeRequest({ type: 'present', assessment_id: result.id }, 2500);
  } catch { /* The popup only reports connection/check status, never risk text. */ }
}
let changingProtection = false;
function updateControls() {
  for (const id of ['pause-30', 'pause-until', 'resume']) el(id).disabled = changingProtection || !state;
  for (const id of ['text-check', 'vision-check']) el(id).disabled = busy || state?.supported !== true;
}
function protectionDetail(value) {
  if (value.active) return 'Muse checks visible text automatically. Only high-risk findings call Muse over.';
  if (Number.isFinite(value.pauseUntil) && value.pauseUntil > Date.now()) {
    const minutes = Math.max(1, Math.ceil((value.pauseUntil - Date.now()) / 60000));
    return `Paused for ${minutes} more ${minutes === 1 ? 'minute' : 'minutes'}. Protection resumes automatically.`;
  }
  return 'Paused until you resume. Manual checks are still available.';
}
async function refresh({ preserveResult = false } = {}) {
  try {
    const value = await send({ type: 'popup-state' });
    if (typeof value.active !== 'boolean' || typeof value.paused !== 'boolean') throw new Error('Reload Muse Guard in Chrome to finish this update.');
    state = value;
    el('protection-status').textContent = state.active ? 'On' : 'Paused';
    el('protection-status').className = 'protection-status ' + (state.active ? 'active' : 'paused');
    el('protection-detail').textContent = protectionDetail(state);
    el('pause-controls').hidden = !state.active;
    el('resume').hidden = state.active;
    el('tab-detail').textContent = state.supported && state.origin
      ? 'Manual check: ' + new URL(state.origin).hostname
      : 'Open a normal website to use manual checks.';
    updateControls();
    if (state.result && !preserveResult) showCompletion(state.result.checked === true);
  } catch (error) {
    state = null;
    el('protection-status').textContent = 'Unavailable';
    el('protection-status').className = 'protection-status';
    el('protection-detail').textContent = error.message || 'Could not read protection status. Reopen Muse Guard to try again.';
    el('tab-detail').textContent = 'Manual checks are unavailable until the connection is restored.';
    updateControls();
  }
}
async function health() {
  try {
    const value = await send({ type: 'status' });
    const ready = value.ok && value.model_ready === true;
    el('light').className = 'light ' + (ready ? 'ready' : 'error');
    el('connection').textContent = ready ? 'Muse is ready' : value.ok ? 'The local model is starting' : 'Open the Muse Guard app';
    el('connection-detail').textContent = ready ? 'Text and visual checks stay on your Mac.' : value.guidance || value.summary || 'The desktop app and Chrome bridge must be running.';
  } catch { el('connection').textContent = 'Open the Muse Guard app'; el('light').className = 'light error'; }
}
async function changeProtection(message) {
  if (changingProtection || !state) return;
  changingProtection = true; updateControls();
  try {
    const result = await send(message);
    if (result?.ok !== true) throw new Error('Could not change protection. Please try again.');
    await refresh({ preserveResult: true });
    el('notice').textContent = '';
  } catch { el('notice').textContent = 'Could not change protection. Please try again.'; }
  finally { changingProtection = false; updateControls(); }
}
el('pause-30').addEventListener('click', () => changeProtection({ type: 'pause', duration_ms: 1800000 }));
el('pause-until').addEventListener('click', () => changeProtection({ type: 'pause', duration_ms: 0 }));
el('resume').addEventListener('click', () => changeProtection({ type: 'resume' }));
async function check(mode) {
  if (busy || state?.supported !== true) return; busy = true;
  updateControls();
  el('notice').textContent = mode === 'vision' ? 'Checking the visible tab with Muse on this Mac…' : 'Checking visible text and destinations…';
  try { const result = await manualCheck(mode); showCompletion(result.ok === true); }
  catch (error) { showCompletion(false); await nativeNotice(/changed/.test(error.message) ? 'changed' : 'unavailable'); }
  finally { busy = false; await refresh({ preserveResult: true }); }
}
el('text-check').addEventListener('click', () => check('text'));
el('vision-check').addEventListener('click', () => check('vision'));
const refreshTimer = setInterval(() => { if (!busy && !changingProtection) void refresh({ preserveResult: true }); }, 30000);
window.addEventListener('pagehide', () => clearInterval(refreshTimer));
refresh(); health();
