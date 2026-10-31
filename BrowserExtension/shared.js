(function (root) {
  'use strict';
  const LIMIT = 6000;
  const EXTREME_TTL_MS = 30000;
  // Reuse unchanged, non-high assessments for scheduling only. This lifetime
  // never extends the short receipt required to interrupt a browser action.
  const ASSESSMENT_REUSE_MS = 5 * 60 * 1000;
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
      summary: 'Muse could not finish this check.', guidance: message || 'This page has not been assessed. Open Muse Guard and check that monitoring is on.',
      categories: [], mode: 'text', duration_ms: 0, error: message || 'unavailable' };
  }
  function verdict(value) {
    if (!value || value.version !== 1 || !['allow', 'block', 'review'].includes(value.decision) ||
      !['safe', 'low', 'medium', 'high', 'unknown'].includes(value.risk_level) ||
      typeof value.summary !== 'string' || typeof value.guidance !== 'string') return failure('The local app returned an incomplete assessment.');
    // Incomplete or inconsistent results are unknown; they cannot invent the
    // confirmed high/block finding required to stop a browser action.
    const decision = value.ok !== true || (value.risk_level === 'high' && value.decision !== 'block') ? 'review' :
      ['medium', 'unknown'].includes(value.risk_level) ? 'review' : value.decision;
    return { ...value, decision, summary: cleanText(value.summary, 500), guidance: cleanText(value.guidance, 800) };
  }
  function normalizeAction(action = { kind: 'page' }) {
    const kind = cleanText(action.kind || 'page', 12);
    return { kind, url: url(action.url) || null, label: cleanText(action.label, 120),
      method: kind === 'submit' ? cleanText(action.method || 'GET', 10).toUpperCase() : 'GET', sensitive: action.sensitive === true };
  }
  function pageEvidence(value) {
    if (!value || value.version !== 1 ||
        !Number.isInteger(value.primary_text_characters) || value.primary_text_characters < 0 || value.primary_text_characters > 8000 ||
        !Number.isInteger(value.visible_text_characters) || value.visible_text_characters < value.primary_text_characters || value.visible_text_characters > 8000 ||
        !Number.isInteger(value.substantial_visuals) || value.substantial_visuals < 0 || value.substantial_visuals > 64 ||
        !Number.isInteger(value.visual_revision) || value.visual_revision < 0 || value.visual_revision > 2147483647 ||
        typeof value.requires_visual !== 'boolean' || typeof value.truncated !== 'boolean') return null;
    return { version: 1, primary_text_characters: value.primary_text_characters,
      visible_text_characters: value.visible_text_characters, substantial_visuals: value.substantial_visuals,
      requires_visual: value.requires_visual, truncated: value.truncated, visual_revision: value.visual_revision };
  }
  function assessmentKey(page, action) {
    return JSON.stringify([url(page.url) || '', cleanText(page.title, 250), cleanText(page.text), normalizeAction(action), pageEvidence(page.evidence)]);
  }
  function publicSignature(action, types = []) {
    return JSON.stringify([normalizeAction(action), types.slice(0, 32).map(type => cleanText(type, 32).toLowerCase())]);
  }
  function isConfirmedExtreme(result, now = Date.now()) {
    return result?.ok === true && result.confirmed_extreme === true && result.risk_level === 'high' && result.decision === 'block' &&
      Number.isFinite(result.expires_at) && result.expires_at > now;
  }
  function isPresentableWarning(result, now = Date.now()) {
    return isConfirmedExtreme(result, now) || result?.ok === true && result.warning_eligible === true &&
      result.risk_level === 'medium' && result.decision === 'review' &&
      Number.isFinite(result.warning_expires_at) && result.warning_expires_at > now;
  }
  const api = { LIMIT, EXTREME_TTL_MS, ASSESSMENT_REUSE_MS, url, origin, cleanText, failure, verdict, normalizeAction, pageEvidence,
    assessmentKey, publicSignature, isConfirmedExtreme, isPresentableWarning };
  root.MuseGuardCore = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(globalThis);
