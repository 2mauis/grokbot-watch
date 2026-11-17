# 目前能做什么，接下来做什么

**现在已做一部分登录、消息、回复、确认和清理逻辑，但 App 仍是文字骨架，暂时不能连接真实 Grok 使用。**

已有项目报告在模拟器启动过双端文字骨架，原始截图未独立核验，功能交互未验证；CI 的 App 检查只做编译和内嵌包检查，不算功能实测，历史演示图也不是当前交互证据。

## 目前的功能

| 功能 | 已做什么 | 模拟器实际测过什么 | 还没做/没测什么 |
|---|---|---|---|
| 手机登录连接 | 部分实现：登录状态、刷新逻辑已做，实际登录未接通 | 未做功能实测 | 真正登录、保存登录信息和连接服务 |
| 手表消息／待办列表 | 部分实现：列表筛选、排序逻辑已做，手表页面未接通 | 未做功能实测 | 真实消息、刷新、列表页面和离线缓存 |
| 快捷文本回复 | 部分实现：候选过滤和规则回复已做，实际生成与发送未接通 | 未做功能实测 | 手机本地模型生成候选、手表点选和真实发送 |
| 常用回复卡片 | 未实现：只有数据字段，没有编辑或同步功能 | 未做功能实测 | 编辑、保存、排序、同步到手表并发送 |
| 系统听写回复 | 未实现：只有消息来源标记，未接系统听写 | 未做功能实测 | 听写输入、确认文字和发送 |
| 确认按钮／选项／简单表单 | 部分实现：选项和字段校验已做，实际按钮与提交未接通 | 未做功能实测 | 显示真实问题、点击或填写、提交和结果回显 |
| 手机手表通信 | 部分实现：消息格式和收发流程已做，真实双端通信未接通 | 未做功能实测 | 实际连接、消息同步、后台送达和重启恢复 |
| 断线重试与防重复 | 部分实现：操作编号、重试条件和去重已做，真实断线流程未接通 | 未做功能实测 | 弱网、断线、回执丢失和重启后的防重复验证 |
| 登出清理 | 部分实现：本机清理及旧操作失效逻辑已做，App 登出与双端清理未接通 | 未做功能实测 | 登出按钮、双端退出、重新登录和跨重启验证 |
| 语音开始／结束／静音与手机麦克风通话 | 未实现：尚无语音会话与通话控制 | 未做功能实测 | 手机麦克风通话、手表开关和字幕；先验证锁屏／挂起时能否发起 |
| 真机安装 | 部分实现：工程和安装说明已准备 | 未做功能实测 | 实际签名、安装和真机功能均未验收；模拟器不能验证真机安装 |

## 建议后续顺序

**建议后续顺序，尚不是已批准实施计划。**

1. **打通手机登录和消息链路。** 交付可登录、读取真实消息并发文本的手机页面；登录后刷新消息、发一条回复，与真实对话核对。
2. **接通手表列表、回复和确认。** 交付待办列表、候选回复、确认按钮和简单表单；在手表上点选或填写，核对手机与服务端的结果。
3. **补齐常用卡片和系统听写。** 手机编辑的卡片能同步到手表，听写后可确认发送；重开页面检查卡片仍在，并核对实际发出的文字。
4. **完成手机麦克风通话和手表开关。** 先在真机验证手机锁屏／挂起等原规格场景能否从手表发起；否则按原规格采用手机发起、手表控制。通话时点静音、结束，检查麦克风、字幕和会话状态。
5. **完成真机交付与异常场景验证。** 走通手机和手表的自用签名安装流程，实测弱网、断线、离线、重启、双端登出及重新登录，确认不重复发送、不带回旧数据。

## 以后再做

- 录音后转写成文字。
- 自动麦克风路由，以及手表麦克风中转和直连。
- 手表独立登录、通过 HTTPS 直连的降级方式。
- 表盘入口和本地可操作通知。
- 其他候选生成后端（如 xAI）及离线候选缓存优化。

常用卡片、系统听写和手机麦克风语音都仍在第一版内；以上才是原规格的后续范围。完整要求见 [原规格](spec.md)。

<details>
<summary>技术参考：验证分层、版本证据、源码与遗留事项</summary>

## 验证层级

| 层级 | 当前事实与来源 | 不能据此认定的事项 |
|---|---|---|
| L：纯 Swift 单元 | macOS CI 已通过，见 [CI 证据](ci.md#公开运行证据)。授权、哈希、HTTP、WC 和候选模型使用协议注入／fake；部分存储用例实际读写临时 JSON 文件并重开 actor | 真实授权／Keychain、HTTP／WCSession／Foundation Models 适配器已实现；真实进程重启或跨设备行为已验收 |
| S-build：模拟器构建与结构 | CI 双端 Debug clean unsigned build、iOS 内嵌 Watch app 及 plist 关系检查通过 | App 已启动、按钮可交互、真实 Grok 可用 |
| S-UI：启动与交互 | 当前版本双端模拟器启动为项目报告，未独立核验原始截图；不作为功能交互验收。当前源码两个入口均只显示文本占位页 | 历史收件箱／审批／候选演示图对应当前入仓 UI，或任何功能交互已实测 |
| D：真机 | 签名、安装、跨设备、锁屏／挂起、麦克风及系统听写均未验证 | 模拟器或 fake 的结果可替代真机结论 |
| E：真实服务端到端 | 真实 HTTP／WC／Keychain 等适配器及 App 接线待开发；尚无真实 Grok 端到端验收证据 | 纯逻辑写入 fake 后得到 accepted 等于真实服务处理成功 |

这只是现有 L／S／D 验收面的事实细分，S-build 与 S-UI 分开说明，E 用来标明真实服务链路；原规格的验收条件和所有未勾选项保持原样。Linux Swift 尚无执行证据。

## 版本与公开证据

本次表达重写前的基线是 [PR #4](https://github.com/2mauis/grokbot-watch/pull/4) head `b53bbb3a761161cb339c4bcb7d5d8edae5b5825e`。[对应成功运行](https://github.com/2mauis/grokbot-watch/actions/runs/44064567633) 的公开日志核验记录为：32 个检查器测试、58 tests／19 suites、双端 clean build 及内嵌检查均通过。它只证明重写前基线的测试与构建结果，**本次表达重写尚未运行 CI**。

下列为更早的核心、首次 CI 与 main 证据，各自绑定原版本：


- 核心登出修复来自 [PR #2 head `7f114c160f01c19703bee0055bd526ee01c04e9d`](https://github.com/2mauis/grokbot-watch/commit/7f114c160f01c19703bee0055bd526ee01c04e9d)，已合入 `420e203728df734ac93d4a2cbae9708b67eedd21`，随后与 CI 一同进入 main `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f`。
- [首次 CI PR run](https://github.com/2mauis/grokbot-watch/actions/runs/44032170467) 对应 PR head `4953d14e8d2c0e65e8859ecf47751751274ca36b`、base `420e203728df734ac93d4a2cbae9708b67eedd21`；[合入后的 main push run](https://github.com/2mauis/grokbot-watch/actions/runs/44040269389) 对应 `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f`。两份记录均成功，各自版本不可混写。
- 首次 PR 日志的执行汇总为 58 tests／19 suites；这是纯逻辑测试，不是真实 HTTP／WC。完整工具链、PR 合成 ref 与结构检查记录见 [ci.md](ci.md#公开运行证据)。本轮文档同步没有重新执行 Swift、Xcode 或 CI。

## 源码核对

[iOS 入口](../Apps/iOS/GrokBotWatchApp.swift) 与 [watchOS 入口](../Apps/watchOS/GrokBotWatchApp.swift) 均为 `WindowGroup { Text("GrokBot Watch") }`，只导入核心包，尚未创建服务客户端或功能页面。README 中三张历史代表性图只作演示，不构成当前入仓交互实现或验收证据。

核心共 11 个源文件，当前职责如下；存在接口或数据字段不等于已有平台适配器。

| 文件 | 已有内容与边界 |
|---|---|
| [AuthClient.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/AuthClient.swift) | PKCE 编排、授权／刷新／登出状态；PKCEHasher、AuthTransport、TokenStore 均为注入接口，尚无真实浏览器或 Keychain 实现 |
| [BotClient.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/BotClient.swift) | 请求与路由模型、响应守卫；HTTPTransport 尚无真实网络实现，线协议映射仍待核实 |
| [Answers.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/Answers.swift) | widget、一次性批准与表单值校验，无交互 UI |
| [EnvelopeCodec.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/EnvelopeCodec.swift) | v1 编解码、快照大小检查及 WCChannel 接口；尚无 WCSession 实现，也未接语音消息 |
| [Operations.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/Operations.swift) | 操作、attempt／nonce、ack／result 模型；card／dictation 来源枚举不代表 F3／F4 已实现 |
| [OperationStore.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/OperationStore.swift) | OperationStore 接口与原子 JSON 存储；设备文件保护与备份策略待接线核验 |
| [Outbox.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/Outbox.swift) | 确认预检、单次写入和只读对账编排；实际传输由注入对象完成 |
| [PhoneRelay.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/PhoneRelay.swift) | 准入、先落盘、去重、结果／快照发布与本机 purge；不含真实跨设备生命周期接线 |
| [WatchOutbox.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/WatchOutbox.swift) | 持久发件箱、重投／重试、结果合并和本机 purge；WC 通道仍需适配器 |
| [SuggestionEngine.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/SuggestionEngine.swift) | 选项优先、候选过滤、模型接口与规则回退；尚无实际 Foundation Models 调用 |
| [Inbox.swift](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/Inbox.swift) | 主 Bot 待处理项／最新消息／候选快照；cards 仅字段，无卡片编辑、真实同步或列表 UI |

测试分组与来源为 [AuthTests.swift](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/AuthTests.swift)、[BotTests.swift](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/BotTests.swift)、[FeatureTests.swift](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/FeatureTests.swift)、[RelayTests.swift](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/RelayTests.swift) 和 [SignOutPurgeTests.swift](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/SignOutPurgeTests.swift)，fake 与公共夹具见 [TestSupport.swift](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/TestSupport.swift)。本机 JSON 文件与 actor 重建测试不等同于 App 重启接线验收。

## 剩余事项

**S2-3 已关闭的范围是本机单实例清理。** `7f114c1` 的修复使清理前挂起的操作按旧代次失效，并等待已交给通道的发布完成；SignOutPurgeTests 覆盖本机清理、失败重试及相关竞态。它不表示 App 已接入登出回调，更不表示跨设备传播、真实重启接线或通道中旧消息已处理；这些仍在 B1／B3 的接入与真机验收范围。

S2-1、S2-2 及核心第一轮 S3 继续按 [PR #2 handoff](handoffs/pr-2-sign-out.md#下轮) 登记，不升级为全部阻断。S2-1 应在真实 F1 传输前修复；S2-2 的快照裁剪责任、S3-10 的候选契约、存储保护及其余补验仍按原记录推进。历史设计／决策中的编号属于各自评审轮，不与此处核心复评编号混用。

**S2-4（核心复评登记，非阻断，接入真实跨设备前处理）**：旧在途 `opId` 在清理后跨代次重新投递，可能被重新准入；旧请求仍在途时，可能对同一操作产生第二次写，确认／表单无 nonce 兜底。当前 [PhoneRelay.purge 的公开源码](https://github.com/2mauis/grokbot-watch/blob/e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f/Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/PhoneRelay.swift#L53) 清空记录并更新本机代次，而 [receive 准入逻辑](https://github.com/2mauis/grokbot-watch/blob/e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f/Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/PhoneRelay.swift#L121) 会按进入时的新代次和空历史判断；旧调用失效并不等于新进入的旧消息被隔离。[现有竞态测试](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/SignOutPurgeTests.swift) 验证代次内保留新操作预约，不构成跨代次旧消息拒绝验收。下一步明确跨登录代次的旧消息隔离契约，补回归测试及双端验收；本次仅登记，不改生产代码或门禁。

**核心第二轮复评，基于 `7f114c1`；以下均非阻断，登记不豁免。** 使用 S3-R2 编号，与设计轮及第一轮 S3 分开记录。

| 编号 | 登记事项与后续状态 | 当前源码／文档依据 |
|---|---|---|
| S3-R2-1 | 清理等待未设上限，WCChannel 未明确“入队即返回”；通道契约及超时待明确 | [PhoneRelay](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/PhoneRelay.swift)、[WCChannel](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/EnvelopeCodec.swift) |
| S3-R2-2 | 清理未完成标志仅在 AuthClient 内存；失败后跨进程重启的清理与再登录契约待验，当前未持久化该标志 | [AuthClient](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/AuthClient.swift) |
| S3-R2-3 | spec“不能写回或发布旧结果”与 architecture“不能写回或发起新的结果发布”措辞待统一；原测试允许已交给通道的旧发布完成。本轮仅登记，不改规范阈值 | [spec](spec.md)、[architecture](architecture.md) |
| S3-R2-4 | SignOutPurgeTests 门控等待没有超时；明确超时及失败回归待补，job 整体 30 分钟超时不表示此项已解决 | [SignOutPurgeTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/SignOutPurgeTests.swift) |
| S3-R2-5 | WatchOutbox.deliver 在清理后静默返回，手表清理不等待在途 sendMessage；并入跨设备契约与真机补验 | [WatchOutbox](../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/WatchOutbox.swift) |
| S3-R2-6 | README 代表图说明与占位源码的差异已在本轮文档中修正；不代表交互实现或验收通过 | [README](../README.md)、[占位入口](../Apps/watchOS/GrokBotWatchApp.swift) |

S-3 仍是 F5 前置闸门，按 [原真机矩阵](spec.md#7-验证项spike结论写回-design) 得出 A／B 结论后再进入 F5 实现。S-4 的真实设备模型质量／延迟、其余真机与 E 验收均未完成。产品 MVP 要按原规格覆盖全部 MVP 行，不能用 CI 成功或演示图替代。

</details>
