# 眼镜能力探测

用于 Rokid Glasses AIUI 真机测试的最小能力探测 Agent。0.2.0 起打开后自动运行，不依赖点击按钮。

## 测试项目

- 相机 API 是否存在，以及 `takePhoto` 是否可用
- `wx.request` 网络请求是否可用
- `wx.speech.playTTS` 和 `speechSynthesis` 是否可用
- `onMessage` 宿主消息是否可进入页面
- `this.finish()` / `wx.navigateBack()` 退出链路是否可用
- `wx.exitMiniProgram()` 退出链路是否可用

## 打包

```bash
npm run pack
```
