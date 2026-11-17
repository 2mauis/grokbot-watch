# grokbot-watch

Apple Watch 上的 Grok Bot 轻量伴侣，配合官方 Grok Bot iPhone app 使用：在手表上快速回复 Bot 的问题、处理确认，并开关语音对话。

> 非官方的个人项目，与 xAI 或 Cursor 没有关联，也未获其认可。项目使用 Grok Bot 官方客户端的私有、未公开接口，接口随时可能变化或失效，使用也可能不符合服务条款。仅限仓库所有者本人侧载自用，不上架，不分发，不商业化。

## 状态

规格 v0.2 已进入第一批实现。B1、B2、B3、F1、F2、F8 的纯 Swift 逻辑已实现并有单元测试，iOS 和 watchOS App 已有占位页面。浏览器授权、Keychain、真实 HTTP 和 WatchConnectivity 适配器待接入。

## 功能演示

以下画面来自 Apple Watch Series 12（46 mm）的 watchOS 27.2 模拟器。演示界面使用现有 Swift 核心和模拟数据。

| 收件箱 | 审批确认 | 快捷回复 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/watchos-inbox.png" alt="收件箱列出待审批和待回复事项" width="190"> | <img src="docs/screenshots/watchos-approval.png" alt="审批确认显示允许一次和拒绝" width="190"> | <img src="docs/screenshots/watchos-quick-replies.png" alt="快捷回复列出三条候选" width="190"> |

## 功能（与 [docs/feature-map.md](docs/feature-map.md) 一致）

第一版（MVP）：
- **F1 确认类问答**：widget 选项、Allow/Deny、简单表单，在手表上一点完成。
- **F2 智能快速回复**：iPhone 根据 Bot 的最新消息生成 2–4 条候选，手表一点即发。
- **F3 自定义常用回复卡片**：在 iPhone 上编辑，在手表上使用。
- **F4 语音输入兜底**：系统听写。
- **F5 语音对话开关**：由 iPhone 跑语音，手表负责开始、结束和静音。手机锁屏时能否从手表发起通话要先验证（S-3）；不行就改为在手机上开始、手表控制。配套 app 被从多任务里划掉后，手表无法把它拉起来，这是已知限制。
- **F8 收件箱**：列出主 Bot 待你处理的问题。
- 基础：B1 iPhone 登录，B2 私有接口客户端，B3 WatchConnectivity 协议（手表持久发件箱，结果保证回传，写操作不自动重放；送达失败时由用户在手表上点"重试"）。

后续：F4+ 录音转写，F6 麦克风智能路由，F7 手表直连降级，F8+ complication 和可操作通知。

## 架构一句话

手表负责轻量的回复和控制；iPhone 配套 app 负责登录、和 Grok Bot 服务通信、跑语音；两端走 WatchConnectivity。手表有网而手机不在身边时，可以走 HTTPS 降级。详见 [docs/architecture.md](docs/architecture.md)。

## 在 Mac 上构建

用 Xcode 打开 `GrokBotWatch.xcodeproj`。两个 App 的最低系统版本为 iOS 26.0 和 watchOS 26.0。

### 模拟器

App 骨架需要在 Mac 上用 Xcode 编译，已用 Xcode 27.2 验证下列无签名构建。

```sh
xcodebuild -project GrokBotWatch.xcodeproj -scheme GrokBotWatch \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GrokBotWatch.xcodeproj -scheme 'GrokBotWatch Watch' \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

纯 Swift 核心包可在 macOS 或 Linux 上运行 `swift test --package-path Packages/GrokBotWatchCore`。GitHub CI 配置已在本地准备，尚未首跑验证：使用标准 `xcode-27` 预览 runner，显式选择 Xcode 27.2，执行完整核心测试、两个 scheme 的 Debug 无签名模拟器 clean build 和 iOS 产物内嵌 Watch 核验。范围、离线验证与故障处理见 [docs/ci.md](docs/ci.md)；不覆盖 Linux、真机、签名或真实适配器。

### Personal Team 真机安装

1. 在本机创建 `Config/Secrets.xcconfig`，填入签名团队 ID 和自选的 Bundle ID 前缀。Git 会忽略此文件。

   ```xcconfig
   DEVELOPMENT_TEAM =
   BUNDLE_ID_PREFIX =
   ```

2. 在 Xcode 的 Signing & Capabilities 中，确认两个 target 使用同一个 Personal Team 和自动签名。
3. 先选择 `GrokBotWatch` scheme 安装 iOS App，再选择 `GrokBotWatch Watch` scheme 安装 Watch App。
4. 免费 Personal Team 的描述文件 7 天后过期，届时需重新构建并安装两个 App。详见 [规格 §10](docs/spec.md#10-构建与签名约束负责人-2026-11-16-决定)。

## 文档

- [docs/spec.md](docs/spec.md)：目标、非目标、功能和验收条件
- [docs/feature-map.md](docs/feature-map.md)：功能地图
- [docs/architecture.md](docs/architecture.md)：架构、消息协议、麦克风路由、降级
- [docs/design/](docs/design/)：调研和决策归档
- [AGENTS.md](AGENTS.md)、[docs/workflow-v2.md](docs/workflow-v2.md)：开发规则（workflow v2.2）

## 许可

MIT，见 [LICENSE](LICENSE)。第三方参考见 [NOTICE.md](NOTICE.md)。
