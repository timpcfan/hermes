# DELIVERY — iPhone Chats 行对齐 Bots、标题换行、模型行与分隔线

分支 `ios-chat-rows`，基线 `de009c4`。三个阶段提交，只改 iPhone 视图与 HermesKit；iPad
`NavigationSplitView` 与 Mac 侧栏外观未变。

## 一、提交

| 提交 | 内容 |
|---|---|
| `bedbfc6` | `Chats: read the model and reasoning effort Hermes reports for a chat` |
| `6509708` | `Chats: grow the iPhone's rows to the Bots tab's sizes and show the model` |
| `734267c` | `Chats: separate rows with a hairline and regions with a stronger line` |

### 改动文件

- `Packages/HermesKit/Sources/HermesKit/Models/SessionModels.swift`：`HermesSession.reasoningEffort`
  解码 `reasoning_effort`（缺失为 nil），编码、相等性与缓存往返沿用现有风格；旧 gateway 不受影响。
- `Packages/HermesKit/Sources/HermesKit/Inbox/ChatRowPresentation.swift`：`ChatRowSubtitle.modelLine(model:effort:)`，
  去 provider 前缀、模型名 28 字符截断加 `…`、effort 小写原样（含 `none`）、缺一不留孤立 `·`、都缺返回 nil。
- `Packages/HermesKit/Tests/HermesKitTests/ChatRowPresentationTests.swift`、`InboxTests.swift`：两种情况、
  只有模型、只有强度、都缺、空串、`provider/` 兜底、超长截断、缓存往返与旧 gateway 解码。
- `Tools/mock-hermes/server.py`：会话行样本覆盖「模型+强度」「只有模型」「只有强度」「都缺」；
  长标题聊天补了一轮消息（列表默认隐藏空会话，否则样本不可见）。
- `Tools/mock-hermes/tests/test_session_list.py`：校验 mock 行携带的 `model` / `reasoning_effort` 形状。
- `App/Views/Sidebar/IOSChatRow.swift`：头像 44pt（`InboxMetrics.faceSize`），标题 `.body.weight(.semibold)`、
  副标题 `.subheadline`、状态 `.footnote.weight(.semibold)`；标题最多 2 行、`.fixedSize(vertical:)`，
  右侧状态固定不被挤压；右下角 `.caption` tertiary 模型行。
- `App/Views/Sidebar/IOSChatList.swift`：最小行高 `InboxMetrics.botRowHeight`（66）；按区域计算
  `SidebarRowDivider`（行线 / 分区线 / 无线）。
- `App/Views/Sidebar/SidebarChrome.swift`：`SidebarRowDivider` 与 `sidebarRowDivider(_:)` 修饰器，
  1 物理像素、左右通栏、分区线上留 6pt、颜色走 `Theme.hairline` / `Theme.separator`。
- `App/Views/Bots/BotRosterSections.swift`：新增默认 `false` 的 `showsRowDividers`；群聊→Bot、
  置顶→非置顶、Bot→Hidden 三个边界画分区线，最后一行无线。
- `App/Views/Sidebar/IOSBotList.swift`：只有 iPhone 的 Bots 列表打开 `showsRowDividers`。
- `docs/inbox.md` §10：记录行排版与两类分隔线。

## 二、截图（iPhone 18 Pro 模拟器，iOS 27.2）

浅色：

- `_brief/screenshots/chats-light.png`：行对齐后的 Chats；右下角 `qwen4-max · xhigh` 与
  `claude-sonnet-4.6`；右上状态保持原样；Pinned→Main 的分区线更重。
- `_brief/screenshots/chats-light-long-title.png`：长标题 `Refactor the authentication middleware
  before the next beta ships` 换行到 2 行并截断，行高高于单行行，右上 `46m` 未被挤压；还有
  标题 `Literature review: attention sinks` 的两行行与 Done 状态。
- `_brief/screenshots/bots-light.png`：Bots 字号/头像与 Chats 对齐，行间 hairline，
  「Launch crew」（群聊）→ Bot 的分区线更重，末行后无线。
- `_brief/screenshots/bots-light-hidden.png`：展开 Hidden；Ada→Hidden 分区线，Hidden 内 Scout
  是最后一行、其后无线。

暗色：

- `_brief/screenshots/chats-dark.png`：暗色 Chats 顶部；模型行与分隔线。
- `_brief/screenshots/chats-dark-long-title.png`：暗色长标题换行、状态与模型行。
- `_brief/screenshots/bots-dark.png`：暗色 Bots 行线与分区线。
- `_brief/screenshots/bots-dark-hidden.png`：暗色展开 Hidden，最后一行无线。

补充像素核对（`bots-light-hidden.png` 按行取平均色）：

- 行间线 `(235, 235, 235)`，分区线 `(198, 198, 200)`，两者 1 物理像素；
- 分量线位于 Launch crew→Research Buddy、Ada→Hidden 两处，最后一行（Scout）之后没有线。

## 三、门禁结果

| 门禁 | 命令 | 结果 |
|---|---|---|
| HermesKit 单测 | `(cd Packages/HermesKit && swift test --force-resolved-versions)` | `1936 tests in 227 suites passed`（exit 0） |
| mock 测试 | `python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_session_list.py` | `Ran 4 tests ... OK` |
| iOS 构建 | `xcodebuild ... -destination 'generic/platform=iOS Simulator' ... build` | `BUILD SUCCEEDED`，exit 0 |
| iOS 告警 | `Scripts/check-build-warnings.sh /tmp/hermes-ios-build.log` | `No warnings in our code.` |
| Mac 构建 | `xcodebuild ... -destination 'platform=macOS' ... CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED`，exit 0 |
| Mac 告警 | `Scripts/check-build-warnings.sh /tmp/hermes-mac-build.log` | `No warnings in our code.` |

验证环境：mock 为 `Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642 --inbox-gtd
--inbox-demo --cross-profile`，App 以 `-HERMES_BOOTSTRAP_*` 指向本地 mock；未接触真实
gateway、`~/.hermes` 或付费模型。验证完成后已停止 mock 并关闭模拟器。

## 四、需求对照

1. **字号/头像/行高对齐 Bots**：Chats 标题 `.body`、副标题 `.subheadline`，头像 44pt、
   最小行高 66pt（`InboxMetrics`），与 Bots 行同一套尺寸。
2. **行间 1px 极浅线、末项无线**：`SidebarRowDivider.line` 用 `Theme.hairline`，
   1/`displayScale` 物理像素，左右通栏；最后一行 `.none`。
3. **分区线**：真实区域边界（Chats：Pinned、Main、Working、Settled；Bots：群聊→Bot、
   置顶→非置顶、Bot→Hidden）用 `Theme.separator` 并留 6pt 间距；标题行保留。
4. **Chats 标题换行、行不等高、不挤压状态**：去掉单行限制，最多 2 行；状态在独立
   HStack 尾部，长标题只向下换行。
5. **右下角模型 + 强度**：`ChatRowSubtitle.modelLine` 生成，`.caption` tertiary、右对齐、
   `lineLimit(1)`；只显示存在的部分，不出现孤立 `·`，都缺时整行隐藏。
6. **右上状态不变**：运行时长 / Done / 已读结束时间 / Needs you / Failed 的 `ChatRowStatusBadge`
   逻辑与字号位置未改。

## 五、已知限制与说明

- **旧 gateway**：没有 `reasoning_effort` 时只显示模型；模型也缺失时整行不显示。解码用
  `try?`，字段类型异常同样退化为 nil，不影响会话列表。
- **没有日期分组**：当前 `InboxSections` 只有 Pinned / Main / Working / Settled，本次不新增
  日期标题，分区线画在真实区域边界（见 `_brief/QUESTIONS.md` 假设 1）。
- **标题上限 2 行**：brief 允许 2–3 行，取 2 行保持首屏密度；更长的标题尾部截断。
- **模型名截断**：超过 28 字符截断加 `…`，界面再加 `lineLimit(1)` 兜底。
- **iPad / Mac 不变**：`BotRosterSections.showsRowDividers` 默认 `false`，只有 `IOSBotList`
  打开；iPad 的分栏侧栏与 Mac 侧栏仍无分线。iPad 构建与 iPhone 共用同一 iOS target，未改
  `NavigationSplitView` 代码。
- **Mac 构建签名**：本机没有 `Mac Development` 证书，macOS 构建以
  `CODE_SIGNING_ALLOWED=NO` 完成；这是环境限制，不是代码问题。
- **设计项目**：Elyx 设计项目不在本 worktree/环境中，无法同步 `.elyx`；颜色全部使用
  `Theme` 既有 token，取舍记录在 `_brief/QUESTIONS.md`。
- **系统版本**：截图来自 iOS 27.2 模拟器（Liquid Glass 标签栏、`.scrollEdgeEffectStyle`）；
  iOS 26 及更早版本的标签栏与滚动边缘效果可能略有差异。
