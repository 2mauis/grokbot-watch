# MVP 实现与验证状态

截至 2026-11-17，事实基线为 [main `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f`](https://github.com/2mauis/grokbot-watch/commit/e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f)。**产品 MVP 尚未达成**。已交付纯逻辑核心、双端占位 App 和构建结构验证，真实 Grok 使用链路仍待开发。

逐 B1／B2／B3／F1／F2／F3／F4 系统听写／F5 手机麦克风／F8 的实现、证据、缺项与下一步见 [功能地图](feature-map.md#mvp-状态矩阵)。MVP 范围与 [spec v0.2](spec.md) 一致，F3、F4、F5 保留，F4+／F6／F7／F8+ 继续属于后续；本次只同步事实，不修改验收门槛。

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
