import { decodeWebP } from './webp.js';

function asUint8(bytes) {
  if (!bytes) return null;
  if (bytes instanceof Uint8Array) return bytes;
  if (bytes.byteLength !== undefined) return new Uint8Array(bytes);
  if (bytes.buffer && bytes.byteLength !== undefined) {
    return new Uint8Array(bytes.buffer, bytes.byteOffset || 0, bytes.byteLength);
  }
  return null;
}

function hexHead(bytes) {
  return Array.prototype.slice.call(bytes, 0, 20)
    .map((item) => item.toString(16).padStart(2, '0'))
    .join('');
}

function isRiffWebP(bytes) {
  return !!(
    bytes &&
    bytes.length >= 16 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  );
}

function webpChunkType(bytes) {
  if (!isRiffWebP(bytes)) return '';
  return String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]).trim();
}

function readUint24LE(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

function readUint32LE(bytes, offset) {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function chunkTag(bytes, offset) {
  return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
}

function findWebPChunk(bytes, expectedType) {
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const type = chunkTag(bytes, offset);
    const size = readUint32LE(bytes, offset + 4);
    const payloadStart = offset + 8;
    const payloadEnd = payloadStart + size;
    if (payloadEnd > bytes.length) return null;
    if (type === expectedType) {
      return { type, size, payloadStart, payloadEnd };
    }
    offset = payloadEnd + (size % 2);
  }
  return null;
}

function parseVp8Dimensions(bytes, chunk) {
  const start = chunk.payloadStart;
  if (start + 10 > bytes.length) return null;
  if (bytes[start + 3] !== 0x9d || bytes[start + 4] !== 0x01 || bytes[start + 5] !== 0x2a) return null;
  return {
    width: ((bytes[start + 7] << 8) | bytes[start + 6]) & 0x3fff,
    height: ((bytes[start + 9] << 8) | bytes[start + 8]) & 0x3fff,
    chunkType: 'VP8'
  };
}

function parseVp8lDimensions(bytes, chunk) {
  const start = chunk.payloadStart;
  if (start + 5 > bytes.length || bytes[start] !== 0x2f) return null;
  const b1 = bytes[start + 1];
  const b2 = bytes[start + 2];
  const b3 = bytes[start + 3];
  const b4 = bytes[start + 4];
  return {
    width: 1 + (((b2 & 0x3f) << 8) | b1),
    height: 1 + (((b4 & 0x0f) << 10) | (b3 << 2) | ((b2 & 0xc0) >> 6)),
    chunkType: 'VP8L'
  };
}

export function getWebPInfoFromBytes(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || !isRiffWebP(bytes)) return null;
  const vp8x = findWebPChunk(bytes, 'VP8X');
  if (vp8x && vp8x.payloadStart + 10 <= bytes.length) {
    return {
      width: readUint24LE(bytes, vp8x.payloadStart + 4) + 1,
      height: readUint24LE(bytes, vp8x.payloadStart + 7) + 1,
      chunkType: 'VP8X'
    };
  }
  const vp8 = findWebPChunk(bytes, 'VP8 ');
  const vp8Info = vp8 ? parseVp8Dimensions(bytes, vp8) : null;
  if (vp8Info) return vp8Info;
  const vp8l = findWebPChunk(bytes, 'VP8L');
  return vp8l ? parseVp8lDimensions(bytes, vp8l) : null;
}

export function getImageExtFromBytes(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.length < 12) return 'unknown';
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return 'jpg';
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'png';
  if (isRiffWebP(bytes)) return 'webp';
  return 'unknown';
}

export async function decodeWebPGrayFromBytes(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.byteLength < 32) throw new Error('照片字节为空');
  if (!isRiffWebP(bytes)) throw new Error(`暂只支持 WebP 快扫 head=${hexHead(bytes)}`);
  const image = await decodeWebP(bytes, { output: 'gray', fast: true });
  return {
    data: image.gray,
    width: image.width,
    height: image.height,
    format: 'webp-gray',
    chunkType: webpChunkType(bytes) || 'unknown',
    head: hexHead(bytes)
  };
}
