(function (root) {
  'use strict';
  const STORE = 'museDownloadHoldsV1';
  const MAX_JOBS = 64;
  function safeURL(value) {
    if (typeof value !== 'string' || value.length > 8192) return undefined;
    try {
      if (value.startsWith('blob:')) {
        const origin = new URL(value.slice(5));
        return ['http:', 'https:'].includes(origin.protocol) ? origin.origin + '/' : undefined;
      }
      const url = new URL(value);
      if (!['http:', 'https:'].includes(url.protocol)) return undefined;
      url.username = ''; url.password = ''; url.search = ''; url.hash = '';
      return url.href;
    } catch { return undefined; }
  }
  function text(value, limit) { return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, limit) : undefined; }
  function metadata(item, phase, holdID, ownedPause = false) {
    const filename = typeof item.filename === 'string' ? item.filename : undefined;
    return { download_id: item.id, phase, hold_id: holdID, owned_pause: ownedPause,
      url: safeURL(item.url), final_url: safeURL(item.finalUrl),
      filename: phase === 'complete' ? text(filename, 4096) : text(filename?.split(/[\\/]/).pop(), 512),
      mime: text(item.mime, 128), state: item.state,
      danger: text(item.danger, 64),
      file_size: Number.isSafeInteger(item.fileSize) && item.fileSize >= 0 ? item.fileSize : undefined,
      total_bytes: Number.isSafeInteger(item.totalBytes) && item.totalBytes >= 0 ? item.totalBytes : undefined };
  }
  function isHigh(value) { return value?.ok === true && value?.risk_level === 'high' && value?.decision === 'block'; }
  function create({ chrome, nativeRequest, isEnabled = async () => true, onResult = () => {},
    now = () => Date.now(), uuid = () => crypto.randomUUID(), schedule = setTimeout, clearScheduled = clearTimeout }) {
    const jobs = new Map();
    let paused = false, started = false, generation = 0, storageTail = Promise.resolve();
    const api = chrome?.downloads;
    const available = !!api && ['search', 'pause', 'resume', 'cancel', 'show'].every(name => typeof api[name] === 'function') &&
      ['onCreated', 'onChanged'].every(name => typeof api[name]?.addListener === 'function' && typeof api[name]?.removeListener === 'function');
    const storage = chrome?.storage?.session;
    async function enabled() { return started && !paused && await isEnabled(); }
    function persist() {
      if (!storage?.set) return Promise.resolve();
      const records = [...jobs.values()].filter(job => job.ownedPause || job.needsComplete)
        .slice(-MAX_JOBS).map(job => ({ download_id: job.id, hold_id: job.holdID, owned_pause: job.ownedPause,
          needs_complete: job.needsComplete, created: job.created }));
      const result = storageTail.then(() => storage.set({ [STORE]: records }), () => storage.set({ [STORE]: records }));
      storageTail = result.catch(() => {}); return storageTail;
    }
    function jobFor(item) {
      let job = jobs.get(item.id);
      if (!job) {
        while (jobs.size >= MAX_JOBS) {
          const old = [...jobs.values()].find(value => !value.ownedPause && !value.running);
          if (!old) return null;
          if (old.retryTimer !== null) clearScheduled(old.retryTimer);
          jobs.delete(old.id);
        }
        job = { id: item.id, holdID: uuid(), created: now(), ownedPause: false, pendingPause: false,
          resuming: false, running: null, metadataDone: false, needsComplete: false, completeKey: null,
          controller: null, held: false, retryCount: 0, retryTimer: null, item };
        jobs.set(item.id, job);
      }
      job.item = item;
      return job;
    }
    async function current(id) { return (await api.search({ id }))[0] || null; }
    async function release(job) {
      if (!job.ownedPause) return false;
      const item = await current(job.id);
      if (!item || item.state !== 'in_progress' || !item.paused) { job.ownedPause = false; job.held = false; await persist(); return false; }
      // Chrome's own danger UI must remain authoritative. Never acceptDanger.
      if (!['safe', 'accepted', 'deepScannedSafe', undefined].includes(item.danger)) return false;
      job.resuming = true;
      try { await api.resume(job.id); job.ownedPause = false; job.held = false; await persist(); return true; }
      finally { job.resuming = false; }
    }
    async function inspect(job, phase, stamp) {
      const item = await current(job.id);
      if (!item || !await enabled() || stamp !== generation) return null;
      job.item = item;
      const controller = new AbortController(); job.controller = controller;
      let result;
      try {
        result = await nativeRequest({ type: 'download-inspect', mode: 'text', download: metadata(item, phase, job.holdID, job.ownedPause) },
          phase === 'complete' ? 75000 : 8000, null, controller.signal);
      } catch (error) { result = { ok: false, risk_level: 'unknown', decision: 'review', error: String(error?.message || error) }; }
      finally { if (job.controller === controller) job.controller = null; }
      if (stamp !== generation || controller.signal.aborted || !await enabled()) return null;
      const latest = await current(job.id);
      if (!latest || latest.id !== item.id || latest.state === 'interrupted') return null;
      if (phase === 'complete' && (latest.state !== 'complete' || latest.filename !== item.filename || latest.fileSize !== item.fileSize)) return null;
      try { await onResult(latest, result); } catch { /* presentation failure never grants file safety */ }
      return result;
    }
    async function process(job) {
      if (job.running) return job.running;
      const stamp = generation;
      const task = (async () => {
        let item = await current(job.id);
        if (!item || !await enabled() || stamp !== generation) return;
        if (item.state === 'in_progress' && !job.metadataDone) {
          if (!item.paused && ['safe', 'accepted', 'deepScannedSafe', undefined].includes(item.danger)) {
            job.pendingPause = true;
            try { await api.pause(job.id); job.ownedPause = true; await persist(); }
            catch { /* A small download may already have completed. */ }
            finally { job.pendingPause = false; }
          }
          if (stamp !== generation || !await enabled()) { try { await release(job); } catch {} return; }
          const result = await inspect(job, 'metadata', stamp);
          if (stamp !== generation) return;
          job.metadataDone = true;
          if (isHigh(result)) { job.held = true; await persist(); }
          else {
            // A disconnected app cannot leave ordinary transfers silently held.
            // This resumes transfer only; it does not mark the file scanned.
            try { await release(job); } catch { /* user/Chrome pause remains visible in Downloads */ }
          }
        }
        item = await current(job.id);
        if (!item || !await enabled() || stamp !== generation) return;
        if (item.state === 'complete' && item.exists !== false && item.filename) {
          const key = JSON.stringify([item.filename, item.fileSize, item.endTime]);
          if (job.completeKey === key) return;
          job.needsComplete = true; await persist();
          const result = await inspect(job, 'complete', stamp);
          if (stamp !== generation) return;
          const retryable = result?.ok !== true || ['error', 'unavailable'].includes(result?.download_inspection?.scan_status);
          if (!retryable) { job.completeKey = key; job.needsComplete = false; job.retryCount = 0; }
          await persist();
          if (retryable && job.retryCount < 2 && started && !paused) {
            job.retryCount += 1;
            if (job.retryTimer !== null) clearScheduled(job.retryTimer);
            job.retryTimer = schedule(() => { job.retryTimer = null; void process(job).catch(() => {}); }, job.retryCount * 15000);
          }
        }
      })();
      job.running = task;
      try { await task; }
      finally {
        if (job.running === task) job.running = null;
        // Completion can arrive while metadata is being checked. Re-read the
        // item once after this task, rather than lose the completion event.
        if (started && !paused) {
          const latest = await current(job.id).catch(() => null);
          if (latest?.state === 'in_progress' && !job.metadataDone) void process(job).catch(() => {});
          else if (latest?.state === 'complete' && latest.exists !== false && latest.filename &&
              job.completeKey !== JSON.stringify([latest.filename, latest.fileSize, latest.endTime]) && !job.needsComplete)
            void process(job).catch(() => {});
        }
      }
    }
    async function created(item) {
      if (!Number.isInteger(item?.id) || item.id < 0 || !await enabled()) return;
      const job = jobFor(item); if (job) await process(job);
    }
    async function changed(delta) {
      if (!Number.isInteger(delta?.id)) return;
      const job = jobs.get(delta.id);
      if (job && delta.paused?.current === false && !job.resuming && !job.pendingPause) {
        job.ownedPause = false; job.held = false; await persist();
      }
      if (job && ['danger', 'filename', 'fileSize', 'finalUrl', 'url', 'mime'].some(key => delta[key])) { job.metadataDone = false; job.completeKey = null; }
      const item = await current(delta.id).catch(() => null);
      if (!item) return;
      // Chrome can deliver a tiny download's terminal change after worker
      // startup without this worker having observed its onCreated event.
      if (job || item.state === 'in_progress' || (item.state === 'complete' && delta.state?.current === 'complete')) await created(item);
    }
    const onCreated = item => { void created(item).catch(() => {}); };
    const onChanged = delta => { void changed(delta).catch(() => {}); };
    const onErased = id => { const job = jobs.get(id); job?.controller?.abort(); if (job?.retryTimer != null) clearScheduled(job.retryTimer); jobs.delete(id); void persist(); };
    async function hydrate() {
      if (!available || !started) return;
      let records = [];
      try { records = (await storage?.get?.({ [STORE]: [] }))?.[STORE] || []; } catch {}
      for (const value of records.slice(-MAX_JOBS)) {
        if (!Number.isInteger(value.download_id) || typeof value.hold_id !== 'string' || value.hold_id.length > 128) continue;
        const item = await current(value.download_id).catch(() => null);
        if (!item) continue;
        const job = jobFor(item); if (!job) continue;
        job.holdID = value.hold_id; job.ownedPause = value.owned_pause === true && item.paused === true;
        job.needsComplete = value.needs_complete === true;
      }
      const active = await api.search({ state: 'in_progress' });
      // Recover only a bounded recent window, rather than silently missing a
      // file that finished while protection or the worker was initializing.
      const recent = await api.search({ state: 'complete', endedAfter: new Date(now() - 60000).toISOString(),
        orderBy: ['-endTime'], limit: MAX_JOBS });
      const candidates = [...active, ...recent.filter(item => item.exists !== false).slice(0, MAX_JOBS),
        ...[...jobs.values()].filter(job => job.needsComplete).map(job => job.item)];
      const unique = new Map(candidates.map(item => [item.id, item]));
      await Promise.allSettled([...unique.values()].map(item => created(item)));
    }
    async function setPaused(value) {
      if (paused === !!value) return;
      paused = !!value; generation += 1;
      for (const job of jobs.values()) {
        job.controller?.abort(); job.controller = null;
        if (job.retryTimer !== null) clearScheduled(job.retryTimer);
        job.retryTimer = null;
      }
      if (paused) await Promise.allSettled([...jobs.values()].filter(job => job.ownedPause).map(job => release(job)));
      else {
        for (const job of jobs.values()) { job.metadataDone = false; job.retryCount = 0; }
        void hydrate().catch(() => {});
      }
    }
    async function handleCommand(command) {
      const job = jobs.get(command?.download_id);
      if (!job || command?.hold_id !== job.holdID || !['resume', 'cancel', 'show'].includes(command?.action)) return { ok: false, error: 'stale_download_command' };
      const item = await current(job.id);
      if (!item) return { ok: false, error: 'download_missing' };
      if (command.action === 'show') {
        if (item.state !== 'complete' || item.exists === false) return { ok: false, error: 'download_not_complete' };
        await api.show(job.id); return { ok: true };
      }
      if (command.action === 'cancel') {
        if (item.state !== 'in_progress') return { ok: false, error: 'download_not_active' };
        job.controller?.abort(); await api.cancel(job.id); job.ownedPause = false; job.held = false; await persist(); return { ok: true };
      }
      if (!job.ownedPause || !job.held || item.state !== 'in_progress') return { ok: false, error: 'download_not_held_by_muse' };
      return { ok: await release(job) };
    }
    async function start() {
      if (started || !available) return;
      started = true; api.onCreated.addListener(onCreated); api.onChanged.addListener(onChanged); api.onErased?.addListener(onErased);
      void hydrate().catch(() => {});
    }
    async function stop() {
      if (!started) return;
      await setPaused(true); started = false;
      api.onCreated.removeListener(onCreated); api.onChanged.removeListener(onChanged); api.onErased?.removeListener(onErased);
    }
    return { start, stop, hydrate, setPaused, handleCommand,
      status: () => ({ available, started, paused,
        processing: [...jobs.values()].filter(job => job.running !== null).length,
        pending: [...jobs.values()].filter(job => job.held || job.needsComplete).length }),
      pending: () => [...jobs.values()].filter(job => job.held).map(job => ({ download_id: job.id, hold_id: job.holdID, owned_pause: job.ownedPause })) };
  }
  root.MuseGuardDownloads = { create, safeURL, metadata };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.MuseGuardDownloads;
})(typeof globalThis !== 'undefined' ? globalThis : this);
