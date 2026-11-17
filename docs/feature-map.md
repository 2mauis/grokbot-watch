# 功能地图 / Feature map

和 [README](../README.md)、[spec.md](spec.md) 同步维护。事实基线为 main `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f`；**产品 MVP 尚未达成**。

实现与验证分开记录：“纯逻辑已实现”表示核心代码存在，不表示 App 集成完成或整项已验收。L 为纯 Swift 单元测试，S-build 为模拟器构建／内嵌结构，S-UI 为启动／交互观察，D 为真机，E 为真实服务端到端；证据和限制见 [验证层级](mvp-status.md#验证层级)。所有行的 D／E 均未验证，功能 UI 均待开发。共同的 S-build 成功只验证 App 骨架，不能提升各功能的交互状态。

## MVP 状态矩阵

各行均属于原 MVP，尚未达到完整产品验收；下一步仍使用 [原规格 §5](spec.md#5-功能要求与验收条件) 的要求与阈值。

| 编号／功能／依赖 | 当前实现 | 已有验证环境与来源 | 尚缺项 | 下一步验收 |
|---|---|---|---|---|
| B1：iPhone 登录；无前置依赖 | 纯逻辑已实现：授权状态、PKCE 编排、刷新与本机清理；App 集成待开发 | L：macOS CI；[AuthFlowTests、AuthRefreshTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/AuthTests.swift) 与 [SignOutPurgeTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/SignOutPurgeTests.swift)，哈希、授权和凭据存储均注入测试实现 | 浏览器授权、实际哈希／AuthTransport、Keychain TokenStore、App 登出接线及跨设备清理 | 按 B1 接真实授权与本机 Keychain，核验 ThisDeviceOnly、刷新不重放、登出；完成 D／E，不能用内存存储测试代替 |
| B2：私有接口客户端与协议失效；依赖 B1 | 纯逻辑已实现：Bot 路由、响应模型校验、写请求约束与只读对账；App 集成待开发 | L：macOS CI；[BotRoutingTests、ProtocolGuardTests、OutboxTests、MessageReconcileTests、EntryStateGuardTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/BotTests.swift)，HTTP 为 fake | 真实 HTTP 线协议／RPC 与响应映射、gateway bootstrap、事件流和 App 调用 | 核实真实接口契约，再验两类 harness 的读写、对账及受影响功能降级（E）；保留不自动重放写请求要求 |
| B3：双端 WC 协议；无前置依赖 | 纯逻辑已实现：信封、持久发件箱、去重／先落盘、结果与快照合并；App 集成待开发 | L：macOS CI；[EnvelopeCodecTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/FeatureTests.swift)、[RelayIdempotencyTests、WatchOutboxTests、ResultDeliveryTests、NonceDerivationTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/RelayTests.swift)；JSON 往返与重开 actor，WC 为 fake | WCSession 适配器、生命周期／重启恢复接线、双端登出、已排队旧消息隔离及设备存储保护 | 接线前处理 [S2-4](mvp-status.md#剩余事项)；在 D 验失联、挂起、重启、回执乱序与跨设备清理，验证结果保证送达 |
| F1：widget／Allow-Deny／user-form；依赖 B2、B3 | 纯逻辑已实现：选项与字段校验、一次性决定、条目状态预检；App 集成待开发 | L：macOS CI；[WidgetAnswerTests、ApprovalTests、UserFormSupportTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/FeatureTests.swift) 及 [EntryStateGuardTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/BotTests.swift) | 真实请求映射、按钮／表单 UI、乐观回显与拒绝恢复 | 真实传输接入前修 S2-1；按原规格完成 S-UI／D 交互及 E 服务端确认，未知表单留手机处理 |
| F2：智能快速回复；依赖 B2、B3 | 纯逻辑已实现：候选过滤、可注入模型与规则回退；App 集成待开发 | L：macOS CI；[SuggestionEngineTests、SuggestionFallbackTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/FeatureTests.swift)，模型为 fake；S-4 未验证 | Foundation Models 实际适配器、消息驱动生成／缓存、同步与点选发送 UI、过期提示 | 保留 S3-10 候选契约核对；完成 S-4 及原规格的数量／长度／新鲜度验收，再验 D／E 点选发送 |
| F3：自定义常用回复卡片；依赖 B3 | 待开发；快照 cards 字段和消息来源标记不构成卡片功能 | 无功能验证；当前没有 QuickCardStoreTests；共同 S-build 不验卡片 | 编辑、增删排序、本地存储、Bot 绑定、同步与离线 UI | 按 F3 补纯逻辑测试、S-UI 编辑和 D 双端同步／离线验收；保留最多 12 张、每张 60 字符 |
| F4：系统听写兜底；依赖 B3 发送 | 待开发；dictation 来源标记不构成系统输入接入 | 无功能验证；当前未接入系统听写 UI | 系统文本输入、确认发送、结果反馈 | 按 F4 在 D 验听写、确认及发送；录音转写仍属后续 F4+ |
| F5：手机麦克风语音对话；依赖 B2、B3、S-3 | 待开发；尚无语音会话与通话控制实现 | 无功能验证；S-3 真机矩阵未验证，不能选定 A／B 为已完成方案 | iPhone 音频／Realtime 会话、凭证、后台会话管理、手表控制／字幕与结束写回 | 先按 [S-3 原矩阵](spec.md#7-验证项spike结论写回-design) 得出结论，再实现并验收 A 或 B；保留手机麦克风模式及全部公共需求 |
| F8：主 Bot 收件箱；依赖 B2、B3 | 纯逻辑已实现：待处理项筛选、排序、最新消息与匹配候选快照；App 集成待开发 | L：macOS CI；[InboxSnapshotTests](../Packages/GrokBotWatchCore/Tests/GrokBotWatchCoreTests/FeatureTests.swift)，输入为合成模型 | 真实数据／事件刷新、WC 快照接收、冷启动缓存、列表和过期提示 UI | 按 F8 与 B3 完成 S-UI 列表、D 冷启动／离线及 E 真实待办同步，不以演示图代替 |

上表 L 的公开运行与版本绑定见 [CI 公开证据](ci.md#公开运行证据)；S-UI 只有项目报告的双端占位页面启动，未独立核验原始截图，不作为任一行功能交互验收。S2-3 已关闭的边界及其余非阻断登记见 [剩余事项](mvp-status.md#剩余事项)。

## 后续范围

| 编号 | 功能／依赖 | 实现状态 | 验证与下一步 |
|---|---|---|---|
| F4+ | 录音后交 iPhone 或 xAI 转写；依赖 B3 | 待开发，仍属后续 | 无功能验证；按后续规格另行实现并真机验收 |
| F6 | 麦克风智能路由，手表中转／直连；依赖 F5，直连还依赖 F7 | 待开发，仍属后续 | S-1、S-2 未验证；不能以 F5 手机麦克风模式或模拟器结果代替 |
| F7 | 手表独立登录与 HTTPS 直连降级；依赖 B2 | 待开发，仍属后续 | 无真实手表登录／直连验证；须独立会话并完成 D／E 验收 |
| F8+ | complication／可操作通知；依赖 F8 | 待开发，仍属后续 | 无功能验证；保留 App Groups 实测与本地通知范围 |

快速回答的优先级：F2 智能快速回复 → F3 自定义卡片 → F4 语音输入（最后的兜底）。

防重复和防丢失规则对 F1–F5 的所有写操作都适用，见 architecture §5.1、§5.2：没收到 ack 只重投（`attempt` 不变），收到 `notDelivered` 后用户点重试（`attempt` 加 1），发消息的 nonce 始终由 `opId` 派生。S-3 的通过标准只看"未运行、已挂起、前台后锁屏"三种状态，"被用户划掉"是已知限制。

签名约束：免费 Personal Team 侧载，签名 7 天过期。远程推送等依赖付费会员的能力不可用，对各功能的影响见 spec §10；F8+ 的可操作通知只能用本地通知，complication 是否可用要先验证 App Groups。

CI 已合入 main，`e0226fe` 的 [main push 运行成功](https://github.com/2mauis/grokbot-watch/actions/runs/44040269389)。它覆盖 macOS 上的 L、双端 S-build 和检查器 fixtures，不覆盖 Linux Swift、S-UI、D 或 E，也不替代独立评审。详见 [ci.md](ci.md)。
