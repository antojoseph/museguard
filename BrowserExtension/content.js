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
  const T = MuseGuardTargets, S = MuseGuardSecrets;
  const nonce = crypto.randomUUID?.() || [...crypto.getRandomValues(new Uint8Array(16))].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const PRIVATE_REGION = 'input,textarea,select,option,script,style,noscript,template,iframe,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"],[data-private],[data-muse-private]';
  const PRIVATE = 'svg,canvas,' + PRIVATE_REGION;
  const NAVIGATION = 'nav,aside,[role="navigation"],[role="complementary"],[role="toolbar"],[role="menubar"],[role="menu"],button,[role="button"],[role="tablist"],[role="tab"],[role="menuitem"]';
  const VISUAL = 'img,canvas,video,svg';
  let active = false, generation = 0, configurationSequence = 0, edits = 0, visualEdits = 0, lastURL = location.href;
  let pageTimer, pageScheduledAt = 0, hoverTimer, mutationTimer, resumeTimer, lastPageKey = '', lastPageAttempt = 0, retryFailures = 0;
  let lastSuccessfulPageKey = '', lastSuccessfulPageUntil = 0, lastSuccessfulPageRisk = null;
  let disposed = false, observer, routeTimer, runtimeMessage, instance;
  let nativeAvailableUntil = 0, trackedTarget = null, targetTimer = null;
  const observedVisuals = new WeakSet();
  let secretGuard;
  const removals = [];
  const cache = new Map(), assessmentReuse = new Map(), inflight = new Map(), presentations = new Set(), localProofs = new Map(), warnedCautions = new Map();
  function dispose() {
    if (disposed) return;
    disposed = true; active = false; generation++; configurationSequence++;
    secretGuard?.dispose(); T.invalidate(window); clearTimeout(targetTimer); trackedTarget = null; nativeAvailableUntil = 0;
    for (const timer of [pageTimer, hoverTimer, mutationTimer, resumeTimer]) clearTimeout(timer);
    clearInterval(routeTimer); observer?.disconnect();
    for (const remove of removals.splice(0)) remove();
    try { if (runtimeMessage) runtime.onMessage.removeListener?.(runtimeMessage); } catch { /* Already invalidated. */ }
    cache.clear(); assessmentReuse.clear(); inflight.clear(); presentations.clear(); localProofs.clear(); warnedCautions.clear();
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
  function sourceGeometry(element) {
    const target = element ? T.capture(element, { documentID: nonce, revision: edits }) : null;
    if (target) {
      trackedTarget = { element, measurement: target, presented: false, renewing: false,
        renewAt: Date.now() + 1000, expiresAt: Date.now() + 12000 };
      clearTimeout(targetTimer); targetTimer = setTimeout(checkTarget, 150);
    }
    return { document_id: nonce, page_revision: edits, ...(target ? { target } : {}) };
  }
  function confirmTarget(target) {
    if (target && trackedTarget?.measurement === target) trackedTarget.presented = true;
  }
  function invalidateGeometry(increment = true) {
    if (increment) edits++;
    // A field edit, DOM mutation or focus event invalidates the element's
    // placement, but does not move the viewport's screen origin. Preserve its
    // recent trusted pointer anchor; targets.capture checks geometryKey again
    // and omits it after window/viewport/zoom changes or its 12-second expiry.
    clearTimeout(targetTimer);
    const hadTarget = trackedTarget !== null; trackedTarget = null;
    if (hadTarget && usable()) send({ type: 'target-invalidated', document_id: nonce, page_revision: edits }).catch(() => {});
  }
  function checkTarget() {
    if (!trackedTarget || !usable()) return;
    if (Date.now() >= trackedTarget.expiresAt || !T.revalidate(trackedTarget.element, trackedTarget.measurement, { documentID: nonce, revision: edits })) {
      invalidateGeometry(); return;
    }
    if (trackedTarget.presented && !trackedTarget.renewing && Date.now() >= trackedTarget.renewAt) void renewTarget(trackedTarget);
    targetTimer = setTimeout(checkTarget, 150);
  }
  async function renewTarget(tracking) {
    const target = T.capture(tracking.element, { documentID: nonce, revision: edits });
    if (!target || !T.same(tracking.measurement, target)) { invalidateGeometry(); return; }
    tracking.renewing = true;
    let response;
    try { response = await send({ type: 'target-update', document_id: nonce, page_revision: edits, target }); }
    catch { response = null; }
    if (trackedTarget !== tracking) return;
    tracking.renewing = false;
    if (response?.ok !== true || !active || !T.revalidate(tracking.element, target, { documentID: nonce, revision: edits })) {
      invalidateGeometry(); return;
    }
    tracking.measurement = target; tracking.renewAt = Date.now() + 1000;
  }
  secretGuard = S.createGuard({ window,
    isActive: () => active && usable() && document.visibilityState === 'visible',
    isAvailable: () => nativeAvailableUntil > Date.now(),
    contextForTarget: element => ({ pageURL: location.href, destinationURL: element.form?.action || location.href }),
    deliveryTimeoutMS: 2500,
    onUnavailable: () => { nativeAvailableUntil = 0; },
    notify: async (metadata, element) => {
      if (!active || !usable() || nativeAvailableUntil <= Date.now()) return false;
      // Never send clipboard text, field values, fingerprints or text around
      // the field. Static detector categories are sufficient for the warning.
      const geometry = sourceGeometry(element);
      const response = await send({ type: 'secret-paste',
        secret: { category: metadata.category, count: metadata.count, categories: [...metadata.categories], phase: metadata.phase },
        page: { url: C.url(location.href), title: C.cleanText(document.title, 250), text: '' }, ...geometry });
      const delivered = response?.ok === true && response.decision === 'block';
      if (!delivered) nativeAvailableUntil = 0;
      else confirmTarget(geometry.target);
      return delivered;
    }
  });
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
    // App navigation and retained, hidden SPA views can precede the content
    // the user is reading by thousands of nodes. Spend the evidence budget
    // on visible main/article regions first, then other visible page text.
    const roots = [];
    for (const element of document.querySelectorAll('main,[role="main"],article,[role="article"]')) {
      if (roots.length >= 8) break;
      if (visible(element) && !roots.some(root => root.contains(element))) roots.push(element);
    }
    const parts = [], primaryParts = [], visibleParts = []; let length = 0, visited = 0, truncated = false;
    function append(value, element, primary, visibleText = true) {
      const remaining = bodyLimit - length;
      const limit = visibleText ? remaining : Math.min(250, remaining);
      const full = C.cleanText(value), text = full.slice(0, Math.max(0, limit));
      if (full.length > limit) truncated = true;
      if (text) {
        parts.push(text); length += text.length + 1;
        if (visibleText) {
          visibleParts.push(text);
          if (primary && !element.closest(NAVIGATION)) primaryParts.push(text);
        }
      }
    }
    function appendText(root, skipRoots = false, primary = false) {
      if (length >= bodyLimit || visited >= 8000) return;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          // Rejected siblings still consume traversal work. Accept one
          // sentinel at the limit so nextNode returns immediately; the outer
          // loop stops before reading it, even if it is private or hidden.
          if (++visited > 8000) { truncated = true; return NodeFilter.FILTER_ACCEPT; }
          if (node.nodeType !== Node.ELEMENT_NODE) return NodeFilter.FILTER_ACCEPT;
          if (skipRoots && roots.includes(node) || node.matches(PRIVATE)) return NodeFilter.FILTER_REJECT;
          const style = getComputedStyle(node);
          // Reject the subtree itself; walking all its hidden text first can
          // exhaust a bounded traversal before reaching an open email.
          return style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0 ?
            NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
        }
      });
      for (let node = walker.nextNode(); node && length < bodyLimit && visited <= 8000; node = walker.nextNode()) {
        if (node.nodeType === Node.ELEMENT_NODE && node.matches('img') && visible(node)) {
          // Accessible descriptions can supply useful public image context,
          // but are not measured text from the image's visible pixels. A long
          // description must not suppress a needed visual check.
          append(node.getAttribute('alt') || '', node, primary, false);
        } else if (node.nodeType === Node.TEXT_NODE && visible(node.parentElement)) {
          append(node.textContent, node.parentElement, primary);
        }
      }
    }
    if (document.body) {
      for (const root of roots) appendText(root, false, true);
      appendText(document.body, true, roots.length === 0);
    }
    const ordered = selector => [...new Set([...roots.flatMap(root => [...root.querySelectorAll(selector)]), ...document.querySelectorAll(selector)])];
    const visuals = ordered(VISUAL); let substantialVisuals = 0, dominantVisual = false;
    if (visuals.length > 256) truncated = true;
    for (const element of visuals.slice(0, 256)) {
      if (element.closest(PRIVATE_REGION) || !displayed(element)) continue;
      const rect = element.getBoundingClientRect();
      const width = Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left));
      const height = Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top));
      if (width < 96 || height < 64) continue;
      observedVisuals.add(element);
      substantialVisuals = Math.min(16, substantialVisuals + 1);
      if (width * height >= innerWidth * innerHeight * 0.25) dominantVisual = true;
    }
    const primaryCharacters = C.cleanText(primaryParts.join(' '), bodyLimit).length;
    const visibleCharacters = C.cleanText(visibleParts.join(' '), bodyLimit).length;
    const evidence = { version: 1, primary_text_characters: primaryCharacters, visible_text_characters: visibleCharacters,
      substantial_visuals: substantialVisuals,
      requires_visual: primaryCharacters < 40 || substantialVisuals > 0 && (primaryCharacters < 240 || dominantVisual && primaryCharacters < 1200),
      truncated, visual_revision: visualEdits };
    const anchors = ordered('a[href]').filter(a => visible(a) && C.url(a.href)).slice(0, 12);
    const perLink = Math.floor((linkLimit - Math.max(0, anchors.length - 1)) / Math.max(1, anchors.length));
    const labelLimit = Math.min(80, Math.floor(perLink * 0.3));
    const links = anchors.map(a => C.cleanText(actionLabel(a), labelLimit) + ' → ' + snapshotDestination(a.href, perLink - labelLimit - 3));
    const forms = ordered('form').filter(visibleForm).slice(0, 3).map(form => {
      const fields = [...form.querySelectorAll('input,textarea,select')].slice(0, 20).map(field => field.type || field.tagName.toLowerCase()).filter(type => type !== 'hidden');
      return 'Form destination: ' + snapshotDestination(form.action || location.href, 150) + '; method: ' + C.cleanText(form.method, 8) +
        '; field types: ' + C.cleanText([...new Set(fields)].join(', '), 80) + '; sensitive fields: ' + sensitive(form);
    });
    return { url: C.url(location.href), title: C.cleanText(document.title, 250),
      text: C.cleanText(parts.join('\n') + '\nVisible link destinations:\n' + C.cleanText(links.join('\n'), linkLimit) +
        '\nVisible forms:\n' + C.cleanText(forms.join('\n'), formLimit)), evidence };
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
    if (!value || !C.isPresentableWarning(value.result) || value.until <= Date.now()) { cache.delete(proof.key); return null; }
    // A framework can replace a link or form with an equivalent node. Match
    // its exact current intent again before using the already-checked finding.
    value.candidate = candidate; value.proof = { ...proof, action_fingerprint: value.proof.action_fingerprint };
    return value;
  }
  function reuseUntil(result) {
    const limit = Date.now() + C.ASSESSMENT_REUSE_MS;
    return result.risk_level !== 'high' && Number.isFinite(result.expires_at) ? Math.min(limit, result.expires_at) : limit;
  }
  function cancelWarnings() {
    for (const id of presentations) send({ type: 'cancel', assessment_id: id }).catch(() => {});
    presentations.clear();
  }
  async function warn(entry, clicked = false) {
    if (!active || document.visibilityState !== 'visible' || !C.isPresentableWarning(entry.result) || entry.until <= Date.now()) return;
    if (entry.presenting || (!clicked && entry.warned)) return;
    const caution = entry.result.risk_level === 'medium';
    if (caution && warnedCautions.get(entry.proof.key) > Date.now()) return;
    if (!stillCurrent(entry.candidate, entry.proof)) return;
    const stamp = generation; entry.presenting = true;
    try {
      const geometry = sourceGeometry(entry.candidate?.submitter || entry.candidate?.element);
      const response = await send({ type: caution ? 'present-warning' : 'present-block', assessment_id: entry.result.id,
        page: entry.proof.page, action: entry.proof.action, public_signature: entry.proof.public_signature,
        action_fingerprint: entry.proof.action_fingerprint,
        ...geometry });
      if (response?.ok === true) {
        if (stamp !== generation || !stillCurrent(entry.candidate, entry.proof)) {
          if (response.id) send({ type: 'cancel', assessment_id: response.id }).catch(() => {});
          return;
        }
        entry.warned = true;
        if (caution) {
          warnedCautions.set(entry.proof.key, Date.now() + C.ASSESSMENT_REUSE_MS);
          if (warnedCautions.size > 40) warnedCautions.delete(warnedCautions.keys().next().value);
        }
        confirmTarget(geometry.target);
        if (typeof response.id === 'string') presentations.add(response.id);
      }
    } catch { /* The original click remains untouched, or held only for known extreme risk. */ }
    finally { entry.presenting = false; }
  }
  function schedulePage(delay = 250) {
    if (!active || !usable()) return;
    const wait = Math.max(0, delay), at = Date.now() + wait;
    // A busy app's next DOM update must not keep postponing the first scan.
    // New evidence may advance a retry, but cannot defer an earlier deadline.
    if (pageTimer && pageScheduledAt <= at) return;
    clearTimeout(pageTimer); pageScheduledAt = at;
    pageTimer = setTimeout(() => { pageTimer = null; pageScheduledAt = 0; void scanPage(); }, wait);
  }
  async function assess(candidate, purpose) {
    if (!active || (candidate && !candidate.element.isConnected)) return null;
    const proof = material(candidate), existing = cache.get(proof.key);
    if (existing && C.isPresentableWarning(existing.result) && existing.until > Date.now()) { void warn(existing); return existing.result; }
    const reused = assessmentReuse.get(proof.key);
    if (reused && reused.until > Date.now() &&
        (reused.result.risk_level !== 'medium' || warnedCautions.get(proof.key) > Date.now())) return reused.result;
    assessmentReuse.delete(proof.key);
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
        if (C.isPresentableWarning(result)) {
          const entry = { result, proof, candidate, warned: false,
            until: Math.min(result.warning_expires_at ?? result.expires_at, Date.now() + C.EXTREME_TTL_MS) };
          cache.set(proof.key, entry); if (cache.size > 40) cache.delete(cache.keys().next().value);
          void warn(entry);
          if (result.risk_level === 'medium') assessmentReuse.set(proof.key, { result, until: reuseUntil(result) });
        } else {
          cache.delete(proof.key);
          if (result.ok === true && result.risk_level !== 'high') {
            assessmentReuse.set(proof.key, { result, until: reuseUntil(result) });
            if (assessmentReuse.size > 40) assessmentReuse.delete(assessmentReuse.keys().next().value);
          }
        }
        return result;
      } catch { return null; }
      finally { if (inflight.get(proof.key) === task) inflight.delete(proof.key); }
    });
    inflight.set(proof.key, task); return task;
  }
  function prefetchForms() {
    if (!active) return;
    for (const form of [...document.forms].filter(form => sensitive(form) && visibleForm(form)).slice(0, 2)) {
      const candidate = describeForm(form, defaultSubmitter(form)); if (candidate) void assess(candidate, 'proactive');
    }
  }
  async function scanPage() {
    if (!active || !usable()) return;
    const key = C.assessmentKey(snapshot()), fresh = cached(null);
    if (fresh) {
      void warn(fresh); prefetchForms(); return;
    }
    // Successful unchanged pages need no recurring inference. DOM/viewport,
    // activation and route events still watch every tab; failures retry below.
    if (key === lastSuccessfulPageKey && Date.now() < lastSuccessfulPageUntil) { prefetchForms(); return; }
    if (key === lastPageKey && Date.now() - lastPageAttempt < 5000) { schedulePage(5000); return; }
    lastPageKey = key; lastPageAttempt = Date.now();
    prefetchForms();
    const stamp = generation, result = await assess(null, 'proactive');
    if (!active || stamp !== generation) return;
    prefetchForms();
    retryFailures = result?.ok ? 0 : Math.min(4, retryFailures + 1);
    if (result?.ok) {
      lastSuccessfulPageKey = key; lastSuccessfulPageUntil = reuseUntil(result); lastSuccessfulPageRisk = result.risk_level;
      return;
    }
    const retryHint = Number.isFinite(result?.retry_after_ms) ? Math.min(60000, Math.max(0, result.retry_after_ms)) : 0;
    const delay = Math.max(retryHint, Math.min(60000, 5000 * (2 ** (retryFailures - 1))));
    schedulePage(delay);
  }
  function gate(event) {
    if (!active || cache.size === 0 || !event.isTrusted || event.defaultPrevented) return;
    if (![...cache.values()].some(entry => entry.until > Date.now() && C.isConfirmedExtreme(entry.result))) return;
    const candidate = candidateForEvent(event); if (!candidate) return;
    const entry = cached(candidate); if (!entry || !C.isConfirmedExtreme(entry.result)) return;
    // No await and no unknown-risk hold: only a fresh, exact, already-confirmed
    // extreme finding can synchronously stop this browser action.
    event.preventDefault(); event.stopImmediatePropagation(); void warn(entry, true);
  }
  // Secret detection runs before the ordinary form gate; its synchronous
  // listener can stop insertion/submission before any page listener receives it.
  listen(window, 'paste', event => secretGuard.paste(event), true);
  listen(window, 'submit', event => secretGuard.submit(event), true);
  for (const type of ['pointermove', 'mousemove', 'pointerdown', 'mousedown', 'click', 'auxclick'])
    listen(window, type, event => T.observeEvent(event, window), { capture: true, passive: true });
  for (const type of ['click', 'auxclick', 'submit']) listen(window, type, gate, true);
  function intent(event) {
    if (!active || !event.isTrusted || document.visibilityState !== 'visible') return;
    const element = event.composedPath().find(value => value instanceof Element);
    const candidate = candidateForElement(element); if (!candidate) return;
    clearTimeout(hoverTimer);
    if (event.type === 'touchstart' || event.type === 'pointerdown' ||
        event.type === 'focusin' && candidate.kind === 'submit' && candidate.sensitive ||
        (event.type === 'keydown' && event.key === 'Enter')) void assess(candidate, 'intent');
    else hoverTimer = setTimeout(() => {
      if (active) void assess(candidate, candidate.kind === 'submit' && candidate.sensitive && event.type !== 'focusin' ? 'proactive' : 'intent');
    }, 200);
  }
  for (const type of ['pointerover', 'mouseover', 'focusin', 'pointerdown', 'touchstart']) listen(window, type, intent, { capture: true, passive: true });
  for (const type of ['pointerout', 'mouseout', 'focusout']) listen(window, type, () => clearTimeout(hoverTimer), { capture: true, passive: true });
  listen(window, 'keydown', event => { if (event.key === 'Enter') intent(event); }, true);
  for (const type of ['input', 'change']) listen(window, type, () => { invalidateGeometry(); if (active) schedulePage(1200); }, true);
  for (const type of ['scroll', 'resize']) listen(window, type, () => { invalidateGeometry(); if (active) schedulePage(400); }, { capture: true, passive: true });
  if (window.visualViewport) for (const type of ['scroll', 'resize'])
    listen(window.visualViewport, type, () => invalidateGeometry(), { passive: true });
  function resetAutomatic() {
    invalidateGeometry();
    generation++; clearTimeout(pageTimer); clearTimeout(hoverTimer); clearTimeout(mutationTimer);
    pageTimer = null; pageScheduledAt = 0; mutationTimer = null;
    cache.clear(); assessmentReuse.clear(); inflight.clear(); localProofs.clear(); warnedCautions.clear(); lastPageKey = ''; lastPageAttempt = 0;
    lastSuccessfulPageKey = ''; lastSuccessfulPageUntil = 0; lastSuccessfulPageRisk = null; retryFailures = 0; cancelWarnings();
  }
  function routeChanged() {
    if (!active || lastURL === location.href) return;
    lastURL = location.href; resetAutomatic(); schedulePage(100);
  }
  function activate() {
    if (!active) return; routeChanged(); const fresh = cached(null);
    if (fresh) void warn(fresh);
    else if (lastSuccessfulPageRisk === 'high') lastSuccessfulPageUntil = 0;
    else if (lastSuccessfulPageRisk === 'medium') {
      const proof = material(null);
      if (!(warnedCautions.get(proof.key) > Date.now())) {
        lastSuccessfulPageUntil = 0; assessmentReuse.delete(proof.key);
      }
    }
    schedulePage(100); prefetchForms();
  }
  async function refresh() {
    const sequence = ++configurationSequence, stamp = generation;
    try {
      const value = await send({ type: 'configuration' });
      if (sequence !== configurationSequence) return;
      const next = value.supported !== false && value.enabled !== false && value.paused !== true && (value.active ?? value.approved) === true;
      const changed = next !== active; active = next; clearTimeout(resumeTimer);
      nativeAvailableUntil = active && Number.isFinite(value.native_available_until) ? Math.min(value.native_available_until, Date.now() + 4500) : 0;
      if (!active) { resetAutomatic(); if (Number.isFinite(value.pauseUntil) && value.pauseUntil > Date.now()) resumeTimer = setTimeout(refresh, value.pauseUntil - Date.now() + 50); }
      else if (changed || stamp === generation) { lastURL = location.href; schedulePage(100); prefetchForms(); }
    } catch { if (sequence === configurationSequence) { active = false; nativeAvailableUntil = 0; resetAutomatic(); } }
  }
  function substantialVisual(element) {
    if (!element?.matches(VISUAL) || element.closest(PRIVATE_REGION) || !displayed(element)) return false;
    const rect = element.getBoundingClientRect();
    return Math.min(innerWidth, rect.right) - Math.max(0, rect.left) >= 96 &&
      Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top) >= 64;
  }
  function sourceVisual(element) {
    if (!(element instanceof Element)) return null;
    if (element.matches(VISUAL)) return element;
    if (element.matches('source')) return element.closest('picture')?.querySelector('img') || element.closest('video');
    return null;
  }
  function changedVisualNode(node) {
    if (!(node instanceof Element)) return false;
    if (substantialVisual(node) || observedVisuals.has(node)) return true;
    return [...node.querySelectorAll(VISUAL)].slice(0, 16).some(element => substantialVisual(element) || observedVisuals.has(element));
  }
  function visualEvidenceChanged() {
    const remaining = pageTimer ? Math.max(0, pageScheduledAt - Date.now()) : 150;
    visualEdits = (visualEdits + 1) % 2147483648;
    // Image identity/pixels can change without changing text. End the old
    // evidence episode and give the worker a fresh opaque visual revision.
    // Never read pixels, fetch a source URL or send image URLs to the bridge.
    resetAutomatic(); schedulePage(Math.min(150, remaining));
  }
  for (const type of ['load', 'loadedmetadata', 'loadeddata']) listen(window, type, event => {
    if (active && event.isTrusted && substantialVisual(sourceVisual(event.target))) visualEvidenceChanged();
  }, true);
  function mutations(records) {
    if (!active) return;
    const visualChanged = records.some(record => {
      if (record.type === 'attributes' && ['src', 'srcset', 'sizes', 'alt', 'poster', 'width', 'height'].includes(record.attributeName)) {
        return substantialVisual(sourceVisual(record.target));
      }
      return record.type === 'childList' && [...record.addedNodes, ...record.removedNodes].slice(0, 64).some(changedVisualNode);
    });
    if (visualChanged) { visualEvidenceChanged(); return; }
    const meaningful = records.some(record => {
      if (record.type === 'attributes' && ['type', 'autocomplete', 'action', 'formaction', 'method', 'formmethod', 'target'].includes(record.attributeName)) return true;
      const element = record.target instanceof Element ? record.target : record.target.parentElement;
      return element && !element.closest(PRIVATE);
    });
    if (!meaningful) return;
    invalidateGeometry();
    cancelWarnings();
    // Batch a short burst once. Continual animation/classes elsewhere in a
    // SPA must not starve the scan of a newly opened message.
    if (!mutationTimer) mutationTimer = setTimeout(() => {
      mutationTimer = null; routeChanged(); schedulePage(1000); prefetchForms();
    }, 150);
  }
  observer = new MutationObserver(records => { if (usable()) mutations(records); });
  observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: ['href', 'action', 'formaction', 'method', 'formmethod', 'target', 'type', 'autocomplete', 'hidden', 'aria-hidden', 'class', 'style',
      'src', 'srcset', 'sizes', 'alt', 'poster', 'width', 'height'] });
  listen(window, 'popstate', routeChanged); listen(window, 'hashchange', routeChanged);
  listen(document, 'visibilitychange', () => { invalidateGeometry(); if (document.visibilityState === 'visible') activate(); });
  // Muse's nonactivating overlay can briefly take key-window focus without
  // changing the page viewport. Tab visibility and measured geometry still
  // invalidate precision; native independently verifies the foreground app.
  listen(window, 'focus', activate);
  listen(document, 'DOMContentLoaded', activate, { once: true });
  listen(window, 'pagehide', () => { nativeAvailableUntil = 0; resetAutomatic(); clearTimeout(resumeTimer); }, true);
  // A back/forward-cache restore keeps this content instance alive, but global
  // protection may have been paused while the page was frozen.
  listen(window, 'pageshow', event => { if (event.persisted) void refresh(); else activate(); });
  routeTimer = setInterval(() => { if (usable() && active) routeChanged(); }, 1000);
  runtimeMessage = (message, sender, reply) => {
    if (!usable() || sender.id !== extensionID) { reply({ ok: false }); return; }
    if (message.type === 'monitor-ready') { reply({ ready: true }); return; }
    if (message.type === 'native-availability') {
      nativeAvailableUntil = active && Number.isFinite(message.available_until) ? Math.min(message.available_until, Date.now() + 4500) : 0;
      reply({ ok: true }); return;
    }
    if (message.type === 'target-state') { reply({ nonce, revision: edits }); return; }
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
    if (message.type === 'snapshot') { reply({ nonce, revision: edits, page: snapshot() }); return; }
    if (message.type === 'configuration-changed') {
      // A fast Pause/Resume can make both settings reads report active. The
      // notification itself invalidates every pre-pause local finding.
      active = false; resetAutomatic(); clearTimeout(resumeTimer);
      refresh().then(() => reply({ ok: true })); return true;
    }
    reply({ ok: false });
  };
  runtime.onMessage.addListener(runtimeMessage);
  refresh();
})();
