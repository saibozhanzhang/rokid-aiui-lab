import jpegDecode from './vendor/jpeg-decoder.js';
import jsQR from './vendor/jsQR.js';
import UPNG from './vendor/upng.js';
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

function downsample(image, maxSide) {
  const width = image.width;
  const height = image.height;
  const source = image.data instanceof Uint8ClampedArray ? image.data : new Uint8ClampedArray(image.data);
  const side = Math.max(width, height);
  if (!side || side <= maxSide) return { data: source, width, height, scale: 1 };
  const scale = Math.ceil(side / maxSide);
  const outWidth = Math.max(1, Math.floor(width / scale));
  const outHeight = Math.max(1, Math.floor(height / scale));
  const out = new Uint8ClampedArray(outWidth * outHeight * 4);
  for (let y = 0; y < outHeight; y++) {
    const sy = Math.min(height - 1, y * scale);
    for (let x = 0; x < outWidth; x++) {
      const sx = Math.min(width - 1, x * scale);
      const src = (sy * width + sx) * 4;
      const dst = (y * outWidth + x) * 4;
      out[dst] = source[src];
      out[dst + 1] = source[src + 1];
      out[dst + 2] = source[src + 2];
      out[dst + 3] = 255;
    }
  }
  return { data: out, width: outWidth, height: outHeight, scale };
}

function hexHead(bytes) {
  return Array.prototype.slice.call(bytes, 0, 20)
    .map((item) => item.toString(16).padStart(2, '0'))
    .join('');
}

function exactArrayBuffer(bytes) {
  if (!bytes) return null;
  if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) return bytes.buffer;
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function webpChunkType(bytes) {
  if (!bytes || bytes.length < 16) return '';
  if (
    bytes[0] !== 0x52 ||
    bytes[1] !== 0x49 ||
    bytes[2] !== 0x46 ||
    bytes[3] !== 0x46 ||
    bytes[8] !== 0x57 ||
    bytes[9] !== 0x45 ||
    bytes[10] !== 0x42 ||
    bytes[11] !== 0x50
  ) return '';
  return String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]).trim();
}

export function decodeImageFromBytes(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.byteLength < 32) throw new Error('照片字节为空');
  const head = hexHead(bytes);
  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    const image = jpegDecode(bytes, {
      useTArray: true,
      formatAsRGBA: true,
      tolerantDecoding: true,
      maxResolutionInMP: 12,
      maxMemoryUsageInMB: 160
    });
    return {
      data: image.data instanceof Uint8ClampedArray ? image.data : new Uint8ClampedArray(image.data),
      width: image.width,
      height: image.height,
      format: 'jpg',
      head
    };
  }
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const image = UPNG.decode(exactArrayBuffer(bytes));
    const rgba = new Uint8Array(UPNG.toRGBA8(image)[0]);
    return {
      data: new Uint8ClampedArray(rgba),
      width: image.width,
      height: image.height,
      format: 'png',
      head
    };
  }
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46) {
    throw new Error(`WebP 需要异步解码 chunk=${webpChunkType(bytes) || 'unknown'} head=${head}`);
  }
  throw new Error(`未知照片格式 head=${head}`);
}

export async function decodeWebPGrayFromBytes(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.byteLength < 32) throw new Error('照片字节为空');
  const head = hexHead(bytes);
  const chunkType = webpChunkType(bytes) || 'unknown';
  const image = await decodeWebP(bytes, { output: 'gray' });
  return {
    data: image.gray,
    width: image.width,
    height: image.height,
    format: 'webp-gray',
    chunkType,
    head
  };
}

export async function decodeImageFromBytesAsync(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.byteLength < 32) throw new Error('照片字节为空');
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46) {
    const head = hexHead(bytes);
    const chunkType = webpChunkType(bytes) || 'unknown';
    const image = await decodeWebP(bytes, { output: 'rgba' });
    return {
      data: image.rgba instanceof Uint8ClampedArray ? image.rgba : new Uint8ClampedArray(image.rgba),
      width: image.width,
      height: image.height,
      format: 'webp',
      chunkType,
      head
    };
  }
  return decodeImageFromBytes(bytes);
}

export function decodeQrFromImage(image) {
  const candidates = [
    { ...downsample(image, 960), label: '960' },
    { ...downsample(image, 640), label: '640' },
    {
      data: image.data instanceof Uint8ClampedArray ? image.data : new Uint8ClampedArray(image.data),
      width: image.width,
      height: image.height,
      scale: 1,
      label: 'full'
    }
  ];
  let lastSize = `${image.width}x${image.height}`;
  for (let i = 0; i < candidates.length; i++) {
    const item = candidates[i];
    lastSize = `${item.label}:${item.width}x${item.height}`;
    const code = jsQR(item.data, item.width, item.height, {
      inversionAttempts: 'attemptBoth'
    });
    if (code && code.data) {
      return {
        found: true,
        text: String(code.data),
        provider: 'local-jsqr',
        rawPreview: `local-jsqr ${image.format} ${lastSize}`,
        width: item.width,
        height: item.height,
        location: code.location || null
      };
    }
  }
  return {
    found: false,
    text: '',
    provider: 'local-jsqr',
    rawPreview: `local-jsqr ${image.format} empty ${lastSize} head=${image.head}${image.chunkType ? ' chunk=' + image.chunkType : ''}`
  };
}

export function decodeQrFromBytes(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.byteLength < 32) throw new Error('照片字节为空');
  return decodeQrFromImage(decodeImageFromBytes(bytes));
}

export async function decodeQrFromBytesAsync(inputBytes) {
  const bytes = asUint8(inputBytes);
  if (!bytes || bytes.byteLength < 32) throw new Error('照片字节为空');
  const image = await decodeImageFromBytesAsync(bytes);
  return decodeQrFromImage(image);
}
