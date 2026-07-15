# Project Memory

## 2026-07-12：项目启动与需求整理

### 对话与用户需求

用户准备启动 iOS 项目“随心记”。核心想法是让用户每天通过文字、图片、视频和语音记录随想；系统汇总当天全部输入，自动生成符合用户自身风格的日记或总结；用户可以在日历中回看每天的原始记录与生成日记，并评价当天开心或不开心、标记重要的日子。

### 本次实际修改

- 初始化 Git 仓库。
- 创建 `README.md`，明确产品主线、MVP 范围和当前状态。
- 创建 `CONTEXT.md`，统一“随心记录、记录日、每日素材、随心日记、表达风格、每日感受、重要日”等领域术语。
- 创建 `docs/PRODUCT.md`，整理产品愿景、核心闭环、MVP 功能、业务规则、信息架构、数据对象、验收场景、非目标和待验证问题。
- 创建 `docs/TECHNICAL-DESIGN.md`，给出 SwiftUI/SwiftData 技术起点、模块边界、本地媒体与 AI 隐私设计、实施顺序。
- 创建适用于 Swift/Xcode 项目的 `.gitignore`。

### 已作出的关键判断

- 原始随心记录与系统生成的随心日记是两个独立对象，重新生成或编辑日记不得修改原始记录。
- 每日感受是用户主动给出的主观评价，不进行医学或心理健康诊断。
- 重要日由用户主动标记，与当天素材数量或情绪无关。
- 首版应离线可记录，AI 或语音转写失败不能阻断基础记录。
- 项目当前运行环境为 Windows，因此本次不创建无法在本地用 Xcode 验证的工程文件。

### 验证结果

- 已确认工作目录起初为空且不是 Git 仓库。
- 已完成 Git 初始化。
- 已检查 Git 状态、Markdown 文件清单、文档标题结构和空白错误。

### 未处理风险与后续注意点

- 尚未确定最低 iOS 版本，这会影响 SwiftData 与兼容方案。
- 尚未确定日记自动生成的默认触发时机。
- 尚未确定“自己的风格”的初始采集方式与是否允许持续学习。
- 尚未决定首版是否需要 iCloud 同步，以及 AI 是否允许处理原始图片或视频。
- 下一步应在 macOS/Xcode 环境创建工程，并优先实现文字记录的最小纵向闭环。

## 2026-07-12：需求访谈与 iOS 前端原型

### 已确认的产品方向

- 初代仅支持 iPhone，最低 iOS 17；暂不上架 App Store，先供个人使用。
- 初代支持文字、图片和语音，完全不提供视频选择、保存或分析入口，也不提供 App 内拍照。
- App 冷启动后直接进入“立即记录”的输入状态，而不是先进入浏览页。
- 一条随心记录可包含整体文字和多张图片；每张图片可以填写独立、可跳过的文字或语音批注。
- 语音可选择保留原始录音，或只保存转写文字；转写在 iPhone 端完成，优先使用系统离线识别，不支持时联网后重试，不内置额外识别模型。
- 离线时仍可创建和查看记录，联网后再同步。
- 日记按用户配置时间自动生成；生成前等待仍在上传的素材，个别上传失败时用其余内容生成并提示遗漏。
- 新增记录后是否自动更新日记是长期用户偏好；重新生成保留历史版本。
- 生成日记是可完整编辑的图文内容，用户可以调整文字、图片和顺序。
- AI 只使用语音转写文字，不分析声调或情绪；最终日记使用 GPT-5.6，OpenAI API 在中国大陆的可用性仅作为个人原型条件，不作为正式上线保证。
- 初代 Windows 电脑运行后端，Mac 负责 Xcode/iPhone 开发；iPhone 通过 Tailscale 访问 Windows 后端，后续再迁移云端。
- 初代无付费 Apple Developer 账号，因此不做远程推送；用户打开 App 后看到日记生成提醒。
- 初代按单人实现，但数据从一开始保留用户标识，为后续多用户预留。

### 本次前端原型修改

- 新建 `prototypes/ios-ui/index.html`，实现一个纯前端、无持久化的 iPhone 交互原型。
- 原型包含四个场景：立即记录、今天、日历、日记编辑。
- 原型包含三个结构不同的方向：A“一页即记”、B“生活拼贴”、C“沉浸语音”，可通过 URL 参数、底部切换器或键盘方向键切换。
- 推荐 A 作为初代信息架构：打开即可写、图片与语音作为同级辅助入口，提交后进入今天页。
- 为每张图片提供独立批注示意；提供语音录制状态、保存跳转、日记版本和图文块编辑示意。
- 新建 `serve.ps1` 提供一条命令启动本地预览，并新建 `VERDICT.md` 等待用户选择后记录结论。
- 生成推荐方案 A 的四张预览图，位于 `prototypes/ios-ui/previews/`。
- 更新根 `README.md`，增加前端原型入口。

### 原型验证结果

- 使用 Python 3.12 的本地 HTTP 服务启动原型并验证返回 HTTP 200。
- 在浏览器中验证“记下这一刻”会从立即记录跳转到今天页。
- 验证 A/B/C 三个方向可切换并同步到 URL 参数。
- 验证立即记录、今天、日历、日记编辑四个场景可进入。
- 验证录音按钮能够进入“正在录音”状态。
- 验证运行时控制台没有 JavaScript 错误。
- 使用 390×844 iPhone 视口检查并输出推荐方案预览图。

### 后续注意点

- 当前原型是用于确认方向的临时代码，不应直接转为生产 SwiftUI 代码；选定方案后删除其他方向并原生重写。
- 原型照片使用远程 Unsplash 资源，离线预览时照片可能不显示；正式 App 使用用户相册素材和本地缩略图。
- 产品与技术启动文档中的早期“支持视频”等内容已被后续访谈部分取代，正式架构设计时需要统一更新。
- 尚未确认用户最终选择的 UI 方向和需要组合保留的元素。

### 日历满意度可视化补充

- 用户对方向 A 给出正向反馈，并要求日历在具体日期下展示当天满意程度，共五档。
- 原型采用“五瓣花”作为满意度图案：一档填充一瓣，五档完整盛开；未填充花瓣保留淡色轮廓，因此不依赖颜色也能读取档位。
- 重要日继续使用独立的小爱心标记，避免与满意度混为同一个概念。
- 日历增加轻量图例“花开得越满，今天越满意”；示例中的 7 月 12 日为四档。
- 日期按钮增加可访问名称，例如“12 日，满意度 4 / 5”。
- 已在 390×844 视口验证花朵、图例与日期布局，并更新 `previews/a-calendar.png`。

## 2026-07-12：首次版本提交

- 用户确认提交“第一版初稿设计”。
- 本次首次提交范围包括产品与技术启动文档、领域术语、项目记忆、Git 忽略规则，以及完整的 iOS 可交互前端原型和推荐方案预览图。
- 提交前已确认仓库此前没有提交记录，当前文件均来自本次项目启动与设计过程，没有用户既有未提交变更需要排除。

## 2026-07-12：关联 GitHub 远程仓库

- Git 作者更新为 `Blinklyk <290913796@qq.com>`，仅配置于当前仓库。
- 远程仓库设置为 `git@github.com:Blinklyk/Life-Notes-APP.git`。
- 远程仓库已有一个只包含 `# Life-Notes-APP` 的初始 README 提交；本地通过非强制合并保留该提交历史，并以完整的“随心记”README 为主体补充英文项目名。
- SSH 主机密钥已通过 GitHub 官方元数据验证，最终使用绑定到 `Blinklyk` 账户且具备写权限的 SSH 密钥进行认证。

## 2026-07-12：macOS 智能体交接准备

- 用户计划次日在 macOS 上由另一个智能体继续 iOS 原生开发，并确认远程仓库是否包含全部设计、下一智能体能否准确理解。
- 已确认远程仓库包含产品文档、技术起点、领域术语、完整 HTML 交互原型和四张推荐方案预览图。
- 识别到早期产品/技术文档仍包含“视频属于 MVP”等已过时内容；后续已确认初代完全不支持视频，因此新增根目录 `AGENTS.md` 明确信息优先级。
- 新增 `docs/MACOS-START.md`，为 macOS 智能体提供阅读顺序、首个 SwiftUI 纵向闭环、非目标、建议模块与验证标准。
- 在系统临时目录生成 `suixinji-macos-handoff.md` 作为会话级备用交接摘要；仓库内文档才是跨设备接手入口。

## 2026-07-13：首个 SwiftUI 纵向闭环代码落地

### 用户要求

- 完整阅读根目录 `AGENTS.md` 与 `docs/MACOS-START.md` 后，在 macOS/Xcode 中实现第一个 SwiftUI 纵向闭环。
- 闭环范围为：启动并解锁、立即记录纯文字、SwiftData 本地保存、进入今天页、重启后仍可读取。

### 本次实际修改

- 创建 `LifeNotes.xcodeproj`，包含 iOS 17+ 的 `LifeNotes` App target、`LifeNotesTests` 单元测试 target 和共享 scheme。
- 按 `App`、`Features`、`Modules`、`Domain`、`Infrastructure` 分层创建单一 App target 内的 Swift 源码。
- 新增 Face ID/设备密码隐私门；后台会取消未完成的认证，inactive 快照不渲染私人内容。
- 新增方案 A 风格的原生 Capture 与 Today 页面，支持进程内草稿保留、空白校验、保存成功提示、时间线倒序展示、Dynamic Type、键盘避让和基础 VoiceOver 语义。
- 新增 `DayKey`、`Entry`、`NewTextEntry` 等领域类型；记录固化本地用户 ID、创建时区和 `YYYYMMDD` 日期键。
- 使用 SwiftData `@ModelActor` 实现文字记录保存与按记录日读取；不接入 AI、后端、同步、图片、语音或视频。
- 新增上海时区日期边界、保存读取、用户/日期隔离、倒序与磁盘 store 重开测试。
- 更新 `README.md`，纠正初代不支持视频并记录当前工程状态。

### 当前验证

- `plutil -lint LifeNotes.xcodeproj/project.pbxproj` 通过。
- shared scheme XML 校验通过，`xcodebuild -list` 可识别两个 target 和 `LifeNotes` scheme。
- 纯 Foundation 的 Domain/DayWorkspace Interface 已用 Swift 5.8.1 typecheck 通过。
- 除旧编译器不认识的 SwiftData `#Predicate` 宏文件外，其余 Swift 文件语法解析通过；`git diff --check` 通过。

### 风险与待办

- 当前机器仍是 Xcode 14.3.1、iOS 16.4 SDK，且 CoreSimulator 与 macOS 15.4 不兼容，无法编译 iOS 17/SwiftData 或运行测试。
- 用户需要安装并切换到 Xcode 15+，建议 Xcode 16.x，同时安装 iOS 17+ Simulator runtime；之后必须补跑 build、全部单测、Simulator 保存/重启读取和界面检查。
- 真机运行前需要在 Signing & Capabilities 选择用户的 Personal Team，并检查 Face ID、动态字体和键盘遮挡。
- 用户已要求将当前实现提交并推送；iOS 17 完整验证仍需在新版 Xcode 到位后补跑并另行记录。

## 2026-07-15：图片选择与逐图批注闭环

### 用户要求

- 继续实现初代全部能力，并先完成图片选择及逐图批注。
- 每完成一项都更新 `README.md` 和项目 memory，并创建一次中文 Conventional Commit。

### 本次实际修改

- 使用 `PhotosPicker` 有序选择最多 20 张图片，仅接收图片，不提供视频或 App 内拍照。
- 支持纯图或图文记录、逐图可选文字批注、移除、导入失败状态和未保存草稿恢复。
- 使用文件表示导入相册资源，在整图进入内存前检查 100 MiB 与 1 亿像素上限；保存原图并生成最长边 1200 像素的 JPEG 缩略图。
- Today 时间线展示缩略图与批注；点击后使用 4096 像素降采样全屏查看，支持缩放、拖动和双击复位。
- 新增 `PhotoAttachmentRecord`、稳定 `sourceDraftID`、跨用户引用保护、安全删除与一小时阈值孤儿回收；旧文字 store 和旧草稿 JSON 可自动迁移。
- 草稿在切入 inactive/background 时立即 flush；草稿读取失败时禁止覆盖、清除和媒体回收，并将立即记录页置为明确故障态。

### 验证

- `plutil -lint LifeNotes.xcodeproj/project.pbxproj` 与 `git diff --check` 通过。
- Xcode 26.6、Apple Swift 6.3.3 下以 `SWIFT_VERSION=6`、`SWIFT_STRICT_CONCURRENCY=complete`、`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 完成 `build-for-testing`。
- 临时 iPhone 17 Pro / iOS 26.5 Simulator 执行 47 项单元与集成测试，47 项通过、0 项失败；结果包为 `/tmp/LifeNotesPhotoTestsFinal6.xcresult`。
- 原 `58ABABC0-1722-47F0-99BB-1B2311C24C60` Simulator 的 per-device 服务异常，曾导致 `addmedia`、安装和 launch worker 长时间等待；后续验证应使用新建临时设备。

### 风险与待办

- macOS 当前锁屏，尚未补完 PhotosPicker、多图批注、全屏缩放、强退恢复、Dynamic Type 与 VoiceOver 的人工 UI 检查；代码与自动化测试已通过，解锁后继续补验。
- 下一项进入语音录制、系统转写、可编辑转写与原始录音保留。

## 2026-07-15：语音录制、转写与逐图语音批注闭环

### 用户要求

- 继续实现初代全部功能，本阶段完成图片记录之后的语音录制、转写和原始录音保留。
- 每完成一项更新 `README.md` 和项目 memory，并创建一次中文 Conventional Commit。

### 本次实际修改

- 新增全局语音与逐图语音批注；每条记录最多一段全局语音，每张图片最多一段语音，同时只允许一个录音或转写任务。
- 使用 `AVAudioRecorder` 录制最长 60 秒的 M4A，支持暂停、继续、停止、试听、后台落盘、系统中断、耳机路由断开和 media services reset。
- 使用 Speech framework 优先设备内识别，不可用时由 Apple 系统能力联网重试；麦克风或语音识别权限拒绝、转写失败均不阻断原音保存。
- 转写可编辑并记录设备内、Apple 网络或手动来源；原音默认保留，也可在转写非空时主动选择仅保留文字。
- Today 按全局语音和对应照片语音展示，支持播放、重试转写和编辑；失配照片的旧数据仍明确显示，不会隐藏。
- 新增 `VoiceAttachmentRecord`、受保护音频文件库、语音草稿恢复、旧草稿兼容、路径/符号链接/大小/时长校验和孤儿回收。
- 删除语音或含语音的照片时先持久化去引用，再清理文件；异常重复语音草稿进入保护状态，不再静默丢弃或误删原音。
- 草稿提交使用确定性记录 ID，两个 SwiftData context 并发提交同一 `(userID, sourceDraftID)` 时保持单条记录。
- 补齐 VoiceOver 录音状态与结束播报、44pt 点击区域、忙碌态禁用及转写中编辑竞态保护。

### 验证

- `plutil -lint LifeNotes.xcodeproj/project.pbxproj`、scheme XML、全量 Swift parse 与 `git diff --check` 通过。
- Xcode 26.6、Apple Swift 6.3.3 下以 `SWIFT_VERSION=6`、`SWIFT_STRICT_CONCURRENCY=complete`、`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 完成 `build-for-testing`。
- iPhone 17 Pro Max / iOS 26.5 Simulator 执行 79 项单元与集成测试，79 项通过、0 项失败、0 项跳过；结果包为 `/tmp/LifeNotesVoiceFinalTests3.xcresult`。
- 两个 SwiftData context 并发提交同一草稿的测试额外重复 20 次，全部通过。

### 风险与待办

- 自动化已覆盖权限拒绝、转写失败、原音/仅转写、逐图语音、后台恢复、删除顺序、文件安全、迁移和并发幂等。
- Simulator CLI 当前不提供 biometric 子命令，尚未补完真实麦克风、系统权限弹窗、Face ID 后语音页面、Dynamic Type 与 VoiceOver 的人工 UI 检查；真机验收时继续补验。
- 下一阶段先实现每日感受与重要日的数据和编辑，再实现月历与五瓣花。

## 2026-07-15：每日感受与重要日闭环

### 用户要求

- 继续实现初代全部功能，本阶段完成每日感受与重要日。
- 每完成一项更新 `README.md` 和项目 memory，并创建一次中文 Conventional Commit。

### 本次实际修改

- 新增一至五档 `DailyFeeling` 与五瓣花 SwiftUI 表达；今天页可选择、清除每日感受，并独立切换“重要的一天”。
- 新增 `DayState`、SwiftData `DayRecord` 和 `DayWorkspace` 查询/更新接口；每日感受与重要日分别保存修改时间，没有记录的日期也可保存状态。
- `DayRecord` 以用户和 `DayKey` 组成唯一 scope，读取及写入前校验 scope、用户、日期和感受原始值，阻止损坏数据串日或部分提交。
- 多个 SwiftData context 首次并发设置感受与重要日时串行化并合并字段；旧文字、图片、语音 store 可自动迁移到包含 `DayRecord` 的 schema。
- AppModel 使用刷新、每日状态发布和 mutation 三组 generation，处理同日迟到刷新、跨日更新及 A→B→A ABA 竞态；旧日期请求不会覆盖新选择或继续锁住控件。
- 补齐五档映射、用户隔离、独立字段更新、清除、持久化重启、旧 store 迁移、并发首次创建、损坏数据拒绝及异步竞态测试。

### 验证

- 全量 Swift parse、`plutil -lint LifeNotes.xcodeproj/project.pbxproj` 与 `git diff --check` 通过。
- Xcode 26.6、Apple Swift 6.3.3 下以 Swift 6 严格并发和 warnings-as-errors 完成构建及全量测试。
- iPhone 17 Pro Max / iOS 26.5 Simulator 执行 97 项测试，97 项通过；结果包为 `/tmp/LifeNotesDayStateFinalTests5.xcresult`。
- 首次并发设置每日感受与重要日的测试额外重复 20 次，20 次通过；结果包为 `/tmp/LifeNotesDayStateConcurrent20.xcresult`。

### 风险与待办

- 五瓣花与重要日控件已覆盖布局回退、44pt 点击区域和 VoiceOver 语义，但仍需在真机补 Dynamic Type、VoiceOver 与跨日本地时间人工验收。
- 当前仅在今天页编辑每日状态；下一阶段实现月历、日期详情和历史日期的五瓣花回看。

## 2026-07-15：月历、日期详情与五瓣花回看闭环

### 用户要求

- 继续实现初代全部功能，本阶段完成日历与五瓣花满意度，并提供历史日期详情。
- 每完成一项更新 `README.md` 和项目 memory，并创建一次中文 Conventional Commit。

### 本次实际修改

- 新增 `CalendarMonth`、`CalendarDaySummary` 和 `DayDetail`，支持闰年、跨年、周一开头固定 42 格及相邻月份日期。
- `DayWorkspace` 新增范围摘要与日期详情接口；SwiftData 用一次记录查询和一次每日状态查询聚合可见 42 天，不逐日读取媒体。
- 新增独立 `CalendarModel` 管理切月、详情和历史日状态更新；月份、详情、摘要 publication 及按日期 mutation generation 处理快速切换、迟到响应和 A→B→A 竞态。
- 新增原生月历、日期格和历史详情；日期格分别呈现记录点、五瓣花、重要日爱心和日记文档标记，VoiceOver 播报日期、数量、感受级别与标记。
- 今天和日历接入统一底部导航；日期详情复用完整图文/语音时间线，历史记录暂时只读，每日感受和重要日可修改并即时同步摘要。
- 时间线按每条记录固化的创建时区显示时间；切月加载期间禁用旧日期格，避免旧网格详情被新月份结果清空。
- 补齐月份计算、范围边界、用户隔离、损坏数据、完整附件详情、快速切月/切日、迟到月/详情刷新、相邻月日期和跨日期保存测试。

### 验证

- 全量 Swift parse、`plutil -lint LifeNotes.xcodeproj/project.pbxproj` 与 `git diff --check` 通过。
- Xcode 26.6、Apple Swift 6.3.3 下以 Swift 6 严格并发和 warnings-as-errors 完成构建及全量测试。
- iPhone 17 Pro Max / iOS 26.5 Simulator 执行 117 项测试，117 项通过；结果包为 `/tmp/LifeNotesCalendarFinalTests3.xcresult`。
- 定向 CalendarModel P1 竞态测试 9 项通过；结果包为 `/tmp/LifeNotesCalendarP1Tests.xcresult`。

### 风险与待办

- 最新构建已安装到 Simulator，但系统身份验证停在“输入 iPhone 密码”；`Matching Face` 不能越过该密码页，尚未完成人工点击月历、Dynamic Type 和 VoiceOver 检查。
- 人工验收前需在 Simulator 的 `Features > Face ID > Enrolled` 启用模拟 Face ID 后重新认证，或输入该模拟器密码；真机仍需检查实际 Face ID 与创建时区显示。
- 下一阶段实现随心日记生成接口、编辑和历史版本，并让月历的日记文档标记接入真实数据。

## 2026-07-15：随心日记生成、编辑与历史版本闭环

### 用户要求

- 继续实现初代全部功能，本阶段完成 AI 生成随心日记及编辑、历史版本。
- 每完成一项更新 `README.md` 和项目 memory，并创建一次中文 Conventional Commit。

### 本次实际修改

- 新增独立 `JournalDay`、`JournalVersion`、`JournalBlock`、表达风格和每日素材 fingerprint；随心记录与随心日记保持独立。
- 以窄 `JournalGenerator` 接口接入本地事实型生成器，只使用文字、逐图批注、语音转写、素材数量及照片快照，不虚构素材外事实。
- 新增 SwiftData 日记主记录和不可变版本记录；生成、重新生成、手写、编辑与恢复历史均追加版本，并保存来源 fingerprint、素材数和 base version。
- Today 与历史日期详情支持生成、重新生成、手写、完整图文编辑、历史预览和恢复；月历接入真实日记标记。
- 编辑器支持标题、正文、照片、caption、增删和上下排序，未保存退出需要确认，保存或恢复期间整页锁定。
- App inactive/background 时保活原内容树并使用隐私门覆盖，重新解锁后保留当前 route 与 sheet，不再丢失未保存日记稿。
- JournalModel 区分同日素材刷新与跨日 operation；已落库 append 即使遇到迟到 load 也会重新读取并收敛，不会误报失败或重复版本。
- 日记读写、月历日记查询和照片保留查询使用共享串行协调器；损坏日记按日降级，历史版本引用的照片继续保留。

### 验证

- 全量 Swift parse、`plutil -lint LifeNotes.xcodeproj/project.pbxproj` 与 `git diff --check` 通过。
- Xcode 26.6、Apple Swift 6.3.3 下使用 Swift 6 完整严格并发与 warnings-as-errors 完成构建和全量测试。
- iPhone 17 Pro Max / iOS 26.5 Simulator 执行 157 项测试，157 项通过；结果包为 `/tmp/LifeNotesJournalFullFinal-20260715-1356.xcresult`。
- 日记持久化与月历降级定向测试 22/22 通过，结果包为 `/tmp/LifeNotesJournalConsistencyTests2.xcresult`。

### 风险与待办

- 当前生成器为可离线工作的本地事实型实现，真实 OpenAI 生成将在 Windows 后端阶段接入，API key 只保存在后端。
- 仍需在 Simulator 或真机人工检查 Face ID 返回后 sheet 保活、Dynamic Type、VoiceOver 和键盘交互。
- 下一阶段实现随心记录编辑、删除与全文搜索。

## 2026-07-15：随心记录编辑、删除与全文搜索闭环

### 用户要求

- 继续实现初代全部功能，本阶段完成随心记录编辑、删除与搜索。
- 每完成一项更新 `README.md` 和项目 memory，并创建一次中文 Conventional Commit。
- 后续按任务 `019f64a1-2216-7812-993d-1ca7c37c2d03` 的结论调整：跳过 Windows 专用宿主，在 macOS 开发 Linux-ready 后端，与 iPhone 联调后直接迁云。

### 本次实际修改

- Today、历史日期详情和跨日期搜索结果均可编辑或永久删除随心记录；编辑范围为正文、逐图文字批注和语音转写，媒体成员与顺序保持不变。
- 新增正文、图片批注、语音转写全文搜索，支持 Unicode 大小写、音调和宽度折叠、多词 AND、稳定倒序及用户隔离。
- `Entry` 与 `EntryRecord` 新增单调 revision；编辑和删除使用乐观并发，删除保留用户确认时快照，不会静默升级 revision 后删除较新内容。
- 删除先提交 SwiftData，再读取所有用户记录及全部日记历史引用，逐项清理无引用照片和原音；历史日记引用继续保留，媒体清理失败只提示不回滚。
- Today、月历、历史详情和日记素材 fingerprint 在 mutation 后统一刷新；编辑预读、搜索、编辑/删除迟到响应和自动转写均有 generation 或 revision 保护。
- generated 日记 append 与记录删除使用同一持久化临界区，并按 live entries 重验 fingerprint/count，纯文字或纯语音记录删除后在途生成不会迟到落库。
- 新增统一附件快照校验，photo/voice 的 entryID、userID、dayKey 及 voice target photo owner 损坏时 fail closed。
- 使用冻结的 V1 SwiftData schema 建立真实无 revision 磁盘 fixture，验证自动迁移为 revision 0 并可继续编辑至 revision 1。
- 共享隐私门覆盖记录/日记编辑、日记历史、语音编辑、每日状态和全屏照片等独立 presentation，后台时禁用交互并保留未保存稿。

### 验证

- 全量 Swift parse、`plutil -lint LifeNotes.xcodeproj/project.pbxproj` 与 `git diff --check` 通过。
- Xcode 26.6 / Swift 6 完整严格并发与 warnings-as-errors 的 `build-for-testing` 通过。
- iPhone 17 Pro / iOS 26.5 Simulator 通过 Xcode 执行 186 项单元与集成测试，186 项通过；报告为 `Test-LifeNotes-2026.07.15_16-08-39-+0800.xcresult`。
- 首次全量运行暴露两个旧夹具与新不变量冲突；修正为合法 owner 下的路径损坏 fail-closed 和非 generated 历史损坏后，第二次全量回归 0 失败。

### 风险与待办

- 当前 Simulator 已设置设备密码并直接进入密码回退页，未知密码下无法完成 Face ID 返回后 presentation 保活、Dynamic Type、VoiceOver 和键盘的人工验收；自动化和共享隐私门严格构建已通过，真机仍需补验。
- 搜索当前在本地全量扫描记录与附件，数据规模增大后需要索引、分页和持久层取消检查。
- 编辑稿保留于进程内；进入后台会隐私覆盖，但若系统终止进程，未保存编辑仍会丢失。
- 下一阶段按最新决定在 macOS 实现跨平台、Linux-ready、容器化 AI 后端；AI 代理只发送文字、图片批注和语音转写，不发送本机路径，API key 只在后端环境变量或 secret 中保存。
- 云同步与多设备同步作为独立阶段，需要 tombstone、离线 outbox、服务端 cursor、认证、对象存储和冲突合并，不能与首个 AI 接口混为一体。
