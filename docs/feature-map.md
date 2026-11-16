# 功能地图 / Feature map

和 [README](../README.md)、[spec.md](spec.md) 同步维护；状态变化时三处一起改。

状态：📝 规格中　🔬 待验证（spike）　⏳ 未开始　🚧 实现中　✅ 已验收

| 编号 | 功能 | 档位 | 端 | 状态 | 依赖 |
|---|---|---|---|---|---|
| B1 | iPhone 登录与 token（Keychain） | MVP | iPhone | 📝 | — |
| B2 | 私有接口客户端与协议失效检测 | MVP | iPhone（F7 时手表复用） | 📝 | B1 |
| B3 | WatchConnectivity 消息协议 v1（手表持久发件箱、`(opId, attempt)` 去重、iPhone 先落盘、结果经 transferUserInfo 回传、`notDelivered` 驱动重试） | MVP | 两端 | 📝 | — |
| F1 | 确认类问答（widget / Allow-Deny / user-form） | MVP | 手表 | 📝 | B2、B3 |
| F2 | 智能快速回复（iPhone 生成 2–4 条候选） | MVP | iPhone 生成，手表展示 | 📝 🔬 S-4 | B2、B3 |
| F3 | 自定义常用回复卡片 | MVP | iPhone 编辑，手表使用 | 📝 | B3 |
| F4 | 语音输入兜底：系统听写 | MVP | 手表 | 📝 | B3（发送） |
| F4+ | 语音输入：录音交 iPhone 或 xAI 转写 | 后续 | 两端 | ⏳ | B3 |
| F5 | 语音对话开关（手机麦克风模式；S-3 通过则手表可发起，不通过则手机发起、手表控制） | MVP | iPhone 跑会话，手表控制 | 📝 🔬 S-3（闸门，先做） | B2、B3、S-3 |
| F6 | 麦克风智能路由（手表中转 / 直连） | 后续 | 两端 | ⏳ 🔬 S-1、S-2 | F5；直连还依赖 F7 |
| F7 | 手表直连 HTTPS 降级（手表独立登录） | 后续 | 手表 | ⏳ | B2 |
| F8 | "需要你处理"收件箱 | MVP | 手表 | 📝 | B2、B3 |
| F8+ | complication / 可操作通知 | 后续 | 两端 | ⏳ | F8 |

快速回答的优先级：F2 智能快速回复 → F3 自定义卡片 → F4 语音输入（最后的兜底）。

防重复和防丢失规则对 F1–F5 的所有写操作都适用，见 architecture §5.1、§5.2：没收到 ack 只重投（`attempt` 不变），收到 `notDelivered` 后用户点重试（`attempt` 加 1），发消息的 nonce 始终由 `opId` 派生。S-3 的通过标准只看"未运行、已挂起、前台后锁屏"三种状态，"被用户划掉"是已知限制。

签名约束：免费 Personal Team 侧载，签名 7 天过期。远程推送等依赖付费会员的能力不可用，对各功能的影响见 spec §10；F8+ 的可操作通知只能用本地通知，complication 是否可用要先验证 App Groups。
