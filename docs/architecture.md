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
| `Outbox` | 按操作类型防重复（§5.1）：发消息用由 `opId` 派生的 nonce，结果未知时按 harness 对账（服务端 Bot 查发送状态，gateway Bot 读对话按 nonce 核对）；确认答复和表单写前重读条目状态；写之前先落盘（§5.2） | 结果未知时标"处理中"；只有收到 `notDelivered` 后才允许用户重试，`opId` 不变、`attempt` 加 1（§5.2） |
| `ProtocolGuard` | 解析时做严格校验：必需字段、类型、枚举；识别"版本过旧"类拒绝；记录不含内容的诊断信息 | 命中后整体进入 `degraded(feature)`，在设置页显示协议状态 |
| `VoiceCredential` / `VoiceSession` | 向 Grok Bot 换取短期语音凭证，连 xAI Realtime（`xai-client-secret.` 子协议，与 [xAI 官方文档](https://docs.x.ai/developers/model-capabilities/audio/ephemeral-tokens) 一致），处理 `session.update`、音频追加、转写和音频增量、断线重拨 | 凭证接口失效：语音功能禁用，提示用官方 app 通话 |

请求约束（沿用 grok-wear 的经验值，实现时再评审）：单次 HTTP 30 s 超时，响应上限 1 MiB，不跟随重定向；读请求超时后重试一次；写请求从不盲目重试。

## 4. 凭据与本地数据

- iPhone token 存 iPhone Keychain，设为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不加入 iCloud 钥匙串（[Keychain services](https://developer.apple.com/documentation/security/keychain-services)）。
- 手表在 F7 里**单独登录**：手表显示二维码，在手机浏览器批准；token 只存手表 Keychain。**不经 WatchConnectivity 传送 token**，避免两端共用 refresh token 造成轮换冲突，也缩小泄露面。
- WC 快照只含展示用的数据：Bot 名、问题文本摘要、选项、候选回复、卡片。快照里不含 token 和 gateway 地址。
- 日志里不记录消息正文、token 或主机名，只记录操作名、状态码类别和耗时。
- 手表发件箱和 iPhone 去重表落在各自设备的 app 沙盒里，按敏感数据对待：只存操作类型、目标条目 ID、回复文本和状态，不存 token；登出时一并清空。

## 5. WatchConnectivity 消息协议（v1）

官方依据：[`sendMessage`](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)) 从手表活跃时调用，会**在后台唤醒 iOS app**；反过来，iPhone 唤醒不了手表。[`isReachable`](https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable) 决定能不能做实时消息。[`updateApplicationContext`](https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:)) 只保留最新状态，适合放快照。

信封：`{ "v": 1, "id": "<uuid>", "type": "<type>", "sentAt": <ms>, "body": {…} }`。信封 `id` 只标识这一次投递（每次投递都新生成）；用户操作由 body 里的 `opId` 标识；写操作的 body 还带 `attempt`（第几次写尝试，从 1 开始）。重投时 `opId` 和 `attempt` 都不变，用户点"重试"时 `opId` 不变、`attempt` 加 1（§5.2）。收到更高版本的消息时，回 `error.version`，提示升级发出方以外的那一端（手表收到更高版本，提示更新手表 app；iPhone 收到更高版本，提示更新配套 app）。application context 和 `transferUserInfo` 没法回 reply，版本不匹配时只在本端显示提示。

| 方向 | type | body 主要字段 | 通道 |
|---|---|---|---|
| 手表→手机 | `inbox.refresh` | `botId?` | sendMessage（带 reply） |
| 手表→手机 | `reply.send` | `botId, text, source(suggestion/card/dictation), opId, attempt` | sendMessage |
| 手表→手机 | `widget.respond` / `widget.dismiss` | `botId, entryId, values[], opId, attempt` | sendMessage |
| 手表→手机 | `approval.resolve` | `botId, approvalId, decision(allow/deny), opId, attempt` | sendMessage |
| 手表→手机 | `form.submit` / `form.dismiss` | `botId, formId, fields{}, opId, attempt` | sendMessage |
| 手表→手机 | `voice.start` / `voice.stop` / `voice.mute` | `botId, sessionId, mic(auto/phone/watch), muted?` | sendMessage |
| 手表→手机 | `audio.up`（后续 F6） | 二进制 PCM 帧和序号 | sendMessageData |
| 手机→手表 | `op.ack` | `opId, attempt, persisted:true` | 对应 sendMessage 的 reply |
| 手机→手表 | `op.result` | `opId, attempt, writesDone, result(accepted/rejected/notDelivered/unknown), reason?, finishedAt` | transferUserInfo（保证送达） |
| 手机→手表 | 快照 | `inbox[], latestMessage, suggestions[], cards[], recentOps[], voice?, authState, protocolState, generatedAt` | updateApplicationContext |
| 手机→手表 | `voice.state` | `sessionId, state, mic, caption?` | sendMessage（手表不可达时丢弃，快照里的 `voice` 字段兜底） |
| 手机→手表 | `audio.down`（后续 F6） | 二进制 PCM | sendMessageData |

规则：
- 手机不可达时：MVP 把操作留在手表发件箱（`queued` 或 `sentNoAck`），显示"手机不可用"，手机恢复可达后由用户点一次"发送"重投；F7 上线后能否改走 DirectClient 按 §5.2 的状态规则处理。
- 快照大小有上限（例如 64 KiB）。候选和卡片截断后要标明。

### 5.1 防重复规则（按操作类型）

总原则：任何路径都**不自动重放写请求**；每一个写请求只由一次用户操作（首次点击或点"重试"）或一次通话结束（transcript 写回、通话后 handoff）发起。结果不确定时自动流程只做对账（读），不再重放。后端去重能力因操作类型而异，所以手动重试的条件也分开定：

| 操作 | 后端去重能力 | 结果未知时的对账 | 手动重试规则 |
|---|---|---|---|
| 发消息（快速回复 F2、卡片 F3、听写 F4） | 服务端按客户端 nonce 只保留一份（grok-wear 记录官方客户端同一 nonce 最多发 3 次；gateway 的发送同样按 nonce 去重） | 服务端 Bot：发送状态查询，约每 2 s 一次，60 s 后放弃；gateway Bot：读对话尾部，找到带同一 nonce 且文本一致的用户条目即视为已送达 | 对账确认未送达或对账放弃时，`op.result` 为 `notDelivered`，手表才显示"重试"；重试沿用同一个 `opId` 和 nonce、`attempt` 加 1，文本不可改（改文本就是新操作、新 `opId`）；同一 `opId` 最多 3 次写请求 |
| 确认答复（widget 单选/多选/dismiss、Allow/Deny） | 没有 nonce，靠条目状态：widget 的已答值或已 dismiss，approval 的 `status`（pending/approved/denied/expired…） | 重读该条目 | 写之前和每次重试之前先重读条目；已处理（不论是不是本 app 处理的）就回 `accepted`（或 `rejected`，原因"已由其他端处理"/"已过期"），不再写；写失败或结果不确定后重读仍是 pending，才回 `notDelivered`，手表显示"重试"（`attempt` 加 1，同一 `opId` 最多 3 次） |
| 表单（user-form 提交/跳过） | 没有 nonce，靠表单条目的处理结果（submitted/dismissed） | 重读该条目 | 同确认答复；重读确认仍待处理才回 `notDelivered`，重试沿用手表上原来填写的值 |
| 语音开关（`voice.start`/`stop`/`mute`） | 不是服务端写请求，不走 `opId`/`attempt`；`setVoiceCallPresence` 一类上线/下线调用按目标状态设置 | 读 iPhone 当前会话状态 | 按"目标状态 + `sessionId`"处理（电平触发）：同一 `sessionId` 的重复 start 返回现有会话，重复 stop 直接确认已结束 |
| 通话结束的自动写（transcript 写回、通话后 handoff） | 发消息类，按 nonce 去重 | 同发消息 | 由通话结束自动发起，每个 `sessionId` 只由会话持有方（iPhone）发起一次；结果不确定时只对账，不重放，也不提供重试按钮（手机上可以看到记录） |

### 5.2 结果送达链路（防丢失）

```text
手表                                   iPhone                              服务端
用户点击 → 生成 opId
→ 写入手表发件箱 queued, attempt=1（落盘）
→ 投递前改为 sentNoAck（落盘）
→ sendMessage(op, opId, attempt) ──►  1. 查去重表，键为 (opId, attempt)：
                                         已有 → 重投，不写；回 ack，有结果就重新排队 transferUserInfo
                                         没有 → 按"重试准入"判断（见下），不准入就回当前结果，不写
                                      2. 准入 → 落盘 {opId, attempt, nonce, kind, state=pending}
                                      3. beginBackgroundTask
   ◄────── reply: op.ack ──────────   4. 回 op.ack（已落盘）
handedToPhone（落盘）                  5. 发写请求（nonce 固定由 opId 派生）──────► 
                                      6. 得到结果或对账结论 → 该记录 state=final
   ◄── transferUserInfo: op.result ── 7. 排队 op.result；同时写进快照 recentOps
accepted / rejected / notDelivered / unknown（落盘）
notDelivered → 显示"重试" → 用户点重试 → attempt+1，回到 queued
```

- **手表持久发件箱**：状态 `queued`（从未投递）→ `sentNoAck`（已投递、没收到 ack）→ `handedToPhone`（收到 ack）→ `accepted / rejected / notDelivered / unknown`，每次状态变化先落盘。`sentNoAck` 在调 `sendMessage` 之前写入，所以只要投递过一次，就不会再回到 `queued`。WC 报错（发送超时、手机不可达）时，手表分不清"没送达"和"已执行但回执丢了"，状态停在 `sentNoAck`。
- **重投和重试**：
  - **重投**：同一次尝试再投递一遍，`opId` 和 `attempt` 都不变。用于 `sentNoAck`（没收到 ack）和手机恢复可达后补投。iPhone 按 `(opId, attempt)` 查到已有记录就不写，只回 ack 和已有结果。重投不计入写次数。
  - **重试**：只有收到 `op.result = notDelivered` 后，手表才显示"重试"；用户点了才发，`opId` 不变、`attempt` 加 1。`accepted`、`rejected` 不显示重试；`unknown` 表示 iPhone 还在对账，只显示"处理中"，等最终结果。
  - **重试准入**（iPhone 在步骤 1 判断，条件全部满足才写）：该 `opId` 上一次尝试的记录已是终态且结果为 `notDelivered`；`attempt == 已写次数 + 1`；`attempt ≤ 3`；确认答复和表单在写前重读条目仍是 pending。上一次已是 `accepted` 时回 `accepted`、不写；`attempt` 跳号或超过 3 时回 `rejected(reason=attempt)`、不写。`attempt` 在写之前和其他字段一起落盘。
  - **nonce 与服务端去重**：发消息的 nonce 只由 `opId` 派生，和 `attempt` 无关，同一 `opId` 的所有尝试用同一个 nonce。即使上一次尝试其实已经到达服务端、只是对账放弃了，重试也只会被服务端按 nonce 合并成一条，不会出现两条消息；同一 nonce 最多写 3 次也和官方客户端一致。确认答复和表单没有 nonce，靠写前重读条目防止重复。
- **iPhone 先落盘**：步骤 2 必须在步骤 5 之前完成并成功；落盘失败就回 `op.result(rejected, reason=storage)`，不发写请求。iPhone 重启后扫描 `state=pending` 的记录：只做对账（§5.1），不再写；对账有结论后照常经 `transferUserInfo` 回传。去重表保留 7 天。
- **服务器请求 ID 派生**：发消息的客户端 nonce 直接取 `opId`（手表生成的 UUID v4，小写带连字符，与官方客户端 nonce 格式一致）。这样中转路径和后续 F7 直连对同一操作落到同一个服务端 nonce。确认答复和表单没有服务器请求 ID，按条目状态去重（§5.1）。
- **改走直连（F7）的状态规则**：`queued`（从未投递）的操作可以由用户选择改走直连，仍用同一个 nonce。`sentNoAck` 的发消息操作也可以改走直连，靠同一 nonce 由服务端去重；`sentNoAck` 的确认答复和表单不得改走直连，必须等手机可达后经手机对账（手机那边可能已经落盘并在写，直连重读条目看到的 pending 不可信）。`handedToPhone` 及之后的操作一律不得改走直连。
- **最终结果经 `transferUserInfo` 回传**：[`transferUserInfo(_:)`](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)) 会排队并在对端可用时按顺序送达，手表放下手腕、app 被挂起都不会丢。`sendMessage` 的 reply 只用来回 `op.ack`；从 iPhone 调 `sendMessage` 唤醒不了手表，所以最终结果不走 `sendMessage`。同时把最近 20 条操作结果放进快照 `recentOps`，作为第二条通道；手表按 `opId` 合并，重复结果只更新一次。
- **后台时间**：iPhone 被唤醒后先 `beginBackgroundTask`；冷路径（刷新 token、gateway bootstrap、HTTP 超时）可能超过 reply 时限，所以 ack 在落盘后立即回，不等网络结果。后台时间用完还没有结果时，记录保持 pending，下次配套 app 运行时继续对账。

### 5.3 语音开关与会话标识

- `sessionId` 由发起通话的一端生成（方案 A 时是手表，方案 B 时是 iPhone），iPhone 是唯一的会话持有方。
- 手表只发目标状态，不假设执行成功；界面以 `voice.state` 和快照里的 `voice` 字段为准。

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
PhoneMic      ──WC 失联──► 保持（手机上的会话继续，手表只显示"已断开"；不在手表另建会话）
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
- 构建和真机调试在负责人的 Mac 笔记本上进行（Xcode 构建、签名、安装到负责人的 iPhone 和 Apple Watch）。
- 签名：使用免费 Personal Team 侧载。描述文件 7 天过期，要重新构建安装；App ID 最多 10 个、设备最多 3 台、每台设备最多 3 个 app；远程推送、PushKit、iCloud、Sign in with Apple、Associated Domains 和受管 entitlement 不可用。各项对本项目的影响见 spec §10。设计上不依赖任何需要付费会员的能力；用到新的 capability 前，先在 Personal Team 下实际签名验证。

## 11. F5 语音对话与后台音频（闸门 S-3）

- iPhone 配套 app 声明后台音频模式，但只在用户显式开始的通话期间激活音频会话，通话结束（用户结束、5 分钟上限、出错）立即停用。不用后台音频保活，不播放静音音频。
- 方案 A（S-3 通过）：手表 `voice.start` 经 `sendMessage` 唤醒 iPhone → iPhone 激活音频会话、开始录音、换取语音凭证、连 Realtime → `voice.state` 回手表。
- 方案 B（S-3 不通过）："手机发起、手表控制"。通话只能在 iPhone 前台开始，开始后可以锁屏继续；手表负责静音、结束和显示字幕。手表在没有进行中的通话时，"开始通话"按钮显示"请在手机上开始通话"。
- 已知限制：用户从多任务里划掉配套 app 后，WatchConnectivity 一般不会再把它拉起来；这种情况在两种方案下都提示"请在手机上打开配套 app"。
- 用 CallKit 发起呼出通话来获得后台音频是重大取舍，不在本轮设计里，要负责人另行批准。
