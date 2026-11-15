# grokbot-watch 规格 v0 / Spec v0

状态：草案 / 待评审（设计评审轮）。采用模板：workflow-template 2.2.2（workflow v2.2）。
对应功能地图：[feature-map.md](feature-map.md)。架构：[architecture.md](architecture.md)。调研与决策归档：[design/](design/)。

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
- 本轮（spec-v0）只写规格和设计评审，不写实现代码，也不加 CI（`.github/**` 属于政策文件，要另行批准）。

## 3. 优先级说明

负责人在 2026-11-16 定了"快速回答"的优先级：**智能快速回复 → 自定义卡片 → 语音输入（ASR，最后的兜底）**。F 编号按这个顺序排。确认类问答（F1）是"回复"能力本身的前提，排在最前；语音对话和麦克风路由排在快速回答之后。基础设施用 B 编号单列，不占 F 序号。

## 4. 功能清单

| 编号 | 功能 | 档位 |
|---|---|---|
| B1 | iPhone 配套 app 登录（浏览器授权加 PKCE），token 只存 iPhone Keychain | MVP |
| B2 | iPhone 端私有接口客户端：Bot 列表、读对话、发消息、widget/approval/user-form 应答、发送状态确认；协议失效检测 | MVP |
| B3 | WatchConnectivity 消息协议（版本化信封、幂等 ID、应用上下文快照） | MVP |
| F1 | 手表处理确认类问答：widget 单选/多选、Allow/Deny、简单 user-form；结果回显，被拒时恢复按钮 | MVP |
| F2 | 智能快速回复：针对 Bot 最新一条消息，在 iPhone 端生成 2–4 条候选回复推给手表，一点即发 | MVP |
| F3 | 自定义常用回复卡片：在 iPhone 端编辑，同步到手表；按 Bot 可选过滤 | MVP |
| F4 | 语音输入兜底：系统听写（MVP）；录音后交 iPhone 或 xAI 转文字（后续） | MVP（只做系统听写）/ 后续 |
| F5 | 手表开关语音对话：由 iPhone 跑语音会话，手表做开始/结束/静音和字幕控制 | MVP（手机麦克风模式） |
| F6 | 麦克风智能路由：手表麦克风（经 iPhone 中转或直连）和手机麦克风之间自动选择、可手动切换 | 后续（取决于验证项 S-1、S-3） |
| F7 | 手表直连 HTTPS 降级：手机不可达时，手表用自己独立登录的会话直接发送回复和确认 | 后续 |
| F8 | "需要你处理"收件箱和入口：打开手表 app 即列出主 Bot 待处理的问题；complication 一键进入 | MVP（收件箱）/ 后续（complication、可操作通知） |

### MVP 范围（第一版）

B1–B3，F1，F2，F3，F4 的系统听写，F5 的手机麦克风模式，F8 的收件箱。

### 后续

F4 的录音转写，F6，F7，F8 的 complication 和可操作通知，F2 的 xAI 生成后端，以及手表离线时的候选缓存优化。

## 5. 功能要求与验收条件

验收面分三种：L 表示本地单元测试（纯 Swift 包，可以在 Linux 或 macOS 上跑 `swift test`）；S 表示 Xcode 模拟器（需要 macOS）；D 表示真机（负责人的 iPhone 和 Apple Watch）。模拟器总是放行低层网络，所以凡是涉及网络限制的项都必须在真机上验收。

### B1 登录
- [ ] 需求：iPhone 发起浏览器授权（PKCE，verifier 只在本机生成和保存）。测试：`AuthFlowTests`。输入：模拟的授权轮询响应。预期：token 写入 Keychain（`ThisDeviceOnly`，不同步），日志里不出现 token。验收面：L、D。
- [ ] 需求：刷新的结果不确定时不自动重试，状态转为"需要重新登录"。测试：`AuthRefreshTests`。验收面：L。
- [ ] 需求：登出时删除本地凭据和缓存，不影响服务端账号。验收面：L、D。

### B2 私有接口客户端
- [ ] 需求：能区分两类 Bot（sandbox gateway 和服务端 harness），并路由到对应接口。测试：`BotRoutingTests`，用录制的匿名化样例做夹具。验收面：L。
- [ ] 需求：发送带客户端 nonce；应答丢失时只查发送状态，绝不自动重发。测试：`OutboxTests`。预期：同一个 nonce 最多一次写请求，后续只有状态查询。验收面：L。
- [ ] 需求：响应字段缺失、类型变化、401/403/404、未知枚举都归入"协议失效"分类，对应功能降级而不崩溃。测试：`ProtocolGuardTests`。验收面：L。

### B3 WatchConnectivity 协议
- [ ] 需求：所有消息使用版本化信封 `{v, id, type, sentAt, body}`；版本不匹配时回 `error.version`。测试：`EnvelopeCodecTests`。验收面：L。
- [ ] 需求：写操作带幂等 ID，iPhone 端去重，重复投递不产生第二次写请求。测试：`RelayIdempotencyTests`。验收面：L。
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
- [ ] 需求：手表点"开始通话"，经 WatchConnectivity 让 iPhone 建立语音会话；手表显示状态（连接中/聆听/思考/说话）、字幕摘要、静音和结束按钮。测试：`VoiceControlStateTests`。验收面：L、D。
- [ ] 需求：iPhone 端无法启动录音时（例如 app 在后台），手表明确提示"请解锁手机或在手机上打开配套 app"，不静默失败。验收面：D（对应验证项 S-3）。
- [ ] 需求：单次通话设上限（默认 5 分钟），结束后把 transcript 写回 Bot 记录（沿用官方客户端的做法）。验收面：D。

### F6 麦克风路由（后续）
- [ ] 需求：按 architecture §6 的状态机选择 PhoneMic / WatchMicRelay / WatchMicDirect，切换时不重复建立会话。测试：`MicRouterTests`（状态机纯逻辑）。验收面：L、D。

### F7 手表直连降级（后续）
- [ ] 需求：手表独立登录（在手表上显示二维码，在手机上批准），token 只存手表 Keychain；手机不可达且手表有网时，F1/F2/F3/F4 的发送改走手表 HTTPS。验收面：D（关掉 iPhone 的 Wi‑Fi 和蓝牙测试）。

### F8 收件箱
- [ ] 需求：打开手表 app 即显示主 Bot 的"需要你处理"列表（问题、审批、表单），以及最近一条 Bot 消息和候选回复。验收面：S、D。

## 6. 不变量

- token、refresh token、gateway token 只存放在获取它的那台设备的 Keychain 里（iPhone 或手表），不经 WatchConnectivity 传输，不写日志，不进快照，不进仓库。
- 写操作（发送、应答、审批）对同一个幂等 ID 最多发出一次写请求；结果不确定时只查询，不重发。
- 协议失效时只降级受影响的功能，并明确提示"请在手机上处理"；不猜测字段，也不改发到其他接口。
- 不在手表或 iPhone 后台常驻；语音只在用户显式点击后开始。
- 不使用 grok-wear 仓库里属于 xAI 的头像设计数据。

## 7. 验证项（spike，不属于 MVP 验收，结论写回 design/）

- S-1：真机上，手表在活跃音频会话期间能否建立到 `wss://api.x.ai/v1/realtime` 的 WebSocket（TN3135 限制）。
- S-2：手表麦克风 PCM 经 `WCSession.sendMessageData` 中转到 iPhone 的端到端延迟和丢包。
- S-3：iPhone 配套 app 被 WatchConnectivity 唤醒到后台时，能否启动录音和语音会话（`AVAudioSession` 在后台启动录音可能失败）。
- S-4：设备端 Foundation Models 生成 2–4 条候选的延迟和质量（iPhone 机型要支持 Apple Intelligence）。

## 8. 风险与回退

- 私有接口随时可能变化，导致功能失效；还可能不符合 xAI 的条款（[Acceptable Use Policy](https://x.ai/legal/acceptable-use-policy) 限制以 bot 方式访问和逆向服务）。负责人已接受这一风险，并限定为个人自用。回退：协议失效时降级为只读或"请在手机上处理"；备选路线见 architecture §8。
- 账号风险：异常调用可能触发风控。缓解：只调用官方客户端会用到的操作，遵守限速，写操作不重试。
- watchOS 网络和后台限制可能使手表直连语音不可行。缓解：手机麦克风模式是 MVP 的默认模式。
- 构建环境：Linux 上的 Codex 云端无法编译 watchOS/iOS target。实现阶段的 App target 要在负责人的 Mac 上用 Xcode 构建，或者经批准后接入 macOS CI。
- 侧载签名：没有付费的 Apple Developer Program 会员时，免费团队签名的有效期短、能力受限（例如 App Group），需要定期重新安装。

## 9. 是否重大变更

是。新建项目，涉及凭据处理、私有接口和跨设备通信。本 spec 需要独立设计评审，并经负责人本人批准后才能进入实现。实现阶段新增任何依赖（包括 xcodegen 之类的工具）要先做架构评估并获批。
