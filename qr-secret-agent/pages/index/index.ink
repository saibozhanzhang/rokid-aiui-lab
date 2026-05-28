<script type="application/json" def>
{
  "navigationBarTitleText": "扫一扫",
  "description": "拍摄二维码并在眼镜里显示智能卡片。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "endpoint": { "type": "string", "description": "二维码解码接口 URL" }
      }
    }
  }
}
</script>

<script setup>
import wx from 'wx';
import { AudioPlayer } from 'audio';
import { BarcodeDetector } from 'barcode';
import { decodeWebPGrayFromBytes, getImageExtFromBytes, getWebPInfoFromBytes } from '../../lib/fast-barcode.js';

const DEFAULT_ENDPOINT = '';
const DEFAULT_PROVIDER = 'rokid';
const BASE64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const DOUBLE_TAP_MS = 420;
const APP_VERSION = '1.0.38';
const BARCODE_FORMATS = ['qr_code'];
const BARCODE_CANVAS_ID = 'decodeCanvas';
const BARCODE_CANVAS_SIZE = 360;
const PHOTO_QUALITY = 'low';
const ENABLE_ENCODED_FAST_PATH = false;
const ENCODED_DETECT_TIMEOUT_MS = 180;
const BARCODE_DETECT_TIMEOUT_MS = 3200;
const DECODE_RENDER_WAIT_MS = 80;
const PHOTO_CAPTURE_PROFILES = [
  {
    name: '极速',
    options: {
      quality: 'low',
      width: 512,
      height: 384,
      maxWidth: 512,
      maxHeight: 384,
      size: 'small',
      resolution: 'low',
      mode: 'fast',
      format: 'rgba',
      imageFormat: 'rgba',
      output: 'imageData',
      resultType: 'imageData',
      dataType: 'imageData',
      returnImageData: true
    }
  },
  {
    name: '小图',
    options: {
      quality: 'low',
      width: 640,
      height: 480,
      maxWidth: 640,
      maxHeight: 480,
      size: 'small',
      resolution: 'low'
    }
  },
  {
    name: '低清',
    options: {
      quality: PHOTO_QUALITY
    }
  }
];
const BRAND_FOOTNOTE = '只显示在你的乐奇 AI 眼镜里，一起乐在奇中，奇乐无穷！';
const LEQI_SECRET = 'leqi-aiui-scan-v1';
const COPYRIGHT_TEXT = '© 赛博站长';
const EFFECT_AUDIO = {
  success: '../../assets/success.mp3',
  fail: '../../assets/fail.mp3'
};
const EFFECT_VOLUME = 0.18;
const EFFECT_POOL_SIZE = 2;
const EFFECT_COOLDOWN_MS = 120;

function safeString(value) {
  if (value === undefined) return 'undefined';
  if (value === null) return 'null';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch (err) {
    return String(value);
  }
}

function getErrorText(err) {
  if (!err) return 'unknown error';
  if (err.message) return err.message;
  return safeString(err);
}

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(label + ' timeout after ' + ms + 'ms')), ms);
    promise.then((value) => {
      clearTimeout(timer);
      resolve(value);
    }).catch((err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function compactMs(ms) {
  const n = Number(ms || 0);
  if (!n) return '0ms';
  if (n >= 1000) return (n / 1000).toFixed(1) + 's';
  return Math.round(n) + 'ms';
}

function compactBytes(bytes) {
  const n = Number(bytes || 0);
  if (!n) return '';
  if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + 'MB';
  return Math.max(1, Math.round(n / 1024)) + 'KB';
}

function photoInfoText(bytes) {
  if (!bytes) return '';
  const info = getWebPInfoFromBytes(bytes);
  const size = compactBytes(bytes.byteLength);
  if (info && info.width && info.height) {
    return `${info.width}x${info.height} ${size}`;
  }
  const ext = getImageExtFromBytes(bytes);
  return `${ext} ${size}`;
}

function parseData(raw) {
  if (raw && raw.statusCode !== undefined && raw.data === undefined && raw.body === undefined) return raw;
  if (raw && raw.body !== undefined) return parseData(raw.body);
  if (raw && raw.data !== undefined && raw.found === undefined && raw.text === undefined) {
    return parseData(raw.data);
  }
  if (typeof raw === 'string') {
    try {
      return JSON.parse(raw);
    } catch (err) {
      return {};
    }
  }
  return raw || {};
}

function responseText(res) {
  if (!res) return 'no response';
  const data = res.data !== undefined ? res.data : (res.body !== undefined ? res.body : res);
  return safeString(data).slice(0, 180);
}

function stripTypedPrefix(text) {
  return String(text || '')
    .trim()
    .replace(/^(IMAGE|IMG|PIC|图片|图像)[:：]\s*/i, '')
    .replace(/^(VIDEO|MP4|MOV|视频)[:：]\s*/i, '')
    .replace(/^(AUDIO|MP3|M4A|音频|电台|直播)[:：]\s*/i, '');
}

function decodeText(value) {
  const text = String(value || '').replace(/\+/g, ' ');
  try {
    return decodeURIComponent(text);
  } catch (err) {
    return text;
  }
}

function isLeqiCipher(text) {
  return /^LQ1:/i.test(String(text || '').trim());
}

function decodeLeqiPayload(text) {
  const value = String(text || '').trim();
  const match = value.match(/^LQ1:([^.]+)\.([^.]+)\.([A-Za-z0-9_-]+)$/i);
  if (!match) throw new Error('bad lq1 payload');
  const nonce = match[1];
  const tag = match[2];
  const bytes = base64UrlDecode(match[3]);
  const seed = fnv32(LEQI_SECRET + '|' + nonce + '|' + tag);
  const plain = utf8FromBytes(xorBytes(bytes, seed));
  const expected = fnv32(plain + '|' + LEQI_SECRET + '|' + nonce).toString(36);
  if (expected !== tag) throw new Error('lq1 checksum mismatch');
  return plain;
}

function xorBytes(bytes, seed) {
  let state = seed >>> 0 || 0x6d2b79f5;
  const out = [];
  for (let i = 0; i < bytes.length; i++) {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    out.push(bytes[i] ^ (state & 255));
  }
  return out;
}

function fnv32(text) {
  let hash = 0x811c9dc5;
  const value = String(text || '');
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

function base64UrlDecode(text) {
  const value = String(text || '').replace(/-/g, '+').replace(/_/g, '/');
  const padded = value + '==='.slice((value.length + 3) % 4);
  const bytes = [];
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < padded.length; i++) {
    const ch = padded.charAt(i);
    if (ch === '=') break;
    const index = BASE64_CHARS.indexOf(ch);
    if (index < 0) continue;
    buffer = (buffer << 6) | index;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 255);
    }
  }
  return bytes;
}

function utf8FromBytes(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
    } else if (b0 >= 0xc0 && b0 < 0xe0) {
      const b1 = bytes[++i] || 0;
      out += String.fromCharCode(((b0 & 0x1f) << 6) | (b1 & 0x3f));
    } else if (b0 >= 0xe0 && b0 < 0xf0) {
      const b1 = bytes[++i] || 0;
      const b2 = bytes[++i] || 0;
      out += String.fromCharCode(((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f));
    } else {
      const b1 = bytes[++i] || 0;
      const b2 = bytes[++i] || 0;
      const b3 = bytes[++i] || 0;
      let code = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
      code -= 0x10000;
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    }
  }
  return out;
}

function trimLines(lines) {
  return lines
    .filter((item) => item !== undefined && item !== null && String(item).trim())
    .map((item) => String(item).trim())
    .join('\n');
}

function domainFromUrl(text) {
  const match = String(text || '').match(/^https?:\/\/([^/?#]+)/i);
  return match ? match[1].replace(/^www\./i, '') : '';
}

function isImageUrl(text) {
  const value = stripTypedPrefix(text);
  return /^https?:\/\/.+\.(png|jpe?g|webp|gif|bmp|svg)(\?.*)?$/i.test(value);
}

function isVideoUrl(text) {
  const value = stripTypedPrefix(text);
  return /^https?:\/\/.+\.(mp4|m3u8|mov|webm|m4v)(\?.*)?$/i.test(value);
}

function isAudioUrl(text) {
  const value = stripTypedPrefix(text);
  return /^https?:\/\/.+\.(mp3|m4a|aac|wav|ogg|flac)(\?.*)?$/i.test(value);
}

function isSvgUrl(text) {
  return /^https?:\/\/.+\.svg(?:[?#].*)?$/i.test(String(text || '').trim());
}

function imageDisplayUrl(text) {
  const url = stripTypedPrefix(text);
  if (!isSvgUrl(url)) return url;
  const withoutProtocol = url.replace(/^https?:\/\//i, '');
  return 'https://wsrv.nl/?url=' + encodeURIComponent(withoutProtocol) + '&output=png&w=900&bg=fff';
}

function isImagePayload(text) {
  return /^(IMAGE|IMG|PIC|图片|图像)[:：]/i.test(String(text || '').trim()) || isImageUrl(text);
}

function isVideoPayload(text) {
  return /^(VIDEO|MP4|MOV|视频)[:：]/i.test(String(text || '').trim()) || isVideoUrl(text);
}

function isAudioPayload(text) {
  return /^(AUDIO|MP3|M4A|音频|电台|直播)[:：]/i.test(String(text || '').trim()) || isAudioUrl(text);
}

function classifyQrText(text) {
  const value = String(text || '').trim();
  if (!value) return 'empty';
  if (isLeqiCipher(value)) return 'secret';
  if (/^\{/.test(value) && /"(title|body|message|text)"\s*:/.test(value)) return 'secret';
  if (isImagePayload(value)) return 'image';
  if (isVideoPayload(value)) return 'video';
  if (isAudioPayload(value)) return 'audio';
  if (/^https?:\/\//i.test(value)) return 'url';
  if (/^WIFI:/i.test(value)) return 'wifi';
  if (/^BEGIN:VCARD/i.test(value)) return 'contact';
  if (/^mailto:/i.test(value)) return 'email';
  if (/^tel:/i.test(value)) return 'phone';
  if (/^(SMSTO:|sms:)/i.test(value)) return 'sms';
  if (/^geo:/i.test(value)) return 'geo';
  if (/^BEGIN:VEVENT/i.test(value)) return 'event';
  if (/^(GLASS-SECRET|眼镜扫描仪)[:：]/i.test(value)) return 'secret';
  if (/^(GLASS-CARD|GLASS-NOTE|GLASS-LINK|眼镜卡片|眼镜密语)[:：]/i.test(value)) return 'secret';
  return 'text';
}

function summarizeQrText(text, type) {
  const value = String(text || '').trim();
  if (!value) return '二维码内容为空。';
  if (type === 'url') return '识别到网址，可用眼镜先看一眼。';
  if (type === 'wifi') return '这是一个 Wi-Fi 二维码。';
  if (type === 'contact') return '这是一个联系人二维码。';
  if (type === 'email') return '这是一个邮箱二维码。';
  if (type === 'phone') return '这是一个电话二维码。';
  if (type === 'sms') return '这是一个短信二维码。';
  if (type === 'geo') return '这是一个位置二维码。';
  if (type === 'event') return '这是一个日程二维码。';
  if (type === 'secret') return isLeqiCipher(value) ? '这是乐奇密文，已在眼镜里解码。' : '这是扫一扫密语，只显示在眼镜里。';
  if (type === 'image') return '识别到图片，已在眼镜中打开。';
  if (type === 'video') return '识别到视频，正在尝试播放。';
  if (type === 'audio') return '识别到音频，正在播放。';
  return '文字已识别。';
}

function cleanField(value) {
  return String(value || '').trim();
}

function leqiDecodeToJson(text) {
  const payload = secretPayload(text);
  if (!isLeqiCipher(payload)) return null;
  const plain = decodeLeqiPayload(payload);
  if (/^\s*\{/.test(plain)) {
    return JSON.parse(plain);
  }
  return {
    type: 'card',
    title: '乐奇密文',
    body: plain
  };
}

function buildDecodedCard(variant, title, subtitle, body, footnote) {
  return {
    variant,
    title: clampText(title || typeLabel(variant), 24),
    subtitle: clampText(subtitle || '', 34),
    body: clampText(body || '', 120),
    footnote: footnote || '单击继续扫描 · 双击退出'
  };
}

function leqiToResult(rawText, base) {
  if (!isLeqiCipher(secretPayload(rawText))) return null;
  const common = {
    ...(base || {}),
    found: true,
    provider: base && base.provider ? base.provider : 'rokid-barcode',
    rawPreview: 'LQ1 乐奇密文'
  };
  let json;
  try {
    json = leqiDecodeToJson(rawText);
  } catch (err) {
    return {
      ...common,
      text: rawText,
      type: 'secret',
      summary: '这枚乐奇密文暂时无法解开。',
      decodedCard: buildDecodedCard(
        'secret',
        '密文无法解码',
        '',
        '这枚二维码不是当前版本的乐奇密文，或内容已经损坏。',
        '单击再扫一次 · 双击退出'
      )
    };
  }

  const kind = cleanField(json && json.type).toLowerCase();
  if (kind === 'image') {
    const url = cleanField(json.url || json.src || json.body || json.text);
    const renderUrl = cleanField(json.renderUrl || json.displayUrl || json.imageUrl) || imageDisplayUrl(url);
    return {
      ...common,
      text: renderUrl,
      type: 'image',
      summary: cleanField(json.title) || '识别到图片，已在眼镜中打开。',
      decodedCard: buildDecodedCard('image', cleanField(json.title) || '图片', domainFromUrl(url) || '图片链接', url, '单击继续扫描 · 双击退出')
    };
  }
  if (kind === 'url' || kind === 'link') {
    const url = cleanField(json.url || json.href || json.body || json.text);
    return {
      ...common,
      text: url,
      type: 'url',
      summary: '识别到网址，可用眼镜先看一眼。',
      decodedCard: buildDecodedCard(
        'url',
        cleanField(json.title) || domainFromUrl(url) || '网址',
        cleanField(json.subtitle) || '网站名称 / 功能',
        url,
        '先看清来源，再决定是否用手机打开'
      )
    };
  }
  if (kind === 'wifi') {
    const ssid = cleanField(json.ssid);
    const auth = cleanField(json.auth || json.encryption || json.t) || 'WPA';
    const password = cleanField(json.password || json.pass || json.p);
    return {
      ...common,
      text: `WIFI:T:${auth};S:${ssid};P:${password};H:${json.hidden ? 'true' : 'false'};;`,
      type: 'wifi',
      summary: '这是一个 Wi-Fi 二维码。',
      decodedCard: buildDecodedCard(
        'wifi',
        ssid || 'Wi-Fi 网络',
        auth === 'nopass' ? '免密码' : auth,
        trimLines([
          password ? `密码：${password}` : '没有密码字段',
          json.hidden ? '隐藏网络：是' : ''
        ]),
        '请在手机或路由器设置里手动连接'
      )
    };
  }
  if (kind === 'contact' || kind === 'vcard') {
    const name = cleanField(json.name || json.fn);
    const org = cleanField(json.org || json.company);
    const tel = cleanField(json.tel || json.phone);
    const email = cleanField(json.email || json.mail);
    return {
      ...common,
      text: trimLines(['BEGIN:VCARD', 'VERSION:3.0', `FN:${name}`, org ? `ORG:${org}` : '', tel ? `TEL:${tel}` : '', email ? `EMAIL:${email}` : '', 'END:VCARD']),
      type: 'contact',
      summary: '这是一个联系人二维码。',
      decodedCard: buildDecodedCard('contact', name || '联系人', org || '名片二维码', trimLines([tel ? `电话：${tel}` : '', email ? `邮箱：${email}` : '']), '单击继续扫描 · 双击退出')
    };
  }
  if (kind === 'phone') {
    const tel = cleanField(json.tel || json.phone);
    return {
      ...common,
      text: `tel:${tel}`,
      type: 'phone',
      summary: '这是一个电话二维码。',
      decodedCard: buildDecodedCard('phone', tel || '电话号码', '电话号码', '请在手机上拨打或保存', '单击继续扫描 · 双击退出')
    };
  }
  if (kind === 'sms') {
    const tel = cleanField(json.tel || json.phone);
    const body = cleanField(json.body || json.message || json.text);
    return {
      ...common,
      text: `SMSTO:${tel}:${body}`,
      type: 'sms',
      summary: '这是一个短信二维码。',
      decodedCard: buildDecodedCard('sms', tel || '短信', '短信二维码', body || '没有短信正文', '单击继续扫描 · 双击退出')
    };
  }
  if (kind === 'email' || kind === 'mail') {
    const to = cleanField(json.to || json.email);
    const subject = cleanField(json.subject);
    const body = cleanField(json.body || json.message || json.text);
    const query = trimLines([subject ? `subject=${encodeURIComponent(subject)}` : '', body ? `body=${encodeURIComponent(body)}` : '']).replace(/\n/g, '&');
    return {
      ...common,
      text: `mailto:${to}${query ? '?' + query : ''}`,
      type: 'email',
      summary: '这是一个邮箱二维码。',
      decodedCard: buildDecodedCard('email', to || '邮箱', subject || '邮件地址', body || '可在手机上发邮件', '单击继续扫描 · 双击退出')
    };
  }
  if (kind === 'place' || kind === 'geo' || kind === 'location') {
    const title = cleanField(json.label || json.title || json.name) || '目的地';
    const address = cleanField(json.address || json.note);
    const lat = cleanField(json.lat || json.latitude);
    const lng = cleanField(json.lng || json.lon || json.longitude);
    const coords = lat && lng ? `${lat},${lng}` : '';
    return {
      ...common,
      text: coords ? `geo:${coords}?q=${encodeURIComponent(title)}` : title,
      type: 'geo',
      summary: '这是一个位置二维码。',
      decodedCard: buildDecodedCard(
        'geo',
        title,
        address || coords || '目的地',
        coords ? `坐标：${coords}` : '当前先显示地点信息，未来可接入眼镜导航。',
        '导航能力接入后可一键前往'
      )
    };
  }
  if (kind === 'event' || kind === 'calendar') {
    const title = cleanField(json.title || json.summary) || '日程';
    const start = cleanField(json.start);
    const end = cleanField(json.end);
    const location = cleanField(json.location || json.address);
    return {
      ...common,
      text: trimLines(['BEGIN:VEVENT', `SUMMARY:${title}`, start ? `DTSTART:${start}` : '', end ? `DTEND:${end}` : '', location ? `LOCATION:${location}` : '', 'END:VEVENT']),
      type: 'event',
      summary: '这是一个日程二维码。',
      decodedCard: buildDecodedCard('event', title, formatEventRange(start, end), location ? `地点：${location}` : '没有地点字段', '单击继续扫描 · 双击退出')
    };
  }

  const body = cleanField(json.body || json.text || json.message || '');
  return {
    ...common,
    text: body,
    type: 'secret',
    summary: '这是乐奇密文，已在眼镜里解码。',
    decodedCard: buildDecodedCard(
      'secret',
      cleanField(json.title) || '乐奇密文',
      '乐奇专属',
      body,
      BRAND_FOOTNOTE
    )
  };
}

function normalizeDecodeResult(data) {
  const raw = parseData(data);
  if (raw && raw.found !== undefined) {
    const rawText = String(raw.text || '').trim();
    const leqi = leqiToResult(rawText, raw);
    if (leqi) return leqi;
    const rawType = classifyQrText(rawText);
    return {
      ...raw,
      text: stripTypedPrefix(rawText),
      type: rawType,
      summary: summarizeQrText(rawText, rawType),
      rawPreview: raw.rawPreview || safeString(raw).slice(0, 100)
    };
  }
  const result = raw && (raw.result || raw.data || raw.text || raw.content);
  const text = typeof result === 'string' ? result.trim() : '';
  const leqi = leqiToResult(text, { provider: raw && raw.provider ? raw.provider : 'fallback-service' });
  if (leqi) return leqi;
  const type = classifyQrText(text);
  return {
    found: !!text,
    text: stripTypedPrefix(text),
    type,
    summary: text ? summarizeQrText(text, type) : '没有识别到二维码。',
    provider: raw && raw.provider ? raw.provider : 'fallback-service',
    rawPreview: safeString(data).slice(0, 90)
  };
}

function normalizeBarcodeResult(barcode) {
  const text = String(barcode && barcode.rawValue || '').trim();
  const leqi = leqiToResult(text, {
    provider: 'rokid-barcode',
    rawFormat: barcode && barcode.format ? barcode.format : 'unknown',
    boundingBox: barcode && barcode.boundingBox,
    cornerPoints: barcode && barcode.cornerPoints
  });
  if (leqi) return leqi;
  const type = classifyQrText(text);
  return {
    found: !!text,
    text: stripTypedPrefix(text),
    type,
    summary: text ? summarizeQrText(text, type) : '没有识别到二维码。',
    provider: 'rokid-barcode',
    rawFormat: barcode && barcode.format ? barcode.format : 'unknown',
    boundingBox: barcode && barcode.boundingBox,
    cornerPoints: barcode && barcode.cornerPoints,
    rawPreview: text ? `Rokid Barcode ${barcode && barcode.format ? barcode.format : 'unknown'}` : 'Rokid Barcode empty'
  };
}

function isImageDataLike(value) {
  return !!(value && value.width && value.height && value.data && value.data.length);
}

function toImageData(value) {
  if (!isImageDataLike(value)) return null;
  const width = Number(value.width);
  const height = Number(value.height);
  if (!width || !height) return null;
  const data = value.data instanceof Uint8ClampedArray ? value.data : new Uint8ClampedArray(value.data);
  if (data.length < width * height * 4) return null;
  if (typeof ImageData !== 'undefined') return new ImageData(data, width, height);
  return { data, width, height };
}

function toPlainImageData(value) {
  if (!isImageDataLike(value)) return null;
  const width = Number(value.width);
  const height = Number(value.height);
  if (!width || !height) return null;
  const data = value.data instanceof Uint8ClampedArray ? value.data : new Uint8ClampedArray(value.data);
  if (data.length < width * height * 4) return null;
  return { data, width, height };
}

function imagePixelStats(value) {
  const image = toPlainImageData(value);
  if (!image) return 'no-pixels';
  const data = image.data;
  const step = Math.max(4, Math.floor(data.length / 1600 / 4) * 4);
  let min = 255;
  let max = 0;
  let sum = 0;
  let count = 0;
  for (let i = 0; i < data.length; i += step) {
    const gray = Math.round((data[i] + data[i + 1] + data[i + 2]) / 3);
    if (gray < min) min = gray;
    if (gray > max) max = gray;
    sum += gray;
    count++;
  }
  const avg = count ? Math.round(sum / count) : 0;
  return `${image.width}x${image.height} g${min}-${max}/${avg}`;
}

function makeBinaryImageData(value) {
  const image = toPlainImageData(value);
  if (!image) return null;
  const input = image.data;
  const output = new Uint8ClampedArray(input.length);
  let sum = 0;
  let count = 0;
  for (let i = 0; i < input.length; i += 4) {
    sum += Math.round((input[i] + input[i + 1] + input[i + 2]) / 3);
    count++;
  }
  const threshold = count ? Math.max(72, Math.min(184, Math.round(sum / count))) : 128;
  for (let i = 0; i < input.length; i += 4) {
    const gray = Math.round((input[i] + input[i + 1] + input[i + 2]) / 3);
    const value2 = gray < threshold ? 0 : 255;
    output[i] = value2;
    output[i + 1] = value2;
    output[i + 2] = value2;
    output[i + 3] = 255;
  }
  return { data: output, width: image.width, height: image.height };
}

function isArrayBufferLike(value) {
  return !!(value && value.byteLength !== undefined);
}

function bytesFromBinary(value) {
  if (!value) return null;
  if (value instanceof Uint8Array) return value;
  if (isArrayBufferLike(value)) return new Uint8Array(value);
  if (value.buffer && value.byteLength !== undefined) return new Uint8Array(value.buffer, value.byteOffset || 0, value.byteLength);
  return null;
}

function exactArrayBuffer(bytes) {
  if (!bytes) return null;
  if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) return bytes.buffer;
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function imageExtFromBytes(bytes) {
  if (!bytes || bytes.length < 12) return 'jpg';
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return 'jpg';
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'png';
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46) return 'webp';
  return 'jpg';
}

function imageMimeFromExt(ext) {
  if (ext === 'png') return 'image/png';
  if (ext === 'webp') return 'image/webp';
  return 'image/jpeg';
}

function stripDataUrl(value) {
  return String(value || '').replace(/^data:image\/\w+;base64,/i, '');
}

function base64LooksLikeImage(value) {
  const text = stripDataUrl(value).slice(0, 16);
  return /^\/9j\//.test(text) || /^iVBORw0KGgo/.test(text) || /^UklGR/.test(text);
}

function bytesToBase64(bytes) {
  let output = '';
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    output += BASE64_CHARS[bytes[i] >> 2];
    output += BASE64_CHARS[((bytes[i] & 3) << 4) | (bytes[i + 1] >> 4)];
    output += BASE64_CHARS[((bytes[i + 1] & 15) << 2) | (bytes[i + 2] >> 6)];
    output += BASE64_CHARS[bytes[i + 2] & 63];
  }
  if (i < bytes.length) {
    output += BASE64_CHARS[bytes[i] >> 2];
    if (i + 1 < bytes.length) {
      output += BASE64_CHARS[((bytes[i] & 3) << 4) | (bytes[i + 1] >> 4)];
      output += BASE64_CHARS[(bytes[i + 1] & 15) << 2];
      output += '=';
    } else {
      output += BASE64_CHARS[(bytes[i] & 3) << 4];
      output += '==';
    }
  }
  return output;
}

function arrayBufferToBase64(buffer) {
  return bytesToBase64(new Uint8Array(buffer));
}

function isBackKey(key) {
  const code = String(key || '');
  return code === 'Backspace' || code === 'BrowserBack' || code === 'GoBack' ||
    code === 'Escape' || code === '8' || code.toLowerCase() === 'back';
}

function isEnterKey(key) {
  const code = String(key || '');
  return code === 'Enter' || code === '13' || code.toLowerCase() === 'ok' ||
    code.toLowerCase() === 'center';
}

function resultDetail(result) {
  if (!result) return '无返回结果';
  const provider = result.provider || 'unknown';
  const requestId = result.requestId ? String(result.requestId).slice(0, 8) : 'no-id';
  const size = result.imgSize && (result.imgSize.Wide || result.imgSize.High)
    ? `${result.imgSize.Wide || '?'}x${result.imgSize.High || '?'}`
    : '';
  const base = size ? `${provider} ${size} ${requestId}` : `${provider} ${requestId}`;
  return result.rawPreview ? `${base} ${result.rawPreview}` : base;
}

function photoKeys(photo) {
  return photo && typeof photo === 'object' ? Object.keys(photo).join(',') : typeof photo;
}

function valueShape(value) {
  if (value === undefined) return 'undefined';
  if (value === null) return 'null';
  if (typeof value === 'string') return `string:${value.length}`;
  if (value instanceof Uint8Array) return `Uint8Array:${value.byteLength}`;
  if (value instanceof Uint8ClampedArray) return `Uint8ClampedArray:${value.byteLength}`;
  if (value && value.byteLength !== undefined) return `byteLength:${value.byteLength}`;
  if (value && value.length !== undefined) return `length:${value.length}`;
  if (value && value.buffer && value.byteLength !== undefined) return `buffer:${value.byteLength}`;
  return typeof value;
}

function photoShape(photo) {
  if (!photo || typeof photo !== 'object') return String(typeof photo);
  const keys = Object.keys(photo);
  const parts = keys.slice(0, 8).map((key) => `${key}=${valueShape(photo[key])}`);
  return parts.join(' ');
}

function typeLabel(type) {
  if (type === 'url') return '网址';
  if (type === 'wifi') return 'Wi-Fi';
  if (type === 'contact') return '联系人';
  if (type === 'email') return '邮箱';
  if (type === 'phone') return '电话';
  if (type === 'sms') return '短信';
  if (type === 'geo') return '位置';
  if (type === 'event') return '日程';
  if (type === 'secret') return '密语';
  if (type === 'image') return '图片';
  if (type === 'video') return '视频';
  if (type === 'audio') return '音频';
  if (type === 'text') return '文字';
  return '未识别';
}

function secretPayload(text) {
  const value = String(text || '').trim();
  return value
    .replace(/^(GLASS-CARD|GLASS-SECRET|GLASS-NOTE|GLASS-LINK|眼镜卡片|眼镜密语|眼镜扫描仪)[:：]\s*/i, '')
    .trim();
}

function clampText(text, max) {
  const value = String(text || '').trim();
  return value.length > max ? value.slice(0, max - 1) + '…' : value;
}

function parseWifi(text) {
  const body = String(text || '').replace(/^WIFI:/i, '').replace(/;;$/, '');
  const out = {};
  body.split(';').forEach((part) => {
    const index = part.indexOf(':');
    if (index <= 0) return;
    out[part.slice(0, index).toUpperCase()] = part.slice(index + 1).replace(/\\;/g, ';').replace(/\\:/g, ':');
  });
  return {
    variant: 'wifi',
    title: out.S || 'Wi-Fi 网络',
    subtitle: out.T && out.T !== 'nopass' ? out.T : '免密码或未知加密',
    body: trimLines([
      out.P ? `密码：${out.P}` : '没有密码字段',
      out.H === 'true' ? '隐藏网络：是' : ''
    ]),
    footnote: '请在手机或路由器设置里手动连接'
  };
}

function vcardField(text, names) {
  const lines = String(text || '').split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const key = line.split(':')[0].split(';')[0].toUpperCase();
    if (names.indexOf(key) >= 0) return line.slice(line.indexOf(':') + 1).trim();
  }
  return '';
}

function parseVcard(text) {
  const name = vcardField(text, ['FN']) || vcardField(text, ['N']).replace(/;/g, ' ');
  const org = vcardField(text, ['ORG']);
  const tel = vcardField(text, ['TEL']);
  const email = vcardField(text, ['EMAIL']);
  return {
    variant: 'contact',
    title: name || '联系人',
    subtitle: org || '名片二维码',
    body: trimLines([tel ? `电话：${tel}` : '', email ? `邮箱：${email}` : '']),
    footnote: '单击继续扫描 · 双击退出'
  };
}

function parseMail(text) {
  const raw = String(text || '').replace(/^mailto:/i, '');
  const parts = raw.split('?');
  const to = decodeText(parts[0] || '');
  const query = parts[1] || '';
  const subjectMatch = query.match(/(?:^|&)subject=([^&]+)/i);
  const bodyMatch = query.match(/(?:^|&)body=([^&]+)/i);
  return {
    variant: 'email',
    title: to || '邮箱',
    subtitle: subjectMatch ? decodeText(subjectMatch[1]) : '邮件地址',
    body: bodyMatch ? decodeText(bodyMatch[1]).slice(0, 90) : '可在手机上发邮件',
    footnote: '单击继续扫描 · 双击退出'
  };
}

function parsePhone(text) {
  return {
    variant: 'phone',
    title: String(text || '').replace(/^tel:/i, '').trim(),
    subtitle: '电话号码',
    body: '请在手机上拨打或保存',
    footnote: '单击继续扫描 · 双击退出'
  };
}

function parseSms(text) {
  const value = String(text || '').trim();
  let number = '';
  let body = '';
  if (/^SMSTO:/i.test(value)) {
    const parts = value.replace(/^SMSTO:/i, '').split(':');
    number = parts[0] || '';
    body = parts.slice(1).join(':');
  } else {
    const raw = value.replace(/^sms:/i, '');
    const parts = raw.split('?');
    number = parts[0] || '';
    const match = (parts[1] || '').match(/(?:^|&)body=([^&]+)/i);
    body = match ? decodeText(match[1]) : '';
  }
  return {
    variant: 'sms',
    title: number || '短信',
    subtitle: '短信二维码',
    body: body || '没有短信正文',
    footnote: '单击继续扫描 · 双击退出'
  };
}

function parseGeo(text) {
  const value = String(text || '').replace(/^geo:/i, '');
  const coords = value.split('?')[0];
  const query = value.match(/[?&]q=([^&]+)/i);
  return {
    variant: 'geo',
    title: query ? decodeText(query[1]) : '位置',
    subtitle: coords || '地理位置',
    body: '可在地图里搜索这个位置',
    footnote: '单击继续扫描 · 双击退出'
  };
}

function eventField(text, name) {
  const re = new RegExp('^' + name + '(?:;[^:]*)?:(.*)$', 'im');
  const match = String(text || '').match(re);
  return match ? match[1].trim() : '';
}

function dateParts(value) {
  const text = String(value || '').trim();
  const match = text.match(/^(\d{4})-?(\d{2})-?(\d{2})(?:T?(\d{2}):?(\d{2})(?::?(\d{2}))?)?/);
  if (!match) return null;
  return {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
    hour: match[4] !== undefined ? Number(match[4]) : null,
    minute: match[5] !== undefined ? Number(match[5]) : null
  };
}

function formatDatePart(parts, withYear) {
  if (!parts) return '';
  const date = withYear ? `${parts.year}年${parts.month}月${parts.day}日` : `${parts.month}月${parts.day}日`;
  if (parts.hour === null) return date;
  return `${date} ${String(parts.hour).padStart(2, '0')}:${String(parts.minute || 0).padStart(2, '0')}`;
}

function formatEventRange(start, end) {
  const s = dateParts(start);
  const e = dateParts(end);
  if (!s && !e) return '';
  if (s && e && s.year === e.year && s.month === e.month && s.day === e.day) {
    const head = formatDatePart(s, true);
    if (e.hour === null) return head;
    return `${head} - ${String(e.hour).padStart(2, '0')}:${String(e.minute || 0).padStart(2, '0')}`;
  }
  return trimLines([formatDatePart(s, true), e ? `至 ${formatDatePart(e, true)}` : '']).replace(/\n/g, ' ');
}

function parseEvent(text) {
  const title = eventField(text, 'SUMMARY') || '日程';
  const start = eventField(text, 'DTSTART');
  const end = eventField(text, 'DTEND');
  const location = eventField(text, 'LOCATION');
  return {
    variant: 'event',
    title,
    subtitle: formatEventRange(start, end),
    body: location ? `地点：${location}` : '没有地点字段',
    footnote: '单击继续扫描 · 双击退出'
  };
}

function parseSecret(text) {
  let body = secretPayload(text);
  let isCipher = false;
  if (isLeqiCipher(body)) {
    isCipher = true;
    try {
      body = decodeLeqiPayload(body);
    } catch (err) {
      return {
        variant: 'secret',
        title: '密文无法解码',
        subtitle: '',
        body: '这枚二维码不是当前版本的乐奇密文，或内容已经损坏。',
        footnote: '单击继续扫描 · 双击退出'
      };
    }
  }
  if (/^\{/.test(body)) {
    try {
      const json = JSON.parse(body);
      if (json.type === 'url' || json.url) {
        const url = json.url || json.body || json.text || '';
        return {
          variant: 'url',
          title: clampText(json.title || domainFromUrl(url) || '网址', 18),
          subtitle: clampText(json.subtitle || '网站名称 / 功能', 22),
          body: clampText(url, 96),
          footnote: '先看清来源，再决定是否用手机打开'
        };
      }
      return {
        variant: 'secret',
        title: clampText(json.title || (isCipher ? '乐奇密文' : '眼镜密语'), 18),
        subtitle: isCipher ? '乐奇专属' : '',
        body: clampText(json.body || json.text || json.message || '', 82),
        footnote: BRAND_FOOTNOTE
      };
    } catch (err) {}
  }
  return {
    variant: 'secret',
    title: isCipher ? '乐奇密文' : '眼镜密语',
    subtitle: isCipher ? '乐奇专属' : '',
    body: clampText(body || String(text || ''), 86),
    footnote: BRAND_FOOTNOTE
  };
}

function buildCard(text, type, result) {
  if (result && result.decodedCard) return result.decodedCard;
  const value = String(text || '').trim();
  if (!value) {
    return {
      variant: 'empty',
      title: '没有扫到',
      subtitle: '调整一下角度',
      body: '让二维码对准中间，靠近一点，避开反光后再扫一次。',
      footnote: '单击再扫一次 · 双击退出'
    };
  }
  if (type === 'wifi') return parseWifi(value);
  if (type === 'contact') return parseVcard(value);
  if (type === 'email') return parseMail(value);
  if (type === 'phone') return parsePhone(value);
  if (type === 'sms') return parseSms(value);
  if (type === 'geo') return parseGeo(value);
  if (type === 'event') return parseEvent(value);
  if (type === 'secret') return parseSecret(value);
  if (type === 'url') {
    return {
      variant: 'url',
      title: domainFromUrl(value) || '网址',
      subtitle: /^https:\/\//i.test(value) ? 'HTTPS 链接' : 'HTTP 链接',
      body: value,
      footnote: '先看清来源，再决定是否用手机打开'
    };
  }
  return {
    variant: 'text',
    title: '',
    subtitle: result && result.summary ? result.summary : '二维码内容',
    body: clampText(value, 150),
    footnote: '单击继续扫描 · 双击退出'
  };
}

function cardTheme(type) {
  if (type === 'secret') {
    return {
      accent: '#40ff5e',
      border: 'rgba(64,255,94,0.72)',
      panel: 'transparent',
      label: '眼镜专属'
    };
  }
  if (type === 'wifi') {
    return {
      accent: '#8effa2',
      border: 'rgba(142,255,162,0.55)',
      panel: 'transparent',
      label: '无线网络'
    };
  }
  if (type === 'url') {
    return {
      accent: '#9fffb1',
      border: 'rgba(159,255,177,0.48)',
      panel: 'transparent',
      label: '链接'
    };
  }
  if (type === 'contact') {
    return {
      accent: '#d7ffd9',
      border: 'rgba(215,255,217,0.42)',
      panel: 'transparent',
      label: '名片'
    };
  }
  if (type === 'phone' || type === 'email' || type === 'sms') {
    return {
      accent: '#c8ffd0',
      border: 'rgba(200,255,208,0.42)',
      panel: 'transparent',
      label: typeLabel(type)
    };
  }
  if (type === 'geo' || type === 'event') {
    return {
      accent: '#b8ffc4',
      border: 'rgba(184,255,196,0.42)',
      panel: 'transparent',
      label: typeLabel(type)
    };
  }
  return {
    accent: '#40ff5e',
    border: 'rgba(64,255,94,0.48)',
    panel: 'transparent',
    label: typeLabel(type).toUpperCase()
  };
}

function buildA2uiCommands(card, type) {
  const theme = cardTheme(type);
  const title = clampText(card.title || typeLabel(type), 18);
  const subtitle = type === 'secret' ? '' : clampText(card.subtitle || '', 28);
  const body = clampText(card.body || '', type === 'url' ? 72 : 62);
  const footnote = type === 'secret' ? BRAND_FOOTNOTE : clampText(card.footnote || '单击继续扫描 · 双击退出', 32);
  const cardChildren = type === 'secret'
    ? ['top', 'title', 'bodybox', 'footnote']
    : ['top', 'title', 'subtitle', 'bodybox', 'footnote'];
  return JSON.stringify([
    {
      type: 'createSurface',
      surfaceId: 'qr-surface',
      containerId: 'root'
    },
    {
      type: 'updateComponents',
      surfaceId: 'qr-surface',
      components: [
        {
          id: 'root',
          type: 'view',
          props: {
            style: 'display: flex; flex-direction: column; justify-content: center; align-items: center; width: 100%; height: 100%; background-color: transparent;'
          },
          children: ['card']
        },
        {
          id: 'card',
          type: 'view',
          props: {
            style: `display: flex; flex-direction: column; width: 449px; min-height: 204px; box-sizing: border-box; padding: 16px 17px; border: 1.5px solid ${theme.border}; border-radius: 18px; background-color: transparent;`
          },
          children: cardChildren
        },
        {
          id: 'top',
          type: 'view',
          props: {
            style: 'display: flex; flex-direction: row; align-items: center; justify-content: space-between; margin-bottom: 8px;'
          },
          children: ['badge', 'type']
        },
        {
          id: 'badge',
          type: 'text',
          props: {
            content: theme.label,
            style: `font-size: 16px; line-height: 22px; font-weight: 800; color: ${theme.accent}; background-color: transparent; border: 1px solid ${theme.border}; border-radius: 12px; padding: 3px 9px;`
          }
        },
        {
          id: 'type',
          type: 'text',
          props: {
            content: typeLabel(type),
            style: `font-size: 16px; line-height: 22px; font-weight: 800; color: ${theme.accent};`
          }
        },
        {
          id: 'title',
          type: 'text',
          props: {
            content: title,
            style: 'font-size: 30px; line-height: 38px; font-weight: 800; color: #ffffff;'
          }
        },
        {
          id: 'subtitle',
          type: 'text',
          props: {
            content: subtitle,
            style: `font-size: 18px; line-height: 25px; color: ${theme.accent}; margin-top: 4px;`
          }
        },
        {
          id: 'bodybox',
          type: 'view',
          props: {
            style: `display: flex; flex-direction: column; margin-top: 13px; padding: 12px; border-radius: 14px; background-color: ${theme.panel}; border: 1px solid ${theme.border};`
          },
          children: ['body']
        },
        {
          id: 'body',
          type: 'text',
          props: {
            content: body,
            style: 'font-size: 21px; line-height: 30px; font-weight: 700; color: #ffffff;'
          }
        },
        {
          id: 'footnote',
          type: 'text',
          props: {
            content: footnote,
            style: 'font-size: 16px; line-height: 22px; color: #8fb89a; margin-top: 10px;'
          }
        }
      ]
    }
  ]);
}

function mediaModeFor(type) {
  if (type === 'image') return 'image';
  if (type === 'video') return 'video';
  if (type === 'audio') return 'audio';
  return 'text';
}

export default {
  data: {
    stageText: '请您看向二维码',
    statusText: '单击镜腿扫描',
    secretText: '双击退出',
    typeText: '准备',
    summaryText: '单击镜腿扫描',
    detailText: '双击退出',
    displayMode: 'intro',
    mediaMode: 'text',
    mediaUrl: '',
    cardVariant: 'text',
    cardTitle: '请您看向二维码',
    cardSubtitle: '单击镜腿扫描',
    cardBody: '双击退出',
    cardFootnote: '',
    a2uiCommands: '',
    showChrome: false,
    showFooter: false,
    showTopbar: true,
    showImageView: false,
    footerHintText: '单击扫描 · 双击退出',
    exitConfirm: false,
    audioHintText: '',
    debugText: '等待诊断',
    endpointText: DEFAULT_ENDPOINT,
    versionText: `v${APP_VERSION}`,
    copyrightText: COPYRIGHT_TEXT,
    autoExitText: '双击退出',
    showCamera: false,
    showTextLayer: false,
    decodeHintText: '乐奇正在解码',
    decodeMark: '|',
    decodeStepText: '正在启动相机',
    decodeProgressWidth: 52,
    busy: false,
    autoExitSeconds: 0
  },

  onLoad(query) {
    const data = query && query.data ? query.data : query || {};
    this.endpoint = String(data.endpoint || DEFAULT_ENDPOINT).trim();
    this.decodeProvider = String(data.provider || DEFAULT_PROVIDER).trim() || DEFAULT_PROVIDER;
    this.audioPlayer = null;
    this.cameraCtx = null;
    this.barcodeDetector = null;
    this.currentAudioUrl = '';
    this.exiting = false;
    this.setupEffectAudio();
    this.attachRuntimeAdapters();
    this.setData({ endpointText: this.decodeProvider === 'cloud' && this.endpoint ? this.endpoint : 'Rokid BarcodeDetector' });
  },

  onUnload() {
    this.detachRuntimeAdapters();
    this.clearTimers();
    this.stopAudio();
    this.destroyEffectAudio();
  },

  onRootTap() {
    const now = Date.now();
    const isDoubleTap = !!(this.lastTapAt && now - this.lastTapAt < DOUBLE_TAP_MS);
    if (this.exiting) {
      this.runExitApis();
      return;
    }
    if (this.data.exitConfirm) {
      if (isDoubleTap || (this.confirmTapAt && now - this.confirmTapAt < DOUBLE_TAP_MS)) {
        this.confirmTapAt = 0;
        this.lastTapAt = 0;
        if (this.confirmCancelTimer) {
          clearTimeout(this.confirmCancelTimer);
          this.confirmCancelTimer = null;
        }
        this.exitAgent();
        return;
      }
      this.confirmTapAt = now;
      this.lastTapAt = now;
      if (this.confirmCancelTimer) clearTimeout(this.confirmCancelTimer);
      this.confirmCancelTimer = setTimeout(() => {
        if (!this.data.exitConfirm || this.confirmTapAt !== now) return;
        this.cancelExitConfirm();
      }, DOUBLE_TAP_MS + 120);
      return;
    }
    if (isDoubleTap) {
      if (this.tapActionTimer) {
        clearTimeout(this.tapActionTimer);
        this.tapActionTimer = null;
      }
      this.lastTapAt = 0;
      this.confirmTapAt = 0;
      this.showExitConfirm();
      return;
    }
    this.lastTapAt = now;
    if (this.tapActionTimer) clearTimeout(this.tapActionTimer);
    this.tapActionTimer = setTimeout(() => {
      this.tapActionTimer = null;
      if (this.exiting || this.data.exitConfirm) return;
      this.handlePrimaryTapAction();
    }, DOUBLE_TAP_MS + 30);
  },

  handlePrimaryTapAction() {
    const audioUrl = this.currentAudioUrl || (this.data && this.data.displayMode === 'audio' ? this.data.mediaUrl : '');
    if (audioUrl) {
      this.playAudio(audioUrl, 'tap');
      return;
    }
    this.scan();
  },

  onMessage(event) {
    const payload = event && event.data ? event.data : event;
    const type = String(payload && (payload.type || payload.event || payload.name || payload.action) || '');
    if (/double.?tap|temple\.doubleTap|double_click/i.test(type)) {
      this.handleExitGesture();
      return;
    }
    if (payload && payload.type === 'voice' && /退出/.test(String(payload.text || ''))) {
      this.handleExitGesture();
    }
  },

  handleExitGesture() {
    if (this.exiting) {
      this.runExitApis();
      return;
    }
    if (this.data.exitConfirm) {
      this.exitAgent();
      return;
    }
    this.showExitConfirm();
  },

  showExitConfirm() {
    if (this.exiting) return;
    this.confirmTapAt = 0;
    this.lastTapAt = 0;
    if (this.tapActionTimer) {
      clearTimeout(this.tapActionTimer);
      this.tapActionTimer = null;
    }
    if (this.confirmCancelTimer) {
      clearTimeout(this.confirmCancelTimer);
      this.confirmCancelTimer = null;
    }
    this.stopDecodeAnimation();
    if (!this.exitUiSnapshot) {
      this.exitUiSnapshot = {
        displayMode: this.data.displayMode,
        showChrome: this.data.showChrome,
        showFooter: this.data.showFooter,
        showTopbar: this.data.showTopbar,
        showCamera: this.data.showCamera,
        showTextLayer: this.data.showTextLayer,
        showImageView: this.data.showImageView,
        mediaMode: this.data.mediaMode,
        mediaUrl: this.data.mediaUrl,
        busy: this.data.busy,
        autoExitText: this.data.autoExitText
      };
    }
    this.setData({
      exitConfirm: true,
      displayMode: 'exit-clear',
      showChrome: false,
      showFooter: false,
      showTopbar: false,
      showCamera: false,
      showTextLayer: false,
      showImageView: false,
      busy: false,
      autoExitText: '双击两次退出'
    });
  },

  cancelExitConfirm() {
    this.confirmTapAt = 0;
    this.lastTapAt = 0;
    if (this.confirmCancelTimer) {
      clearTimeout(this.confirmCancelTimer);
      this.confirmCancelTimer = null;
    }
    const snapshot = this.exitUiSnapshot || {};
    this.exitUiSnapshot = null;
    this.setData(Object.assign({
      exitConfirm: false,
      showTopbar: true,
      autoExitText: '双击退出'
    }, snapshot));
  },

  onVoiceWakeup() {
    this.scan();
  },

  onKeyDown(event) {
    const key = event && (event.key || event.code || event.keyCode);
    if (isBackKey(key)) {
      this.handleExitGesture();
      return;
    }
    if (isEnterKey(key)) {
      if (this.data.exitConfirm) {
        this.cancelExitConfirm();
        return;
      }
      this.scan();
    }
  },

  attachRuntimeAdapters() {
    this.detachRuntimeAdapters();
    this.runtimeDisposers = [];
    const root = typeof globalThis !== 'undefined' ? globalThis : {};
    const temple =
      root.aiui && root.aiui.temple ? root.aiui.temple :
      root.rokid && root.rokid.temple ? root.rokid.temple :
      wx && wx.temple ? wx.temple :
      null;
    if (temple && temple.onDoubleTap) {
      const off = temple.onDoubleTap(() => this.handleExitGesture());
      if (off) this.runtimeDisposers.push(off);
    }
  },

  detachRuntimeAdapters() {
    if (!this.runtimeDisposers) return;
    this.runtimeDisposers.forEach((dispose) => {
      try {
        if (typeof dispose === 'function') dispose();
      } catch (err) {}
    });
    this.runtimeDisposers = [];
  },

  setupEffectAudio() {
    this.effectPools = {};
    this.effectLastFireAt = {};
    this.effectAudioReady = typeof AudioPlayer !== 'undefined';
  },

  destroyEffectAudio() {
    if (!this.effectPools) return;
    Object.keys(this.effectPools).forEach((key) => {
      const entry = this.effectPools[key];
      const players = entry && entry.players ? entry.players : [];
      players.forEach((player) => {
        try {
          if (player && player.pause) player.pause();
        } catch (err) {}
        try {
          if (player && player.destroy) player.destroy();
        } catch (err2) {}
      });
    });
    this.effectPools = null;
    this.effectLastFireAt = null;
    this.effectAudioReady = false;
  },

  playEffect(name) {
    const src = EFFECT_AUDIO[name];
    if (!src || typeof AudioPlayer === 'undefined') return;
    const now = Date.now();
    const lastAt = this.effectLastFireAt && this.effectLastFireAt[name] ? this.effectLastFireAt[name] : 0;
    if (now - lastAt < EFFECT_COOLDOWN_MS) return;
    if (!this.effectPools) this.effectPools = {};
    if (!this.effectLastFireAt) this.effectLastFireAt = {};
    this.effectLastFireAt[name] = now;
    let entry = this.effectPools[name];
    if (!entry) {
      entry = { players: new Array(EFFECT_POOL_SIZE).fill(null), index: 0 };
      this.effectPools[name] = entry;
    }
    const slot = entry.index;
    entry.index = (entry.index + 1) % EFFECT_POOL_SIZE;
    const oldPlayer = entry.players[slot];
    if (oldPlayer) {
      try {
        if (oldPlayer.pause) oldPlayer.pause();
      } catch (err) {}
      try {
        if (oldPlayer.destroy) oldPlayer.destroy();
      } catch (err2) {}
    }
    try {
      const player = new AudioPlayer();
      player.src = src;
      player.autoplay = false;
      player.loop = false;
      if ('volume' in player) player.volume = EFFECT_VOLUME;
      player.play();
      entry.players[slot] = player;
    } catch (err) {
      entry.players[slot] = null;
    }
  },

  clearTimers() {
    if (this.autoExitTimer) {
      clearInterval(this.autoExitTimer);
      this.autoExitTimer = null;
    }
    if (this.decodeAnimTimer) {
      clearInterval(this.decodeAnimTimer);
      this.decodeAnimTimer = null;
    }
    if (this.confirmCancelTimer) {
      clearTimeout(this.confirmCancelTimer);
      this.confirmCancelTimer = null;
    }
    if (this.tapActionTimer) {
      clearTimeout(this.tapActionTimer);
      this.tapActionTimer = null;
    }
    if (this.exitBurstTimers) {
      this.exitBurstTimers.forEach((timer) => clearTimeout(timer));
      this.exitBurstTimers = [];
    }
  },

  startDecodeAnimation() {
    if (this.decodeAnimTimer) clearInterval(this.decodeAnimTimer);
    const marks = ['.', '..', '...'];
    const steps = ['正在拍照', '读取图像', '识别二维码', '整理卡片'];
    this.decodeAnimTick = 0;
    this.decodeAnimTimer = setInterval(() => {
      this.decodeAnimTick = (this.decodeAnimTick || 0) + 1;
      const tick = this.decodeAnimTick;
      this.setData({
        decodeMark: marks[tick % marks.length],
        decodeStepText: steps[Math.floor(tick / 5) % steps.length],
        decodeProgressWidth: 64 + ((tick * 23) % 150)
      });
    }, 180);
  },

  stopDecodeAnimation() {
    if (this.decodeAnimTimer) {
      clearInterval(this.decodeAnimTimer);
      this.decodeAnimTimer = null;
    }
  },

  async scan() {
    if (this.data.busy) return;
    this.stopAudio();
    this.currentAudioUrl = '';
    this.cancelExitConfirm();
    this.scanStartedAt = Date.now();
    this.scanPhotoMs = 0;
    this.scanDecodeMs = 0;
    this.scanDetectMs = 0;
    this.scanPhotoInfo = '';
    this.scanPhotoProfile = '';
    this.setData({
      busy: true,
      stageText: '扫描中',
      statusText: '请保持画面稳定',
      secretText: '正在读取二维码...',
      typeText: '识别中',
      summaryText: '稍等一下',
      detailText: '正在拍照',
      footerHintText: '请保持画面稳定',
      displayMode: 'camera',
      showCamera: true,
      showTextLayer: false,
      showImageView: false,
      mediaMode: 'text',
      mediaUrl: '',
      cardVariant: 'text',
      cardTitle: '扫描中',
      cardSubtitle: '请保持画面稳定',
      cardBody: '正在读取二维码...',
      cardFootnote: '正在拍照',
      a2uiCommands: '',
      showChrome: true,
      showFooter: false,
      exitConfirm: false,
      autoExitText: '双击退出'
    });
    try {
      const photoPromise = this.takePhoto();
      await this.showDecodingState();
      const photo = await photoPromise;
      if (this.data.exitConfirm || this.exiting) {
        this.stopDecodeAnimation();
        this.setData({
          busy: false,
          displayMode: 'exit-clear',
          showCamera: false,
          showTextLayer: false,
          showImageView: false,
          showChrome: false,
          showFooter: false,
          showTopbar: false
        });
        return;
      }
      this.setData({
        showCamera: false,
        showTextLayer: true,
        displayMode: 'text',
        showImageView: false,
        decodeHintText: '乐奇正在解码',
        decodeStepText: '正在识别二维码',
        decodeProgressWidth: 188
      });
      await wait(16);
      let result;
      if (this.decodeProvider !== 'cloud') {
        result = await this.decodeWithRokidBarcode(photo);
      } else {
        if (!this.endpoint) throw new Error('云端接口未配置');
        const payload = this.buildPayload(photo);
        result = await this.requestDecode(payload);
      }
      if (this.data.exitConfirm || this.exiting) {
        this.stopDecodeAnimation();
        this.setData({
          busy: false,
          displayMode: 'exit-clear',
          showCamera: false,
          showTextLayer: false,
          showImageView: false,
          showChrome: false,
          showFooter: false,
          showTopbar: false
        });
        return;
      }
      this.renderResult(result);
    } catch (err) {
      this.stopDecodeAnimation();
      if (this.data.exitConfirm || this.exiting) {
        this.setData({
          busy: false,
          displayMode: 'exit-clear',
          showCamera: false,
          showTextLayer: false,
          showImageView: false,
          showChrome: false,
          showFooter: false,
          showTopbar: false
        });
        return;
      }
      this.playEffect('fail');
      const perfText = this.scanPerfText();
      this.setData({
        busy: false,
        stageText: '没扫到',
        statusText: '调整角度再试',
        secretText: '没有读到二维码',
        typeText: '未识别',
        summaryText: '让二维码对准中间，靠近一点，避开反光。',
        detailText: '单击再扫一次 · 双击退出',
        displayMode: 'card',
        showCamera: false,
        showTextLayer: false,
        showImageView: false,
        mediaMode: 'text',
        mediaUrl: '',
        cardVariant: 'empty',
        cardTitle: '没有扫到',
        cardSubtitle: '调整一下角度',
        cardBody: '让二维码对准中间，靠近一点，避开反光后再扫一次。',
        cardFootnote: '',
        a2uiCommands: '',
        showChrome: false,
        showFooter: true,
        footerHintText: '单击再扫一次 · 双击退出',
        debugText: [perfText, getErrorText(err).slice(0, 120)].filter((item) => item).join(' | ')
      });
    }
  },

  async showDecodingState() {
    this.setData({
      stageText: '解码中',
      statusText: '乐奇正在解码',
      secretText: '乐奇正在解码',
      typeText: '处理中',
      summaryText: '',
      detailText: '',
      footerHintText: '',
      displayMode: 'text',
      showCamera: true,
      showTextLayer: true,
      showImageView: false,
      mediaMode: 'text',
      mediaUrl: '',
      cardBody: '乐奇正在解码',
      decodeHintText: '乐奇正在解码',
      decodeMark: '...',
      decodeStepText: '正在拍照',
      decodeProgressWidth: 52,
      showChrome: false,
      showFooter: false
    });
    this.startDecodeAnimation();
    await wait(DECODE_RENDER_WAIT_MS);
  },

  getCameraContext() {
    if (this.cameraCtx && typeof this.cameraCtx.takePhoto === 'function') {
      return this.cameraCtx;
    }
    const createFromMedia = wx && wx.media && wx.media.createCameraContext;
    const createFromRoot = wx && wx.createCameraContext;
    const createFromCamera = wx && wx.camera && wx.camera.createCameraContext;
    const factory = createFromMedia || createFromRoot || createFromCamera;
    if (!factory) throw new Error('createCameraContext 不存在');
    const owner = wx.media || wx.camera || wx;
    const candidates = [
      () => factory.call(owner, 'secretCamera', this),
      () => factory.call(owner, 'secretCamera'),
      () => factory.call(owner),
      () => factory.call(owner, undefined, this)
    ];
    for (let i = 0; i < candidates.length; i++) {
      try {
        const ctx = candidates[i]();
        if (ctx && typeof ctx.takePhoto === 'function') {
          this.cameraCtx = ctx;
          return ctx;
        }
      } catch (err) {}
    }
    throw new Error('camera.takePhoto 不存在');
  },

  async takePhotoOnce(profile) {
    const camera = this.getCameraContext();
    if (!camera || !camera.takePhoto) throw new Error('camera.takePhoto 不存在');
    const startedAt = Date.now();
    const captureProfile = profile || PHOTO_CAPTURE_PROFILES[PHOTO_CAPTURE_PROFILES.length - 1];
    const captureOptions = Object.assign({}, captureProfile.options || {});
    const photo = await withTimeout(new Promise((resolve, reject) => {
      let done = false;
      const finish = (fn, payload) => {
        if (done) return;
        done = true;
        fn(payload);
      };
      let ret;
      try {
        ret = camera.takePhoto(Object.assign(captureOptions, {
          success: (res) => finish(resolve, res),
          fail: (err) => finish(reject, err)
        }));
      } catch (err) {
        finish(reject, err);
        return;
      }
      if (ret && typeof ret.then === 'function') {
        ret.then((res) => finish(resolve, res)).catch((err) => finish(reject, err));
      } else if (ret && typeof ret === 'object' && Object.keys(ret).length > 0) {
        finish(resolve, ret);
      }
    }), 12000, 'takePhoto');
    this.scanPhotoMs = Date.now() - startedAt;
    this.scanPhotoProfile = captureProfile.name || '相机';
    const bytes = this.getPhotoBinary(photo);
    this.scanPhotoInfo = photoInfoText(bytes) || photoShape(photo) || photoKeys(photo);
    const sizeText = this.scanPhotoInfo ? ` ${this.scanPhotoInfo}` : '';
    this.appendTrace(`相机${this.scanPhotoProfile}${sizeText} ${compactMs(this.scanPhotoMs)} ${photoKeys(photo)}`);
    return photo;
  },

  async takePhoto() {
    let lastErr = null;
    for (let i = 0; i < PHOTO_CAPTURE_PROFILES.length; i++) {
      const profile = PHOTO_CAPTURE_PROFILES[i];
      try {
        if (i > 0) {
          this.setData({ detailText: `相机回退 ${profile.name}` });
          await wait(260);
        }
        return await this.takePhotoOnce(profile);
      } catch (err) {
        lastErr = err;
        this.setData({ debugText: `相机${profile.name}失败 ${getErrorText(err).slice(0, 64)}` });
      }
    }
    throw lastErr || new Error('takePhoto failed');
  },

  directPhotoImageData(photo) {
    const candidates = [
      photo && photo.imageData,
      photo && photo.rgba,
      photo && photo.pixels,
      photo && photo.frame,
      photo
    ];
    for (let i = 0; i < candidates.length; i++) {
      const imageData = toImageData(candidates[i]);
      if (imageData) return imageData;
    }
    if (photo && photo.data && photo.width && photo.height && photo.data.byteLength !== undefined) {
      return toImageData({
        width: photo.width,
        height: photo.height,
        data: new Uint8ClampedArray(photo.data)
      });
    }
    return null;
  },

  getPhotoFilePath(photo) {
    if (!photo) return '';
    return photo.tempFilePath || photo.tempImagePath || photo.tempImagePathPath ||
      photo.path || photo.filePath || photo.tempFileURL || photo.url || '';
  },

  getPhotoBinary(photo) {
    if (!photo) return null;
    const candidates = [
      photo.arrayBuffer,
      photo.buffer,
      photo.binary,
      photo.bytes,
      photo.data,
      photo.file,
      photo.image
    ];
    for (let i = 0; i < candidates.length; i++) {
      const bytes = bytesFromBinary(candidates[i]);
      if (bytes && bytes.byteLength > 32) return bytes;
    }
    return null;
  },

  async decodedImageDataFromPhoto(photo) {
    const bytes = this.getPhotoBinary(photo);
    if (!bytes) return null;
    try {
      const start = Date.now();
      const ext = getImageExtFromBytes(bytes);
      if (ext !== 'webp') throw new Error(`暂只支持 WebP 快扫，当前 ${ext}`);
      const image = await decodeWebPGrayFromBytes(bytes);
      this.scanDecodeMs = Date.now() - start;
      this.appendTrace(`解 ${image.format} ${image.width}x${image.height} ${this.scanDecodeMs}ms${image.chunkType ? ' ' + image.chunkType : ''}`);
      this.lastDecodedPhotoImage = image;
      return image;
    } catch (err) {
      this.appendTrace(`解码错 ${getErrorText(err)}`);
      return null;
    }
  },

  async detectEncodedPhotoFast(photo) {
    if (!ENABLE_ENCODED_FAST_PATH) return null;
    if (this.encodedDetectUnsupported) return null;
    const bytes = this.getPhotoBinary(photo);
    if (!bytes) return null;
    const info = getWebPInfoFromBytes(bytes);
    if (!info || !info.width || !info.height) return null;
    try {
      this.appendTrace(`原生试 ${info.chunkType} ${info.width}x${info.height}`);
      const result = await this.detectBarcodeSource({
        data: bytes,
        width: info.width,
        height: info.height
      }, `encoded ${info.chunkType}`, ENCODED_DETECT_TIMEOUT_MS);
      if (result && result.found) {
        this.appendTrace('原生命中');
        result.provider = 'rokid-barcode-encoded';
        return result;
      }
      this.encodedDetectUnsupported = true;
      this.appendTrace('原生空');
      return null;
    } catch (err) {
      this.encodedDetectUnsupported = true;
      this.appendTrace(`原生错 ${getErrorText(err)}`);
      return null;
    }
  },

  getPhotoBase64(photo) {
    if (!photo) return '';
    const candidates = [
      photo.base64,
      photo.imageBase64,
      photo.dataBase64,
      typeof photo.data === 'string' ? photo.data : ''
    ];
    for (let i = 0; i < candidates.length; i++) {
      const text = String(candidates[i] || '').trim();
      if (text && base64LooksLikeImage(text)) return stripDataUrl(text);
    }
    return '';
  },

  photoToDataUrl(photo) {
    const bytes = this.getPhotoBinary(photo);
    if (bytes) {
      const ext = getImageExtFromBytes(bytes);
      const base64 = bytesToBase64(bytes);
      this.appendTrace(`dataURL ${ext} ${Math.round(bytes.byteLength / 1024)}KB`);
      return `data:${imageMimeFromExt(ext)};base64,${base64}`;
    }
    const base64 = this.getPhotoBase64(photo);
    if (base64) {
      const ext = base64.slice(0, 8) === 'iVBORw0K' ? 'png' : (base64.slice(0, 5) === 'UklGR' ? 'webp' : 'jpg');
      this.appendTrace(`dataURL base64 ${Math.round(base64.length / 1024)}KB`);
      return `data:${imageMimeFromExt(ext)};base64,${base64}`;
    }
    return '';
  },

  writePhotoToTempFile(photo) {
    if (!wx || !wx.getFileSystemManager) throw new Error('文件系统不可用');
    const fs = wx.getFileSystemManager();
    const baseDir = wx.env && wx.env.USER_DATA_PATH ? wx.env.USER_DATA_PATH : '';
    if (!baseDir) throw new Error('USER_DATA_PATH 不存在');
    const bytes = this.getPhotoBinary(photo);
    if (bytes) {
      const ext = getImageExtFromBytes(bytes);
      const path = `${baseDir}/scan-${Date.now()}.${ext}`;
      fs.writeFileSync(path, exactArrayBuffer(bytes));
      this.setData({ debugText: `转换器 写入${ext} ${Math.round(bytes.byteLength / 1024)}KB` });
      return path;
    }
    const base64 = this.getPhotoBase64(photo);
    if (base64) {
      const ext = base64.slice(0, 8) === 'iVBORw0K' ? 'png' : (base64.slice(0, 5) === 'UklGR' ? 'webp' : 'jpg');
      const path = `${baseDir}/scan-${Date.now()}.${ext}`;
      fs.writeFileSync(path, base64, 'base64');
      this.setData({ debugText: `转换器 写入base64 ${Math.round(base64.length / 1024)}KB` });
      return path;
    }
    throw new Error('照片不是 ImageData，也不是图片路径或图片二进制');
  },

  appendTrace(text) {
    const item = String(text || '').replace(/\s+/g, ' ').slice(0, 42);
    this.decodeTrace = this.decodeTrace || [];
    this.decodeTrace.push(item);
    if (this.decodeTrace.length > 8) this.decodeTrace.shift();
  },

  async canvasImageDataFromPath(filePath, label) {
    if (!filePath) throw new Error('没有可绘制图片路径');
    if (!wx || !wx.createCanvasContext || !wx.canvasGetImageData) throw new Error('canvas 像素接口不可用');
    const size = BARCODE_CANVAS_SIZE;
    const ctx = wx.createCanvasContext(BARCODE_CANVAS_ID, this);
    if (!ctx || !ctx.drawImage) throw new Error('canvas.drawImage 不存在');
    if (ctx.clearRect) ctx.clearRect(0, 0, size, size);
    ctx.drawImage(filePath, 0, 0, size, size);
    this.setData({ debugText: `转换器 ${label || 'path'} -> canvas` });
    await withTimeout(new Promise((resolve, reject) => {
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      try {
        const ret = ctx.draw(false, done);
        if (ret && ret.then) ret.then(done).catch(reject);
        setTimeout(done, 500);
      } catch (err) {
        reject(err);
      }
    }), 2500, 'canvas.draw');
    const data = await withTimeout(new Promise((resolve, reject) => {
      wx.canvasGetImageData({
        canvasId: BARCODE_CANVAS_ID,
        x: 0,
        y: 0,
        width: size,
        height: size,
        success: resolve,
        fail: reject
      }, this);
    }), 3500, 'canvasGetImageData');
    const imageData = toImageData(data);
    if (!imageData) throw new Error('canvas 未返回 ImageData');
    this.appendTrace(`canvas ${label || 'path'} ${imagePixelStats(imageData)}`);
    return imageData;
  },

  async convertPhotoToImageData(photo) {
    const direct = this.directPhotoImageData(photo);
    if (direct) {
      this.setData({ debugText: `转换器 direct ${direct.width}x${direct.height}` });
      return direct;
    }
    const path = this.getPhotoFilePath(photo);
    if (path) return this.canvasImageDataFromPath(path, 'path');
    const dataUrl = this.photoToDataUrl(photo);
    if (dataUrl) return this.canvasImageDataFromPath(dataUrl, 'dataURL');
    const tempPath = this.writePhotoToTempFile(photo);
    return this.canvasImageDataFromPath(tempPath, 'file');
  },

  async getBarcodeSources(photo) {
    const sources = [];
    const direct = this.directPhotoImageData(photo);
    if (direct) {
      sources.push({
        label: `direct ${direct.width}x${direct.height}`,
        source: direct
      });
      this.appendTrace(`直 ${direct.width}x${direct.height}`);
      return sources;
    }
    const decoded = await this.decodedImageDataFromPhoto(photo);
    if (decoded) {
      if (decoded.format === 'webp-gray') {
        sources.push({
          label: `official webp gray ${decoded.chunkType || ''}`.trim(),
          source: {
            data: decoded.data,
            width: Number(decoded.width),
            height: Number(decoded.height)
          }
        });
        return sources;
      } else {
        const imageObject = toImageData(decoded);
        if (imageObject) sources.push({ label: `decoded ${decoded.format} ImageData`, source: imageObject });
        sources.push({ label: `decoded ${decoded.format} plain`, source: toPlainImageData(decoded) || decoded });
        const binary = makeBinaryImageData(decoded);
        if (binary) sources.push({ label: `decoded ${decoded.format} binary`, source: binary });
      }
    }
    if (photo && photo.data && photo.width && photo.height) {
      sources.push({
        label: `photo.data ${photo.width}x${photo.height}`,
        source: {
          data: photo.data,
          width: Number(photo.width),
          height: Number(photo.height)
        }
      });
    }
    if (photo && photo.imageData) {
      sources.push({ label: 'photo.imageData', source: photo.imageData });
    }
    if (photo && photo.frame) {
      sources.push({ label: 'photo.frame', source: photo.frame });
    }
    if (photo && photo.rgba && photo.width && photo.height) {
      sources.push({
        label: `photo.rgba ${photo.width}x${photo.height}`,
        source: {
          data: photo.rgba,
          width: Number(photo.width),
          height: Number(photo.height)
        }
      });
    }
    if (photo && photo.pixels && photo.width && photo.height) {
      sources.push({
        label: `photo.pixels ${photo.width}x${photo.height}`,
        source: {
          data: photo.pixels,
          width: Number(photo.width),
          height: Number(photo.height)
        }
      });
    }
    if (photo && photo.data && photo.imageWidth && photo.imageHeight) {
      sources.push({
        label: `photo.image ${photo.imageWidth}x${photo.imageHeight}`,
        source: {
          data: photo.data,
          width: Number(photo.imageWidth),
          height: Number(photo.imageHeight)
        }
      });
    }
    sources.push({ label: 'photo object', source: photo });
    return sources;
  },

  imageDataSources(imageData, label) {
    const sources = [];
    const plain = toPlainImageData(imageData);
    if (!plain) return sources;
    const stats = imagePixelStats(plain);
    sources.push({ label: `${label} plain ${stats}`, source: plain });
    const imageObject = toImageData(plain);
    if (imageObject) sources.push({ label: `${label} imageData ${stats}`, source: imageObject });
    const binary = makeBinaryImageData(plain);
    if (binary) sources.push({ label: `${label} binary ${imagePixelStats(binary)}`, source: binary });
    return sources;
  },

  getBarcodeDetector() {
    if (!this.barcodeDetector) {
      this.barcodeDetector = new BarcodeDetector({ formats: BARCODE_FORMATS });
    }
    return this.barcodeDetector;
  },

  async detectBarcodeSource(source, label, timeoutMs) {
    const detector = this.getBarcodeDetector();
    const start = Date.now();
    const barcodes = await withTimeout(Promise.resolve(detector.detect(source)), timeoutMs || BARCODE_DETECT_TIMEOUT_MS, 'BarcodeDetector.detect');
    const elapsed = Date.now() - start;
    this.scanDetectMs = (this.scanDetectMs || 0) + elapsed;
    this.appendTrace(`扫 ${label || 'input'} ${elapsed}ms`);
    if (!barcodes || !barcodes.length) {
      return {
        found: false,
        text: '',
        type: 'empty',
        summary: '没有识别到二维码。',
        provider: 'rokid-barcode',
        rawPreview: `empty ${label || ''}`
      };
    }
    return normalizeBarcodeResult(barcodes[0]);
  },

  async tryBarcodeSources(sources) {
    let lastErr = null;
    let lastEmpty = null;
    for (let i = 0; i < sources.length; i++) {
      const item = sources[i];
      if (!item || !item.source) continue;
      try {
        this.appendTrace(`试 ${item.label}`);
        const result = await this.detectBarcodeSource(item.source, item.label);
        if (result && result.found) {
          this.appendTrace(`中 ${item.label}`);
          return result;
        }
        lastEmpty = result;
        this.appendTrace(`空 ${item.label}`);
      } catch (err) {
        lastErr = err;
        this.appendTrace(`错 ${item.label} ${getErrorText(err)}`);
      }
    }
    if (lastEmpty) {
      lastEmpty.rawPreview = this.decodeTrace && this.decodeTrace.length ? this.decodeTrace.join(' / ') : lastEmpty.rawPreview;
      return lastEmpty;
    }
    throw lastErr || new Error('没有可识别输入');
  },

  async decodeWithRokidBarcode(photo) {
    this.decodeTrace = [];
    this.lastDecodedPhotoImage = null;
    this.appendTrace(`photo ${photoShape(photo) || photoKeys(photo)}`);
    const encodedResult = await this.detectEncodedPhotoFast(photo);
    if (encodedResult && encodedResult.found) return encodedResult;
    const sources = await this.getBarcodeSources(photo);
    let lastErr = null;
    let lastEmpty = null;
    try {
      const result = await this.tryBarcodeSources(sources);
      if (result && result.found) return result;
      lastEmpty = result;
    } catch (err) {
      lastErr = err;
    }
    if (this.lastDecodedPhotoImage && this.lastDecodedPhotoImage.format === 'webp-gray') {
      if (lastEmpty) {
        lastEmpty.rawPreview = this.decodeTrace && this.decodeTrace.length ? this.decodeTrace.join(' / ') : lastEmpty.rawPreview;
        return lastEmpty;
      }
      throw lastErr || new Error('Rokid Barcode 快扫未识别');
    }
    if (lastEmpty) return lastEmpty;
    throw lastErr || new Error('Rokid Barcode 识别失败，相机字段 ' + photoKeys(photo));
  },

  scanPerfText() {
    const parts = [];
    const total = this.scanStartedAt ? Date.now() - this.scanStartedAt : 0;
    if (total) parts.push(`总${compactMs(total)}`);
    const photoLine = [this.scanPhotoProfile, this.scanPhotoInfo].filter((item) => item).join(' ');
    if (photoLine) parts.push(photoLine);
    if (this.scanPhotoMs) parts.push(`拍${compactMs(this.scanPhotoMs)}`);
    if (this.scanDecodeMs) parts.push(`解${compactMs(this.scanDecodeMs)}`);
    if (this.scanDetectMs) parts.push(`扫${compactMs(this.scanDetectMs)}`);
    return parts.join(' · ');
  },

  buildPayload(photo) {
    const payload = {
      clientVersion: APP_VERSION,
      photoKeys: photoKeys(photo),
      photoPreview: safeString(photo).slice(0, 220)
    };
    if (photo && photo.data && photo.data.byteLength !== undefined) {
      payload.imageBase64 = arrayBufferToBase64(photo.data);
      payload.transport = 'arraybuffer';
      this.setData({ debugText: `payload ${payload.transport} ${Math.round(payload.imageBase64.length / 1024)}KB ${payload.photoKeys}` });
      return payload;
    }
    const base64 = this.getPhotoBase64(photo);
    if (base64) {
      payload.imageBase64 = base64;
      payload.transport = 'base64';
      this.setData({ debugText: `payload ${payload.transport} ${Math.round(payload.imageBase64.length / 1024)}KB ${payload.photoKeys}` });
      return payload;
    }
    const filePath = this.getPhotoFilePath(photo);
    if (filePath && wx && wx.getFileSystemManager) {
      const fs = wx.getFileSystemManager();
      payload.imageBase64 = String(fs.readFileSync(filePath, 'base64')).replace(/^data:image\/\w+;base64,/, '');
      payload.transport = 'filepath-base64';
      this.setData({ debugText: `payload ${payload.transport} ${Math.round(payload.imageBase64.length / 1024)}KB ${payload.photoKeys}` });
      return payload;
    }
    throw new Error('相机未返回可上传图片');
  },

  requestDecode(payload) {
    if (!wx || !wx.request) throw new Error('wx.request 不存在');
    const requestData = {
      imageBase64: payload.imageBase64,
      transport: payload.transport || 'unknown'
    };
    return withTimeout(new Promise((resolve, reject) => {
      wx.request({
        url: this.endpoint,
        method: 'POST',
        dataType: 'json',
        responseType: 'text',
        header: { 'content-type': 'application/json' },
        data: requestData,
        success: (res) => {
          const status = res && res.statusCode;
          const data = parseData(res);
          const rawText = responseText(res);
          this.setData({
            detailText: `备用接口 HTTP ${status || '?'}`,
            debugText: rawText
          });
          if (status && status >= 400) {
            reject(new Error(`备用接口 HTTP ${status}`));
            return;
          }
          const result = normalizeDecodeResult(data);
          result.httpStatus = status || '?';
          result.rawPreview = result.rawPreview || rawText;
          resolve(result);
        },
        fail: (err) => {
          this.setData({ detailText: `备用接口失败 ${getErrorText(err).slice(0, 36)}` });
          reject(err);
        }
      });
    }), 18000, 'qr-decode');
  },

  renderResult(result) {
    this.stopDecodeAnimation();
    if (this.data.exitConfirm || this.exiting) {
      this.setData({
        busy: false,
        displayMode: 'exit-clear',
        showCamera: false,
        showTextLayer: false,
        showImageView: false,
        showChrome: false,
        showFooter: false,
        showTopbar: false
      });
      return;
    }
    const found = !!(result && result.found);
    this.playEffect(found ? 'success' : 'fail');
    const text = found ? String(result.text || '') : '没有识别到二维码。';
    const detail = resultDetail(result);
    const label = typeLabel(result && result.type);
    const mediaMode = found ? mediaModeFor(result && result.type) : 'text';
    const isMedia = mediaMode === 'image' || mediaMode === 'video' || mediaMode === 'audio';
    const mediaUrl = mediaMode === 'image' ? imageDisplayUrl(text) : (isMedia ? stripTypedPrefix(text) : '');
    const resultType = result && result.type;
    const displayMode = !found ? 'card' : (isMedia ? mediaMode : (resultType === 'text' ? 'plain' : 'a2ui'));
    const card = buildCard(found ? text : '', result && result.type, result);
    const a2uiCommands = displayMode === 'a2ui' ? buildA2uiCommands(card, resultType) : '';
    const perfText = this.scanPerfText();
    const footerText = found ? '单击继续扫描 · 双击退出' : '单击再扫一次 · 双击退出';
    this.currentAudioUrl = mediaMode === 'audio' ? mediaUrl : '';
    this.setData({
      busy: false,
      stageText: found ? '识别完成' : '没扫到',
      statusText: mediaMode === 'audio' ? '音频就绪' : (found ? '已识别' : '调整角度再试'),
      secretText: isMedia
        ? (mediaMode === 'image' ? '图片已打开' : (mediaMode === 'audio' ? '单击播放音频' : '视频播放中'))
        : (text || '（空内容）'),
      typeText: label,
      summaryText: mediaMode === 'audio' ? '已识别音频地址，正在尝试自动播放。' : (found ? (result.summary || '识别完成') : '让二维码对准中间，靠近一点，避开反光。'),
      detailText: found
        ? (mediaMode === 'audio' ? '若无声，请单击画面重试 · 双击退出' : (mediaMode === 'video' ? mediaUrl : '单击继续扫描 · 双击退出'))
        : '单击再扫一次 · 双击退出',
      footerHintText: footerText,
      displayMode,
      showCamera: false,
      showTextLayer: displayMode === 'text',
      showImageView: displayMode === 'image',
      mediaMode,
      mediaUrl,
      cardVariant: card.variant || 'text',
      cardTitle: found ? card.title : '没有扫到',
      cardSubtitle: found ? card.subtitle : '调整一下角度',
      cardBody: found ? card.body : '让二维码对准中间，靠近一点，避开反光后再扫一次。',
      cardFootnote: found ? card.footnote : '',
      a2uiCommands,
      showChrome: !!isMedia,
      showFooter: !isMedia,
      audioHintText: mediaMode === 'audio' ? 'AudioPlayer 等待事件' : '',
      debugText: [perfText, result.rawPreview || detail].filter((item) => item).join(' | ')
    });
    if (displayMode === 'a2ui') {
      setTimeout(() => this.applyA2ui(a2uiCommands), 120);
    }
    if (mediaMode === 'audio') {
      setTimeout(() => this.playAudio(mediaUrl, 'auto'), 260);
    }
  },

  applyA2ui(commands) {
    try {
      if (!commands || typeof a2ui === 'undefined' || !a2ui.createA2UIContext) return;
      const ctx = a2ui.createA2UIContext('qr-a2ui');
      if (ctx && ctx.write) ctx.write(commands);
    } catch (err) {
      this.setData({ debugText: 'A2UI ' + getErrorText(err).slice(0, 80) });
    }
  },

  playAudio(src, reason) {
    this.stopAudio();
    if (typeof AudioPlayer === 'undefined') {
      this.setData({
        statusText: '音频不可用',
        summaryText: '当前 AIUI 运行时没有 AudioPlayer。',
        audioHintText: 'AudioPlayer undefined'
      });
      return;
    }
    try {
      const player = new AudioPlayer();
      this.audioPlayer = player;
      this.audioPlayReason = reason || 'manual';
      this.audioDidPlay = false;
      player.src = src;
      if ('autoplay' in player) player.autoplay = false;
      player.loop = false;
      if ('volume' in player) player.volume = 1.0;
      if (player.onCanplay) {
        player.onCanplay(() => {
          this.setData({
            statusText: '音频已缓冲',
            audioHintText: 'onCanplay'
          });
        });
      }
      if (player.onPlay) {
        player.onPlay(() => {
          this.audioDidPlay = true;
          this.setData({
            statusText: '正在播放',
            summaryText: '真机已触发 onPlay。',
            audioHintText: 'onPlay ' + (this.audioPlayReason || '')
          });
        });
      }
      if (player.onPause) {
        player.onPause(() => {
          this.setData({
            statusText: '音频暂停',
            audioHintText: 'onPause'
          });
        });
      }
      if (player.onEnded) {
        player.onEnded(() => {
          this.setData({
            statusText: '播放结束',
            summaryText: '音频播放完成。',
            audioHintText: 'onEnded'
          });
        });
      }
      if (player.onError) {
        player.onError((err) => {
          this.setData({
            statusText: '音频失败',
            summaryText: 'AudioPlayer 无法播放：' + getErrorText(err).slice(0, 28),
            audioHintText: 'onError ' + getErrorText(err).slice(0, 32)
          });
        });
      }
      this.setData({
        statusText: reason === 'tap' ? '手动播放' : '尝试播放',
        summaryText: 'AudioPlayer.play 已调用；若无声，请单击重试。',
        audioHintText: 'play(' + (reason || 'manual') + ')'
      });
      const playResult = player.play();
      if (playResult && playResult.then) {
        playResult.then(() => {
          this.setData({ audioHintText: 'play promise ok' });
        }).catch((err) => {
          this.setData({
            statusText: '音频失败',
            audioHintText: 'promise ' + getErrorText(err).slice(0, 32)
          });
        });
      }
      setTimeout(() => {
        if (!this.audioPlayer || this.audioPlayer !== player || this.audioDidPlay) return;
        try {
          player.play();
          this.setData({
            audioHintText: 'play retry',
            summaryText: '已重试播放；仍无声说明系统可能没有开放音频输出。'
          });
        } catch (err2) {
          this.setData({ audioHintText: 'retry ' + getErrorText(err2).slice(0, 32) });
        }
      }, 700);
    } catch (err) {
      this.setData({
        statusText: '音频失败',
        summaryText: 'AudioPlayer 调用失败：' + getErrorText(err).slice(0, 28),
        audioHintText: 'catch ' + getErrorText(err).slice(0, 32)
      });
    }
  },

  stopAudio() {
    try {
      if (this.audioPlayer && this.audioPlayer.pause) this.audioPlayer.pause();
    } catch (err) {}
    try {
      if (this.audioPlayer && this.audioPlayer.destroy) this.audioPlayer.destroy();
    } catch (err2) {}
    this.audioPlayer = null;
    this.audioDidPlay = false;
  },

  runExitApis() {
    try {
      if (wx && wx.exitMiniProgram) wx.exitMiniProgram({});
    } catch (err) {}
    try {
      if (typeof this.finish === 'function') this.finish();
    } catch (err2) {}
    try {
      if (wx && wx.navigateBack) wx.navigateBack({ delta: 99 });
    } catch (err3) {}
    try {
      if (wx && wx.navigateBack) wx.navigateBack({ delta: 10 });
    } catch (err4) {}
    try {
      if (wx && wx.navigateBack) wx.navigateBack({ delta: 2 });
    } catch (err5) {}
    try {
      if (wx && wx.navigateBack) wx.navigateBack({ delta: 1 });
    } catch (err6) {}
    try {
      if (wx && wx.navigateBack) wx.navigateBack();
    } catch (err7) {}
    const root = typeof globalThis !== 'undefined' ? globalThis : {};
    const hosts = [root.aiui, root.rokid];
    hosts.forEach((host) => {
      try {
        if (host && typeof host.exit === 'function') host.exit();
      } catch (err8) {}
      try {
        if (host && typeof host.close === 'function') host.close();
      } catch (err9) {}
    });
  },

  exitAgent() {
    if (this.exiting) {
      this.runExitApis();
      return;
    }
    this.exiting = true;
    this.confirmTapAt = 0;
    this.lastTapAt = 0;
    this.clearTimers();
    this.stopAudio();
    this.setData({
      busy: false,
      exitConfirm: false,
      showTopbar: false,
      showChrome: false,
      showFooter: false,
      displayMode: 'exit-clear',
      showCamera: false,
      showTextLayer: false,
      showImageView: false,
      autoExitText: '正在退出'
    });
    this.runExitApis();
    const delays = [80, 180, 360, 700, 1200, 1900];
    this.exitBurstTimers = delays.map((delay) => setTimeout(() => this.runExitApis(), delay));
  }
};
</script>

<page>
  <view class="page" bindtap="onRootTap">
    <view class="topbar" ink:if="{{showTopbar}}">
      <text class="brand">扫一扫</text>
      <text class="timer">{{autoExitText}}</text>
    </view>
    <view class="display-frame">
      <view class="intro-card" ink:if="{{displayMode === 'intro'}}">
        <text class="intro-main">请您看向二维码</text>
        <text class="intro-action">单击镜腿扫描</text>
        <text class="intro-action">双击退出</text>
      </view>
      <camera id="secretCamera" class="camera-probe" ink:if="{{showCamera}}"></camera>
      <image class="media-image" src="{{mediaUrl}}" mode="aspectFit" ink:if="{{showImageView}}"></image>
      <video class="media-video" src="{{mediaUrl}}" autoplay controls ink:if="{{displayMode === 'video'}}"></video>
      <view class="audio-panel" ink:if="{{displayMode === 'audio'}}">
        <text class="audio-mark">ON AIR</text>
        <text class="audio-title">{{secretText}}</text>
        <text class="audio-hint">{{audioHintText}}</text>
        <text class="audio-url">{{mediaUrl}}</text>
      </view>
      <view class="a2ui-shell" ink:if="{{displayMode === 'a2ui'}}">
        <a2ui
          id="qr-a2ui"
          commands="{{a2uiCommands}}"
          style="display: flex; flex-direction: column; width: 100%; height: 100%"
        />
      </view>
      <view class="smart-card" ink:if="{{displayMode === 'card'}}">
        <text class="card-kicker">{{typeText}}</text>
        <text class="card-title">{{cardTitle}}</text>
        <text class="card-subtitle">{{cardSubtitle}}</text>
        <text class="card-body">{{cardBody}}</text>
        <text class="card-footnote">{{cardFootnote}}</text>
      </view>
      <view class="secret-card" ink:if="{{displayMode === 'secret'}}">
        <text class="secret-badge">眼镜专属 · 密语</text>
        <text class="secret-title">{{cardTitle}}</text>
        <text class="secret-subtitle">{{cardSubtitle}}</text>
        <text class="secret-body">{{cardBody}}</text>
        <text class="secret-footnote">{{cardFootnote}}</text>
      </view>
      <view class="plain-card" ink:if="{{displayMode === 'plain'}}">
        <text>{{cardBody}}</text>
      </view>
      <view class="text-layer" ink:if="{{showTextLayer}}">
        <view class="decode-panel">
          <view class="decode-pulse">
            <text class="decode-mark">{{decodeMark}}</text>
          </view>
          <text class="decode-title">{{decodeHintText}}</text>
          <text class="decode-subtitle">惊喜推送中</text>
          <text class="decode-step">{{decodeStepText}}</text>
          <view class="decode-progress">
            <view class="decode-progress-fill" style="width: {{decodeProgressWidth}}px;"></view>
          </view>
        </view>
      </view>
    </view>
    <view class="statusbar" ink:if="{{showChrome}}">
      <text class="status">{{statusText}}</text>
      <text class="type-pill">{{typeText}}</text>
    </view>
    <view class="result-title" ink:if="{{showChrome}}">
      <text>{{stageText}}</text>
    </view>
    <view class="meta" ink:if="{{showChrome}}">
      <text>{{summaryText}}</text>
      <text>{{detailText}}</text>
      <text class="copyright">{{copyrightText}}</text>
    </view>
    <view class="footerbar" ink:if="{{showFooter}}">
      <text class="footer-hint">{{footerHintText}}</text>
      <text class="copyright">{{copyrightText}}</text>
    </view>
    <view class="exit-overlay" ink:if="{{exitConfirm}}">
      <view class="exit-dialog">
        <view class="exit-dialog-body">
          <text class="exit-title">确认退出</text>
          <text class="exit-copy">请再双击一次</text>
          <text class="exit-copy">再双击一次完成退出</text>
          <text class="exit-copy">单击取消</text>
        </view>
      </view>
    </view>
  </view>
</page>

<style>
.page {
  width: 100%;
  min-height: 100vh;
  box-sizing: border-box;
  padding: 9px;
  background: transparent;
  color: #eaffea;
  flex-direction: column;
  position: relative;
  overflow: hidden;
}

.topbar {
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 6px;
}

.brand {
  color: #40ff5e;
  font-size: 24px;
  line-height: 30px;
  font-weight: 800;
}

.timer {
  color: #7f9e86;
  font-size: 16px;
  line-height: 22px;
}

.display-frame {
  width: 100%;
  height: 274px;
  border: 0;
  background: transparent;
  margin-bottom: 6px;
  box-sizing: border-box;
  justify-content: center;
  position: relative;
  overflow: hidden;
}

.camera-probe {
  width: 100%;
  height: 274px;
  background: transparent;
  position: absolute;
  top: 0;
  left: 0;
  z-index: 1;
}

.intro-card {
  width: 100%;
  height: 274px;
  padding: 24px 20px;
  box-sizing: border-box;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  background: transparent;
}

.intro-main {
  color: #ffffff;
  font-size: 36px;
  line-height: 46px;
  font-weight: 900;
  text-align: center;
  width: 100%;
}

.intro-action {
  color: #40ff5e;
  font-size: 29px;
  line-height: 38px;
  font-weight: 800;
  text-align: center;
  width: 100%;
  margin-top: 8px;
}

.text-layer {
  width: 100%;
  height: 274px;
  padding: 18px 24px;
  box-sizing: border-box;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  background: transparent;
  position: absolute;
  top: 0;
  left: 0;
  z-index: 20;
}

.decode-panel {
  width: 100%;
  height: 238px;
  box-sizing: border-box;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  background: transparent;
}

.decode-pulse {
  width: 48px;
  height: 48px;
  border-radius: 24px;
  background: transparent;
  border: 2px solid rgba(64, 255, 94, 0.82);
  align-items: center;
  justify-content: center;
  margin-bottom: 14px;
  box-sizing: border-box;
}

.decode-mark {
  color: #40ff5e;
  font-size: 20px;
  line-height: 22px;
  font-weight: 800;
  text-align: center;
}

.decode-title {
  color: #ffffff;
  font-size: 28px;
  line-height: 36px;
  font-weight: 800;
  text-align: center;
  width: 100%;
}

.decode-subtitle {
  color: #b9ffc3;
  font-size: 21px;
  line-height: 28px;
  font-weight: 700;
  text-align: center;
  width: 100%;
  margin-top: 2px;
}

.decode-step {
  color: #86c891;
  font-size: 16px;
  line-height: 22px;
  text-align: center;
  width: 100%;
  margin-top: 12px;
}

.decode-progress {
  width: 240px;
  height: 8px;
  border-radius: 4px;
  background: transparent;
  border: 1px solid rgba(64, 255, 94, 0.45);
  box-sizing: border-box;
  margin-top: 12px;
  overflow: hidden;
}

.decode-progress-fill {
  width: 130px;
  height: 8px;
  border-radius: 4px;
  background: #40ff5e;
}

.plain-card {
  width: 100%;
  height: 274px;
  padding: 16px 18px;
  box-sizing: border-box;
  flex-direction: column;
  justify-content: center;
  background: transparent;
}

.plain-card text {
  color: #ffffff;
  font-size: 30px;
  line-height: 40px;
  font-weight: 800;
  width: 100%;
}

.a2ui-shell {
  width: 100%;
  height: 274px;
  box-sizing: border-box;
  background: transparent;
}

.smart-card {
  width: 100%;
  height: 274px;
  padding: 14px 16px;
  box-sizing: border-box;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  background: transparent;
}

.card-kicker {
  color: #40ff5e;
  font-size: 16px;
  line-height: 22px;
  font-weight: 800;
  width: 100%;
}

.card-title {
  color: #ffffff;
  font-size: 28px;
  line-height: 35px;
  font-weight: 800;
  margin-top: 5px;
  width: 100%;
}

.card-subtitle {
  color: #b9ffc3;
  font-size: 18px;
  line-height: 25px;
  margin-top: 4px;
  width: 100%;
}

.card-body {
  color: #ffffff;
  font-size: 22px;
  line-height: 31px;
  font-weight: 700;
  margin-top: 10px;
  width: 100%;
}

.card-footnote {
  color: #83b98c;
  font-size: 16px;
  line-height: 22px;
  margin-top: 10px;
  width: 100%;
}

.secret-card {
  width: 100%;
  height: 274px;
  padding: 16px 18px;
  box-sizing: border-box;
  flex-direction: column;
  align-items: flex-start;
  background: transparent;
  border: 1px solid rgba(64, 255, 94, 0.55);
}

.secret-badge {
  color: #40ff5e;
  background: transparent;
  border: 1px solid rgba(64, 255, 94, 0.55);
  font-size: 16px;
  line-height: 22px;
  padding: 2px 7px;
  border-radius: 3px;
  font-weight: 800;
}

.secret-title {
  color: #ffffff;
  font-size: 30px;
  line-height: 38px;
  font-weight: 900;
  margin-top: 12px;
  width: 100%;
}

.secret-subtitle {
  color: #9fffae;
  font-size: 18px;
  line-height: 25px;
  margin-top: 4px;
  width: 100%;
}

.secret-body {
  color: #ffffff;
  font-size: 26px;
  line-height: 35px;
  font-weight: 800;
  margin-top: 15px;
  width: 100%;
}

.secret-footnote {
  color: #79b983;
  font-size: 16px;
  line-height: 22px;
  margin-top: 10px;
  width: 100%;
}

.statusbar {
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 7px;
}

.status {
  color: #c8ffd0;
  font-size: 17px;
  line-height: 23px;
}

.type-pill {
  color: #40ff5e;
  background: transparent;
  border: 1px solid rgba(64, 255, 94, 0.55);
  font-size: 16px;
  line-height: 22px;
  padding: 2px 7px;
  border-radius: 4px;
  font-weight: 800;
}

.result-title {
  margin-bottom: 5px;
}

.result-title text {
  color: #40ff5e;
  font-size: 18px;
  line-height: 24px;
  font-weight: 800;
}

.media-image {
  width: 100%;
  height: 274px;
}

.media-video {
  width: 100%;
  height: 274px;
}

.audio-panel {
  width: 100%;
  height: 274px;
  padding: 24px 14px;
  box-sizing: border-box;
  flex-direction: column;
  justify-content: center;
  background: transparent;
}

.audio-mark {
  color: #40ff5e;
  font-size: 16px;
  line-height: 22px;
  font-weight: 800;
}

.audio-title {
  color: #ffffff;
  font-size: 30px;
  line-height: 38px;
  font-weight: 800;
  margin-top: 8px;
}

.audio-hint {
  color: #40ff5e;
  font-size: 18px;
  line-height: 24px;
  margin-top: 8px;
}

.audio-url {
  color: #94dba0;
  font-size: 16px;
  line-height: 22px;
  margin-top: 10px;
}

.exit-overlay {
  width: 100%;
  height: 100vh;
  position: absolute;
  top: 0;
  left: 0;
  z-index: 100;
  background-color: transparent;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}

.exit-dialog {
  width: 76%;
  height: 172px;
  padding: 18px 20px;
  box-sizing: border-box;
  border-radius: 18px;
  border: 2px solid #40ff5e;
  background-color: transparent;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}

.exit-dialog-body {
  width: 100%;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}

.exit-title {
  color: #ffffff;
  font-size: 28px;
  line-height: 36px;
  font-weight: 800;
  width: 100%;
  text-align: center;
}

.exit-copy {
  color: #9fffae;
  font-size: 20px;
  line-height: 28px;
  margin-top: 5px;
  width: 100%;
  text-align: center;
}

.meta {
  margin-top: 7px;
  flex-direction: column;
}

.meta text {
  color: #94dba0;
  font-size: 16px;
  line-height: 22px;
}

.copyright {
  color: #5f8f67;
  font-size: 16px;
  line-height: 22px;
  font-weight: 800;
  margin-top: 2px;
}

.footerbar {
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  min-height: 22px;
}

.footer-hint {
  color: #9fffae;
  font-size: 16px;
  line-height: 22px;
}

</style>
