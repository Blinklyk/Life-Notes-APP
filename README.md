# 随心记

Life Notes App

随心记是一款以“按天记录”为核心的 iOS 私人日记应用。用户可以随时用文字、图片或语音留下片段，系统在一天结束后将这些原始记录整理成一篇符合用户表达风格、且可继续编辑的每日随心日记。

## 产品主线

1. 随手记录：尽可能缩短从打开应用到完成输入的路径。
2. 每日整理：保留原始记录，同时生成独立、可重做的每日随心日记。
3. 回望自己：通过日历浏览历史，并为每天标注心情和重要程度。
4. 尊重隐私：个人素材默认私密，AI 处理方式必须向用户明确说明。

## MVP 范围

- 文字、图片和语音记录，不支持视频或 App 内拍照
- 语音录制、播放，以及条件允许时的语音转文字
- 按用户本地时区将记录归入某一天
- 自动生成、重新生成和手动编辑每日随心日记
- 月历浏览、日期详情和有记录日期提示
- 每日心情选择和“重要的一天”标记
- 本地持久化与媒体文件管理

完整产品定义见 [docs/PRODUCT.md](docs/PRODUCT.md)，技术边界见 [docs/TECHNICAL-DESIGN.md](docs/TECHNICAL-DESIGN.md)，统一领域语言见 [CONTEXT.md](CONTEXT.md)。

## 当前状态

项目已创建 iOS 17+ 原生 SwiftUI 工程 [LifeNotes.xcodeproj](LifeNotes.xcodeproj)，当前实现首个纵向闭环：

`启动并解锁 → 立即记录纯文字 → SwiftData 本地保存 → 进入今天页 → 重启后仍可读取`

工程包含 `LifeNotes` App target 与 `LifeNotesTests` 单元测试 target。开发环境至少需要 Xcode 15，建议使用兼容当前 macOS 的 Xcode 16.x，并安装 iOS 17+ Simulator runtime。

准备在 macOS 上继续开发时，请从 [docs/MACOS-START.md](docs/MACOS-START.md) 开始，并先阅读根目录 [AGENTS.md](AGENTS.md)。

## iOS 前端原型

可交互的临时原型位于 [prototypes/ios-ui](prototypes/ios-ui)。它包含“立即记录、今天、日历、日记编辑”四个场景，以及三个可切换的设计方向；当前推荐“一页即记”作为初代基线。
