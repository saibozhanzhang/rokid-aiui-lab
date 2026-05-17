# 眼镜扫描仪 AIUI Agent

- 类型：Scene 场景智能体
- 能力：相机、网络
- 目标：拍摄二维码，优先使用 Rokid AIUI 内置 `BarcodeDetector` 本机解码，并只在眼镜 UI 上显示秘密内容。
- 备用：只有传入 `endpoint` 时，才会在本机识别失败后请求外部 `/api/qr-decode` 兼容服务。
- 后续：可把 `GLASS-SECRET:` 协议接到加密/一次性口令/OpenClaw 动作。
