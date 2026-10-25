# Kazumi 的 App Intents 机会评估

> 分析日期：2026-10-25 · 代码基线：`241e7ab6`（分支 `native/plugin-layer`，工作区干净）· 首次分析

## 现有的 App Intents

**这个 App 目前声明 0 个 App Intent。** 没有 `AppIntent`、`AppShortcutsProvider`、`AppEntity`、`EntityQuery`、`AppEnum` 或任何 schema 宏声明，也没有 widget 或 control 扩展——所以快捷指令、聚焦、Siri、Apple 智能现在都没有可用的入口。

搜索范围：`ios/Runner/NativeApp` 下全部 133 个 Swift 文件（逐目录），加上 `ios/project.yml` 的目标定义。两个目标 `Runner`、`RunnerTests`，没有别的扩展目标。

| 业务动作 | 已有 Intent / 快捷指令 / 实体 / 查询 | 现在接了什么（入口、App 快捷指令、schema） | 缺什么 |
| --- | --- | --- | --- |
| — | 无 | 无 | 全部待建 |

源码里有集成，不等于系统入口就能看见或能跑——这个 App 现在连声明都没有，谈不上入口。

## 项目与范围

- 项目：Kazumi（`/projects/054be8c4-8fb6-4080-b549-44847e3498ee`），iOS 原生版。
- 来源：导入型。仓库原本是 Flutter 工程，`ios/Runner/NativeApp/` 是用纯 SwiftUI 重写的原生版，与原 Dart 实现逐页对齐。
- 这次为什么分析：原生版核心功能（推荐、时间表、追番、详情、播放、历史、设置）这一轮已经落地，按流程做第一次 App Intents 机会盘点。
- 没有 brief 文件；行为口径以原 Dart 实现和代码注释为准。
- 读过：应用入口与依赖装配、路由、追番与历史存储、时间表存储、Bangumi API 与缓存、详情页的追番状态写入链路、搜索接口。没读过：播放器内部选源细节（只读到入口签名）。

| 目标 / 配置 | 相关源码 | 部署版本 | SDK / 工具链证据 | 未知 |
| --- | --- | --- | --- | --- |
| `Runner`（App） | `ios/Runner/NativeApp/**`（133 个 Swift 文件）、`ios/Runner/Assets.xcassets` | iOS 26.0 | `ios/project.yml`：`deploymentTarget iOS 26.0`、`SWIFT_VERSION 6.0`、`SWIFT_STRICT_CONCURRENCY complete`、`xcodeVersion 26.0`；实际编译在远端 `runbuild` 主机上完成 | **本机没有 Xcode / iOS SDK，这次也没法联网查 Apple 文档（两个联网工具都返回 402 额度用尽），所以没有任何符号级可用性证据。** |
| `RunnerTests` | 测试目标 | iOS 26.0 | 同上 | 与本次评估无关 |

## 结论

**可以立刻开工的第一批：0 个。**

原因不是功能不够，而是这一条证据链断了：我既读不到本机的 SDK 声明（沙箱里没有 Xcode），也读不到 Apple 文档（联网工具额度用尽）。App Intents 的 `AppIntent`、`AppEntity`、`AppShortcutsProvider` 这些符号各自的最低系统版本，我没法在本次分析里指到具体声明或文档页。按评估规则，这种路径要标成「待核实」并移出可开工批次，不能靠记忆里的版本号顶上去。

**一个检查就能解锁整批**（在远端编译机上，一分钟内）：确认 iOS 26 SDK 里 `AppIntents` 模块存在且 `AppIntent` 协议可见——例如在编译机上看 `AppIntents.framework` 的 `.swiftinterface`，或编一个三行的探针文件。这条通过后，下面「待核实」里的第 1、2 项就是第一批。

**已经排好序、待核实的三项**（业务侧证据都在，只差可用性这一条）：

1. 打开某部番的详情——价值最高，追番列表就是现成的实体来源，成本 S/M。
2. 今天（或某天）有什么番——Siri 一句话能问的问题，成本 M。
3. 搜索番剧——成本最小，但和「打开详情」抢同一类入口，放后面。

**不建议进第一批的**：改追番状态（要连 Bangumi 账号、远端写入失败会整体作废，得先想清楚确认与回滚）、从历史继续观看（要先跑规则选源，播放器在后台不成立）。

需要产品决定的一件事：第一批是「详情 + 今天有什么番」两项一起上，还是先只做详情这一项。

## 逐个动作

### 打开番剧详情 — 「嘿 Siri，打开药屋少女的详情」

- **业务状态**：已实现。详情页是完整功能页，路由、数据、播放入口都在。
- **代码链路**：
  - 入口：`Features/Collect/LibraryScreen.swift` 的 `onOpen` → `router.push(.bangumiInfo(bangumiID: entry.id))`；同样写法在 `Features/Bangumi/Views/BangumiPosterCard.swift`、`Features/Timeline/BangumiTimelineCard.swift`、`Features/Info/InfoTabPanels.swift`、`Features/Player/PlayerScreen.swift` 都有。
  - 路由：`App/State/AppRouter.swift` 的 `enum AppRoute { case bangumiInfo(bangumiID: Int) }`，`push` 走导航栈。
  - 数据：`Features/Bangumi/Service/BangumiAPI.swift` 的 `info(id:)`；`Features/Bangumi/Service/BangumiSubjectCache.swift` 提供 24 小时落盘缓存（`item(for:)`、`needsInfoRefresh(_:)`），所以已看过的番在没网时也能出内容。
  - 实体来源：`App/State/LibraryStore.swift` 的 `LibraryEntry`（`id`、`name`、`nameCn`、`imageURL`，`Codable` 落盘在 `Application Support/Kazumi/library.json`），ID 重启后仍然有效。
- **判定**：**待核实**。业务链完整，只差符号可用性证据。
- **方向**：动作「打开番剧」+ 实体「番剧」。参数：一个必填的番剧实体。实体解析分两层——先查本地追番库（离线、稳定、不需要账号），再允许用 `BangumiAPI.search(keyword:)` 按名字搜在线库兜底；重名时让系统问一句，不要默认挑第一个。执行时把 App 带到前台并压入 `AppRoute.bangumiInfo`。**新增的是「待处理路由」这一段**：App 现在没有 URL scheme，也没有 `onOpenURL`，Intent 执行完没法直接把路由塞进运行中的导航栈，需要在 `AppRouter` 上加一个 pending route、由 `KazumiApp`/`AppRoot` 在激活时消费。这是提案，不是现有能力。
- **访问与安全**：不需要登录，不需要设备认证；只读，不写任何数据，没有破坏性。输出里带番剧名，属于用户自己的追番数据，可接受。
- **普通路径**：`AppIntent` + `AppEntity` + `EntityQuery`，提案。
- **schema 增强**：未确定。没有核实到任何 schema 域/成员，因此不作建议。
- **系统入口**：快捷指令与聚焦靠实体索引，Siri 靠 App 快捷指令短语；三者的可见性都要在真机上验，本次一项都没验。Apple 智能另说，不能从声明里推断。
- **优先级与成本**：第 1 位。用户价值高（追番的人高频动作就是从系统入口直达详情），成本 S/M：主体是一个实体 + 一个查询 + 一个 Intent，加一段待处理路由。
- **验证与下一步**：代码已读到位；编译、可见性、模拟器执行、真机执行**都没做**。先做上面那条 SDK 可用性检查。

### 今天有什么番 — 「嘿 Siri，今天有什么番」

- **业务状态**：已实现。时间表页每天一列，数据来自 bangumi 日历。
- **代码链路**：
  - 数据：`Features/Bangumi/Service/BangumiAPI.swift` 的 `calendar() async -> [[BangumiItem]]`，按周一到周日返回 7 组，顺带把条目写进 `BangumiSubjectCache`。
  - 展示：`Features/Timeline/TimelineController.swift` 负责排布；`Features/Timeline/BangumiTimelineStore.swift` 是 UserDefaults 单例（`kazumi.settings.bangumiTimelineEntries`），存用户手改的放送星期和「在时间表展示」开关，界面之外可直接读。
  - 注意口径：**放送星期只认 bangumi 日历分组和用户手改，不从更新时刻反推**（`timeline_controller.dart:245-252` 的注释写了原因：AniList 的 airingAt 跟先行配信，bangumi 的星期跟电视放送，反推会把番挪错天）。做查询时也要守这条。
- **判定**：**待核实**。同样是缺符号证据。
- **方向**：动作「列出某天在播的番」。参数：可选星期（不传就是今天）。结果：若干条番剧，带名字和放送时刻。**口径提案**：默认只列 bangumi 日历里那天的番；「放送时刻」用现有的 `BangumiAirTimeService`（优先 AniList）——但星期永远来自日历分组。后台执行可行：`calendar()` 是纯网络请求，不依赖界面。
- **访问与安全**：不需要登录；只读。网络失败时返回空列表并说明，不要假装成功。
- **普通路径**：`AppIntent` + 参数 + 返回列表，提案。
- **schema 增强**：未确定。
- **系统入口**：Siri 与快捷指令最自然；聚焦意义不大（内容每天变）。
- **优先级与成本**：第 2 位。成本 M：主要是把日历结果整理成适合口头播报的短文本（别把 30 部番全念出来）。
- **验证与下一步**：同第 1 项，先过可用性检查。

### 搜索番剧 — 「在 Kazumi 里搜一下药屋少女」

- **业务状态**：已实现。搜索页与搜索接口都在。
- **代码链路**：`AppRoute.search(keyword: String)`；`Features/Bangumi/Service/BangumiAPI.swift` 的 `search(keyword:tags:limit:offset:sort:...)`。
- **判定**：**待核实**，且优先级低于前两项。
- **方向**：参数一个关键词字符串，执行后打开搜索页并带上关键词。同样需要上面说的待处理路由。
- **优先级与成本**：第 3 位，成本 S。价值一般：能搜的地方太多，Siri 里「搜番」不像「打开我追的番」那么有指向性。
- **验证与下一步**：同前。

### 改追番状态（在看 / 想看 / 看过 / 搁置 / 抛弃）

- **业务状态**：已实现，但链路比看起来重。
- **代码链路**：`Features/Info/BangumiInfoScreen.swift` 的 `collect(_:_:)` → 若设置里「自动同步追番」开着，先 `environment.bangumiSync.pushCollectible(bangumiID:type:)` 推到 Bangumi 服务器，**推失败就整次作废**（`applyCollect` 不会被调用）；成功才 `applyCollect` → `LibraryStore.upsert` + `BangumiTimelineStore.shared.dropIfNotWatching`。
- **判定**：**不建议进第一批**。理由：远端写入依赖账号与网络，失败语义是「什么都不改」；系统入口触发时没法像界面上那样给一句「同步失败，已取消」。要做就得先定确认策略和失败回执，属于产品决策。
- **会改变决定的事**：如果只做「本地追番库」的状态修改（不动 Bangumi 账号），并且失败时明确回报，就可以重估。

### 从历史继续观看

- **业务状态**：部分实现。历史记录（`WatchRecord`：`bangumiID`、`episodeNumber`、`progressSeconds`、`durationSeconds`）已落盘在 `library.json`。
- **代码链路**：`App/State/LibraryStore.swift` 的 `history`；播放入口 `AppRoute.player(bangumiID:episode:source:)`，需要先跑规则选源（`Features/Plugins`）。
- **判定**：**不建议**。选源要跑插件规则、要网络，播放器在后台不成立；做成系统入口的实际体验是「点了之后还要等选源」，不如打开详情页。

### 查看追番列表

- **业务状态**：已实现（`LibraryStore.watchingEntries`）。
- **判定**：**不单独立项**。它天然是「打开番剧」那个实体的查询结果，单独做一个「列列表」的 Intent 只是重复。

## API 与可用性证据

**本次没有任何一行是核实过的**：本机无 Xcode / iOS SDK，联网工具在分析时返回 402。下表只列出各方案依赖的符号，全部标未验证，并给出该查哪里。

| ID | 符号 | 最低系统版本 | 需要的 SDK / 选定 SDK 证据 | 适用面 | 来源 | 核实日期 | 缺口与下一步 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | `AppIntent` 协议 | 未验证 | 需 iOS 26 SDK 中 `AppIntents` 模块 | 全部方案 | 无（本次不可读） | 2026-10-25（未核实） | 编译机上查 `AppIntents.framework` 的 `.swiftinterface` |
| E2 | `AppEntity` / `EntityQuery` | 未验证 | 同上 | 打开详情 | 无 | 同上 | 同上 |
| E3 | `AppShortcutsProvider` / `AppShortcut` | 未验证 | 同上 | Siri 短语、快捷指令 | 无 | 同上 | 同上；短语令牌是否被接受要真机验 |
| E4 | `@Parameter`、`IntentDescription` | 未验证 | 同上 | 全部方案 | 无 | 同上 | 同上 |
| E5 | Apple 智能 schema 域/成员 | 未确定 | 未核实 | 无 | 无 | 同上 | 没有证据就不提方案 |

## 计划中、存疑与排除的

| 功能 / 用户任务 | 业务状态与证据 | 判定与原因 | 什么会改变结论 |
| --- | --- | --- | --- |
| 改追番状态 | 已实现（`BangumiInfoScreen.collect`） | 排除出第一批：远端写入 + 账号 + 失败即作废 | 只改本地库并明确回报失败 |
| 继续观看 | 历史已落盘，播放需选源 | 排除：后台不可行，体验不如打开详情 | 选源能在毫秒级完成 |
| 查看追番列表 | 已实现 | 不单独立项，是实体的查询结果 | — |
| 通知设置 / 主题切换等设置项 | 已实现 | 排除：纯设置项，没有任务价值 | — |
| 以图搜番 | 未读实现细节 | 本次不评：证据不足 | 读完 `Features/Search` 相关实现 |

## 交接给产品

- 提议的第一批：**待核实状态，0 项可开工**。解锁条件只有一个——在编译机上确认 `AppIntents` 模块与 `AppIntent` 协议的可用性（E1~E4）。
- 解锁后按顺序做：打开番剧详情 → 今天有什么番 → 搜索番剧。
- 需要产品决定：第一批两项一起上，还是先只做「打开详情」。
- 真正写代码是另一件事，要单独开任务。
- 本次分析**只写了这份报告**，没有改任何代码、配置、权限或部署目标，也没有执行任何业务操作（没改追番状态、没发请求）。编译、模拟器、真机都没验。
