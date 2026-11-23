# 配套 App 登录与只读手表收件箱 / Companion sign-in and read-only Watch inbox

## 简体中文

### PR #5 设计附录

待独立设计评审。采用 workflow-template 2.2.2，对应规格 v0.2。

#### 背景与目标

`eee7feb39e2c077325598422753456e41d68f511` 先实现了 iPhone 的浏览器、授权传输和钥匙串适配器。两个 App 入口当时仍只显示标题。本附录追溯覆盖该提交。使用模拟数据时，手机根据账号记录识别主 Bot 并读取会话。用户可以在手表看到同一条消息，点开详情、候选回复或审批预览。[既有 iPhone 适配器][phone] · [核心模型][core]

#### 非目标

真实登录、OAuth、生产服务请求、发送消息、提交审批、语音、F3 卡片、F4 听写、签名安装和真机验收均后置。生产读传输默认抛出“未配置”，本轮对真实服务的请求数为零。

#### 不变量

- `GrokBotLoginTarget` 和 `GrokBotOAuthClientID` 默认未配置。任一为空、含未展开的 `$(` 或未通过已有格式检查时，授权与刷新都在第一个请求前返回配置错误。iPhone 显示“登录未配置”，浏览器保持关闭。client、redirect、scope 的值均须来自正式配置。[配置占位符][plist] · [配置检查][phone]
- 候选回复和 Allow/Deny 只改变手表当前页面的预览。固定文案为“预览，未发送”。点选、返回、重选或重新打开详情均不创建发件箱条目、不发写信封。手机只读入口也要在调用已有写中转和恢复待处理写操作之前拒绝写入。
- 凭据只留在 iPhone Keychain，属性为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 且不同步。快照、WC 消息、日志和仓库均不含凭据。诊断只记操作名、状态类别和耗时。[Apple Keychain 属性][apple-keychain]

#### 方案与设计评审

1. **B1 登录入口。** 在手机主界面显示配置和会话状态，提供登录、取消和登出。取消结束浏览器及轮询，迟到的授权结果作废。只有 DEBUG 加显式启动参数才可启用授权替身，界面标“测试替身”。只读模拟数据另需显式启动参数，界面标“模拟数据”。Release 不包含这两个实现。HTTP 会话及端点可注入，保留现有配置检查。
2. **B2 只读编排。** 先读 roster，再按明确的主 Bot 标识选出唯一条目，随后仅读该 Bot 的 transcript，由 `InboxBuilder` 构造快照。找不到唯一主 Bot 时显示空态，不选择列表第一项。请求指定其他 Bot 时不返回其内容。只读调用面仅提供列表和会话读取。未经证实的字段、URL 或方法均在创建生产请求前抛出“未配置”。下方中英共用的字段表列出实际依据。
3. **B3 刷新与缓存。** 两端先设置 `WCSession` delegate 并激活。手机用 `updateApplicationContext` 发布完整快照。手表启动时先显示本地最近快照及生成时间，激活后接收最近的 context。双方可达时，手表用 `sendMessage` 发 `inbox.refresh`。手机在写分支前分发，读取所选主 Bot 的会话，通过该次请求的 reply 返回有界的 `inbox.snapshot`，同一快照也用于 context。登出时回复空的已登出快照。读取失败保留上次成功时间并标记降级，失联或只能显示缓存时标“可能过期”。未知版本沿用 `error.version`。同一请求只调用一次 reply。[Apple 会话][apple-wc] · [应用上下文][apple-context] · [交互消息][apple-message]
4. **入队与回执。** `WCChannel` 向系统提交后立即返回本地接收结果，或返回本地错误。`updateApplicationContext` 和 `transferUserInfo` 都在本机入队后立即返回，不等待对端收到。手机清理只等待先前提交给本机通道的调用结束。交互式 `sendMessage` 的 reply/error 由独立回调完成一次。现有 `async throws -> Data` 调用者仍可在请求层等待回执。登出不等待该回执。激活尚未完成时保留最新待发布状态，待激活后提交。[现有通道接口][codec] · [手机发布与清理][relay]
5. **64 KiB 裁剪。** 手机在合入最多 20 条最近操作结果后，按最终编码的整个快照信封计字节，含头部和裁剪标记。边界为 65,536 字节。保留授权状态、生成时间和最近结果，先移除卡片、候选，再从最旧待处理项开始裁剪。单条过长摘要按字符边界截短，重新编码计量。若标识本身过长则移除整个条目及关联候选，绝不截短标识。收件箱和最近消息引用同一条时同步裁剪。发生裁剪即标“已截断”，沿用候选和卡片的专用标记，新增的总体标记缺省为 false，以兼容既有 v1 快照。接收端继续拒绝超限信封。[快照编码][codec] · [收件箱排序和候选绑定][inbox]
6. **跨设备登出。** 停止旧会话读取，调用 `AuthClient.signOut()`，在其 `clearCache` 内完成 `PhoneRelay.purge()`。凭据和本机记录都清理成功后，手机才发布只含状态的“已登出”快照。清理失败显示重试，发送失败保留最新待发送状态。手表收到后先隐藏旧内容、执行 `WatchOutbox.purge()`，再清掉内存和磁盘上的收件箱、详情、候选及预览。清理失败继续隐藏旧内容并重试。手机为快照持久记录清理代次和递增序号。手表保存最近接受的顺序，迟到的 reply 或 context 不得恢复旧内容。若系统用下一次登录的快照替换了登出快照，代次变化仍先触发清理。已有无代次的 v1 缓存仅在首次迁移时作为可能过期的内容，收到带代次快照后不再接受无代次快照。[本地登出约定][purge] · [Apple 的 context 替换语义][apple-context]

S2-2 的快照裁剪、S3-1 的只读刷新分发与回执、S3-R2-1 的入队契约列入本批。S2-1 涉及确认预检的瞬时错误，核心复评的 S2-4 涉及登出后迟到写请求再次获准。两者均随写路径顺延，**启用写路径之前必须先修**。独立评审需要核对下面的字段证据、两侧写入口隔离、裁剪边界和登出后迟到消息。评审结论待协调方转达。[第一轮登记][purge] · [核心复评登记][backlog]

#### 验收测试清单

测试输入、预期和证据载体列在文末共用矩阵。全部为待执行项。每条 `xcodebuild` 命令显式传入 `GROK_BOT_LOGIN_TARGET= GROK_BOT_OAUTH_CLIENT_ID=`。只判断最终 iOS Info.plist 两个键均存在且为空，不输出值。

#### 红绿测试证据

`eee7feb` 的既有 CI 原始日志记录了 58 个 Swift 测试、19 个 suite、32 个 Python 测试、双端无签名 Debug clean build 及 Watch 内嵌核验成功。本附录的新行为测试未运行。独立设计评审通过后，先记录目标断言失败的提交和输出，再记录修复后的同一用例。编译、导入或缺 target 的错误不能证明目标断言失败。[基线 CI 日志][ci]

#### 风险与回退

配置失效时关闭登录和生产读取。快照送达前手表可能仍显示上次数据，需显示时间和“可能过期”。遇到清理错误优先隐藏旧内容。此阶段如需撤回设计，用后续文档提交记录决定。实现阶段如需关闭接入，恢复未配置入口，保留本地登出清理。

#### 是否重大变更

是。范围涉及凭据、私有协议和跨设备清理，沿用规格 v0.2 §9 的独立设计评审。设计通过后才进入测试和实现。[规格][spec]

## English

### PR #5 design appendix

Awaiting independent design review under workflow-template 2.2.2 and specification v0.2.

#### Background and goal

Commit `eee7feb` implemented the iPhone adapters before this retrospective appendix. Both apps still opened to a title at that commit. The proposed flow signs in with an explicit test double, identifies the one primary Bot, reads its conversation and shows the same message on the paired Watch.

#### Non-goals

Live authorization, production service requests, writes, voice, F3, F4, signing, physical devices and end-to-end service validation are deferred. The production read adapter throws an unconfigured error before any request.

#### Invariants

The two bundle settings default to unconfigured. Empty, unexpanded or invalid settings fail authorization and refresh before networking or opening a browser. Use issued configuration for client, redirect and scope. Credentials stay in the non-synchronizing, device-only iPhone Keychain. Logs contain only operation, status category and elapsed time. Previewing a suggestion or Allow/Deny always shows “预览，未发送”. The Watch creates zero outbox entries and sends zero write envelopes. The phone rejects write ingress and skips write recovery in this mode.

#### Approach and design review

- **Sign-in and reads.** Show sign-in, cancel, sign-out and status in the normal phone entry point. Cancel invalidates outstanding browser and polling work. The auth double (“测试替身”) and read fixtures (“模拟数据”) each require DEBUG and an explicit launch argument. Both are excluded from Release. Inject the HTTP configuration and endpoints for tests. A unique primary pointer is required to read a transcript. An absent or ambiguous primary produces an empty inbox. The field evidence below governs production configuration.
- **Watch delivery.** Activate both sessions. Publish the latest snapshot with application context. A reachable Watch sends `inbox.refresh` and receives exactly one bounded snapshot reply for the selected primary. Use the same snapshot for context, an empty signed-out snapshot after logout, the previous timestamp on read failure and the existing version error on an unsupported version. The Watch shows the timestamp and “可能过期” for cached data. WC submissions return upon local enqueue or local failure. Interactive callers may await their separate reply/error callback. Purge never waits for remote delivery. Preserve the latest pending context through activation.
- **Size and sign-out.** Count the entire encoded envelope against 65,536 bytes, including flags and up to 20 recent results. Trim cards, suggestions, then oldest inbox items. Shorten oversized summaries at character boundaries. Omit an unrepresentable identifier with its item and associated suggestions. Keep duplicate views of the latest item consistent. Preserve status, timestamp, recent results and existing field flags. Show “已截断” and default a missing overall flag to false on legacy v1. Keep the decoder's input limit.
- **Cleanup.** Invalidate old phone reads and run relay purge within the auth cache callback. After both credential and relay cleanup succeed, publish an empty signed-out snapshot. Retry failed cleanup or a pending context submission. The Watch hides old content, purges its outbox and clears memory and disk caches including detail and preview. Persist a cleanup generation and increasing publication sequence. Reject older arrivals and purge on a new generation even when a later context supersedes the signed-out one. Accept legacy unversioned cache as stale only until the first generation-bearing snapshot.
- **Review.** This batch covers S2-2 clipping, S3-1 read refresh/reply and S3-R2-1 enqueue semantics. Fix S2-1 transient preflight classification and the core review's S2-4 readmission of old writes before enabling any write path. Independent review of field provenance, write isolation, the byte boundary and late delivery is pending.

#### Acceptance test checklist

See the shared matrix below. Pass both empty build settings explicitly to every `xcodebuild` command. Check only whether the two keys exist and are empty in the built iOS Info.plist.

#### Red/green test evidence

The baseline CI job passed 58 Swift tests in 19 suites, 32 Python tests, both unsigned Debug simulator builds and embedded Watch validation. New behavior has no red or green run yet. After design approval, record the failing behavior assertion and its passing counterpart with their respective commits. [Baseline job log][ci]

#### Risks and rollback

Keep production sign-in and reads disabled on missing configuration. Display the last update time for cached data and hide old content on cleanup failure. Roll back by an appended change restoring the unconfigured entry point while preserving local purge.

#### Is this a major change?

Yes. Credentials, a private protocol and cross-device cleanup require independent review under specification v0.2 §9 before implementation.

## 协议出处 / Protocol evidence

`eee7feb` 写入了 `https://cursor.com/loginDeepControl`、后端 `https://api2.cursor.sh` 的 `auth/poll` 与 `oauth/token`，以及刷新请求中的 `client_id`。Grok Wear 的公开 MIT 源码可逐项定位到同样写法。原提交未说明作者如何取得这些具体值，其直接来源未知。这些端点和字段均未经官方公开合同核实。参考客户端的标识和回跳值不用于本项目，本轮不向上述地址或任何生产服务发出请求。[原提交适配器][phone] · [参考实现主机][hosts] · [登录页构造][login] · [轮询与刷新构造][auth-http]

The pinned MIT source corroborates the literals above. The baseline commit does not document their direct provenance. An official public contract and issued companion settings remain unverified. No live service requests are in scope.

下表列出静态可核对的字段及缺口。Swift 模型和模拟夹具定义本地输入，未证实的生产 URL、方法、字段类型或语义统一返回“未配置”，包括表中仅有第三方观察的路径。The table records observations from the pinned reference. A gap in any production mapping fails the affected read before network access.

| 用途 / Use | 字段及证据 / Field and evidence |
| --- | --- |
| 主 Bot / Primary | 参考实现读取 `settings.mainAgentId`。本地的 `Bot.isPrimary` 是与 roster ID 唯一匹配后的布尔值。名字、排序和置顶顺序均不能替代该关系。[Preferences][primary] |
| Bot ID | 服务端使用 `agentId`，旧行回退到 `legacyAgentId`。gateway 行可见 `id`、`agentId`。服务端行的 `id` 另有用途。[Roster][roster] |
| Harness | 参考实现识别 `harness` 的 `temporal` 值。其余值到本地 `.gateway` 的完整映射来源未知。[Roster][roster] · [Harness constant][harness] |
| 读会话 / Transcript request | 参考实现的服务端请求使用 `agentId`、`limit`、可选 `sessionId` 和 `beforeSeq`。本批生产 roster、transcript 与 bootstrap 的 URL、方法及兼容版本尚未核实。[Server page][server-page] |
| 行标识 / Entry ID | 服务端 `entries[]` 行含 `seq`、编码的 `body`。参考实现从解码条目读取 `id` 和 `kind`，序号仅用于排序。[Row decoder][rows] |
| 角色 / Role | 普通 `message` 的 `role` 在参考实现中区分 `user`、`assistant`。所有事件变体到本地 `RemoteEntry.Role` 的对应关系尚未核实。[History][messages] |
| 正文 / Text | 普通消息的 `content` 与文字型 `send-message` 的 `message.content` 按各自的类型分支读取。[History][messages] |
| 时间 / Time | 参考实现读取条目的 `timestampMs`。本地 `sentAt` 用于排序，快照的 `generatedAt` 则由手机生成。[History timestamp][time] · [Snapshot][inbox] |
| 状态 / Pending and resolution | 审批可见 `message.approval.requestId`、`status`，其中 `pending` 表示待处理。普通消息的待答条件以及 widget、form 到本地 `resolution` 的完整映射来源未知。[Approval parser][approval] |
| Nonce | 本地 `RemoteEntry.nonce` 为可选字段。只读收件箱无需该值，两种 harness 的统一映射来源未知。[Core model][core] |
| Bootstrap | 参考实现读取 gateway 地址、凭据和 headers 的不同拼写。可供本配套客户端使用的正式端点、权限和响应合同来源未知，不构造生产请求。这些值均不得写入 Watch 快照。[Bootstrap reader][bootstrap] |

## 验收矩阵 / Acceptance matrix

| 层 / Layer | 输入与可核查结果 | Input and observable result |
| --- | --- | --- |
| L | 核心包用 spy 记录调用。唯一主 Bot 只产生列表与其会话读取。缺失或冲突时不读其他会话。压到边界与超限时解码完整信封并核对字节数、保留字段和裁剪标记。刷新只回一次。候选及 Allow/Deny 预览前后发件箱不变，写信封计数为零。已登出快照清空发件箱和可重开的缓存，迟到回执不能恢复内容。连续五次全套 `swift test` 后加跑一次 TSan，并记录 SHA 和结果。 | Use a core spy for the unique, absent and ambiguous primary, byte-boundary clipping, one refresh reply, zero enqueues and writes on preview, and empty durable caches after logout and late replies. Run the full Swift suite five times, then once under TSan. |
| S-build | 两个 scheme 各自无签名 Debug clean build。核验最终 iOS plist 的空配置和内嵌 Watch 的 bundle 对应关系。运行 `scripts/ci` 的 Python 单元测试及 `check_ci.py embedded-app`。 | Clean-build both unsigned Debug schemes. Verify the two empty iOS settings and the host/embedded Watch relationship. Run the Python CI suite and embedded-app checker. |
| S-unit | 新增 Apple 框架的 iOS 宿主测试。分别输入空值和含 `$(` 的值，授权、刷新均报配置错误，请求数为零。用 URLProtocol 拦截所有 HTTP 请求，断言注入端点的请求方法、路径和字段。遇到未知主机就在拦截器内失败，网络请求数为零。模拟器 Keychain 验证创建、读、更新、删除、ThisDeviceOnly 及不同步属性。遇 entitlement 错误记录并停止。[Keychain][apple-keychain] | In an iOS host target, test each empty or unresolved setting, zero requests on failure, method/path/fields intercepted by URLProtocol and rejection of unknown hosts inside the interceptor. Exercise Keychain CRUD and access attributes with synthetic data. Stop on entitlement errors. |
| S-UI | 配对模拟器运行正常入口。记录手机“登录未配置”、替身登录/取消/登出和“测试替身”，以及“模拟数据”下同一会话的手表列表、详情、“可能过期”、候选和审批预览。优先 UI 测试，手动项附运行步骤和实际截图。 | On paired simulators, capture normal unconfigured launch, labeled auth-double sign-in/cancel/logout, and the same fixture in the Watch list, detail, stale state and both preview types. Use UI tests or provide actual screenshots and manual steps. |
| S-WC | 用 Watch scheme 启动配对 App，使用真正的 WCSession。逐项记录两端激活、context 送达、前台 refresh 往返、显式重新启动手表后读到相同时间的缓存、登出后清空、手机收到的写信封为零。记录 Xcode、两个 runtime 和去内容日志。模拟器上的异常只记为观察结果。Apple 明示模拟器不支持 `transferUserInfo`，上述只读验收使用 context 和交互消息。[Watch scheme][sim] · [Apple transferUserInfo][apple-transfer] | Launch the Watch scheme with a real paired WCSession. Record activation, latest context, round trip, cache/time after explicit relaunch, logout purge and zero write envelopes received by the phone. Record versions, redacted observations and the simulator limit on user-info transfers. |
| D / E | 后置。未覆盖后台唤醒、断连、冷启动拉起、真机无线电、首次解锁、备份迁移或真实服务。手动重启 App 读取缓存只覆盖本地恢复。 | Deferred. Background wake, disconnection, remote cold launch, physical radios, first unlock, backup migration and live services remain untested. |

[phone]: ../../Apps/iOS/PhoneSession.swift
[plist]: ../../Config/PhoneInfo.plist
[core]: ../../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/BotClient.swift
[inbox]: ../../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/Inbox.swift
[codec]: ../../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/EnvelopeCodec.swift
[relay]: ../../Packages/GrokBotWatchCore/Sources/GrokBotWatchCore/PhoneRelay.swift
[purge]: ../handoffs/pr-2-sign-out.md
[backlog]: ../mvp-status.md
[spec]: ../spec.md
[ci]: https://github.com/2mauis/grokbot-watch/actions/runs/44577873497/job/135750207277
[apple-wc]: https://developer.apple.com/documentation/watchconnectivity/wcsession
[apple-context]: <https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:)>
[apple-message]: <https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)>
[apple-transfer]: <https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)>
[apple-keychain]: https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly
[sim]: https://help.apple.com/xcode/mac/current/en.lproj/devfd9e28378.html
[hosts]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/GrokAuthCore.java#L37
[login]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/GrokAuthCore.java#L539-L542
[auth-http]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/GrokAuthClient.java#L80-L86
[primary]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/GrokCore.java#L256-L261
[roster]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/ServerTranscripts.java#L171-L190
[harness]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/GrokCore.java#L502
[server-page]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/BotAccount.java#L711-L720
[rows]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/ServerTranscripts.java#L42-L71
[messages]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/HistoryCoordinator.java#L174-L177
[time]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/HistoryCoordinator.java#L185-L189
[approval]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/Approvals.java#L23-L36
[bootstrap]: https://github.com/maplenk/grok-wear/blob/6c3a4e8fd36cd686ea60e27f14926d8b26dc8d9d/app/src/main/java/si/zya/grokwear/GrokAuthCore.java#L426-L447
