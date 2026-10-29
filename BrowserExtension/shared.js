(function (root) {
  'use strict';
  const LIMIT = 6000;
  const EXTREME_TTL_MS = 30000;
  function url(value, base) {
    try {
      const parsed = new URL(value, base);
      if (!['http:', 'https:'].includes(parsed.protocol)) return null;
      parsed.username = ''; parsed.password = ''; parsed.search = ''; parsed.hash = '';
      return parsed.href;
    } catch { return null; }
  }
  function origin(value) { try { return new URL(value).origin; } catch { return ''; } }
  function cleanText(value, limit = LIMIT) {
    return String(value || '').replace(/https?:\/\/[^\s<>"')]+/gi, value => url(value) || '[unsupported address]')
      .replace(/\s+/g, ' ').trim().slice(0, limit);
  }
  function failure(message, id = '') {
    return { version: 1, id, ok: false, decision: 'review', risk_level: 'unknown',
      summary: 'Muse could not finish this check.', guidance: message || 'This page has not been assessed. You can try a manual check.',
      categories: [], mode: 'text', duration_ms: 0, error: message || 'unavailable' };
  }
  function verdict(value) {
    if (!value || value.version !== 1 || !['allow', 'block', 'review'].includes(value.decision) ||
      !['safe', 'low', 'medium', 'high', 'unknown'].includes(value.risk_level) ||
      typeof value.summary !== 'string' || typeof value.guidance !== 'string') return failure('The local app returned an incomplete assessment.');
    // Incomplete or inconsistent results are unknown; they cannot invent the
    // confirmed high/block finding required by automatic interruption.
    const decision = value.ok !== true || (value.risk_level === 'high' && value.decision !== 'block') ? 'review' :
      ['medium', 'unknown'].includes(value.risk_level) ? 'review' : value.decision;
    return { ...value, decision, summary: cleanText(value.summary, 500), guidance: cleanText(value.guidance, 800) };
  }
  function normalizeAction(action = { kind: 'page' }) {
    const kind = cleanText(action.kind || 'page', 12);
    return { kind, url: url(action.url) || null, label: cleanText(action.label, 120),
      method: kind === 'submit' ? cleanText(action.method || 'GET', 10).toUpperCase() : 'GET', sensitive: action.sensitive === true };
  }
  function assessmentKey(page, action) {
    return JSON.stringify([url(page.url) || '', cleanText(page.title, 250), cleanText(page.text), normalizeAction(action)]);
  }
  function publicSignature(action, types = []) {
    return JSON.stringify([normalizeAction(action), types.slice(0, 32).map(type => cleanText(type, 32).toLowerCase())]);
  }
  function isConfirmedExtreme(result, now = Date.now()) {
    return result?.ok === true && result.confirmed_extreme === true && result.risk_level === 'high' && result.decision === 'block' &&
      Number.isFinite(result.expires_at) && result.expires_at > now;
  }
  function canPresent(result, kind = 'page', manual = false) {
    if (manual) return !!result && result.version === 1 && typeof result.id === 'string' &&
      ['allow', 'block', 'review'].includes(result.decision) && ['medium', 'high', 'unknown'].includes(result.risk_level);
    return isConfirmedExtreme(result);
  }
  const api = { LIMIT, EXTREME_TTL_MS, url, origin, cleanText, failure, verdict, normalizeAction, assessmentKey, publicSignature, isConfirmedExtreme, canPresent };
  root.MuseGuardCore = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(globalThis);
