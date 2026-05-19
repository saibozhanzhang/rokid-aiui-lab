# Rokid AIUI Lab

这里记录我和 Codex 一起折腾 Rokid Glasses / 乐奇 AI 眼镜 AIUI Agent 的实验项目。

目标很简单：让 AIUI Agent 不只是“能跑”，而是真的适合戴在眼镜上用。

## 项目里有什么

### 扫一扫

目录：`qr-secret-agent`

一个面向 Rokid Glasses 的二维码扫描 AIUI Agent。

戴上眼镜，单击镜腿扫描二维码，眼镜会把内容整理成适合眼镜阅读的界面：

- 普通文字：大字显示
- 网址：卡片显示
- 图片链接：直接显示图片
- Wi-Fi、名片、电话、邮箱、短信、位置、日程：整理成 GUI 卡片
- 眼镜密语：只有戴眼镜的人能看到

当前版本：`1.0.27`

主要技术点：

- 场景智能体
- `wx.takePhoto`
- Rokid `BarcodeDetector`
- WebP 照片解码
- 本地 AudioPlayer 成功 / 失败音效
- A2UI / native `.ink` 混合 GUI
- 镜腿单击扫描、双击退出

### AIUI 小白教程网页

目录：`aiui-agent-workshop`

一个给 0 基础用户看的网页教程，讲怎么从项目文件夹开始，编辑、调试、打包并发布 AIUI Agent。

### 能力探测 Agent

目录：`aiui-capability-probe`

用于测试眼镜端能力，例如相机、网络、退出链路等。

### 文档

目录：`docs`

- `AIUI-工作总结-2026-05-15.md`：阶段性工作总结
- `rokid-aiui-field-notes.md`：真机测试经验和踩坑记录

## 怎么运行

先安装 AIUI 开发工具，并参考官方文档：

- AIUI 文档：https://js.rokid.com/AIUI
- AIUI Craft：https://js.rokid.com/craft
- 灵珠平台：https://rizon.rokid.com

进入某个 Agent 目录：

```bash
cd qr-secret-agent
npm install
npm run pack
```

打包后会生成 `.aix` 文件，可以上传到 [灵珠平台](https://rizon.rokid.com "Rokid灵珠平台") 测试。

## 真机经验

眼镜端不是普通浏览器，很多手机和网页上的习惯不能照搬。

我们目前确认比较可靠的是：

- 场景智能体可以显示完整自定义 UI
- 相机可用
- 网络请求可用
- Rokid `BarcodeDetector` 可以扫码
- 图片可以显示
- 镜腿单击常见为 `Enter`
- 镜腿双击常见为 `Backspace`

目前不稳定或未完全确认的是：

- TTS
- ASR
- IMU
- 网页视频播放
- MP3 播放
- 一次性彻底退出

所以 UI 要诚实、简短、可恢复。不要把工程诊断信息直接显示给普通用户。

## 发布前注意

不要上传这些东西：

- `.env`
- API Key
- `node_modules`
- `.aix` 历史包
- APK 提取文件
- 系统日志

本仓库已经用 `.gitignore` 排除了常见危险文件。

## 作者

赛博站长
