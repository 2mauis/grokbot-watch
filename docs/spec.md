# grokbot-watch 规格 v0 / Spec v0

当前阶段（2026-11-17）：纯逻辑核心、占位 App 和 CI 已合入 main `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f`，**产品 MVP 尚未达成**。实现与验证分开记录于 [功能地图](feature-map.md) 和 [MVP 状态](mvp-status.md)，实际 CI 证据见 [ci.md](ci.md#公开运行证据)。需求版本仍为 v0.2；本次状态同步不改变下列需求、验收阈值或勾选标准。

历史设计阶段状态：草案 v0.2 / 待复评（设计评审轮；v0.1 按首轮评审的 3 项阻断 S2 修订，v0.2 按复评的 2 项阻断 S2 修订，见 design/2026-11-16-review-decisions.md 和 design/2026-11-16-review-2-decisions.md）。采用模板：workflow-template 2.2.2（workflow v2.2）。
对应功能地图：[feature-map.md](feature-map.md)。架构：[architecture.md](architecture.md) 保留设计阶段记录，当前 CI 状态以 [ci.md](ci.md) 为准。调研与决策归档：[design/](design/)。

## 1. 背景与目标

官方 Grok Bot iPhone app 的通知会镜像到 Apple Watch，但在手表上只能看，不能回复、不能确认，也不能发起语音。本项目给官方 iPhone app 做一个**轻量补充**：

- 在手表上快速处理 Bot 发来的问题，尤其是确认类问答（widget 选项、Allow/Deny、user-form），默认面向用户指定的一个主 Bot（典型是 Chief of Staff 一类的调度 Bot）。
- 除了 yes/no，也能快速回答开放式问题。按优先级依次是：智能快速回复 → 自定义常用回复卡片 → 语音输入（ASR）兜底。
- 在手表上开始和结束与 Bot 的语音对话，并按场景智能选择用手表还是手机的麦克风。

形态：watchOS app 只负责轻量的回复和控制；iPhone 配套 app 负责登录、和 Grok Bot 服务通信（中转）、语音会话。两端用 WatchConnectivity 通信。手表有网而手机不在身边时，可以直接走 HTTPS 发送回复，作为降级路径。

后端：使用 Grok Bot 官方客户端的**私有、未公开接口**（协议设计参考 MIT 许可的 grok-wear，见 NOTICE.md），和官方 app 共用账号与对话记录。

使用边界（负责人已明确接受风险）：仅限仓库所有者本人使用，非商业，不上架，不公开分发，只侧载到自己的设备。

## 2. 非目标

- 不替代官方 iPhone app，不做 Bot 管理、routine、连接器、电脑接管、文件和图片附件。
- 不上 App Store，不对外分发 TestFlight，不商业化。
- 不读取、复用或转存官方 app 或其他设备上的凭据文件；凭据只能通过本 app 自己的登录流程获得。
- 不做后台常驻或保活：不滥用 workout 或 extended runtime session。
- 不替换 Siri，不监听唤醒词。
- 第一版不做 xAI 官方 API 直连路线（作为协议失效时的备选，见 architecture §8）。
- 历史阶段（spec-v0）只写规格和设计评审，不写实现代码，也不加 CI（`.github/**` 属于政策文件，要另行批准）。后续实现与单独批准的 CI 已进入 main，见文首状态；此处保留原阶段范围。

## 3. 优先级说明

负责人在 2026-11-16 定了"快速回答"的优先级：**智能快速回复 → 自定义卡片 → 语音输入（ASR，最后的兜底）**。F 编号按这个顺序排。确认类问答（F1）是"回复"能力本身的前提，排在最前；语音对话和麦克风路由排在快速回答之后。基础设施用 B 编号单列，不占 F 序号。

## 4. 功能清单

| 编号 | 功能 | 档位 |
|---|---|---|
| B1 | iPhone 配套 app 登录（浏览器授权加 PKCE），token 只存 iPhone Keychain | MVP |
| B2 | iPhone 端私有接口客户端：Bot 列表、读对话、发消息、widget/approval/user-form 应答、发送状态确认；协议失效检测 | MVP |
| B3 | WatchConnectivity 消息协议（版本化信封、操作 ID、手表持久发件箱、iPhone 先落盘、结果经 transferUserInfo 回传、应用上下文快照） | MVP |
| F1 | 手表处理确认类问答：widget 单选/多选、Allow/Deny、简单 user-form；结果回显，被拒时恢复按钮 | MVP |
| F2 | 智能快速回复：针对 Bot 最新一条消息，在 iPhone 端生成 2–4 条候选回复推给手表，一点即发 | MVP |
| F3 | 自定义常用回复卡片：在 iPhone 端编辑，同步到手表；按 Bot 可选过滤 | MVP |
| F4 | 语音输入兜底：系统听写（MVP）；录音后交 iPhone 或 xAI 转文字（后续） | MVP（只做系统听写）/ 后续 |
| F5 | 手表开关语音对话：由 iPhone 跑语音会话，手表做开始/结束/静音和字幕控制 | MVP（手机麦克风模式；手表能否冷启动通话取决于闸门验证 S-3，不通过则改为“手机发起、手表控制”） |
| F6 | 麦克风智能路由：手表麦克风（经 iPhone 中转或直连）和手机麦克风之间自动选择、可手动切换 | 后续（取决于验证项 S-1、S-3） |
| F7 | 手表直连 HTTPS 降级：手机不可达时，手表用自己独立登录的会话直接发送回复和确认 | 后续 |
| F8 | "需要你处理"收件箱和入口：打开手表 app 即列出主 Bot 待处理的问题；complication 一键进入 | MVP（收件箱）/ 后续（complication、可操作通知） |

### MVP 范围（第一版）

B1–B3，F1，F2，F3，F4 的系统听写，F5 的手机麦克风模式（形态以 S-3 结论为准），F8 的收件箱。

F5 的实现批次以 S-3 为前置闸门：S-3 没有结论之前，不开始 F5 的实现；其他 MVP 项不受影响。

### 后续

F4 的录音转写，F6，F7，F8 的 complication 和可操作通知，F2 的 xAI 生成后端，以及手表离线时的候选缓存优化。

## 5. 功能要求与验收条件

验收面分三种：L 表示本地单元测试（纯 Swift 包，可以在 Linux 或 macOS 上跑 `swift test`）；S 表示 Xcode 模拟器（需要 macOS）；D 表示真机（负责人的 iPhone 和 Apple Watch）。模拟器总是放行低层网络，所以凡是涉及网络限制的项都必须在真机上验收。

第一批纯逻辑实现的状态见 [功能地图](feature-map.md)。已有 fake／协议注入单元测试及模拟器构建结构证据，不能代替 App 交互、真机或真实服务验收；分层说明见 [MVP 状态](mvp-status.md#验证层级)。各项验收仍按对应的 L、S 和 D 验收面执行，下列验收框保持原状态。

### B1 登录
- [ ] 需求：iPhone 发起浏览器授权（PKCE，verifier 只在本机生成和保存）。测试：`AuthFlowTests`。输入：模拟的授权轮询响应。预期：token 写入 Keychain（`ThisDeviceOnly`，不同步），日志里不出现 token。验收面：L、D。
- [ ] 需求：刷新的结果不确定时不自动重试，状态转为"需要重新登录"。测试：`AuthRefreshTests`。验收面：L。
- [ ] 需求：登出时删除本地凭据和缓存，不影响服务端账号。各端完成清理后，发件箱或去重表的内存与存储都为空，清理前挂起的操作不能写回或发布旧结果。测试：`SignOutPurgeTests`。验收面：L、D。

### B2 私有接口客户端
- [ ] 需求：能区分两类 Bot（sandbox gateway 和服务端 harness），并路由到对应接口。测试：`BotRoutingTests`，用录制的匿名化样例做夹具。验收面：L。
- [ ] 需求：按操作类型执行防重复规则（architecture §5.1）：任何路径都不自动重放写请求；用户发起的写请求只来自首次点击或点"重试"。测试：`OutboxTests`。输入：写请求超时、连接中断、5xx、401。预期：自动流程只产生查询（对账）请求，不产生第二次写请求；用户发起的写请求次数等于首次点击加重试的次数。验收面：L。
- [ ] 需求：发消息（快速回复、卡片、听写）使用由 `opId` 派生的客户端 nonce，重试沿用同一个 nonce（与 `attempt` 无关），同一 `opId` 最多 3 次写请求；对账确认未送达或放弃时回 `notDelivered`；结果未知时按 harness 对账：服务端 Bot 用发送状态查询（约每 2 s 一次，60 s 后放弃），gateway Bot 读对话尾部按 nonce 加文本核对。测试：`MessageReconcileTests`。预期：对账确认已送达后，手动重试按钮消失；同一 nonce 在服务端只留一条。验收面：L。
- [ ] 需求：确认答复（widget、Allow/Deny）和表单（user-form）没有 nonce，靠条目状态去重：写之前和手动重试之前都先重读条目（widget 的已答值、approval 的 `status`、表单的处理结果），已经处理过就直接显示结果，不再写。测试：`EntryStateGuardTests`。输入：条目已答、已过期、仍待处理三种状态。预期：只有"仍待处理"时才发写请求。验收面：L。
- [ ] 需求：响应字段缺失、类型变化、401/403/404、未知枚举都归入"协议失效"分类，对应功能降级而不崩溃。测试：`ProtocolGuardTests`。验收面：L。

### B3 WatchConnectivity 协议
- [ ] 需求：所有消息使用版本化信封 `{v, id, type, sentAt, body}`，写操作的 body 带 `opId` 和 `attempt`；版本不匹配时回 `error.version`。测试：`EnvelopeCodecTests`。验收面：L。
- [ ] 需求：手表为每次用户操作生成一个 `opId`，先写入手表本地持久发件箱再交给 WatchConnectivity；状态为 `queued`（从未投递）→ `sentNoAck`（已投递未 ack）→ `handedToPhone` → `accepted / rejected / notDelivered / unknown`，`sentNoAck` 在投递之前落盘。WC 报错、回执丢失、手表 app 被挂起时都不换 `opId`，只做重投（`attempt` 不变）；只有收到 `notDelivered` 才显示"重试"，用户点重试时 `attempt` 加 1。测试：`WatchOutboxTests`。预期：手表重启后发件箱条目还在，状态不倒退；投递过的条目不会回到 `queued`；`accepted`/`rejected`/`unknown` 不显示重试。验收面：L、D。
- [ ] 需求：iPhone 去重键为 `(opId, attempt)`。收到写请求后，先把 `(opId, attempt) → nonce, state=pending` 落盘（write-ahead），落盘成功才发网络写请求；重启后遇到 pending 记录只对账，不再写。新的 `attempt` 只有满足"重试准入"（architecture §5.2：`attempt ≥ 2` 才要求上一次为终态 `notDelivered`；所有尝试要求 `attempt == 已写次数 + 1 ≤ 3`，确认和表单重读仍为 pending）才写。已写次数和 `writesDone` 均为同一 `opId` 已准入、已落盘的尝试数。去重记录保留 7 天。测试：`RelayIdempotencyTests`。输入：①回执丢失后手表用同一 `(opId, attempt)` 重投；②iPhone 在写请求发出后、结果落盘前被杀，重启后同一 `(opId, attempt)` 再次投递；③同一 `(opId, attempt)` 经 WC 投递两次；④上一次为 `notDelivered` 时收到 attempt 2；⑤上一次为 `accepted` 时收到 attempt 2；⑥attempt 跳号（1 之后直接 3）；⑦attempt 4；⑧iPhone 在尝试落盘后、发请求前被杀，对账为 `notDelivered` 后收到 attempt 2。预期：①②③只有一次写请求，后续只对账；④产生第二次写请求且 nonce 不变；⑤回 `accepted` 不写；⑥⑦回 `rejected(reason=attempt)` 不写；⑧attempt 2 准入，累计两次已落盘的尝试。验收面：L。
- [ ] 需求：服务器请求 ID 由手表 `opId` 确定性派生（规则见 architecture §5.2），中转路径和后续 F7 直连路径对同一操作落到同一个服务端 nonce；改走直连的状态规则见 architecture §5.2（`sentNoAck` 的确认和表单不得直连）。测试：`NonceDerivationTests`，断言 nonce 为小写、同一 `opId` 的各次尝试 nonce 相同。验收面：L。
- [ ] 需求：回执分两段：`sendMessage` 的 reply 只回"手机已接收"（`op.ack`）；结果（`op.result`）一律经 `transferUserInfo` 回传（排队、保证送达，手表不在前台也不丢），同时写进下一次快照的 `recentOps`。测试：`ResultDeliveryTests`。预期：手表放下手腕后再抬起，能看到最终结果；两条通道没有先后顺序，按 `(opId, attempt)` 合并。`unknown` 表示 iPhone 仍在对账，可更新为 `accepted`、`rejected` 或 `notDelivered`；终态不会被覆盖，较旧 attempt 的结果只记录、不改界面。纯逻辑用例覆盖 `unknown → accepted`、快照晚到但结果早于 userInfo，以及旧 attempt 的结果迟到。验收面：L、D。
- [ ] 需求：待处理列表和候选回复用 application context 快照下发，手表冷启动时能立即显示上一次快照并标明时间。验收面：S、D。

### F1 确认类问答
- [ ] 需求：widget 单选一点即发；多选勾选后点"完成"；可以 dismiss。测试：`WidgetAnswerTests`。预期：发送的 value 与 widget 定义一致（有 value 用 value，否则用 label）。验收面：L、D。
- [ ] 需求：Allow/Deny 只发单次决定，不提供"总是允许"（这类常驻规则留在手机上处理）。测试：`ApprovalTests`。验收面：L、D。
- [ ] 需求：user-form 只支持单行文本、单选、是/否三种字段，其他字段显示"请在手机上处理"。测试：`UserFormSupportTests`。验收面：L。
- [ ] 需求：结果先乐观回显；服务端拒绝时恢复原按钮并提示。验收面：S、D。

### F2 智能快速回复
- [ ] 需求：针对主 Bot 最新一条需要回复的消息，iPhone 端生成 2–4 条、每条不超过 40 个字符的候选，随快照推给手表；手表一点即发（发送前可以确认，可配置）。测试：`SuggestionEngineTests`。输入：样例消息。预期：2–4 条、去重、长度合规、不含链接和凭据样式文本。验收面：L、D。
- [ ] 需求：生成器按顺序回退：①消息自带的选项（widget 选项直接用，不另生成）→ ②设备端 Apple Foundation Models（iPhone 支持时）→ ③规则模板（是/否/稍后/请展开说明等，按问句类型选择）。测试：`SuggestionFallbackTests`。验收面：L。
- [ ] 需求：候选生成在 iPhone 本地完成，第一版不把消息内容发给额外的第三方服务。验收面：评审确认。
- [ ] 需求：手机不可达时，手表显示最后一次快照里的候选并标明"可能过期"；消息变化后不再显示旧候选。验收面：S、D。

### F3 自定义常用回复卡片
- [ ] 需求：iPhone 端增删改排序卡片，最多 12 张，每张不超过 60 个字符；可以全局使用，也可以绑定某个 Bot。测试：`QuickCardStoreTests`。验收面：L、S。
- [ ] 需求：卡片经 application context 同步到手表，手表本地缓存，离线也能用。验收面：D。

### F4 语音输入兜底
- [ ] 需求（MVP）：回复界面提供"听写"，调用系统文本输入（含听写），确认后再发送。验收面：D。
- [ ] 需求（后续）：手表录音（AVAudioRecorder），文件交给 iPhone 转写（Apple 语音识别或 xAI `/v1/stt`），文本回传后确认再发送。验收面：D。

### F5 语音对话（手机麦克风模式）
前置闸门：S-3（§7）。F5 的验收按 S-3 的结论二选一，实现任务书要写明采用哪一套。

- [ ] 公共需求：手表显示状态（连接中/聆听/思考/说话/已断开）、字幕摘要、静音和结束按钮；`voice.start`/`voice.stop`/`voice.mute` 带 `sessionId`，重复的 start/stop 不建立第二个会话、不重复写回 transcript。测试：`VoiceControlStateTests`。验收面：L、D。
- [ ] 公共需求：iPhone 只在用户显式开始的通话期间使用后台音频，通话结束（包括 5 分钟上限、出错）立即停用音频会话。验收面：D（检查通话结束后配套 app 不再保持后台音频）。
- [ ] 方案 A（S-3 通过时）：手表点"开始通话"，经 WatchConnectivity 唤醒 iPhone 配套 app 并在后台建立语音会话，手机保持锁屏也能通话。验收面：D，按 S-3 的测试矩阵逐项复测。
- [ ] 方案 B（S-3 不通过时，"手机发起、手表控制"）：通话在 iPhone 上开始（打开配套 app 点开始，之后可以锁屏继续）；手表在通话进行中显示状态和字幕，提供静音、结束；手表上的"开始通话"在没有进行中的通话时显示"请在手机上开始通话"。验收面：D。
- [ ] 需求：iPhone 端无法启动录音、配套 app 被用户划掉、或 WC 不可达时，手表明确提示原因和下一步（"请在手机上打开配套 app"），不静默失败。验收面：D。
- [ ] 需求：单次通话设上限（默认 5 分钟），结束后把 transcript 写回 Bot 记录（沿用官方客户端的做法）。验收面：D。

### F6 麦克风路由（后续）
- [ ] 需求：按 architecture §6 的状态机选择 PhoneMic / WatchMicRelay / WatchMicDirect，切换时不重复建立会话。测试：`MicRouterTests`（状态机纯逻辑）。验收面：L、D。

### F7 手表直连降级（后续）
- [ ] 需求：手表独立登录（在手表上显示二维码，在手机上批准），token 只存手表 Keychain；手机不可达且手表有网时，F1/F2/F3/F4 的发送改走手表 HTTPS。验收面：D（关掉 iPhone 的 Wi‑Fi 和蓝牙测试）。

### F8 收件箱
- [ ] 需求：打开手表 app 即显示主 Bot 的"需要你处理"列表（问题、审批、表单），以及最近一条 Bot 消息和候选回复。验收面：S、D。

## 6. 不变量

- token、refresh token、gateway token 只存放在获取它的那台设备的 Keychain 里（iPhone 或手表），不经 WatchConnectivity 传输，不写日志，不进快照，不进仓库。
- 任何路径都不自动重放写请求（发消息、确认答复、表单、transcript 写回、通话后 handoff）。每个写请求只由一次用户操作（首次点击或点"重试"）或一次通话结束自动发起；结果不确定时只对账，不重放。语音开关不是服务端写请求，按目标状态处理。各类操作的去重方式见 architecture §5.1。
- 同一个用户操作在整个链路上只有一个 `opId`：手表发件箱、iPhone 落盘记录、服务端请求 ID 都由它派生；重试只增加 `attempt`，不换 `opId`。结果未知的操作按 architecture §5.2 的状态规则决定能否换路径。
- 协议失效时只降级受影响的功能，并明确提示"请在手机上处理"；不猜测字段，也不改发到其他接口。
- 不在手表或 iPhone 后台常驻；只在用户显式开始的通话期间使用后台音频（单次上限 5 分钟），通话结束立即停用。
- 不使用 grok-wear 仓库里属于 xAI 的头像设计数据。

## 7. 验证项（spike，结论写回 design/）

S-3 是 F5 实现批次的**前置闸门**，必须先做；其余验证项不属于 MVP 验收。

- S-1：真机上，手表在活跃音频会话期间能否建立到 `wss://api.x.ai/v1/realtime` 的 WebSocket（TN3135 限制）。
- S-2：手表麦克风 PCM 经 `WCSession.sendMessageData` 中转到 iPhone 的端到端延迟和丢包。
- **S-3（闸门，先做）**：手机锁屏时，能否从手表发起 iPhone 后台录音和语音会话。配套 app 声明后台音频模式，手表经 `sendMessage` 唤醒 iPhone 后尝试激活 `AVAudioSession` 并开始录音（后台启动录音可能报 `cannotStartRecording`）。测试矩阵（三种状态，各测手机锁屏和解锁两种情况）：
  - 未运行：iPhone 重启后解锁一次（首次解锁），不打开配套 app；用 Xcode 的设备进程列表或控制台确认配套 app 进程不在。
  - 已挂起：打开配套 app，回到主屏幕，等至少 30 秒，确认 app 已挂起（Xcode 调试器断开后观察，不能在调试器附着下测，附着会改变挂起行为）。
  - 前台后锁屏：配套 app 停在前台时按侧边按钮锁屏。
  
  通过标准：三种状态的"锁屏"项全部通过，F5 采用方案 A；任一锁屏项不通过，F5 改为方案 B"手机发起、手表控制"。
  
  已知限制（不计入通过标准）：配套 app 被用户从多任务里划掉后，WatchConnectivity 一般不会再把它拉起来，两种方案下都一样。这一项只用来验证手表上的提示文案（"请在手机上打开配套 app"）是否正确出现。用 CallKit 发起呼出通话来换取后台音频属于重大取舍，不在本验证范围内，要负责人另行批准。
- S-4：设备端 Foundation Models 生成 2–4 条候选的延迟和质量（iPhone 机型要支持 Apple Intelligence）。

## 8. 风险与回退

- 私有接口随时可能变化，导致功能失效；还可能不符合 xAI 的条款（[Acceptable Use Policy](https://x.ai/legal/acceptable-use-policy) 限制以 bot 方式访问和逆向服务）。负责人已接受这一风险，并限定为个人自用。回退：协议失效时降级为只读或"请在手机上处理"；备选路线见 architecture §8。
- 账号风险：异常调用可能触发风控。缓解：只调用官方客户端会用到的操作，遵守限速，写操作不重试。
- watchOS 网络和后台限制可能使手表直连语音不可行。缓解：手机麦克风模式是 MVP 的默认模式。
- 构建环境：Linux 上的 Codex 云端无法编译 watchOS/iOS target。App target 已有 macOS CI 无签名模拟器构建证据（见 [ci.md](ci.md)），签名和真机调试仍在负责人的 Mac 上用 Xcode 进行（见 §10）。
- 侧载签名：使用免费 Personal Team，签名 7 天过期，App ID 和能力受限，见 §10。

## 9. 是否重大变更

是。新建项目，涉及凭据处理、私有接口和跨设备通信。本 spec 需要独立设计评审，并经负责人本人批准后才能进入实现。实现阶段新增任何依赖（包括 xcodegen 之类的工具）要先做架构评估并获批。

## 10. 构建与签名约束（负责人 2026-11-16 决定）

- 构建和真机调试：在负责人的 Mac 笔记本上用 Xcode 构建 watchOS/iOS target、签名、安装到负责人的 iPhone 和 Apple Watch。纯 Swift 核心包仍可在 Linux 上 `swift test`。本轮不接 macOS CI。

后续状态（2026-11-17）：CI 已经单独批准并合入 main，覆盖双端无签名模拟器构建和纯逻辑测试，见 [ci.md](ci.md#公开运行证据)。Linux Swift 尚未实跑；真机签名、安装及功能尚未验收。上条保留 2026-11-16 的原始决定。

- 签名：没有付费 Apple Developer Program 会员，使用免费的 Personal Team 侧载（依据 Apple [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/)）：
  - 描述文件签发 7 天后过期，过期后 app 打不开，要回到 Mac 上重新构建、安装（iPhone 和手表 app 都要）。
  - 最多 10 个 App ID（7 天过期），最多 3 台设备（iPhone 和手表占 2 台），每台设备最多装 3 个这样签名的 app。本项目需要 iOS app、watchOS app 两个 App ID，后续加 complication/widget 扩展会再占一个。
  - bundle ID 保持固定：换 ID 会占新的 App ID，Keychain 里的登录信息也读不到，要重新登录。
  - 不能用 TestFlight，也不能分发给其他人（与本项目"仅本人使用"一致）。
- 依赖付费会员的能力及其影响（凡是实现时要用到下表以外的 capability，先在 Personal Team 下实际签名验证）：

| 能力 | 免费 Personal Team | 对本项目的影响 |
|---|---|---|
| 远程推送（APNs） | 不可用 | 本项目本来没有自己的服务器，不依赖远程推送。新消息提醒仍靠官方 app 的通知；手表数据新鲜度靠打开手表 app 时的 `inbox.refresh` 和 iPhone 前台事件流。F8 的可操作通知只能用本地通知，后续评估时按这个前提 |
| PushKit / VoIP 推送 | 不可用（依赖推送） | 不能靠来电式推送唤醒 iPhone；F5 方案 A 只能依赖 WatchConnectivity 唤醒，这正是 S-3 要验证的 |
| Private Cloud Compute 受管 entitlement | 不可用（需要申请） | 不在本项目范围；F2 只用 iPhone 端 `SystemLanguageModel` 和规则模板 |
| App Groups | 以实际签名结果为准 | MVP 不依赖：iPhone 和手表之间走 WatchConnectivity，不共享容器。后续手表 complication 扩展如需和手表 app 共享数据，要先验证；不可用时 complication 只显示静态入口 |
| iCloud、Sign in with Apple、Associated Domains | 不可用 | 不使用。B1 登录走轮询，不需要 universal link 回调 |
| 后台模式（音频）、Keychain | 一般可用，以实际签名结果为准 | F5 需要后台音频；S-3 必须用 Personal Team 签名的构建在真机上测 |
