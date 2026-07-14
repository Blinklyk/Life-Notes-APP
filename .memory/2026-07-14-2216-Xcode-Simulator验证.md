---
时间: 2026-07-14 2216
工具: codex
---

## 我的要求 / 遇到的问题
- 在 Xcode 更新并安装 iOS Simulator 后，补齐首个 SwiftUI 纵向闭环的编译、测试和 Simulator 界面验证。
- 验证范围为：Face ID 解锁、立即记录纯文字、本地保存、进入今天页、强制终止 App 后仍可读取。

## 改动点
- `.memory/2026-07-14-2216-Xcode-Simulator验证.md`: 记录新版 Xcode 下的完整验证结果；本轮没有修改 Swift 源码或工程配置。

## 验证
- 环境：Xcode 26.6（17F113）、Apple Swift 6.3.3、iPhone 17 Simulator、iOS 26.5（23F77）。
- 无签名 iPhoneOS Debug build 通过：`xcodebuild -project LifeNotes.xcodeproj -scheme LifeNotes -configuration Debug -destination generic/platform=iOS -derivedDataPath /tmp/LifeNotesDeviceDerivedData CODE_SIGNING_ALLOWED=NO build`。
- `LifeNotesTests` 在上述 Simulator 执行 7 项测试，7 项通过、0 项失败、0 项跳过；结果包位于 `/tmp/LifeNotesTestResults.xcresult`。
- Simulator 启用 Face ID Enrolled 后，通过 Matching Face 解锁；解锁后直接进入“立即记录”。
- 保存“这是重启后仍应存在的一条测试记录”后进入今天页，时间线显示 1 条记录；强制终止并重新启动 App、再次 Face ID 解锁后，从今天页仍能读取相同内容。
- 软件键盘显示时，正文输入区与“记下这一刻”按钮均位于键盘上方，没有遮挡。
- Dynamic Type 切换到 `accessibility-extra-extra-extra-large` 后，Capture 与 Today 页面内容可换行、无控件重叠；检查后已恢复为 `large`。
- 截图保存在 `/tmp/lifenotes-today-saved.png`、`/tmp/lifenotes-today-after-relaunch.png`、`/tmp/lifenotes-keyboard.png`、`/tmp/lifenotes-dynamic-type-capture-clean.png` 和 `/tmp/lifenotes-dynamic-type-today.png`。

## git
- `906829d` feat: 完成首个 SwiftUI 文字记录闭环。

## 备注 / 待办
- Simulator 已覆盖 LocalAuthentication 流程和 UI 闭环，但不能替代实体 iPhone 的 Face ID 验证；连接真机并配置 Personal Team 后仍需补一次真机检查。
- 测试记录保留在专用 Simulator 中，方便用户直接打开检查；`/tmp` 下的结果包和截图是临时验证产物，不纳入 git。
