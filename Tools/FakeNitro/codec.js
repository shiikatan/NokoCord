  // PNG/APNG chunk composition follows the APNG specification. The upstream
  // apng-canvas adaptation is credited in NOTICE; this decoder is bounded and
  // loads one frame at a time rather than retaining all decoded frame images.
  const PNG_SIGNATURE = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const crcTable = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ c >>> 1 : c >>> 1; crcTable[n] = c; }
  function crc32(bytes) { let c = 0xffffffff; for (const b of bytes) c = crcTable[(c ^ b) & 255] ^ c >>> 8; return (c ^ 0xffffffff) >>> 0; }
  function pngChunk(type, data) {
    const bytes = new Uint8Array(data.length + 12), view = new DataView(bytes.buffer);
    view.setUint32(0, data.length); for (let i = 0; i < 4; i++) bytes[4 + i] = type.charCodeAt(i);
    bytes.set(data, 8); view.setUint32(bytes.length - 4, crc32(bytes.subarray(4, bytes.length - 4))); return bytes;
  }
  function parseAnimation(bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length < 57 || bytes.length > 8 * 1024 * 1024
      || !PNG_SIGNATURE.every((b, i) => bytes[i] === b)) throw new Error('Invalid PNG sticker.');
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let offset = 8, width = 0, height = 0, expected = 0, ended = false, sequence = 0, chunks = 0, header = null, frame = null;
    const frames = [], ancillary = [];
    while (offset < bytes.length) {
      if (++chunks > 4096 || offset + 12 > bytes.length) throw new Error('Invalid PNG chunk bounds.');
      const size = view.getUint32(offset), end = offset + size + 12;
      if (size > bytes.length - offset - 12 || end > bytes.length) throw new Error('Invalid PNG chunk size.');
      const type = String.fromCharCode(...bytes.subarray(offset + 4, offset + 8));
      const data = bytes.subarray(offset + 8, end - 4), part = new DataView(data.buffer, data.byteOffset, data.byteLength);
      if (crc32(bytes.subarray(offset + 4, end - 4)) !== view.getUint32(end - 4)) throw new Error('PNG checksum failed.');
      if (!header && type !== 'IHDR') throw new Error('PNG header missing.');
      if (type === 'IHDR') {
        if (header || size !== 13) throw new Error('Invalid PNG header.');
        width = part.getUint32(0); height = part.getUint32(4); header = data.slice();
        if (!width || !height || width > 2048 || height > 2048 || width * height > 4194304) throw new Error('Sticker dimensions are too large.');
      } else if (type === 'acTL') {
        if (expected || size !== 8 || frames.length || frame) throw new Error('Invalid animation header.');
        expected = part.getUint32(0); if (!expected || expected > 180) throw new Error('Sticker has too many animation frames.');
      } else if (type === 'fcTL') {
        if (!expected || size !== 26 || part.getUint32(0) !== sequence++) throw new Error('Invalid animation sequence.');
        if (frame) frames.push(frame);
        frame = { width: part.getUint32(4), height: part.getUint32(8), left: part.getUint32(12), top: part.getUint32(16),
          delay: 1000 * part.getUint16(20) / (part.getUint16(22) || 100), dispose: data[24], blend: data[25], parts: [] };
        if (!frame.width || !frame.height || frame.left + frame.width > width || frame.top + frame.height > height
          || frame.dispose > 2 || frame.blend > 1 || frames.length >= expected) throw new Error('Invalid animation frame.');
        frame.delay = Math.max(20, Math.min(10000, frame.delay || 100));
      } else if (type === 'fdAT') {
        if (!frame || size < 5 || part.getUint32(0) !== sequence++) throw new Error('Invalid frame payload.');
        frame.parts.push(data.subarray(4));
      } else if (type === 'IDAT') {
        if (frame) frame.parts.push(data);
      } else if (type === 'IEND') {
        if (size || end !== bytes.length) throw new Error('Invalid PNG ending.'); ended = true; break;
      } else if (['PLTE', 'tRNS', 'gAMA', 'cHRM', 'sRGB', 'iCCP'].includes(type)) {
        ancillary.push(pngChunk(type, data));
      } else if (type[0] === type[0].toUpperCase()) throw new Error('Unsupported PNG chunk.');
      offset = end;
    }
    if (frame) frames.push(frame);
    if (!ended || !expected || frames.length !== expected || frames.some(f => !f.parts.length)
      || width * height * frames.length > 64 * 1024 * 1024 || frames.reduce((n, f) => n + f.delay, 0) > 60000) {
      throw new Error('Animated sticker exceeds the conversion budget.');
    }
    return { width, height, header, ancillary, frames };
  }
  async function boundedSticker(url, signal) {
    if (!validMedia(url)) throw new Error('Only Discord sticker media is supported.');
    const response = await fetch(url, { credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error', signal });
    if (!response.ok || !response.body || Number(response.headers.get('content-length') || 0) > 8 * 1024 * 1024) throw new Error('Sticker download failed or is too large.');
    const reader = response.body.getReader(), chunks = []; let count = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read(); if (done) break;
        count += value.byteLength;
        if (signal.aborted || count > 8 * 1024 * 1024 || chunks.length >= 4096) throw new Error('Sticker download exceeded its limit.');
        chunks.push(value);
      }
    } finally { try { await reader.cancel(); } catch {} reader.releaseLock(); }
    const data = new Uint8Array(count); let cursor = 0; for (const chunk of chunks) { data.set(chunk, cursor); cursor += chunk.length; } return data;
  }
  async function decodeFrame(blob, signal) {
    if (signal.aborted) throw new Error('Conversion cancelled.');
    if (typeof createImageBitmap === 'function') return createImageBitmap(blob);
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(blob), image = new Image();
      const finish = (error) => { URL.revokeObjectURL(url); signal.removeEventListener('abort', abort); image.onload = image.onerror = null; error ? reject(error) : resolve(image); };
      const abort = () => { image.src = ''; finish(new Error('Conversion cancelled.')); };
      signal.addEventListener('abort', abort, { once: true });
      image.onload = () => finish(); image.onerror = () => finish(new Error('Could not decode sticker frame.')); image.src = url;
    });
  }
  let conversionBusy = false;
  async function animatedStickerFile(url, id, lease) {
    if (conversionBusy) throw new Error('Another animated sticker is being prepared. Try again shortly.');
    conversionBusy = true;
    const controller = new AbortController(); pending.add(controller);
    const timer = setTimeout(() => controller.abort(), 20000);
    const progress = document.createElement('div'), progressText = document.createElement('span'), cancel = document.createElement('button');
    progress.setAttribute('data-noko-fake-nitro-conversion', ''); progress.setAttribute('role', 'status');
    progress.style.cssText = 'position:fixed;right:18px;bottom:136px;z-index:2147483001;display:flex;gap:16px;align-items:center;padding:12px 16px;border-radius:12px;background:var(--background-secondary,#25252c);color:var(--text-normal,#eee);font:13px system-ui;box-shadow:0 4px 20px #0005';
    progressText.textContent = 'Preparing animated sticker…'; cancel.textContent = 'Cancel'; cancel.onclick = () => controller.abort();
    progress.append(progressText, cancel); document.documentElement.append(progress);
    let sourceCanvas, outputCanvas;
    try {
      const animation = parseAnimation(await boundedSticker(url, controller.signal));
      const resolution = settings.store.stickerSize;
      if (Math.max(resolution * resolution, animation.width * animation.height) * animation.frames.length > 64 * 1024 * 1024) throw new Error('Choose a smaller sticker size for this animation.');
      sourceCanvas = document.createElement('canvas'); sourceCanvas.width = animation.width; sourceCanvas.height = animation.height;
      outputCanvas = document.createElement('canvas'); outputCanvas.width = outputCanvas.height = resolution;
      const ctx = sourceCanvas.getContext('2d', { willReadFrequently: true }), output = outputCanvas.getContext('2d', { willReadFrequently: true });
      if (!ctx || !output) throw new Error('Image conversion is unavailable.');
      const gif = GIFEncoder(), scale = resolution / Math.max(animation.width, animation.height);
      for (let i = 0; i < animation.frames.length; i++) {
        progressText.textContent = `Preparing animated sticker… ${i + 1}/${animation.frames.length}`;
        if (!active || generation !== lease || controller.signal.aborted) throw new Error('Conversion cancelled.');
        const frame = animation.frames[i], header = animation.header.slice(), headerView = new DataView(header.buffer);
        headerView.setUint32(0, frame.width); headerView.setUint32(4, frame.height);
        const blob = new Blob([PNG_SIGNATURE, pngChunk('IHDR', header), ...animation.ancillary,
          ...frame.parts.map(part => pngChunk('IDAT', part)), pngChunk('IEND', new Uint8Array())], { type: 'image/png' });
        const previous = frame.dispose === 2 ? ctx.getImageData(frame.left, frame.top, frame.width, frame.height) : null;
        const image = await decodeFrame(blob, controller.signal);
        try {
          if (!active || generation !== lease || controller.signal.aborted) throw new Error('Conversion cancelled.');
          if (frame.blend === 0) ctx.clearRect(frame.left, frame.top, frame.width, frame.height);
          ctx.drawImage(image, frame.left, frame.top, frame.width, frame.height);
        } finally { image.close?.(); }
        output.clearRect(0, 0, resolution, resolution);
        output.drawImage(sourceCanvas, (resolution - animation.width * scale) / 2, (resolution - animation.height * scale) / 2, animation.width * scale, animation.height * scale);
        const pixels = output.getImageData(0, 0, resolution, resolution).data;
        const palette = quantize(pixels, 256, { format: 'rgba4444', oneBitAlpha: true, clearAlpha: true });
        const transparentIndex = palette.findIndex(color => color[3] === 0);
        gif.writeFrame(applyPalette(pixels, palette, 'rgba4444'), resolution, resolution, { palette, delay: frame.delay,
          transparent: transparentIndex >= 0, transparentIndex: Math.max(0, transparentIndex), dispose: 2, repeat: 0 });
        if (gif.bytesView().byteLength > 8 * 1024 * 1024) throw new Error('Converted sticker is too large.');
        if (frame.dispose === 1 || (i === 0 && frame.dispose === 2)) ctx.clearRect(frame.left, frame.top, frame.width, frame.height);
        else if (previous) ctx.putImageData(previous, frame.left, frame.top);
        await new Promise(resolve => setTimeout(resolve, 0));
      }
      gif.finish(); return new File([gif.bytesView()], id + '.gif', { type: 'image/gif' });
    } finally {
      clearTimeout(timer); pending.delete(controller); conversionBusy = false;
      progress.remove();
      if (sourceCanvas) sourceCanvas.width = sourceCanvas.height = 0;
      if (outputCanvas) outputCanvas.width = outputCanvas.height = 0;
    }
  }
