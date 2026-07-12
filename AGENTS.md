# 随心记项目协作说明

## 开始任何任务前

按顺序阅读：

1. `docs/MACOS-START.md`
2. `.memory/MEMORY.md` 的最新条目
3. `CONTEXT.md`
4. 与任务相关的产品、技术或原型文件

## 信息优先级

- 后续已确认的用户决定高于早期启动文档。
- `.memory/MEMORY.md` 的较新条目高于较旧条目。
- 初代 MVP 已明确不支持视频，即使早期 `docs/PRODUCT.md` 或 `docs/TECHNICAL-DESIGN.md` 仍出现视频描述，也不要实现视频。
- `prototypes/ios-ui/` 是用于确认方向的临时 HTML 原型，不是生产代码；正式客户端必须使用原生 SwiftUI 重写。

## 当前实现方向

- 仅支持 iPhone，最低 iOS 17。
- 解锁后直接进入“立即记录”。
- 初代输入为文字、图片和语音。
- UI 以 `prototypes/ios-ui/?variant=A` 的“一页即记”为基线。
- 日历满意度采用五瓣花：填充花瓣数量对应一至五档。

## 项目工作约定

- 修改前后检查 `git status`，保护用户已有未提交变更。
- 每次代码修改都更新 `.memory/MEMORY.md`，记录需求、修改、验证与风险。
- 完成修改后运行与风险相称的验证，并在交付时列出相关文件、命令和未触碰的既有脏工作区变更。
