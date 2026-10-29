(function () {
  'use strict';
  if (window.top !== window) return;
  // Declarative navigation injection and existing-tab hydration can race.
  // The singleton lives only in Chrome's isolated world, not the page's JS.
  const INSTANCE_KEY = '__museGuardContentLifecycle';
  const previous = window[INSTANCE_KEY];
  try { if (previous?.isAlive()) return; } catch { /* An old extension world may already be invalid. */ }
  try { previous?.dispose(); } catch { /* A replacement never depends on stale context cleanup. */ }
  const runtime = chrome.runtime, extensionID = runtime.id;
  const C = MuseGuardCore;
  const nonce = crypto.randomUUID?.() || [...crypto.getRandomValues(new Uint8Array(16))].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const PRIVATE = 'input,textarea,select,option,script,style,noscript,template,svg,canvas,iframe,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"],[data-private],[data-muse-private],muse-guard-panel';
  let active = false, generation = 0, configurationSequence = 0, edits = 0, lastURL = location.href;
  let pageTimer, hoverTimer, mutationTimer, resumeTimer, lastPageKey = '', lastPageAttempt = 0, retryFailures = 0;
  let disposed = false, observer, routeTimer, runtimeMessage, instance;
  const removals = [];
  const cache = new Map(), inflight = new Map(), presentations = new Set(), localProofs = new Map();
  function dispose() {
    if (disposed) return;
    disposed = true; active = false; generation++; configurationSequence++;
    for (const timer of [pageTimer, hoverTimer, mutationTimer, resumeTimer]) clearTimeout(timer);
    clearInterval(routeTimer); observer?.disconnect();
    for (const remove of removals.splice(0)) remove();
    try { if (runtimeMessage) runtime.onMessage.removeListener?.(runtimeMessage); } catch { /* Already invalidated. */ }
    cache.clear(); inflight.clear(); presentations.clear(); localProofs.clear();
    if (window[INSTANCE_KEY] === instance) delete window[INSTANCE_KEY];
  }
  function usable() {
    if (disposed) return false;
    try { if (extensionID && runtime.id === extensionID && window[INSTANCE_KEY] === instance) return true; } catch { /* Invalidated after reload. */ }
    dispose(); return false;
  }
  function listen(target, type, listener, options) {
    const guarded = event => { if (usable()) listener(event); };
    target.addEventListener(type, guarded, options);
    removals.push(() => target.removeEventListener(type, guarded, options));
  }
  async function send(message) {
    if (!usable()) throw new Error('Muse Guard extension context is no longer active.');
    try { return await runtime.sendMessage({ ...message, nonce }); }
    catch (error) {
      if (!usable() || /extension context invalidated/i.test(String(error?.message || error))) dispose();
      throw error;
    }
  }
  instance = { isAlive: usable, dispose };
  window[INSTANCE_KEY] = instance;
  function displayed(element) {
    for (let ancestor = element; ancestor; ancestor = ancestor.parentElement) {
      const style = getComputedStyle(ancestor);
      if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return false;
    }
    const box = element.getBoundingClientRect();
    return box.width > 0 && box.height > 0 && box.bottom > 0 && box.top < innerHeight && box.right > 0 && box.left < innerWidth;
  }
  function visible(element) { return !!element && !element.closest(PRIVATE) && displayed(element); }
  function sensitive(form) { return !!form?.querySelector('input[type="password"],input[autocomplete~="one-time-code"],input[autocomplete~="current-password"],input[autocomplete~="new-password"]'); }
  function snapshotDestination(value, limit) {
    const destination = C.url(value);
    if (!destination) return 'unsupported';
    if (destination.length <= limit) return destination;
    // Keep a complete origin: a cut-off hostname could suggest the wrong site.
    if (new URL(destination).origin.length > limit - 2) return '[destination too long]';
    return destination.slice(0, limit - 2) + ' …';
  }
  function snapshot() {
    // Independent budgets preserve visible form evidence on link-heavy pages.
    const bodyLimit = 3500, linkLimit = 1400, formLimit = 1000;
    const parts = []; let length = 0;
    if (document.body) {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(), visited = 0; node && length < bodyLimit && visited++ < 4000; node = walker.nextNode()) {
        if (!visible(node.parentElement)) continue;
        const text = C.cleanText(node.textContent, bodyLimit - length);
        if (text) { parts.push(text); length += text.length + 1; }
      }
    }
    const anchors = [...document.querySelectorAll('a[href]')].filter(a => visible(a) && C.url(a.href)).slice(0, 12);
    const perLink = Math.floor((linkLimit - Math.max(0, anchors.length - 1)) / Math.max(1, anchors.length));
    const labelLimit = Math.min(80, Math.floor(perLink * 0.3));
    const links = anchors.map(a => C.cleanText(actionLabel(a), labelLimit) + ' → ' + snapshotDestination(a.href, perLink - labelLimit - 3));
    const forms = [...document.forms].filter(visibleForm).slice(0, 3).map(form => {
      const fields = [...form.querySelectorAll('input,textarea,select')].slice(0, 20).map(field => field.type || field.tagName.toLowerCase()).filter(type => type !== 'hidden');
      return 'Form destination: ' + snapshotDestination(form.action || location.href, 150) + '; method: ' + C.cleanText(form.method, 8) +
        '; field types: ' + C.cleanText([...new Set(fields)].join(', '), 80) + '; sensitive fields: ' + sensitive(form);
    });
    return { url: C.url(location.href), title: C.cleanText(document.title, 250),
      text: C.cleanText(parts.join('\n') + '\nVisible link destinations:\n' + C.cleanText(links.join('\n'), linkLimit) +
        '\nVisible forms:\n' + C.cleanText(forms.join('\n'), formLimit)) };
  }
  function actionLabel(element) {
    const explicit = element.getAttribute('aria-label') || element.getAttribute('title');
    if (explicit) return C.cleanText(explicit, 120);
    if (['INPUT', 'FORM'].includes(element.tagName)) return 'Submit form';
    const parts = [], walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    let length = 0;
    for (let text = walker.nextNode(); text && length < 120; text = walker.nextNode()) {
      if (!visible(text.parentElement)) continue;
      parts.push(text.textContent); length += text.textContent.length;
    }
    return C.cleanText(parts.join(' '), 120);
  }
  function fieldTypes(form) {
    return [...form.elements].slice(0, 32).map(field => String(field.type || field.tagName.toLowerCase()).toLowerCase());
  }
  function formDetails(form, submitter) {
    return { href: submitter?.hasAttribute('formaction') ? submitter.formAction : form.action || location.href,
      method: (submitter?.hasAttribute('formmethod') ? submitter.formMethod : form.method || 'GET').toUpperCase(),
      target: submitter?.hasAttribute('formtarget') ? submitter.formTarget : form.target,
      sensitive: sensitive(form), types: fieldTypes(form) };
  }
  function visibleForm(form) {
    if (!form?.isConnected || form.closest('[hidden],[aria-hidden="true"],[data-private],[data-muse-private]')) return false;
    if (visible(form)) return true;
    return [...form.elements].some(element => {
      return element.type !== 'hidden' && !element.closest('[hidden],[aria-hidden="true"],[data-private],[data-muse-private]') && displayed(element);
    });
  }
  function describeForm(form, submitter = null) {
    if (!(form instanceof HTMLFormElement) || !visibleForm(form)) return null;
    const details = formDetails(form, submitter);
    if (!C.url(details.href) || !['GET', 'POST'].includes(details.method)) return null;
    return { kind: 'submit', element: form, submitter, ...details, label: actionLabel(submitter || form) };
  }
  function describeLink(anchor) {
    if (!anchor?.isConnected || !visible(anchor) || !C.url(anchor.href)) return null;
    if (anchor.href === location.href || (anchor.hash && anchor.href.split('#')[0] === location.href.split('#')[0])) return null;
    return { kind: 'link', element: anchor, href: anchor.href, target: anchor.target, label: actionLabel(anchor), types: [] };
  }
  function defaultSubmitter(form) {
    return [...form.elements].find(field => !field.disabled && ['submit', 'image'].includes(field.type)) || null;
  }
  function candidateForElement(element) {
    if (!(element instanceof Element)) return null;
    const link = element.closest('a[href]'); if (link) return describeLink(link);
    const button = element.closest('button,input[type="submit"],input[type="image"]');
    if (button?.form && !button.disabled && ['submit', 'image'].includes(button.type)) return describeForm(button.form, button);
    if (element.form) return describeForm(element.form, defaultSubmitter(element.form));
    return null;
  }
  function candidateForEvent(event) {
    if (event.type === 'submit') return describeForm(event.target, event.submitter || null);
    if (event.type === 'auxclick' && event.button !== 1) return null;
    const element = event.composedPath().find(value => value instanceof Element);
    if (!element) return null;
    const link = element.closest('a[href]');
    if (link) return describeLink(link);
    if (event.type === 'auxclick' || event.button !== 0) return null;
    const button = element.closest('button,input[type="submit"],input[type="image"]');
    if (button?.form && !button.disabled && ['submit', 'image'].includes(button.type)) return describeForm(button.form, button);
    return null;
  }
  function actionFor(candidate) {
    return C.normalizeAction(candidate ? { kind: candidate.kind, url: candidate.href, method: candidate.method,
      label: candidate.label, sensitive: candidate.sensitive } : { kind: 'page' });
  }
  function localSignature(candidate) {
    if (!candidate) return 'page';
    if (candidate.kind === 'link') return JSON.stringify([candidate.element.href, candidate.element.target, candidate.element.getAttribute('download'), actionLabel(candidate.element)]);
    return JSON.stringify([formDetails(candidate.element, candidate.submitter), candidate.submitter?.isConnected !== false, actionLabel(candidate.submitter || candidate.element)]);
  }
  function material(candidate) {
    const page = snapshot(), action = actionFor(candidate);
    const signature = C.publicSignature(action, candidate?.types || []), local = localSignature(candidate);
    return { page, action, public_signature: signature, local,
      key: JSON.stringify([location.href, C.assessmentKey(page, action), signature, local]), rawURL: location.href };
  }
  async function actionFingerprint(local) {
    if (crypto.subtle) {
      const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(local));
      return [...new Uint8Array(bytes)].map(byte => byte.toString(16).padStart(2, '0')).join('');
    }
    // Some HTTP documents do not expose SubtleCrypto. A random identity bound
    // to this exact local intent has the same isolation property; raw URLs
    // stay in Chrome, and changing the intent always gets a different token.
    if (!localProofs.has(local)) {
      localProofs.set(local, [...crypto.getRandomValues(new Uint8Array(32))].map(byte => byte.toString(16).padStart(2, '0')).join(''));
      if (localProofs.size > 64) localProofs.delete(localProofs.keys().next().value);
    }
    return localProofs.get(local);
  }
  function stillCurrent(candidate, original) {
    if (!active || !usable() || original.rawURL !== location.href || (candidate && !candidate.element.isConnected)) return false;
    return material(candidate).key === original.key;
  }
  function cached(candidate) {
    const proof = material(candidate), value = cache.get(proof.key);
    if (!value || !C.isConfirmedExtreme(value.result) || value.until <= Date.now()) { cache.delete(proof.key); return null; }
    // A framework can replace a link or form with an equivalent node. Match
    // its exact current intent again before using the already-checked finding.
    value.candidate = candidate; value.proof = { ...proof, action_fingerprint: value.proof.action_fingerprint };
    return value;
  }
  function cancelWarnings() {
    for (const id of presentations) send({ type: 'cancel', assessment_id: id }).catch(() => {});
    presentations.clear();
  }
  async function warn(entry, clicked = false) {
    if (!active || document.visibilityState !== 'visible' || !C.isConfirmedExtreme(entry.result) || entry.until <= Date.now()) return;
    if (entry.presenting || (!clicked && entry.warned)) return;
    if (!stillCurrent(entry.candidate, entry.proof)) return;
    const stamp = generation; entry.presenting = true;
    try {
      const response = await send({ type: 'present-block', assessment_id: entry.result.id,
        page: entry.proof.page, action: entry.proof.action, public_signature: entry.proof.public_signature,
        action_fingerprint: entry.proof.action_fingerprint });
      if (response?.ok === true) {
        if (stamp !== generation || !stillCurrent(entry.candidate, entry.proof)) {
          if (response.id) send({ type: 'cancel', assessment_id: response.id }).catch(() => {});
          return;
        }
        entry.warned = true;
        if (typeof response.id === 'string') presentations.add(response.id);
      }
    } catch { /* The original click remains untouched, or held only for known extreme risk. */ }
    finally { entry.presenting = false; }
  }
  function schedulePage(delay = 250) {
    if (!active || !usable()) return; clearTimeout(pageTimer); pageTimer = setTimeout(scanPage, Math.max(0, delay));
  }
  async function assess(candidate, purpose) {
    if (!active || (candidate && !candidate.element.isConnected)) return null;
    const proof = material(candidate), existing = cache.get(proof.key);
    if (existing && C.isConfirmedExtreme(existing.result) && existing.until > Date.now()) { void warn(existing); return existing.result; }
    if (inflight.has(proof.key)) return inflight.get(proof.key);
    if (inflight.size >= (purpose === 'intent' ? 4 : 3)) return null;
    const stamp = generation;
    let task;
    task = Promise.resolve().then(async () => {
      try {
        proof.action_fingerprint = await actionFingerprint(proof.local);
        if (stamp !== generation || !stillCurrent(candidate, proof)) return null;
        const result = C.verdict(await send({ type: 'assess', purpose, page: proof.page, action: proof.action,
          public_signature: proof.public_signature, action_fingerprint: proof.action_fingerprint }));
        if (stamp !== generation || !stillCurrent(candidate, proof)) return null;
        if (C.isConfirmedExtreme(result)) {
          const entry = { result, proof, candidate, warned: false, until: Math.min(result.expires_at, Date.now() + C.EXTREME_TTL_MS) };
          cache.set(proof.key, entry); if (cache.size > 40) cache.delete(cache.keys().next().value);
          void warn(entry);
        } else cache.delete(proof.key);
        return result;
      } catch { return null; }
      finally { if (inflight.get(proof.key) === task) inflight.delete(proof.key); }
    });
    inflight.set(proof.key, task); return task;
  }
  function prefetchForms() {
    if (!active) return;
    for (const form of [...document.forms].filter(form => sensitive(form) && visibleForm(form)).slice(0, 2)) {
      const candidate = describeForm(form, defaultSubmitter(form)); if (candidate) void assess(candidate, 'intent');
    }
  }
  async function scanPage() {
    if (!active || !usable()) return;
    const key = C.assessmentKey(snapshot()), fresh = cached(null);
    if (fresh) {
      void warn(fresh); prefetchForms(); schedulePage(Math.max(250, fresh.until - Date.now() + 10)); return;
    }
    // Coalesce repeated mutations without permanently skipping unchanged pages
    // after an unavailable model, full queue, or a previous non-extreme result.
    if (key === lastPageKey && Date.now() - lastPageAttempt < 5000) { schedulePage(5000); return; }
    lastPageKey = key; lastPageAttempt = Date.now();
    prefetchForms();
    const stamp = generation, result = await assess(null, 'proactive');
    if (!active || stamp !== generation) return;
    prefetchForms();
    retryFailures = result?.ok ? 0 : Math.min(4, retryFailures + 1);
    const retryHint = Number.isFinite(result?.retry_after_ms) ? Math.min(60000, Math.max(0, result.retry_after_ms)) : 0;
    const delay = result?.ok ? C.EXTREME_TTL_MS : Math.max(retryHint, Math.min(60000, 5000 * (2 ** (retryFailures - 1))));
    schedulePage(delay);
  }
  function gate(event) {
    if (!active || cache.size === 0 || !event.isTrusted || event.defaultPrevented) return;
    const candidate = candidateForEvent(event); if (!candidate) return;
    const entry = cached(candidate); if (!entry) return;
    // No await and no unknown-risk hold: only a fresh, exact, already-confirmed
    // extreme finding can synchronously stop this browser action.
    event.preventDefault(); event.stopImmediatePropagation(); void warn(entry, true);
  }
  for (const type of ['click', 'auxclick', 'submit']) listen(window, type, gate, true);
  function intent(event) {
    if (!active || !event.isTrusted) return;
    const element = event.composedPath().find(value => value instanceof Element);
    const candidate = candidateForElement(element); if (!candidate) return;
    clearTimeout(hoverTimer);
    if (event.type === 'touchstart' || event.type === 'pointerdown' || (event.type === 'keydown' && event.key === 'Enter')) void assess(candidate, 'intent');
    else hoverTimer = setTimeout(() => { if (active) void assess(candidate, 'intent'); }, 200);
  }
  for (const type of ['pointerover', 'mouseover', 'focusin', 'pointerdown', 'touchstart']) listen(window, type, intent, { capture: true, passive: true });
  for (const type of ['pointerout', 'mouseout', 'focusout']) listen(window, type, () => clearTimeout(hoverTimer), { capture: true, passive: true });
  listen(window, 'keydown', event => { if (event.key === 'Enter') intent(event); }, true);
  for (const type of ['input', 'change']) listen(window, type, () => { edits++; if (active) schedulePage(1200); }, true);
  function resetAutomatic() {
    generation++; clearTimeout(pageTimer); clearTimeout(hoverTimer); clearTimeout(mutationTimer);
    cache.clear(); inflight.clear(); localProofs.clear(); lastPageKey = ''; lastPageAttempt = 0; retryFailures = 0; cancelWarnings();
  }
  function routeChanged() {
    if (!active || lastURL === location.href) return;
    lastURL = location.href; resetAutomatic(); schedulePage(100);
  }
  function activate() {
    if (!active) return; routeChanged(); const fresh = cached(null); if (fresh) void warn(fresh); schedulePage(100); prefetchForms();
  }
  async function refresh() {
    const sequence = ++configurationSequence, stamp = generation;
    try {
      const value = await send({ type: 'configuration' });
      if (sequence !== configurationSequence) return;
      const next = value.supported !== false && value.enabled !== false && value.paused !== true && (value.active ?? value.approved) === true;
      const changed = next !== active; active = next; clearTimeout(resumeTimer);
      if (!active) { resetAutomatic(); if (Number.isFinite(value.pauseUntil) && value.pauseUntil > Date.now()) resumeTimer = setTimeout(refresh, value.pauseUntil - Date.now() + 50); }
      else if (changed || stamp === generation) { lastURL = location.href; schedulePage(100); prefetchForms(); }
    } catch { if (sequence === configurationSequence) { active = false; resetAutomatic(); } }
  }
  function mutations(records) {
    if (!active) return;
    const meaningful = records.some(record => {
      if (record.type === 'attributes' && ['type', 'autocomplete', 'action', 'formaction', 'method', 'formmethod', 'target'].includes(record.attributeName)) return true;
      const element = record.target instanceof Element ? record.target : record.target.parentElement;
      return element && !element.closest(PRIVATE);
    });
    if (!meaningful) return;
    cancelWarnings();
    clearTimeout(mutationTimer); mutationTimer = setTimeout(() => { routeChanged(); schedulePage(1000); prefetchForms(); }, 150);
  }
  observer = new MutationObserver(records => { if (usable()) mutations(records); });
  observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: ['href', 'action', 'formaction', 'method', 'formmethod', 'target', 'type', 'autocomplete', 'hidden', 'aria-hidden'] });
  listen(window, 'popstate', routeChanged); listen(window, 'hashchange', routeChanged);
  listen(document, 'visibilitychange', () => { if (document.visibilityState === 'visible') activate(); }); listen(window, 'focus', activate);
  listen(document, 'DOMContentLoaded', activate, { once: true });
  listen(window, 'pagehide', () => { resetAutomatic(); clearTimeout(resumeTimer); }, true);
  // A back/forward-cache restore keeps this content instance alive, but global
  // protection may have been paused while the page was frozen.
  listen(window, 'pageshow', event => { if (event.persisted) void refresh(); else activate(); });
  routeTimer = setInterval(() => { if (usable() && active) routeChanged(); }, 1000);
  runtimeMessage = (message, sender, reply) => {
    if (!usable() || sender.id !== extensionID) { reply({ ok: false }); return; }
    if (message.type === 'monitor-ready') { reply({ ready: true }); return; }
    if (message.type === 'monitor-activated') {
      // Chrome's tab event is an independent recovery path when a document's
      // visibility/focus event was missed or its initial config read failed.
      // Re-read global Pause before scheduling; keep current in-flight checks
      // and exact caches when protection is still active.
      refresh().then(() => {
        if (!usable()) { reply({ ok: false }); return; }
        activate(); reply({ ok: true, active });
      }); return true;
    }
    if (message.type === 'snapshot') { reply({ nonce, revision: edits, captureSupport: 2, page: snapshot() }); return; }
    if (message.type === 'prepare-capture') { reply({ ok: message.nonce === nonce, nonce }); return; }
    if (message.type === 'restore-capture' || message.type === 'manual-result') { reply({ ok: true }); return; }
    if (message.type === 'configuration-changed') {
      // A fast Pause/Resume can make both settings reads report active. The
      // notification itself invalidates every pre-pause local finding.
      active = false; resetAutomatic(); clearTimeout(resumeTimer);
      refresh().then(() => reply({ ok: true })); return true;
    }
  };
  runtime.onMessage.addListener(runtimeMessage);
  refresh();
})();
