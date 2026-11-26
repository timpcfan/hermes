# 交付说明：切模型必须落在下一条消息上

- 分支：`fix/model-switch-applied`（基于 `master-lzt`，未 push、未合并）
- 状态：实现与测试完成，iPhone / Mac 构建通过，仓库内测试全绿（除一个与本改动无关的既有失败）

## 1. 改了什么

### HermesKit（可测的决策与编排）

- `Packages/HermesKit/Sources/HermesKit/Sending/RunSettings.swift`（红阶段已提交）
  - `RunSettings`：聊天要设置的模型与推理强度。
  - `ConfigSetAnswer`：把一次 `config.set` 的「结果 + 错误」读成四种状态：
    - `applied(deferred:)`：有 `applied: true` 就用；`applied: false` 且 `deferred: true`
      也算已接受（本回合开始时生效）。
    - `confirmRequired(message:)`：`confirm_required: true`，没有切换。
    - `sessionNotFound`：4001。
    - `failed(message:)`：5001、5032、其他错误、`applied: false` 又非 deferred。
    - 旧网关没有 `applied` 时：没有 `deferred` / `confirm_required` 的普通回执视为成功。
- `Packages/HermesKit/Sources/HermesKit/Sending/RunSettingsApply.swift`
  - 按需设置模型和强度；模型 `config.set` 收到 4001 时调用一次 `reattach`（`session.resume`），
    在新 runtime 上重新设置仍然不同的项，然后再返回给调用方去 `prompt.submit`。
  - 没有真正生效的设置不会写进 `applied`：模型失败时保留会话实际在用的模型，并生成一句
    用户可见的提示；强度失败只留在下一次发送，不产生提示、不阻塞消息。
  - 恢复后如果打开会话跟到了另一台设备的新选择（`Reattach.wanted`），以新选择为准。
  - 聊天没有本机选择（“Gateway default”）时不发模型设置，也不会把会话报告的默认模型
    误当成本机选择。

### App

- `App/Model/ConversationModel.swift`
  - `applyRunSettings` 改为返回最终应使用的 runtime，内部调用 `RunSettingsApply`；
    只有回执表示生效时才更新 `appliedRunSettings`，失败时回到会话实际模型并追加一条
    `kind: "model"` 的本地 notice（“Hermes didn't switch this chat to X. This message runs on Y.”）。
  - 三个 4001 恢复点都先重新应用设置再继续：发送前的 `applyRunSettings`、图片上传的 resume、
    `prompt.submit` 外层的 resume。`prompt.submit` 只在网关明确回 4001（prompt 未接收）时重发一次。
  - `confirmModel`（昂贵模型确认卡）也改为读回执：确认后仍未生效时回退模型并给出同样提示；
    `confirm_required` 的“回退选择 + 弹确认卡”行为保持不变。

### Mock（按真实契约回答，未迁就实现）

- `Tools/mock-hermes/chats.py`
  - `config.set`：空闲会话切换成功答 `applied: true`；回合运行中答
    `applied: false, deferred: true` 并在下一回合开始时生效；选择守卫答
    `applied: false, confirm_required: true`；失效 runtime 答 4001。
  - 新增 mock-only 控制端点 `/api/mock/config-set`（按会话构造“无 `applied` 的旧网关”、
    强制 deferred、指定错误码）和 `/api/mock/calls`（记录 `config.set` / `prompt.submit`
    实际带了什么，包括每条 prompt 运行的模型）。
- `Tools/mock-hermes/backend.py`：`/api/mock/close-sessions` 支持只关闭指定会话，
  并行测试互不干扰；无参数时保持原行为。
- `Tools/mock-hermes/tests/test_session_model.py`：9 个 mock 契约测试。
- `docs/development.md`：记录上述控制端点与回执形状。

### 文档与工程

- `docs/sessions-and-models.md` §4：回执三态、4001 恢复后重新应用、失败回退与提示、
  强度失败不阻塞。
- `Hermes.xcodeproj/project.pbxproj`：`ComposeMenuPanel.swift` 之前加入仓库但未重新生成工程，
  iOS 构建找不到它；用 `xcodegen generate` 补上（Mac 不编译该文件，所以之前没暴露）。

## 2. 为什么

原来的 `applyRunSettings` 用 `try?` 吞掉 `config.set` 的错误，然后无条件把选择记成
`appliedRunSettings`，于是：

1. 设置失败时客户端仍显示新模型，且下一次发送因“没有变化”不再重试；
2. gateway 忘掉 runtime（4001）后，`session.resume` 拿到的新 runtime 上没有重新设置模型，
   `prompt.submit` 仍由旧模型执行，下一轮才换。

现在把“是否真的生效”作为唯一标准：回执说生效才记录，4001 就先 resume、重新设置成功后再提交，
失败就回到真实模型并明确告诉用户这一条用的是哪个模型。

## 3. 验收项与测试

运行命令（在 `Packages/HermesKit`）：

```sh
swift test --filter RunSettingsTests
HERMES_MOCK_BACKEND=http://127.0.0.1:19319 swift test --filter BackendIntegrationTests
HERMES_MOCK_BACKEND=http://127.0.0.1:19319 swift test
```

mock 启动（本次使用 19319 / 19642）：

```sh
python3 -I Tools/mock-hermes/backend.py --port 19319 --gateway-port 19642
```

mock 自身的契约测试：

```sh
python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_session_model.py
```

| 验收项 | 测试 |
|---|---|
| 1. 空闲/已停止会话选 B 后第一条消息由 B 执行 | `RunSettingsTests.aDeadRuntimeIsResumedAndTheModelSetBeforeTheMessage`（顺序：旧 runtime 4001 → resume → 新 runtime 设模型 → 设强度）<br>`RunSettingsTests.aResumedSessionThatAlreadyRunsThePickIsNotSetTwice`<br>`RunSettingsTests.aResumeThatReportsAnotherPickFollowsIt`<br>`BackendIntegrationTests.aModelPickOnADeadRuntimeRunsTheVeryNextMessage`（mock 后端：关掉 runtime → 选 B → 发送 → 只有一次 `prompt.submit`，属于新 runtime，会话模型是 B） |
| 2. 未生效不得记 applied、顶栏回退、用户可见提示 | `RunSettingsTests.aFailedSwitchIsNotRecordedAndSaysSo`（5001：`applied` 仍是旧模型；提示同时包含 B 和旧模型名）<br>`RunSettingsTests.anErrorIsNeverApplied`（5001 / 5032 / 4001 / 网络错误）<br>`test_session_model.py::test_a_refused_config_set_answers_its_code_and_records_it`<br>App 端：`applyRunSettings` 回退 `model` 并追加 `kind: "model"` 的 notice；`confirmModel` 同理（逻辑已编译，未做 UI 自动化） |
| 3. 三态回执（有 `applied` 用它；旧网关推断；deferred 接受；confirm_required 拒绝且原行为不变） | `RunSettingsTests.aReceiptWithAppliedSaysWhatHermesDid`<br>`RunSettingsTests.anOlderGatewayWithoutAppliedIsReadByItsFields`<br>`RunSettingsTests.aDeferredSwitchCountsForThisMessage`<br>`RunSettingsTests.aConfirmationIsNeverTaken`<br>`test_session_model.py::test_an_older_gateway_answers_without_applied`<br>`test_session_model.py::test_a_switch_while_a_turn_runs_is_deferred_and_takes_over_next_turn`<br>`test_session_model.py::test_an_expensive_model_waiting_for_confirmation_changes_nothing` |
| 4. 任何恢复/重试路径不重复提交同一条消息 | `BackendIntegrationTests.aModelPickOnADeadRuntimeRunsTheVeryNextMessage` 断言 `prompt.submit` 只收到一次；`RunSettingsTests.aResumedSessionThatAlreadyRunsThePickIsNotSetTwice` 断言恢复后不重复设置；`prompt.submit` 只在网关明确回 4001（未接收）时重发 |
| 5. 强度失败不记 applied、但不阻止消息 | `RunSettingsTests.aFailedEffortIsNotRecordedAndDoesNotHoldTheMessage` |
| 附加：没有本机选择时不误设置 | `RunSettingsTests.aChatOnTheGatewaysDefaultSetsNoModel` |
| 附加：确实没变化时不发请求 | `RunSettingsTests.nothingChangedMakesNoCalls` |

## 4. 实际结果

- **红阶段**：commit `8a9f5ce`（`Tests: a model pick must run the next message, not the one after it`）只加了测试与回执类型，
  `RunSettingsApply` 仍是旧的无条件 `applied = wanted`。当时 5 个 applying 测试失败（17 个 issue），
  receipt 测试通过，红是测试真实驱动出来的。
- **实现绿**：`swift test --filter RunSettingsTests` → **12 个测试全部通过**。
  - `aModelPickOnADeadRuntimeRunsTheVeryNextMessage` 单独运行 → **1 test passed**。
- **HermesKit 全量**（连 mock）：`HERMES_MOCK_BACKEND=http://127.0.0.1:19319 swift test`
  → **1956 tests / 228 suites，1 个失败**：`BackendIntegrationTests.approvalsAreServerRequests`。
  该失败与本改动无关：把 `Tools` 复制到 `/tmp` 并用 `git show HEAD:...` 还原改动前的
  `chats.py` / `backend.py` 后，同一测试仍然失败（它的断言字符串本来就不在 mock 的 approve 回复里）。
- **mock 契约测试**：`python3 -I -m unittest ... -p test_session_model.py` → **9 tests OK**。
- **iOS Simulator 构建**：`xcodebuild ... -destination 'generic/platform=iOS Simulator' ... build`
  → `** BUILD SUCCEEDED **`，本仓库代码 **0 warning**。
- **Mac 构建**：`xcodebuild ... -destination 'platform=macOS' ... CODE_SIGNING_ALLOWED=NO build`
  → `** BUILD SUCCEEDED **`，本仓库代码 **0 warning**（本机无 “Mac Development” 证书，未签名）。
- **mock 证据**：集成测试通过 `/api/mock/calls` 读到该会话的 3 次 `config.set`
  （旧 runtime 一次 4001；新 runtime 上模型、强度各一次，均 `applied: true`）和恰好 1 次
  `prompt.submit`（新 runtime，`model == openai/gpt-5`）。

## 5. 已知限制

- **未在真机 / 真实 gateway 上验证**。本机运行的 gateway 仍是旧代码，没有 `applied` 字段；
  两种回执都由 mock 构造并测试（符合 QUESTIONS 的要求）。gateway 升级重启后建议再做一次手工冒烟。
- **UI 只做了编译验证**：顶栏/胶囊回退和 in-chat notice 的渲染没有 UI 自动化或截图证据；
  其决策与提示文案由 HermesKit 测试覆盖，App 的接线未在运行中的界面里点过。
- App target 没有单元测试 target，因此 mock 集成测试直接驱动 `RunSettingsApply`（App 发送路径
  调用的同一函数），而不是整个 `ConversationModel.send`。App 侧调用点只经过编译和代码审查。
- **旧网关的 deferred**：按契约它在本回合开始时生效，所以这一条消息就算数；如果某个旧网关的
  deferred 实际含义不同，客户端无法从回执分辨。
- 失败且没有发生 resume 时，`applied` 是这台设备最后一次知道的设置（可能为空）；顶栏会退到
  会话行报告的真实模型或 “Gateway default”，不会额外发一次查询去问 gateway。
- Mac 构建未签名；未运行 UI 测试（需要模拟器与 mock，本次交付的必测证据不包含 UI 测试）。
- `approvalsAreServerRequests` 是既有失败，未在本分支修复。
- 为让 iOS 构建通过，提交了 `ComposeMenuPanel.swift` 的工程成员修复（既有遗漏）。

## 6. 与 BRIEF 的差异

- BRIEF 引用的 `applyRunSettings` 行号（约 5786–5817）在改动后已变化；现在该函数在
  `App/Model/ConversationModel.swift` 约 5788 行起，并返回 runtime。
- BRIEF 说 mock 在 `Tools/mock-hermes/backend.py`；实际的 `config.set` 实现在
  `Tools/mock-hermes/chats.py`，`backend.py` 只注册新增的 mock-only 控制端点。
- 额外处理了 BRIEF 未列出的两种情况：恢复时跟到另一台设备的新选择；聊天使用
  Gateway default（没有本机模型选择）时不做无意义的模型设置。
- 除必测用例外，还补了 `aResumeThatReportsAnotherPickFollowsIt`、
  `aChatOnTheGatewaysDefaultSetsNoModel`、`nothingChangedMakesNoCalls`，防止实现引入回归。
