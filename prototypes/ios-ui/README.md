# 随心记 iOS UI 原型（可删除）

> 问题：初代 iPhone App 在“打开即记录”的前提下，应该采用什么界面结构？

这是用于确认视觉与交互方向的临时原型，不是生产代码。它包含三个结构明显不同的方向，并可切换四个核心场景：立即记录、今天、日历和日记编辑。

## 运行

在项目根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\prototypes\ios-ui\serve.ps1
```

然后打开 <http://127.0.0.1:4173>。

## 方向

- `?variant=A`：一页即记（推荐基线）
- `?variant=B`：生活拼贴
- `?variant=C`：沉浸语音

底部悬浮条或键盘左右方向键可切换方案。页面右侧可切换“立即记录、今天、日历、日记编辑”场景。

## 原型结论

等待用户选择后填写 [VERDICT.md](VERDICT.md)，随后删除未选方案和原型切换器，再以原生 SwiftUI 重写正式界面。
