# macOS / Xcode 开发入口

该文档是新 macOS 智能体的最短入口。完整产品背景见 `README.md` 与 `docs/PRODUCT.md`，统一语言见 `CONTEXT.md`，最新决定见 `.memory/MEMORY.md`，界面基线见 `prototypes/ios-ui/VERDICT.md` 和 `prototypes/ios-ui/index.html`。

## 当前目标

在 Xcode 中创建 iOS 17+ SwiftUI App，先完成以下纵向闭环：

`启动并解锁 → 立即记录纯文字 → 本地保存 → 进入今天页 → 重启后仍可读取`

这一闭环完成前，不接入真实 AI、Windows 后端、Tailscale、云同步或视频能力。

## 必须保留的产品规则

- 原始随心记录与生成的随心日记是独立对象。
- 离线记录不得依赖转写、AI 或后端成功。
- 一条随心记录未来可包含整体文字、多张图片及每张图片的独立可选批注。
- 初代不支持视频，也不提供 App 内拍照。
- HTML 原型中的视觉与交互可作为参照，代码结构需按 SwiftUI 和可测试的数据模块重新设计。

## 推荐首批工程结构

- `App`：应用入口、依赖组装、Face ID 隐私门。
- `Features/Capture`：立即记录界面和草稿状态。
- `Features/Today`：今天页和时间线。
- `Modules/DayWorkspace`：保存、读取和观察某个记录日的深模块 Interface。
- `Domain`：`DayKey`、`Entry` 等无 UI 领域类型。
- `Infrastructure/Persistence`：SwiftData 实现。

先在单一 App target 中形成清晰模块，不要为每个目录提前拆 Swift Package。

## 第一阶段验证

- `DayKey` 在中国时区下的日期归属测试。
- 纯文字随心记录的保存和读取测试。
- App 重启后的持久化验证。
- iPhone 真机 Face ID、动态字体和键盘遮挡检查。
- 提交后更新 `.memory/MEMORY.md`，记录 Xcode、Swift 和模拟器/真机版本。

## 建议使用的技能

- `codebase-design`：确定 `DayWorkspace` Interface 与 SwiftData seam。
- `tdd`：先写日期归属和保存读取测试。
- `domain-modeling`：新术语或规则变化时更新 `CONTEXT.md`。
- `diagnosing-bugs`：定位 SwiftData、权限、并发或真机差异问题。
