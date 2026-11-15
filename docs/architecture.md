# 架构 / Architecture（v0 草案）

对应规格：[spec.md](spec.md)。官方依据都附了链接；结论需要真机验证的地方，标为 S-n（见 spec §7）。

## 1. 总览

```text
┌──────────── Apple Watch（watchOS app，轻量）────────────┐
│ 收件箱 / 确认按钮 / 候选回复 / 卡片 / 听写 / 通话控制      │
│ WatchSessionClient ── WatchConnectivity ──┐               │
│ DirectClient（后续 F7，HTTPS，手表自有会话）┼──► Grok Bot 服务│
└───────────────────────────────────────────┼───────────────┘
                                            │
┌──────────── iPhone（配套 app）─────────────┼───────────────┐
│ PhoneRelay ◄── WatchConnectivity ──────────┘               │
│ AuthClient / BotClient / EventStream / Outbox ─HTTPS──► Grok Bot 服务（私有接口）
│ SuggestionEngine（Foundation Models → 规则模板）           │
│ VoiceSession ── WebSocket ──► xAI Realtime（凭证由 Grok Bot 下发）│
│ Keychain（iPhone 自有 token）                              │
└────────────────────────────────────────────────────────────┘
```

共享代码放在纯 Swift 包 `Packages/GrokBotWatchCore`，它不依赖 UIKit 或 WatchKit，可以在 Linux 上 `swift test`。内容包括：协议模型、信封编解码、Outbox 状态机、ProtocolGuard、MicRouter 状态机、建议规则引擎。

## 2. 分工

| 能力 | 手表 | iPhone |
|---|---|---|
| 登录、持有 token | 只在 F7（后续）里有一份手表自己的独立会话 | 主会话（B1） |
| 读 Bot、待处理项、最新消息 | 读快照，或经中转实时拉取 | 调私有接口，生成快照 |
| 发送回复和确认 | 发出 WC 请求；F7 时可以直连 | 执行写请求、去重、查状态 |
| 智能候选 | 展示、点选 | 生成（F2） |
| 自定义卡片 | 缓存、点选 | 编辑、同步（F3） |
| ASR | 系统听写；后续录音 | 后续负责转写 |
| 语音对话 | 控制、字幕；后续可以采集和播放 | 建立会话、采集和播放（MVP） |

## 3. 私有接口模块（iPhone 端；F7 时手表复用同一个包）

协议设计参考 grok-wear 的 [docs/ARCHITECTURE.md](https://github.com/maplenk/grok-wear/blob/main/docs/ARCHITECTURE.md)（MIT），按 Swift 重新实现，不复制代码。

| 模块 | 职责 | 失效时的降级 |
|---|---|---|
| `AuthClient` | 浏览器授权（`ASWebAuthenticationSession`）加 PKCE，轮询换取 token，刷新；token 存 Keychain | 刷新结果不确定，或返回 401/403：进入"需要重新登录"；手表显示"请在手机上重新登录" |
| `Bootstrap` | 获取 gateway 连接信息（Bot 所在环境），定期刷新，不阻塞读路径 | 失败时只用服务端 harness 的接口；两边都失败则只读快照 |
| `BotClient` | Bot 列表、主 Bot 识别、读对话尾部；按 harness 分流：sandbox Bot 走 gateway 操作（list/transcript/send/respondToWidget/submitUserForm/resolveAutoReviewApproval），服务端 Bot 走后端 RPC（List/Send/Respond/Submit/ResolveAutoReviewApproval、GetSendStatus） | 单个操作失效时只禁用对应按钮，显示"请在手机上处理" |
| `EventStream` | 前台时订阅事件流（keep-alive 超时判定断线、指数退避）；断流后重新读对话，不信任可能漏掉的事件 | 退回到定时拉取（只在 app 前台时） |
| `Outbox` | 写操作幂等：客户端 nonce、单次写请求；应答丢失时调发送状态查询，直到 Sent / NotSent / 放弃 | 结果未知时标"未确认"，只能由用户手动重试，并且沿用同一个 nonce |
| `ProtocolGuard` | 解析时做严格校验：必需字段、类型、枚举；识别"版本过旧"类拒绝；记录不含内容的诊断信息 | 命中后整体进入 `degraded(feature)`，在设置页显示协议状态 |
| `VoiceCredential` / `VoiceSession` | 向 Grok Bot 换取短期语音凭证，连 xAI Realtime（`xai-client-secret.` 子协议，与 [xAI 官方文档](https://docs.x.ai/developers/model-capabilities/audio/ephemeral-tokens) 一致），处理 `session.update`、音频追加、转写和音频增量、断线重拨 | 凭证接口失效：语音功能禁用，提示用官方 app 通话 |

请求约束（沿用 grok-wear 的经验值，实现时再评审）：单次 HTTP 30 s 超时，响应上限 1 MiB，不跟随重定向；读请求超时后重试一次；写请求从不盲目重试。

## 4. 凭据与本地数据

- iPhone token 存 iPhone Keychain，设为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不加入 iCloud 钥匙串（[Keychain services](https://developer.apple.com/documentation/security/keychain-services)）。
- 手表在 F7 里**单独登录**：手表显示二维码，在手机浏览器批准；token 只存手表 Keychain。**不经 WatchConnectivity 传送 token**，避免两端共用 refresh token 造成轮换冲突，也缩小泄露面。
- WC 快照只含展示用的数据：Bot 名、问题文本摘要、选项、候选回复、卡片。快照里不含 token 和 gateway 地址。
- 日志里不记录消息正文、token 或主机名，只记录操作名、状态码类别和耗时。

## 5. WatchConnectivity 消息协议（v1）

官方依据：[`sendMessage`](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)) 从手表活跃时调用，会**在后台唤醒 iOS app**；反过来，iPhone 唤醒不了手表。[`isReachable`](https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable) 决定能不能做实时消息。[`updateApplicationContext`](https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:)) 只保留最新状态，适合放快照。

信封：`{ "v": 1, "id": "<uuid>", "type": "<type>", "sentAt": <ms>, "body": {…} }`。手表收到更高版本的消息时，回 `error.version`，提示升级配套 app。

| 方向 | type | body 主要字段 | 通道 |
|---|---|---|---|
| 手表→手机 | `inbox.refresh` | `botId?` | sendMessage（带 reply） |
| 手表→手机 | `reply.send` | `botId, text, source(suggestion/card/dictation), opId` | sendMessage |
| 手表→手机 | `widget.respond` / `widget.dismiss` | `botId, entryId, values[], opId` | sendMessage |
| 手表→手机 | `approval.resolve` | `botId, approvalId, decision(allow/deny), opId` | sendMessage |
| 手表→手机 | `form.submit` / `form.dismiss` | `botId, formId, fields{}, opId` | sendMessage |
| 手表→手机 | `voice.start` / `voice.stop` / `voice.mute` | `botId, mic(auto/phone/watch)` | sendMessage |
| 手表→手机 | `audio.up`（后续 F6） | 二进制 PCM 帧和序号 | sendMessageData |
| 手机→手表 | `op.result` | `opId, result(accepted/rejected/unknown), reason?` | reply 或 sendMessage |
| 手机→手表 | 快照 | `inbox[], latestMessage, suggestions[], cards[], authState, protocolState, generatedAt` | updateApplicationContext |
| 手机→手表 | `voice.state` | `state, mic, caption?` | sendMessage |
| 手机→手表 | `audio.down`（后续 F6） | 二进制 PCM | sendMessageData |

规则：
- `opId` 由手表生成，iPhone 把它映射成 Outbox 的客户端 nonce，同一个 `opId` 只执行一次（持久化去重表，保留 24 h）。
- 手机不可达时：MVP 显示"手机不可用"，并保留草稿；F7 上线后改走 DirectClient。
- 快照大小有上限（例如 64 KiB）。候选和卡片截断后要标明。

## 6. 麦克风路由状态机（F6；MVP 只启用 PhoneMic）

输入信号：
- `phoneReachable`：`WCSession.isReachable`。
- `startedFrom`：手表或手机；手表 app 前台运行，即视为抬腕主动发起。
- `userPref`：auto / phone / watch。
- `phoneAudioBusy`：iPhone 正在通话或已有其他录音会话，可用 [`CXCallObserver`](https://developer.apple.com/documentation/callkit/cxcallobserver) 等可检测的信号。
- `phoneCanRecord`：S-3 的结果，加上实际启动录音是否成功。
- `watchDirectWS`：S-1 的结果，运行时探测，失败就记住。
- `watchOnline`：手表自身是否有网。

```text
Idle ──start──► Selecting
Selecting:
  userPref=phone ∧ phoneReachable ∧ phoneCanRecord            → PhoneMic
  userPref=watch ∨ (auto ∧ startedFrom=watch):
      phoneReachable ∧ relayOK                                 → WatchMicRelay
      ¬phoneReachable ∧ watchOnline ∧ watchDirectWS            → WatchMicDirect
  auto ∧ phoneReachable ∧ phoneCanRecord ∧ ¬phoneAudioBusy     → PhoneMic
  否则                                                         → Unavailable（给出原因）
PhoneMic      ──phone 失联──► 尝试 WatchMicDirect，否则 Ending
WatchMicRelay ──phone 失联──► 尝试 WatchMicDirect，否则 Ending
WatchMicDirect──socket 被系统拒──► 记 watchDirectWS=false → Selecting
任意 ──用户切换麦克风──► Switching（不重建 Realtime 会话，只换音频端点；会话由 iPhone 持有时）
任意 ──stop / 5 分钟上限──► Ending ──写回 transcript──► Idle
```

- **PhoneMic**：iPhone 采集和播放，手表只做控制和字幕。这是 MVP 默认模式，也是最稳的路径。
- **WatchMicRelay**：手表采集 24 kHz PCM16，经 `sendMessageData` 送到 iPhone，iPhone 持有 WebSocket，回程音频再送回手表播放。延迟和可靠性看 S-2。已有开源项目用同样的结构，见 design/。
- **WatchMicDirect**：手表自己建立 WebSocket，受 TN3135 限制（§7），要等 S-1 通过才启用。
- 抖动抑制：路由变化需要信号稳定 2 s 以上才切换，避免来回抖动。

## 7. watchOS 低层网络限制（TN3135）和对策

[TN3135: Low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos) 规定，`URLSessionWebSocketTask`、`URLSessionStreamTask` 和 Network framework 都属于低层网络，只在三种情况下可用：音频流 app 实际播放音频期间（watchOS 6 起）、CallKit VoIP 通话期间（watchOS 9 起）、tvOS 设备发现。其他情况一律阻止，BSD socket 在任何情况下都不可用；模拟器总是放行，所以必须真机测试。HTTPS（`URLSession` 数据任务、`bytes(for:)` 流式读取）对所有 app 开放。

对策：
1. 手表上所有回复和确认路径（F1–F4、F7）**只用 HTTPS**，不受这条限制影响。
2. 语音默认由 iPhone 持有 WebSocket（PhoneMic / WatchMicRelay）。
3. WatchMicDirect 只做实验：在活跃音频会话期间尝试连接（S-1），被拒就记住并回退；不为绕过限制去伪装成 VoIP 或滥用后台模式。
4. 手表上的事件流只在前台使用；后台不保持连接。

## 8. 失效降级与备选路线

| 失效 | 影响 | 降级 |
|---|---|---|
| 登录或刷新被拒 | 全部写操作 | 手表显示"请在手机上重新登录" |
| 某个写操作的协议变化 | 对应按钮 | 只禁用该类操作，显示"请在手机上处理" |
| 事件流失效 | 实时性 | 前台定时拉取 |
| 语音凭证失效 | F5/F6 | 语音入口禁用，提示用官方 app 通话 |
| 整体协议失效 | 全部 | 只读最后一次快照；设置页提示 |

备选路线（不在 MVP 内，用于私有接口长期不可用时）：语音和候选生成改走 xAI 官方 API（Responses/Realtime，见 [docs.x.ai](https://docs.x.ai/docs/overview)）。这条路线拿不到 Bot 的记忆和对话，只能算降级体验；是否启用由负责人决定。

## 9. 智能快速回复（F2）

官方能力核查：
- 手表端：WatchKit 的 [`presentTextInputController(withSuggestions:…)`](https://developer.apple.com/documentation/watchkit/wkinterfacecontroller/presenttextinputcontroller(withsuggestions:allowedinputmode:completion:)) 和 `presentTextInputControllerWithSuggestions(forLanguage:…)` 可以在系统输入界面里展示 app **自己提供**的候选短语，再配合听写和 emoji。系统不会根据上下文自动生成候选。SwiftUI 有 [`TextFieldLink`](https://developer.apple.com/documentation/swiftui/textfieldlink)（watchOS 9+）用来发起文本输入。`textInputSuggestions` 只在 macOS 上提供。信息 app 那种上下文智能回复，**没有对第三方开放的 API**。
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)：框架在 iOS 26+ 可用，watchOS 27 起也列入。但设备端模型 [`SystemLanguageModel`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) 的平台列表**不含 watchOS**。watchOS 27 可以用 [`PrivateCloudComputeLanguageModel`](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)，但需要满足资格条件并申请受管 entitlement（[entitlement 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute)），而且要求设备和地区支持 Apple Intelligence，个人侧载不适用。
- 可操作通知：[`UNTextInputNotificationAction`](https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction) 在 watchOS 3+ 可用，但只对**本 app 发出**的通知生效，官方 Grok Bot app 的通知加不了动作（F8 后续再评估）。

结论和设计：
- 候选**在 iPhone 端生成**，随快照推给手表；手表用自建按钮列表展示，同时把候选传给系统文本输入界面作为 suggestions，听写也在同一个界面里。
- 生成器按顺序回退：①消息自带的选项 → ②设备端 `SystemLanguageModel`（iPhone 支持 Apple Intelligence 且 `availability` 为可用时；用 `@Generable` 结构化输出 2–4 条短句）→ ③规则模板（按问句类型：是/否类、时间类、选择类、开放类）。
- 后续可以接 xAI API 当生成后端（要配 key，并且会把消息内容发给第三方），需要另行批准。
- 触发：iPhone 收到主 Bot 新消息时（前台事件流，或手表请求 `inbox.refresh` 时）生成；按消息 id 缓存。

## 10. 构建、测试与 CI

- Linux 上的 Codex 云端**编译不了** watchOS/iOS target，只能负责 `GrokBotWatchCore` 纯 Swift 包和 `swift test`。
- App target（watchOS、iOS）要在负责人的 Mac 上用 Xcode 构建、签名、侧载和真机调试；也可以经批准后用 macOS CI。
- 本轮不加 CI。新增 `.github/workflows/**` 属于政策文件变更，要另行批准。
- 签名：个人自用侧载。付费开发者会员可以用 App Group 和更长的描述文件有效期；免费团队签名有效期短，能力也受限（具体见 [Compare memberships](https://developer.apple.com/support/compare-memberships/)）。
