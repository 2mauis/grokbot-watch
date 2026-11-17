# GitHub CI

当前状态（2026-11-17）：CI 已随 PR #3 合入 [main `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f`](https://github.com/2mauis/grokbot-watch/commit/e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f)，首次 PR 运行及合入后的 main push 运行均成功。它验证纯逻辑和模拟器构建结构，**产品 MVP 尚未达成**；实现与功能验收状态见 [功能地图](feature-map.md) 和 [MVP 状态](mvp-status.md)。原本地准备快照与离线红／绿记录保留在下方历史章节。

## 公开运行证据

| 运行 | 绑定版本 | 结果与验证范围 |
|---|---|---|
| [首次 CI PR run 44032170467](https://github.com/2mauis/grokbot-watch/actions/runs/44032170467) | PR head `4953d14e8d2c0e65e8859ecf47751751274ca36b`；base `420e203728df734ac93d4a2cbae9708b67eedd21` | completed／success；预检、检查器 fixtures、纯逻辑测试、双端 Debug clean unsigned build 与 iOS 内嵌 Watch 核验均成功 |
| [main push run 44040269389](https://github.com/2mauis/grokbot-watch/actions/runs/44040269389) | main `e0226fe833b9fed617c7c1c6f06eb23d7b29fe9f` | completed／success；同一 workflow 的各验证步骤成功，证明 CI 已在 main 实际执行 |

首次 PR run 的标准合成 merge-ref 是 `461db216458fa2e0a43158052a84603ddf2c5333`，与该 PR head 同树；PR head、合成 ref 与合入后的 main 是不同提交，证据按各自版本记录。PR #2 核心修复 head `7f114c160f01c19703bee0055bd526ee01c04e9d` 已合入 `420e203728df734ac93d4a2cbae9708b67eedd21`，之后才合入 CI；这些后继运行不是 PR #2 当时 head 上的 CI 运行。

首次 PR 公开日志记录 Python 3.15.2、Xcode 27.2、Swift 6.4.2；32 个检查器测试通过，Swift 实际汇总为 **58 tests／19 suites** 通过。双端 Debug clean unsigned build、实际 iOS `Watch/*.app` 内嵌、companion ID 与宿主一致、independent 为布尔 false、WKApplication 为布尔 true、两端最低版本为字符串 `26.0`，均 PASS。这些数字绑定首次 PR run，不将源码参数展开数当作日志汇总，也不将其改写为 main run 的独立计数。

两次公开 job／步骤状态均已核对；本轮文档同步未重跑 Swift、Xcode 或 CI。CI 不启动 UI。双端模拟器启动仅为项目报告，未独立核验原始截图；不作为功能交互验收。Linux Swift、真机签名／安装、真实 HTTP／WC／Keychain／Foundation Models、跨设备登出与语音链路均未验收。

## 范围与权限

已单独获批并合入的 [CI workflow](../.github/workflows/ci.yml) 只监听 `pull_request` 和 `push` 到 `main`，没有准备分支特殊触发或定时任务。顶层仅授予 `contents: read`，checkout 不持久保存凭据；官方 `actions/checkout` v6 使用已从官方 tag 核实的完整 commit SHA：[`d23441a48e516b6c34aea4fa41551a30e30af803`](https://github.com/actions/checkout/commit/d23441a48e516b6c34aea4fa41551a30e30af803)。

单 job 超时 30 分钟；同一个 PR 的旧运行会被取消，main 运行不主动取消进行中的同组运行。未改 required checks、仓库设置、AGENTS 或 workflow 开发规则。CI 不自动合并，Draft PR 转 ready、合并及部署仍按现有门禁执行。

required checks 仍未配置。[AGENTS.md](../AGENTS.md) 等政策文档中的“暂无 CI”是尚未同步的历史措辞，本次不修改政策文件；已有 CI 成功不新增或替代任何既有批准、扫描或独立评审门禁。

不新增依赖、secrets、签名、Keychain、SDK 下载、缓存、artifact 上传或外部服务。构建日志仅保留在公开 job 输出和 runner 的临时目录；不读取或上传私人原始日志。未涉及发布、安装或设备部署。

## Runner 与工具链预检

使用 [GitHub 标准 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 标签 `xcode-27`，不使用 larger 或 self-hosted runner。[runner-images](https://github.com/actions/runner-images#available-images) 将它列为 public preview，镜像会变化，不能把标签当作固定工具链版本。

已核对的 [Xcode 27 镜像清单](https://raw.githubusercontent.com/actions/runner-images/main/images/macos/xcode-27-arm64-Readme.md) 为 `20261104.0337.1`：提供 Xcode 27.2，但默认是 27.1。因此 job 显式将 `DEVELOPER_DIR` 指向镜像内 Xcode 27.2 的 Developer 目录（具体值见 workflow），每次运行重新验证实际工具链，不依赖 `macos-latest` 或默认选择。

`scripts/ci/check_ci.py preflight` 使用 Python 标准库，要求：

- `python3` 可调用，指定 Developer 目录存在；缺失即失败。
- `xcodebuild -version` 的版本精确为 `27.2`；`27.20`、`27.2.1` 等也拒绝。
- `xcrun --find swift` 解析后的真实文件路径在所选 Xcode 内；记录该可执行文件的 `--version`，不固定 Swift 小版本。
- `xcodebuild -showsdks` 包含精确的 `iphonesimulator27.2`、`watchsimulator27.2`。
- `xcrun simctl list runtimes --json` 中 iOS 和 watchOS 27.2 的 identifier、version 正确，`isAvailable` 为布尔 true。仅读元数据，不启动模拟器或安装设备。

日志只打印工具链路径、版本、SDK/runtime 元数据及测试／产物检查结果，不转储环境变量。元数据命令各有 60 秒超时；非零退出、不可调用、解析失败或缺失均使预检失败。generic destination 在缺少 runtime 时能否纯构建尚未单独验证；本 CI 按已评审要求保守地强制核验。

## 执行顺序与产物验收

所有 run 块显式使用 Bash 和 `set -euo pipefail`；测试／构建经 `tee` 输出时保留真实退出码，不跳过失败或降级冒绿。

1. 检查 Python，运行与 box 相同的离线 fixture：`python3 -B -m unittest discover -s scripts/ci -p 'test_*.py' -v`。
2. 运行 `python3 -B scripts/ci/check_ci.py preflight`。
3. 运行完整核心包：`xcrun swift test --package-path Packages/GrokBotWatchCore`。日志记录实际测试汇总，不固定测试数量或筛选用例；`xcrun` 使用已核验的 Xcode Swift。
4. iOS：`GrokBotWatch` scheme，显式 `-configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO clean build`。
5. 对这次 iOS 构建运行 `python3 -B scripts/ci/check_ci.py embedded-app --derived-data "$derived_data"`。
6. watchOS：`GrokBotWatch Watch` scheme，显式 `-configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO clean build`。

两次构建分别通过 `mktemp -d` 在 `$RUNNER_TEMP` 下创建独立、全新的 `-derivedDataPath`，所有可能含空格的路径与 scheme 参数都加引号。完整命令见 [workflow](../.github/workflows/ci.yml)。

产物检查只读取 iOS 那次 DerivedData 下的 `Build/Products/Debug-iphonesimulator/GrokBotWatch.app`，要求该目录恰有这一个宿主 app；宿主 `Watch/` 必须恰有一个 app 目录，不能从多个候选取第一个，也不能用单独 watchOS 构建的产物顶替内嵌内容。宿主、Watch 目录及 Watch app 不接受符号链接，可执行文件解析后的路径须位于 app 内。通过 `plistlib` 读取真实产物的 XML 或 binary `Info.plist`，逐项打印核验值：

| 对象 | 必须满足 |
|---|---|
| 两个 app | plist 存在且为字典；`CFBundleIdentifier` 为已解析字符串；`CFBundlePackageType=APPL`；`CFBundleExecutable` 指向 app 内存在的非空文件 |
| 宿主 | `CFBundleSupportedPlatforms=[iPhoneSimulator]`；`MinimumOSVersion` 为字符串 `26.0` |
| 内嵌 Watch | `CFBundleSupportedPlatforms=[WatchSimulator]`；`MinimumOSVersion` 为字符串 `26.0` |
| 内嵌 Watch | bundle ID 等于宿主实际 ID 加 `.watchkitapp`；`WKCompanionAppBundleIdentifier` 等于宿主实际 ID，不硬编码 bundle 前缀 |
| 内嵌 Watch | `WKRunsIndependentlyOfCompanionApp` 键存在且为布尔 false；`WKApplication` 键存在且为布尔 true，拒绝字符串或数字代替布尔值 |

这些关系来自当前工程配置；Apple 的 [`WKApplication`](https://developer.apple.com/documentation/bundleresources/information-property-list/wkapplication) 与 [`WKRunsIndependentlyOfCompanionApp`](https://developer.apple.com/documentation/bundleresources/information-property-list/wkrunsindependentlyofcompanionapp) 文档列明对应布尔键。检查不代表已运行 app 或验证真实设备行为。

## 历史离线红绿与准备快照

以下保留 CI 实现阶段的原记录，其中“待首跑”“待 GitHub”只描述当时状态；当前已通过的公开运行见文首。

> 状态：配置已在本地准备，尚未提交、推送或首跑验证。当前工作基于 `7f114c160f01c19703bee0055bd526ee01c04e9d`，属于后继 CI 准备；不能作为不含此 workflow 的 PR #2 的 CI 证据。待前序工作合并后，应先与实际最新 main 对齐并复核，再通过独立 Draft PR 验证。

在基点 `7f114c160f01c19703bee0055bd526ee01c04e9d` 的未提交工作树上，先写目标行为 fixture，并使用可导入但故意放行无效输入的最小 scaffold 运行同一条 unittest 命令：exit 1，27 个测试方法，91 个目标断言失败（90 个为应拒绝的输入未抛 `CheckError`，1 个为 CLI 缺少成功输出），没有导入／缺模块错误。实现检查器后，同命令 exit 0，27 个测试方法通过；每个方法可含多个输入子用例。

随后为预检命令包装及内嵌路径边界补充回归用例：32 个测试方法中，符号链接／可执行文件越界的 4 个目标断言先失败（exit 1），收紧后同命令 exit 0，32 个方法全部通过。

离线静态检查命令通过现有 `python3 -B -` 驱动：对两个文件调用 `py_compile.compile(..., doraise=True)`（字节码写入临时目录），对提取的五个 run 块逐一调用 `bash -n`，均 exit 0；核对触发范围、最小权限、官方 checkout pin、两个 shared schemes 与构建参数的文本结构检查 exit 0。单独执行 `bash --noprofile --norc -c 'set -euo pipefail; (exit 7) | tee'` 返回预期 exit 7，证明失败未被管道末端掩盖。YAML 文本检查不等于 YAML 解析或 GitHub workflow 验证。

fixtures 为合成数据，不含真实日志。覆盖正确 XML/binary 产物及空格路径、宿主缺失／多宿主、缺 Watch／空目录／多 Watch、companion 不符、independent 与 WKApplication 的缺失／错误类型／错误值、最低版本不符、plist 损坏、缺可执行文件，以及错误 Xcode、Swift 越界、缺 SDK、runtime 缺失／不可用／版本或类型不符。CLI 正反用例核验 exit 0/1。

box 上现有 Python 3.13.5、Bash 可用；Swift 和 Xcode 不可用，未尝试运行实际 Swift 测试或模拟器构建。检查了现有 Python 的 `yaml`／`ruamel`／`strictyaml` 及 Node 的 `yaml`／`js-yaml`，均不可用，Ruby／yq 也不可用；只做 YAML 结构静态检查，正式解析待 GitHub。未安装任何工具。离线通过仅证明检查器行为；首次 GitHub 解析、runner 排队、实际镜像、完整 Swift 测试及双端 clean build 仍待独立 Draft PR 首跑验证。该 CI 不覆盖 Linux Swift 运行、真机、签名、UI 交互测试或真实 HTTP／Keychain／WatchConnectivity 适配器，也不替代独立评审。lint、SAST 和 required checks 的既有未配置状态不变。

> 当前仅完成本地准备。后续先处理前序记录与合并，再对齐最新 main；协调方独立执行隐私／凭据扫描及实现评审后，按授权提交并创建独立 Draft PR。首次运行验收应记录对应 head、工具链元数据、Swift 测试汇总、两个构建及真实嵌入检查结果；未通过前保持“待验证”。任何扫描命中（含疑似误报）先停报，不修改 allowlist 或基线。

## 故障策略、后续与回退

预览 runner 排队不可用或缺少指定 Xcode／SDK／runtime 时，保留失败或待运行状态并上报；job 超时不能作为排队时限保证。不自动换到其他标签、旧工具链，不下载 SDK，不放宽检查。修复须在授权范围内经复测与独立评审；涉及新依赖或门禁调整时按现有停止点处理。

后续变更继续绑定各自 head 记录 CI、工具链、测试与产物检查结果；未运行／失败不能写成成功，已有成功也不能外推为 S-UI、D 或 E 验收。真实适配器、跨设备登出和 S-3 等待开发与验收事项见 [MVP 状态](mvp-status.md#剩余事项)。扫描、独立评审、合并与设备部署仍按既有流程，不由 CI 自动执行。

回退仅撤回本次 workflow、`scripts/ci/` 和文档改动，不涉及生产 Swift、设备、secret 或仓库设置；后续已提交的回退也按正常分支、评审及批准流程进行，不改写历史。
