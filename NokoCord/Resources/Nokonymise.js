/* Maomao's bundled Nokonymise provider. No native content bridge or network
   service. Files are immutable local copies, processed in a short-lived worker. */
(() => {
  'use strict';
  if (location.origin !== 'https://discord.com' || globalThis !== top) return;
  if (globalThis.__nokoNokonymise) return;
  const workerSource = /* NOKONYMise_WORKER_SOURCE */;
  const tracking = new Set(['fbclid', 'gclid', 'dclid', 'msclkid', 'gbraid', 'wbraid',
    'twclid', 'ttclid', 'igshid', 'mc_cid', 'mc_eid', '_ga', '_gl']);
  const signed = /^(?:sig|signature|hmac|hm|policy|key-pair-id|token|access_token|auth|auth_key|x-amz-.+|x-goog-.+)$/i;
  let active = false, worker = null, workerURL = null, serial = 0, pendingBytes = 0;
  let processed = new WeakMap(), prepared = new WeakSet();
  const jobs = new Map(), replayed = new WeakSet(), restorers = [];
  const pickerInputs = new Set();
  let pickers = new WeakMap();
  const allowed = () => active && location.origin === 'https://discord.com' &&
    (location.pathname === '/app' || location.pathname.startsWith('/channels/'));

  function cleanURL(raw) {
    try {
      if (!/^https?:\/\/[^/]/i.test(raw) || /%(?![a-f\d]{2})/i.test(raw) || /[\\\u0000-\u0020]/.test(raw)) return raw;
      const url = new URL(raw);
      if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) return raw;
      const hash = raw.indexOf('#'), end = hash < 0 ? raw.length : hash;
      const query = raw.indexOf('?');
      if (query < 0 || query > end) return raw;
      const parts = raw.slice(query + 1, end).split('&');
      const keys = parts.map(part => decodeURIComponent(part.split('=', 1)[0].replace(/\+/g, ' ')).toLowerCase());
      if (keys.some(key => signed.test(key))) return raw;
      const kept = parts.filter((_, index) => !keys[index].startsWith('utm_') && !tracking.has(keys[index]));
      if (kept.length === parts.length) return raw;
      return raw.slice(0, query) + (kept.length ? '?' + kept.join('&') : '') + raw.slice(end);
    } catch { return raw; }
  }
  function cleanText(text) {
    if (typeof text !== 'string' || !/https?:\/\//i.test(text)) return text;
    // Matched code spans/fences are copied verbatim. An unmatched backtick is
    // ambiguous, so leave the remaining text alone rather than editing code.
    let result = '', cursor = 0;
    while (cursor < text.length) {
      const tick = text.indexOf('`', cursor);
      const end = tick < 0 ? text.length : tick;
      result += text.slice(cursor, end).replace(/https?:\/\/[^\s<>"'`]+/gi, (match, offset, segment) => {
        const before = segment[offset - 1];
        if (before && /[\w/@\\]/.test(before)) return match;
        let candidate = match, suffix = '';
        while (/[.,!;:]$/.test(candidate)) { suffix = candidate.slice(-1) + suffix; candidate = candidate.slice(0, -1); }
        for (const [open, close] of [['(', ')'], ['[', ']'], ['{', '}']]) {
          while (candidate.endsWith(close) && candidate.split(close).length > candidate.split(open).length) {
            suffix = close + suffix; candidate = candidate.slice(0, -1);
          }
        }
        return cleanURL(candidate) + suffix;
      });
      if (tick < 0) break;
      let count = 1;
      while (text[tick + count] === '`') count++;
      const delimiter = '`'.repeat(count), close = text.indexOf(delimiter, tick + count);
      if (close < 0) { result += text.slice(tick); break; }
      result += text.slice(tick, close + count); cursor = close + count;
    }
    return result;
  }
  function messageRoute(method, raw) {
    try {
      const url = new URL(raw, location.href);
      if (url.origin !== 'https://discord.com') return false;
      const path = url.pathname.replace(/^\/api\/v\d+/, '');
      return (method === 'POST' && /^\/channels\/\d+\/(messages|threads)$/.test(path)) ||
        (method === 'PATCH' && /^\/channels\/\d+\/messages\/\d+$/.test(path));
    } catch { return false; }
  }
  function cleanJSON(body) {
    if (typeof body !== 'string' || body.length > 2 * 1024 * 1024) return body;
    try {
      const value = JSON.parse(body);
      if (!value || Array.isArray(value) || typeof value !== 'object') return body;
      const target = typeof value.content === 'string' ? value : value.message;
      if (!target || typeof target.content !== 'string') return body;
      const cleaned = cleanText(target.content);
      if (cleaned === target.content) return body;
      target.content = cleaned;
      return JSON.stringify(value);
    } catch { return body; }
  }
  function cleanBody(body) {
    if (!(body instanceof FormData)) return cleanJSON(body);
    const payload = body.get('payload_json'), cleaned = cleanJSON(payload);
    if (cleaned === payload) return body;
    const copy = new FormData();
    for (const [key, value] of body) copy.append(key, key === 'payload_json' ? cleaned : value);
    return copy;
  }
  function patch(object, key, wrap) {
    const original = object[key], replacement = wrap(original);
    object[key] = replacement;
    restorers.push(() => { if (object[key] === replacement) object[key] = original; });
  }
  function installMessages() {
    const requests = new WeakMap();
    patch(XMLHttpRequest.prototype, 'open', original => function(method, url, ...rest) {
      requests.set(this, {method: String(method).toUpperCase(), url: String(url)});
      return Reflect.apply(original, this, [method, url, ...rest]);
    });
    patch(XMLHttpRequest.prototype, 'send', original => function(body) {
      const request = requests.get(this);
      const cleaned = allowed() && request && messageRoute(request.method, request.url) ? cleanBody(body) : body;
      return Reflect.apply(original, this, [cleaned]);
    });
    patch(globalThis, 'fetch', original => function(input, init) {
      const request = input instanceof Request ? input : null;
      const method = String(init?.method || request?.method || 'GET').toUpperCase();
      if (!allowed() || !messageRoute(method, request?.url || input)) return Reflect.apply(original, this, [input, init]);
      if (init && 'body' in init) return Reflect.apply(original, this, [input, {...init, body: cleanBody(init.body)}]);
      // Discord currently supplies a serialized body. Also handle small JSON
      // Request bodies without consuming the caller's stream or altering signals.
      if (request && /application\/json/i.test(request.headers.get('content-type') || '')) {
        const receiver = this;
        return (async () => {
          let replacement = request;
          try {
            const reader = request.clone().body?.getReader();
            if (reader) {
              const chunks = []; let size = 0;
              try {
                while (true) {
                  const {done, value} = await reader.read(); if (done) break;
                  size += value.length;
                  if (size > 2 * 1024 * 1024 || !allowed()) {
                    // A cloned body tees the original stream. Cancellation can
                    // wait for that original to be consumed by fetch, so do
                    // not await it before forwarding an unchanged request.
                    void reader.cancel().catch(() => {});
                    return Reflect.apply(original, receiver, [input, init]);
                  }
                  chunks.push(value);
                }
                const bytes = new Uint8Array(size); let offset = 0;
                for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
                const body = new TextDecoder('utf-8', {fatal:true}).decode(bytes), cleaned = cleanJSON(body);
                if (cleaned !== body && allowed()) replacement = new Request(request, {body:cleaned});
              } finally { reader.releaseLock(); }
            }
          } catch {}
          return Reflect.apply(original, receiver, [replacement, init]);
        })();
      }
      return Reflect.apply(original, this, [input, init]);
    });
  }
  function randomName(file) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let name = '';
    while (name.length < 16) {
      for (const byte of crypto.getRandomValues(new Uint8Array(24))) {
        if (byte < 248 && name.length < 16) name += alphabet[byte % 62];
      }
    }
    const match = file.name.match(/\.([a-z\d]{1,16})$/i);
    const extensions = {'image/png':'png', 'image/jpeg':'jpg', 'image/gif':'gif', 'image/webp':'webp',
      'image/heic':'heic', 'image/heif':'heif', 'video/mp4':'mp4', 'video/quicktime':'mov', 'application/pdf':'pdf'};
    const extension = match?.[1] || extensions[file.type] || '';
    // SPOILER_ is Discord's functional flag, not an original-name fragment.
    return (/^SPOILER_/i.test(file.name) ? 'SPOILER_' : '') + name + (extension ? '.' + extension : '');
  }
  function renamed(file, name) { return new File([file], name, {type:file.type, lastModified:0}); }
  function releaseWorker() {
    worker?.terminate(); worker = null;
    if (workerURL) URL.revokeObjectURL(workerURL);
    workerURL = null;
  }
  function finish(id, file) {
    const job = jobs.get(id); if (!job) return;
    jobs.delete(id); clearTimeout(job.timer); pendingBytes -= job.file.size;
    prepared.add(file); job.resolve(file);
    if (!jobs.size) releaseWorker();
  }
  function failWorker() {
    for (const [id, job] of jobs) finish(id, renamed(job.file, job.name));
    releaseWorker();
  }
  function prepare(file) {
    if (prepared.has(file)) return Promise.resolve(file);
    if (processed.has(file)) return processed.get(file);
    const name = randomName(file);
    // Unsupported, large and overloaded files keep their bytes. Renaming a
    // Blob is cheap; only bounded image metadata work enters the worker.
    if (!/\.(png|jpe?g|gif|webp)$/i.test(name) || file.size > 64 * 1024 * 1024 || jobs.size >= 10 || pendingBytes + file.size > 128 * 1024 * 1024) {
      const copy = renamed(file, name); prepared.add(copy); return Promise.resolve(copy);
    }
    const promise = new Promise(resolve => {
      const id = ++serial;
      const timer = setTimeout(failWorker, 30000);
      jobs.set(id, {file, name, resolve, timer}); pendingBytes += file.size;
      try {
        if (!worker) {
          workerURL = URL.createObjectURL(new Blob([workerSource], {type:'text/javascript'}));
          worker = new Worker(workerURL);
          worker.onmessage = event => {
            const job = jobs.get(event.data?.id); if (!job) return;
            const blob = event.data.blob instanceof Blob ? event.data.blob : job.file;
            finish(event.data.id, new File([blob], job.name, {type:job.file.type, lastModified:0}));
          };
          worker.onerror = failWorker; worker.onmessageerror = failWorker;
        }
        worker.postMessage({id, file});
      } catch { failWorker(); }
    });
    processed.set(file, promise);
    // Weak identity caching exists only for the current batch. Prepared copies
    // carry weak markers, so a replay or Noko-Chat handoff cannot process twice.
    promise.finally(() => processed.delete(file));
    return promise;
  }
  function chatTarget(target) {
    return target instanceof Element && !!target.closest('[class*="channelTextArea_"], [class*="chat_"], [class*="chatContent_"], [class*="threadSidebar_"]');
  }
  function releasePicker(input) {
    const reference = pickers.get(input);
    if (!reference) return;
    input.removeEventListener('change', onFiles, true);
    input.removeEventListener('cancel', onPickerCancel, true);
    pickers.delete(input); pickerInputs.delete(reference);
  }
  function onPickerCancel(event) { releasePicker(event.target); }
  function installPickers() {
    const mark = input => {
      if (!allowed() || input.type !== 'file' || pickers.has(input)) return;
      // Discord can create a temporary input in a popover portal or detach it
      // from the document. Capture on that input before its bubble listeners.
      const composer = document.querySelector('[class*="channelTextArea_"] [data-slate-editor="true"]');
      // A detached single-file image picker is also used by Noko-Chat's local
      // converter. It is not outbound until the resulting GIF is attached.
      const outbound = chatTarget(input) || (input.multiple && composer && !document.querySelector('[role="dialog"], [class*="standardSidebarView_"]'));
      if (!outbound) return;
      for (const reference of pickerInputs) if (!reference.deref()) pickerInputs.delete(reference);
      // At most one system picker is normally open. Bound stale cancelled
      // inputs even if a WebKit release fails to dispatch its cancel event.
      if (pickerInputs.size >= 32) {
        const reference = pickerInputs.values().next().value;
        const old = reference.deref(); if (old) releasePicker(old); else pickerInputs.delete(reference);
      }
      const reference = new WeakRef(input); pickerInputs.add(reference); pickers.set(input, reference);
      input.addEventListener('change', onFiles, true);
      input.addEventListener('cancel', onPickerCancel, true);
    };
    for (const method of ['click', 'showPicker']) if (typeof HTMLInputElement.prototype[method] === 'function') {
      patch(HTMLInputElement.prototype, method, original => function(...args) {
        mark(this); return Reflect.apply(original, this, args);
      });
    }
  }
  function transfer(files, strings) {
    const data = new DataTransfer();
    for (const file of files) data.items.add(file);
    for (const [type, value] of strings) data.setData(type, value);
    return data;
  }
  function onFiles(event) {
    if (!allowed() || replayed.has(event) || event.defaultPrevented) return;
    const target = event.target, input = target instanceof HTMLInputElement && target.type === 'file';
    // File inputs inside Discord's chat are uploads. Leave avatar/profile,
    // server, import, and Noko-Chat's converter picker alone.
    const picker = input && pickers.has(target);
    if ((!chatTarget(target) && !picker) || (event.type === 'change' && !input)) return;
    const data = event.clipboardData || event.dataTransfer;
    const files = [...(input ? target.files || [] : data?.files || [])];
    if (!files.length || files.every(file => prepared.has(file))) { if (picker) releasePicker(target); return; }
    // Directory entry enumeration is Discord's responsibility. Do not replace
    // a transfer whose entries carry a directory rather than ordinary files.
    if (data && [...data.items].some(item => item.kind === 'file' && item.webkitGetAsEntry?.()?.isDirectory)) return;
    const strings = [];
    if (data) for (const type of data.types) {
      // Discord derives pasted PNG names from HTML img URLs. File-containing
      // pastes must omit that redundant HTML to avoid restoring a private name.
      if (type !== 'Files' && !(event.type === 'paste' && type === 'text/html')) strings.push([type, data.getData(type)]);
    }
    const route = location.href, type = event.type;
    const point = {clientX:event.clientX || 0, clientY:event.clientY || 0};
    event.preventDefault(); event.stopImmediatePropagation();
    void Promise.all(files.map(file => {
      try { return prepare(file).catch(() => file); } catch { return Promise.resolve(file); }
    })).then(copies => {
      if ((!target.isConnected && !picker) || location.href !== route) { if (picker) releasePicker(target); return; }
      try {
        const value = transfer(allowed() ? copies : files, strings);
        let replay;
        if (input) { target.files = value.files; replay = new Event('change', {bubbles:true}); }
        else if (type === 'paste') replay = new ClipboardEvent('paste', {bubbles:true, cancelable:true, clipboardData:value});
        else replay = new DragEvent('drop', {bubbles:true, cancelable:true, dataTransfer:value, ...point});
        if (picker) releasePicker(target);
        replayed.add(replay); target.dispatchEvent(replay);
      } catch {
        // Native clipboard/drop stores enter protected mode after the original
        // event returns. Keep an immutable snapshot for a safe fallback replay.
        const replay = new Event(type, {bubbles:true, cancelable:true});
        if (!input) {
          const snapshot = {files, types:['Files', ...strings.map(([type]) => type)],
            items:files.map(file => ({kind:'file', type:file.type, getAsFile:() => file})),
            getData:type => strings.find(([key]) => key === type)?.[1] || ''};
          Object.defineProperty(replay, type === 'paste' ? 'clipboardData' : 'dataTransfer', {value:snapshot});
          Object.defineProperty(replay, 'clientX', {value:point.clientX});
          Object.defineProperty(replay, 'clientY', {value:point.clientY});
        }
        if (picker) releasePicker(target);
        replayed.add(replay); target.dispatchEvent(replay);
      }
    });
  }
  function stop() {
    active = false;
    for (const type of ['change', 'paste', 'drop']) window.removeEventListener(type, onFiles, true);
    for (const reference of pickerInputs) { const input = reference.deref(); if (input) releasePicker(input); }
    pickerInputs.clear(); pickers = new WeakMap();
    while (restorers.length) restorers.pop()();
    failWorker(); processed = new WeakMap(); prepared = new WeakSet();
  }
  globalThis.__nokoNokonymise = Object.freeze({
    configure(enabled) {
      if (active === enabled) return;
      if (!enabled) { stop(); return; }
      active = true;
      try {
        installMessages();
        installPickers();
        for (const type of ['change', 'paste', 'drop']) window.addEventListener(type, onFiles, true);
      } catch { stop(); throw new Error('Nokonymise could not start'); }
    }
  });
})();
