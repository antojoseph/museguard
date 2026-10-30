'use strict';
const el = id => document.getElementById(id);
let changing = false, state = null, ready = false;
function controls() {
  el('pause').disabled = changing || !state;
  el('resume').disabled = changing || !state;
  el('pause-duration').disabled = changing;
}
function showState(value) {
  state = value;
  const confirmed = value.monitoringConfirmed === true;
  el('pause-controls').hidden = value.paused && confirmed;
  el('resume').hidden = !value.paused;
  el('protection-status').textContent = value.paused ? confirmed ? 'Paused' : 'Pause pending' : ready && confirmed ? 'Active' : 'Unavailable';
  el('protection-status').className = 'protection-status ' + (value.paused ? 'paused' : ready && confirmed ? 'active' : '');
  if (value.paused && !confirmed) {
    el('protection-detail').textContent = 'Chrome is paused. Desktop monitoring has not confirmed the pause yet. Open Muse Guard or try Pause monitoring again.';
  } else if (value.paused) {
    const minutes = value.pauseUntil > Date.now() ? Math.max(1, Math.ceil((value.pauseUntil - Date.now()) / 60000)) : 0;
    el('protection-detail').textContent = minutes ? `All monitoring is paused for ${minutes} more ${minutes === 1 ? 'minute' : 'minutes'}. It resumes automatically.` : 'All monitoring is paused until you resume.';
  } else el('protection-detail').textContent = ready && confirmed ? 'Muse checks your Chrome tabs automatically. Serious warnings come from Muse, even when she is hidden.' : 'Monitoring is enabled, but Muse cannot check pages until the local connection is ready.';
  el('tab-detail').textContent = value.supported && value.readable ? 'This tab is connected to Muse.' : 'Chrome does not allow Muse to read this tab.';
  const downloads = value.downloads;
  el('downloads-status').textContent = downloads?.available !== true ? 'Downloads unavailable. Reload Muse Guard in Chrome.' :
    downloads.started !== true ? 'Downloads are not connected. Reload Muse Guard in Chrome.' :
    downloads.paused || value.paused ? 'Download checks paused.' :
    !ready || !confirmed ? 'Download checks are waiting for Muse.' :
    downloads.processing > 0 ? `Checking ${downloads.processing === 1 ? 'a download' : `${downloads.processing} downloads`}…` :
    downloads.pending > 0 ? `${downloads.pending === 1 ? 'A download is' : `${downloads.pending} downloads are`} waiting.` : 'Downloads connected to Muse.';
  controls();
}
async function refresh() {
  try {
    const [value, health] = await Promise.all([chrome.runtime.sendMessage({ type: 'popup-state' }), chrome.runtime.sendMessage({ type: 'status' })]);
    if (typeof value?.active !== 'boolean' || typeof value?.paused !== 'boolean') throw new Error('Reload Muse Guard in Chrome to finish this update.');
    ready = health?.ok === true && health.model_ready === true;
    el('light').className = 'light ' + (ready ? 'ready' : 'error');
    el('connection').textContent = ready ? 'Muse is ready' : health?.ok === true ? 'Muse is getting ready' : 'Open the Muse Guard app';
    el('connection-detail').textContent = ready ? 'Everything is checked locally on your Mac.' : health?.ok === true ? 'The local model is starting.' : 'Monitoring needs the desktop app and Chrome connection.';
    showState(value);
  } catch (error) {
    state = null; ready = false;
    el('light').className = 'light error';
    el('connection').textContent = 'Connection unavailable';
    el('connection-detail').textContent = error.message || 'Open Muse Guard and reopen this popup.';
    el('protection-status').textContent = 'Unavailable';
    el('protection-status').className = 'protection-status';
    el('downloads-status').textContent = 'Download connection unavailable.';
    controls();
  }
}
async function change(type) {
  if (changing || !state) return;
  changing = true; controls();
  try {
    const message = { type };
    if (type === 'pause') message.duration_ms = Number(el('pause-duration').value);
    const result = await chrome.runtime.sendMessage(message);
    if (result?.ok !== true) throw new Error(result?.error || 'Monitoring could not change. Open Muse Guard and try again.');
    el('notice').textContent = '';
  } catch (error) { el('notice').textContent = error.message; }
  finally { changing = false; await refresh(); }
}
el('pause').addEventListener('click', () => change('pause'));
el('resume').addEventListener('click', () => change('resume'));
const timer = setInterval(() => { if (!changing) void refresh(); }, 2000);
window.addEventListener('pagehide', () => clearInterval(timer));
void refresh();
