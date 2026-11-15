# grokbot-watch

Apple Watch 上的 Grok Bot 轻量伴侣，配合官方 Grok Bot iPhone app 使用：在手表上快速回复 Bot 的问题、处理确认，并开关语音对话。

> 非官方的个人项目，与 xAI 或 Cursor 没有关联，也未获其认可。项目使用 Grok Bot 官方客户端的私有、未公开接口，接口随时可能变化或失效，使用也可能不符合服务条款。仅限仓库所有者本人侧载自用，不上架，不分发，不商业化。

## 状态

规格 v0.1 设计复评中（已按首轮评审修订防重复、防丢失和 F5 闸门），还没有实现代码。

## 功能（与 [docs/feature-map.md](docs/feature-map.md) 一致）

第一版（MVP）：
- **F1 确认类问答**：widget 选项、Allow/Deny、简单表单，在手表上一点完成。
- **F2 智能快速回复**：iPhone 根据 Bot 的最新消息生成 2–4 条候选，手表一点即发。
- **F3 自定义常用回复卡片**：在 iPhone 上编辑，在手表上使用。
- **F4 语音输入兜底**：系统听写。
- **F5 语音对话开关**：由 iPhone 跑语音，手表负责开始、结束和静音。手机锁屏时能否从手表发起通话要先验证（S-3）；不行就改为在手机上开始、手表控制。
- **F8 收件箱**：列出主 Bot 待你处理的问题。
- 基础：B1 iPhone 登录，B2 私有接口客户端，B3 WatchConnectivity 协议（手表持久发件箱，结果保证回传，写操作不自动重发）。

后续：F4+ 录音转写，F6 麦克风智能路由，F7 手表直连降级，F8+ complication 和可操作通知。

## 架构一句话

手表负责轻量的回复和控制；iPhone 配套 app 负责登录、和 Grok Bot 服务通信、跑语音；两端走 WatchConnectivity。手表有网而手机不在身边时，可以走 HTTPS 降级。详见 [docs/architecture.md](docs/architecture.md)。

## 构建

watchOS、iOS target 在负责人的 Mac 笔记本上用 Xcode 构建和真机调试；纯 Swift 核心包可以在 Linux 上跑 `swift test`。本仓库暂时没有 CI。

签名用免费 Personal Team 侧载：描述文件 7 天过期，要重新构建安装；App ID、设备数量和可用能力都有限制，远程推送等依赖付费会员的能力不可用。详见 [docs/spec.md](docs/spec.md) §10。

## 文档

- [docs/spec.md](docs/spec.md)：目标、非目标、功能和验收条件
- [docs/feature-map.md](docs/feature-map.md)：功能地图
- [docs/architecture.md](docs/architecture.md)：架构、消息协议、麦克风路由、降级
- [docs/design/](docs/design/)：调研和决策归档
- [AGENTS.md](AGENTS.md)、[docs/workflow-v2.md](docs/workflow-v2.md)：开发规则（workflow v2.2）

## 许可

MIT，见 [LICENSE](LICENSE)。第三方参考见 [NOTICE.md](NOTICE.md)。
