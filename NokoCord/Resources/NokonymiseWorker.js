/* Lossless metadata editing only. Encoded pixels, frame data, color chunks and
   timing are copied verbatim. Malformed/complex containers fall back unchanged.
   The worker is created on demand and terminated when its batch completes. */
'use strict';
const ascii = (bytes, start, length) => String.fromCharCode(...bytes.subarray(start, start + length));
const viewOf = bytes => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
const starts = (bytes, value) => ascii(bytes, 0, value.length) === value;

function orientation(bytes) {
  if (starts(bytes, 'Exif\0\0')) bytes = bytes.subarray(6);
  const view = viewOf(bytes), little = starts(bytes, 'II');
  if ((!little && !starts(bytes, 'MM')) || bytes.length < 8 || view.getUint16(2, little) !== 42) throw Error('Unsupported EXIF');
  const offset = view.getUint32(4, little);
  if (offset < 8 || offset + 2 > bytes.length) throw Error('Invalid EXIF');
  const count = view.getUint16(offset, little);
  if (count > 4096 || offset + 2 + count * 12 + 4 > bytes.length) throw Error('Invalid EXIF');
  let result = 1;
  for (let index = 0; index < count; index++) {
    const entry = offset + 2 + index * 12;
    const tag = view.getUint16(entry, little);
    if (tag === 0x8769) {
      // Some images rely on EXIF rather than an ICC profile to identify a
      // non-sRGB color space. These receive filename protection only.
      if (view.getUint16(entry + 2, little) !== 4 || view.getUint32(entry + 4, little) !== 1) throw Error('Invalid EXIF directory');
      const exif = view.getUint32(entry + 8, little);
      if (exif + 2 > bytes.length) throw Error('Invalid EXIF directory');
      const entries = view.getUint16(exif, little);
      if (entries > 4096 || exif + 2 + entries * 12 + 4 > bytes.length) throw Error('Invalid EXIF directory');
      for (let index = 0; index < entries; index++) {
        const entry = exif + 2 + index * 12;
        if (view.getUint16(entry, little) === 0xA001 &&
            (view.getUint16(entry + 2, little) !== 3 || view.getUint32(entry + 4, little) !== 1 || view.getUint16(entry + 8, little) !== 1)) throw Error('Non-sRGB EXIF');
      }
    }
    if (tag !== 0x112) continue;
    if (view.getUint16(entry + 2, little) !== 3 || view.getUint32(entry + 4, little) !== 1) throw Error('Invalid orientation');
    result = view.getUint16(entry + 8, little);
    if (result < 1 || result > 8) throw Error('Invalid orientation');
  }
  return result;
}
function minimalEXIF(value) {
  const bytes = new Uint8Array(26), view = viewOf(bytes);
  bytes.set([0x49, 0x49, 42, 0, 8, 0, 0, 0]);
  view.setUint16(8, 1, true); view.setUint16(10, 0x112, true);
  view.setUint16(12, 3, true); view.setUint32(14, 1, true); view.setUint16(18, value, true);
  return bytes;
}
const crcTable = Array.from({length:256}, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = (value & 1) ? 0xEDB88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc(bytes) {
  let result = 0xFFFFFFFF;
  for (const byte of bytes) result = crcTable[(result ^ byte) & 255] ^ (result >>> 8);
  return (result ^ 0xFFFFFFFF) >>> 0;
}
function pngChunk(type, data) {
  const bytes = new Uint8Array(data.length + 12), view = viewOf(bytes);
  view.setUint32(0, data.length);
  bytes.set([...type].map(char => char.charCodeAt(0)), 4); bytes.set(data, 8);
  view.setUint32(bytes.length - 4, crc(bytes.subarray(4, bytes.length - 4)));
  return bytes;
}
function png(bytes) {
  if (bytes.length < 33 || ![137,80,78,71,13,10,26,10].every((value, index) => bytes[index] === value)) throw Error('Invalid PNG');
  const view = viewOf(bytes), parts = [bytes.subarray(0, 8)];
  let offset = 8, count = 0, image = false, ended = false;
  while (offset + 12 <= bytes.length) {
    if (++count > 100000) throw Error('Too many chunks');
    const length = view.getUint32(offset), end = offset + length + 12;
    if (end > bytes.length) throw Error('Invalid chunk');
    const type = ascii(bytes, offset + 4, 4), data = bytes.subarray(offset + 8, end - 4);
    if (crc(bytes.subarray(offset + 4, end - 4)) !== view.getUint32(end - 4)) throw Error('Invalid CRC');
    if (count === 1 && (type !== 'IHDR' || length !== 13)) throw Error('Invalid header');
    if (type === 'IDAT') image = true;
    if (type === 'eXIf') parts.push(pngChunk('eXIf', minimalEXIF(orientation(data))));
    else if (!['tEXt', 'zTXt', 'iTXt', 'tIME'].includes(type)) parts.push(bytes.subarray(offset, end));
    offset = end;
    if (type === 'IEND') { if (length !== 0) throw Error('Invalid end'); ended = true; break; }
  }
  if (!ended || !image || offset !== bytes.length) throw Error('Incomplete PNG');
  return new Blob(parts);
}
function jpegSegment(marker, data) {
  const bytes = new Uint8Array(data.length + 4);
  bytes.set([255, marker]); viewOf(bytes).setUint16(2, data.length + 2); bytes.set(data, 4);
  return bytes;
}
function jpeg(bytes) {
  if (bytes[0] !== 255 || bytes[1] !== 216) throw Error('Invalid JPEG');
  const view = viewOf(bytes), parts = [bytes.subarray(0, 2)];
  let offset = 2, scans = 0, ended = false, count = 0;
  while (offset < bytes.length) {
    if (++count > 100000 || bytes[offset] !== 255) throw Error('Invalid JPEG marker');
    const start = offset++;
    while (bytes[offset] === 255) offset++;
    const marker = bytes[offset++];
    if (marker === 217) { parts.push(bytes.subarray(start, offset)); ended = true; break; }
    if (marker === 0 || marker === 216 || marker === undefined) throw Error('Invalid marker');
    if (marker === 1 || (marker >= 208 && marker <= 215)) { parts.push(bytes.subarray(start, offset)); continue; }
    if (offset + 2 > bytes.length) throw Error('Truncated JPEG');
    const length = view.getUint16(offset), end = offset + length;
    if (length < 2 || end > bytes.length) throw Error('Truncated segment');
    const data = bytes.subarray(offset + 2, end);
    if ((marker === 226 && starts(data, 'MPF\0')) || marker === 235) throw Error('Complex JPEG');
    if (marker === 225) {
      // Ultra HDR/gain-map JPEGs can depend on XMP and absolute byte offsets.
      // Preserve these containers rather than removing rendering information.
      const header = ascii(data, 0, Math.min(data.length, 65533));
      if (/hdrgm:|GainMap|Container:Directory|hdr-gain-map/i.test(header)) throw Error('HDR JPEG');
      if (starts(data, 'Exif\0\0')) {
        const tiff = minimalEXIF(orientation(data));
        const minimal = new Uint8Array(6 + tiff.length); minimal.set([69,120,105,102,0,0]); minimal.set(tiff, 6);
        parts.push(jpegSegment(marker, minimal));
      }
    } else if (marker === 224 && starts(data, 'JFIF\0')) {
      if (data.length < 14) throw Error('Invalid JFIF');
      const header = data.slice(0, 14); header[12] = 0; header[13] = 0;
      parts.push(jpegSegment(marker, header));
    } else if (!(marker === 237 || marker === 254 || (marker === 224 && starts(data, 'JFXX\0')))) {
      parts.push(bytes.subarray(start, end));
    }
    offset = end;
    if (marker === 218) {
      scans++;
      const start = offset;
      while (offset < bytes.length) {
        if (bytes[offset] !== 255) { offset++; continue; }
        let next = offset + 1;
        while (bytes[next] === 255) next++;
        if (bytes[next] === 0 || (bytes[next] >= 208 && bytes[next] <= 215)) { offset = next + 1; continue; }
        break;
      }
      parts.push(bytes.subarray(start, offset));
    }
  }
  if (!ended || !scans || offset !== bytes.length) throw Error('Incomplete JPEG');
  return new Blob(parts);
}
function gif(bytes) {
  if (!['GIF87a', 'GIF89a'].includes(ascii(bytes, 0, 6)) || bytes.length < 14) throw Error('Invalid GIF');
  let offset = 13 + (bytes[10] & 128 ? 3 * (1 << ((bytes[10] & 7) + 1)) : 0);
  if (offset > bytes.length) throw Error('Invalid palette');
  const parts = [bytes.subarray(0, offset)]; let images = 0, ended = false;
  function subBlocks() {
    while (offset < bytes.length) {
      const length = bytes[offset++]; if (!length) return;
      offset += length; if (offset > bytes.length) throw Error('Invalid GIF block');
    }
    throw Error('Incomplete GIF block');
  }
  while (offset < bytes.length) {
    const start = offset, marker = bytes[offset++];
    if (marker === 59) { parts.push(bytes.subarray(start, offset)); ended = true; break; }
    if (marker === 44) {
      if (offset + 9 > bytes.length) throw Error('Invalid GIF image');
      const packed = bytes[offset + 8]; offset += 9;
      if (packed & 128) offset += 3 * (1 << ((packed & 7) + 1));
      if (offset >= bytes.length || bytes[offset] < 2 || bytes[offset] > 8) throw Error('Invalid GIF data');
      offset++; subBlocks(); images++; parts.push(bytes.subarray(start, offset));
    } else if (marker === 33) {
      const label = bytes[offset++];
      const xmp = label === 255 && bytes[offset] === 11 && ascii(bytes, offset + 1, 11) === 'XMP DataXMP';
      subBlocks();
      if (label !== 254 && !xmp) parts.push(bytes.subarray(start, offset));
    } else throw Error('Invalid GIF marker');
  }
  if (!ended || !images || offset !== bytes.length) throw Error('Incomplete GIF');
  return new Blob(parts);
}
function webpChunk(type, data) {
  const bytes = new Uint8Array(8 + data.length + (data.length & 1));
  bytes.set([...type].map(char => char.charCodeAt(0))); viewOf(bytes).setUint32(4, data.length, true); bytes.set(data, 8);
  return bytes;
}
function webp(bytes) {
  const view = viewOf(bytes);
  if (bytes.length < 20 || !starts(bytes, 'RIFF') || ascii(bytes, 8, 4) !== 'WEBP' || view.getUint32(4, true) + 8 !== bytes.length) throw Error('Invalid WebP');
  const chunks = []; let offset = 12, image = false, exif = false, flags = null;
  while (offset + 8 <= bytes.length) {
    const type = ascii(bytes, offset, 4), length = view.getUint32(offset + 4, true), end = offset + 8 + length + (length & 1);
    if (end > bytes.length) throw Error('Invalid WebP chunk');
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    if (['VP8 ', 'VP8L', 'ANMF'].includes(type)) image = true;
    if (type === 'VP8X') {
      if (length !== 10 || flags) throw Error('Invalid WebP header');
      flags = data.slice(); chunks.push({type, data:flags});
    } else if (type === 'EXIF') {
      chunks.push({type, data:minimalEXIF(orientation(data))}); exif = true;
    } else if (type !== 'XMP ') chunks.push({raw:bytes.subarray(offset, end)});
    offset = end;
  }
  if (offset !== bytes.length || !image || (exif && !flags)) throw Error('Incomplete WebP');
  if (flags) flags[0] = (flags[0] & ~12) | (exif ? 8 : 0);
  const parts = chunks.map(chunk => chunk.raw || webpChunk(chunk.type, chunk.data));
  const header = bytes.slice(0, 12); viewOf(header).setUint32(4, 4 + parts.reduce((sum, part) => sum + part.length, 0), true);
  return new Blob([header, ...parts]);
}
self.onmessage = async event => {
  const {id, file} = event.data;
  let blob = file;
  try {
    if (!(file instanceof Blob) || file.size > 64 * 1024 * 1024) throw Error('Unsupported file');
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (bytes[0] === 137) blob = png(bytes);
    else if (bytes[0] === 255 && bytes[1] === 216) blob = jpeg(bytes);
    else if (starts(bytes, 'GIF')) blob = gif(bytes);
    else if (starts(bytes, 'RIFF')) blob = webp(bytes);
    // A mismatched extension/magic never triggers a guessed re-encode.
  } catch { blob = file; }
  self.postMessage({id, blob});
};
