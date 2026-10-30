(function (root) {
  'use strict';
  // Geometry stays outside model prompts. An element is measured again when
  // its finding is presented; no selector, field value or page text is sent.
  const MAX_AGE_MS = 2500, POINTER_MAX_AGE_MS = 12000;
  const pointers = new WeakMap();
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  const number = (value, low, high) => finite(value) && value >= low && value <= high;
  const identity = value => typeof value === 'string' && /^[a-z0-9-]{1,256}$/i.test(value);
  const clock = view => (view?.Date || Date).now();
  const close = (a, b, tolerance) => finite(a) && finite(b) && Math.abs(a - b) <= tolerance;
  function viewport(view) {
    const visual = view.visualViewport;
    const value = { width: view.innerWidth, height: view.innerHeight,
      scroll_x: view.scrollX || 0, scroll_y: view.scrollY || 0,
      device_pixel_ratio: view.devicePixelRatio || 1,
      visual_scale: visual?.scale ?? 1, offset_x: visual?.offsetLeft ?? 0, offset_y: visual?.offsetTop ?? 0 };
    return validViewport(value) ? value : null;
  }
  function validViewport(value) {
    return value && number(value.width, 1, 100000) && number(value.height, 1, 100000) &&
      number(value.scroll_x, -10000000, 10000000) && number(value.scroll_y, -10000000, 10000000) &&
      number(value.device_pixel_ratio, 0.1, 32) && close(value.visual_scale, 1, 0.001) &&
      close(value.offset_x, 0, 0.001) && close(value.offset_y, 0, 0.001);
  }
  function geometryKey(view) {
    const v = viewport(view);
    return v && JSON.stringify([view.screenX, view.screenY, view.outerWidth, view.outerHeight,
      v.width, v.height, v.device_pixel_ratio, v.visual_scale, v.offset_x, v.offset_y]);
  }
  function observeEvent(event, view = event?.view || root.window) {
    if (!view || event?.isTrusted !== true || !/^(pointer|mouse|click|auxclick)/.test(event.type || '')) return false;
    const v = viewport(view), key = geometryKey(view);
    if (!v || !key || !number(event.clientX, 0, v.width) || !number(event.clientY, 0, v.height) ||
        !number(event.screenX, -100000, 100000) || !number(event.screenY, -100000, 100000)) return false;
    pointers.set(view, { key, value: { client_x: event.clientX, client_y: event.clientY,
      screen_x: event.screenX, screen_y: event.screenY, captured_at: clock(view) } });
    return true;
  }
  function displayed(element, view) {
    let node = element, depth = 0;
    while (node && depth++ < 64) {
      if (node.hidden || node.getAttribute?.('aria-hidden') === 'true') return false;
      const style = view.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity || 1) === 0) return false;
      node = node.parentElement || node.getRootNode?.().host;
    }
    return depth < 64;
  }
  function capture(element, metadata = {}) {
    const view = element?.ownerDocument?.defaultView;
    if (!view || view.top !== view || !element.isConnected || !identity(metadata.documentID) ||
        !Number.isSafeInteger(metadata.revision) || metadata.revision < 0 || !displayed(element, view)) return null;
    const v = viewport(view);
    if (!v) return null; // Pinch zoom has a separate visual coordinate space.
    const box = element.getBoundingClientRect();
    if (![box.left, box.top, box.right, box.bottom, box.width, box.height].every(finite) || box.width <= 0 || box.height <= 0) return null;
    const left = Math.max(0, box.left), top = Math.max(0, box.top);
    const right = Math.min(v.width, box.right), bottom = Math.min(v.height, box.bottom);
    if (right - left < 1 || bottom - top < 1) return null;
    const result = { version: 1, document_id: metadata.documentID, revision: metadata.revision,
      measured_at: clock(view), rect: { x: left, y: top, width: right - left, height: bottom - top }, viewport: v };
    const pointer = pointers.get(view);
    if (pointer && pointer.key === geometryKey(view) && result.measured_at - pointer.value.captured_at <= POINTER_MAX_AGE_MS)
      result.pointer = { ...pointer.value };
    return result;
  }
  function validMeasurement(value, now = Date.now()) {
    const r = value?.rect, v = value?.viewport;
    return value?.version === 1 && identity(value.document_id) && Number.isSafeInteger(value.revision) && value.revision >= 0 &&
      number(value.measured_at, now - MAX_AGE_MS, now + 250) && validViewport(v) && r &&
      number(r.x, 0, v.width) && number(r.y, 0, v.height) && number(r.width, 1, v.width) && number(r.height, 1, v.height) &&
      r.x + r.width <= v.width + 0.01 && r.y + r.height <= v.height + 0.01;
  }
  function same(first, latest) {
    if (!first || !latest || first.document_id !== latest.document_id || first.revision !== latest.revision) return false;
    return ['x', 'y', 'width', 'height'].every(key => close(first.rect?.[key], latest.rect?.[key], 0.5)) &&
      ['width', 'height', 'scroll_x', 'scroll_y'].every(key => close(first.viewport?.[key], latest.viewport?.[key], 0.25)) &&
      ['device_pixel_ratio', 'visual_scale', 'offset_x', 'offset_y'].every(key => close(first.viewport?.[key], latest.viewport?.[key], 0.001));
  }
  function revalidate(element, original, metadata) {
    return validMeasurement(original, clock(element?.ownerDocument?.defaultView)) && same(original, capture(element, metadata));
  }
  // The service worker supplies these fields from tabs.getZoom/windows.get,
  // never from a content-script claim about the browser's outer rectangle.
  function bind(value, trusted, expected, now = Date.now()) {
    if (!validMeasurement(value, now) || value.document_id !== expected?.documentID || value.revision !== expected?.revision ||
        !Number.isSafeInteger(trusted?.tabID) || trusted.tabID <= 0 || !Number.isSafeInteger(trusted?.windowID) || trusted.windowID <= 0 ||
        trusted.window?.id !== trusted.windowID || !number(trusted.zoom, 0.25, 5)) return null;
    const w = trusted.window;
    if (!number(w.left, -100000, 100000) || !number(w.top, -100000, 100000) ||
        !number(w.width, 100, 100000) || !number(w.height, 100, 100000)) return null;
    const result = { version: 1, document_id: value.document_id, revision: value.revision, measured_at: value.measured_at,
      rect: { x: value.rect.x, y: value.rect.y, width: value.rect.width, height: value.rect.height },
      viewport: { width: value.viewport.width, height: value.viewport.height,
        scroll_x: value.viewport.scroll_x, scroll_y: value.viewport.scroll_y,
        device_pixel_ratio: value.viewport.device_pixel_ratio, visual_scale: value.viewport.visual_scale,
        offset_x: value.viewport.offset_x, offset_y: value.viewport.offset_y }, browser_window: { id: trusted.windowID, tab_id: trusted.tabID,
        left: w.left, top: w.top, width: w.width, height: w.height, zoom: trusted.zoom } };
    const p = value.pointer;
    if (p && number(p.client_x, 0, value.viewport.width) && number(p.client_y, 0, value.viewport.height) &&
        number(p.screen_x, -100000, 100000) && number(p.screen_y, -100000, 100000) &&
        number(p.captured_at, now - POINTER_MAX_AGE_MS, now + 250)) {
      result.pointer = { client_x: p.client_x, client_y: p.client_y, screen_x: p.screen_x, screen_y: p.screen_y, captured_at: p.captured_at };
    }
    return result;
  }
  const api = { capture, observeEvent, revalidate, same, validMeasurement, bind,
    invalidate(view) { if (view) pointers.delete(view); }, MAX_AGE_MS, POINTER_MAX_AGE_MS };
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.MuseGuardTargets = api;
})(typeof globalThis === 'object' ? globalThis : this);
