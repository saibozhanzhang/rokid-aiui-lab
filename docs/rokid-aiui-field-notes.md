# Rokid AIUI Field Notes

These notes summarize practical lessons from building and testing Rokid Glasses AIUI Agents on YodaOS Sprite.

## What Worked Reliably

- Scene agents can display custom `.ink` UI on glasses.
- Camera capture can work when the app is a scene agent and the `camera` permission is declared.
- Network requests can work from the agent.
- Tencent Cloud SCF plus OCR QR decode can identify text and URL QR codes from glasses photos.
- Rokid's `barcode` module can decode QR codes on-device after converting camera WebP bytes into image data.
- Static image URLs can render in an `<image mode="aspectFit">` result view.
- `wx.exitMiniProgram({})` plus a delayed `wx.navigateBack({ delta: 1 })` is a practical exit fallback.

## What Was Unreliable Or Not Proven

- ASR, TTS, IMU, MP3 playback, and video playback were not reliable in tested agents.
- Ordinary mouse-like click, Bluetooth ring/flying mouse, and temple touch did not behave like browser pointer events.
- Page `bindtap` alone was not enough for robust glasses physical interaction.
- Web video and MP3 URLs could show UI states but did not produce dependable playback on device.
- OpenAI/GPT-only services timed out from China-facing deployment paths unless proxied through a reachable backend.
- `navigator.mediaDevices.getUserMedia`, canvas pixel reads, and file-system conversion were not reliable in AIUI runtime.
- Exit remained host-dependent: even aggressive API calls could still require repeated physical double taps.

## Physical Input Mapping

Extracted runtime samples indicated:

- Real temple single tap can arrive as `page.onKeyDown` with `keyCode`/`key` equivalent to `Enter`.
- Real temple double tap can arrive as `page.onKeyDown` with `Backspace`.
- Some samples also expose `aiui.temple.onDoubleTap`, `rokid.temple.onDoubleTap`, or `onMessage` with `temple.doubleTap`.
- Use all available channels, but keep `onKeyDown` as the practical baseline.

Implementation pattern:

```js
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
}
```

## Exit Confirmation Pattern

Use an explicit confirmation state.

- First Backspace/double tap: set `exitConfirm: true`.
- Second Backspace/double tap while visible: call exit.
- Enter/single tap while visible: cancel confirmation.
- Do not call exit directly from the first Backspace.
- If real testing shows the host needs two double-tap rounds after the dialog appears, write that in the dialog instead of hiding it:

```text
确认退出？
先双击一次
再双击一次退出
单击取消
```

- In code, avoid returning early after one fallback succeeds syntactically. Call all plausible exits: `wx.exitMiniProgram`, `this.finish`, `wx.navigateBack` with several deltas, and any host `exit/close` API.

## Template And CSS Compatibility

Prefer simple bindings:

- Good: `ink:if="{{showFooter}}"`
- Risky: `ink:if="{{!showChrome}}"`

Prefer direct classes:

- Good: `.copyright`
- Risky: `.footerbar .copyright`

Keep layout fixed and simple:

- Use one top bar, one main result panel, one bottom bar.
- Avoid repeated status text outside the card.
- Avoid nested borders unless the design explicitly needs them.
- Use short Chinese labels; English labels wrap sooner and can clip.
- Explicitly set `flex-direction: column` on card/dialog containers. Real glasses can otherwise place sibling text nodes in one horizontal row.
- Use an opaque background for modal confirmations. Transparent overlays collide visually with green HUD text behind them.
- Avoid tiny fonts. Treat 16px as the practical floor; use 24-36px for primary instructions.

## A2UI Lessons

- A2UI can create better GUI-like cards than raw text, but keep commands static and direct.
- Dynamic interpolation inside command content may not resolve on glasses.
- Use native fallback views for plain text, secret cards, and media.
- Badge text should be short, such as `眼镜专属`, not `FOR GLASSES ONLY`.

## QR Scanner Pattern

For a QR scanner/secret-sharing agent:

- Use scene agent.
- Permissions: `camera`, `network`.
- Do not request microphone/voice recognition unless the feature truly depends on it.
- Preferred runtime path: `wx.takePhoto` -> WebP bytes -> WebP gray decode -> `BarcodeDetector.detect()`.
- Cloud QR/OCR is a fallback, not the default, when Rokid BarcodeDetector works.
- Classify decoded text into `text`, `url`, `image`, `wifi`, `contact`, `phone`, `email`, `sms`, `geo`, `event`, or custom secret format.
- Render normal text as large plain text.
- Render URLs as cards with domain and full URL.
- Render image URLs directly as an image.
- Render custom secret QR payloads as glasses-only cards.
- Do not show the captured photo preview after scanning if speed matters.
- Use a processing overlay before or during capture to mask the camera preview and reduce waiting anxiety.
- For empty results, show only recovery advice: center the QR code, move closer, reduce reflection, scan again.
- Keep engineering diagnostics in internal `debugText`, not visible UI.

## Rokid BarcodeDetector Implementation Notes

The stable QR path from the scanner project was:

1. Open as a scene agent with camera permission.
2. Reuse camera context and barcode detector across scans.
3. Try a low-quality/small photo profile first.
4. Treat returned WebP bytes as the normal case.
5. Decode WebP to grayscale image data.
6. Pass `{ data, width, height }` to `new BarcodeDetector({ formats: ['qr_code'] }).detect(...)`.
7. Render the result as native `.ink` or A2UI cards.

Avoid adding jsQR, PNG, JPEG, canvas, or file-system fallback to the hot path unless testing proves they help. On-device speed improved when the hot path stayed narrow.

## First Screen Pattern

Do not start with a noisy camera view if the user needs orientation. A good first launch prompt is centered and large:

```text
请您看向二维码
单击镜腿扫描
双击退出
```

Hide footer/status chrome on this first screen to avoid duplicate instructions.

## Copywriting For Public Agent Forms

Keep descriptions short, specific, and playful.

Example name:

```text
扫一扫
```

Example function intro:

```text
戴上乐奇 AI 眼镜，扫一扫二维码，就能看到别人看不到的文字、网址、图片和眼镜密语。适合聚会破冰、暗号传递、展会互动、朋友之间分享小秘密。
```

Example wakeup tests:

```text
打开扫一扫，帮我识别这个二维码。
```

```text
扫一扫这个二维码，看看里面藏了什么。
```

## Packaging Checklist

Before giving the user a build:

- Bump all versions consistently: source constant, `app.json`, `package.json`, output `.aix`.
- Run `npm run pack`.
- Copy the output `.aix` to Desktop or another obvious path.
- Inspect the package as a zip and confirm the expected version and critical strings are inside.
- If the user says the file did not change, check the installed file name, app version, and package contents before changing behavior.
