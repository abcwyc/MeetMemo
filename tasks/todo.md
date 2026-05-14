# 转录功能重构 TODO

## 背景

经过完整代码审计 + 亲自验证后，确认的真实问题清单（已排除子代理误判的 P3、P12、P2）。

## 修复清单

### Phase 1 — 低风险快速修复 ✅

- [x] **P10** 在 `markRecordingActive(sessionToken:)` 中 reset `micRetryCount = 0`
- [x] **P5** `scheduleSystemAudioRecovery` 锚定 sessionID + guard + `stopRecording` 中显式 cancel
- [x] **P15** `loadFullMeetingIfNeeded` 直播时保留 transcriptChunks
- [x] Phase 1 build verification — `xcodebuild Debug` BUILD SUCCEEDED

### Phase 2 — Stop 流程改造 ✅

- [x] **P7** STTProvider 协议加 `awaitPendingFinalization(timeout:)`，默认实现走 sleep；DoubaoSTTProvider 跟踪 `didSendFinalAudioAt`/`lastTranscriptAt`，按"首次回包后 300ms 静默"或上限 timeout 返回。AudioManager.stopRecording 用 withTaskGroup 等两路 provider；`scheduleDisconnectAfterFinalFlush` 同样改用此接口；`finalAudioFlushDelay = 0.8s` → `finalFlushTimeout = 3.0s`。

### Phase 3 — 时间基准统一 ✅

- [x] **P6** 把初始 `startMicrophoneTap` 与 `startSystemAudioTap` 中的 offset 从 `recordingBaseOffsetMilliseconds` 改为 `elapsedRecordingMilliseconds()`，让每路 provider 用各自 connect 时刻的偏移，两路对齐到 wall-clock。rotate/recover 路径已正确，无需改动。（未引入新的 RecordingTimeline 类型——单一改动即解决根因）

### Phase 4 — STT 生命周期 ✅

- [x] **P11** 经 trace 验证当前无双 disconnect 问题（rotate 替换 micSTT/systemSTT，stop 断的是替换后的当前值，旧 provider 仅走一次 schedule disconnect）。仅补上 rotate 中段 guard 的 `!isStoppingRecording` 收紧
- [x] **P9** 错误分类：
  - `ErrorHandler.isPermanentAuthErrorMessage` 新增
  - 永久（auth）→ 立即 stop
  - 配额（concurrency）→ system 走降级 / mic 仍停止
  - 暂时 → `scheduleSTTRecovery` 按 0.5/1/2/4s 退避，上限 4 次
  - 成功重连 reset attempts；start/stop 时清空 attempts + 取消所有 recovery tasks

### Phase 5 — UI/性能 ⏭️ (经审视，不改)

- [x] **P14** STT 实际输出 ≤10Hz，`refreshTranscriptDisplayChunks` 在长会议下约 O(10K) ops/sec，不是真实瓶颈。试过 throttle 100ms，但 stop 后最后一段会因 `isRecordingMeeting` guard 跳过——回归大于收益，撤回

## 验证策略

每个 Phase 完成后：
1. `xcodebuild -project MeetMemo.xcodeproj -scheme MeetMemo -configuration Debug build` 必须通过
2. 主观回归（用户跑录制场景）

## 风险点

- Phase 2 改 STTProvider 接口要兼顾既有调用，避免破坏接口
- Phase 3 时间基准改动影响转录 timeline，需用真实双路录音回归
- Phase 4 锁顺序要小心，避免和 stop 流程死锁

## 修复后回顾

### 实际改动文件

- `MeetMemo/Managers/AudioManager.swift` — P10/P5/P7/P6/P11/P9 主战场
- `MeetMemo/Managers/RecordingSessionManager.swift` —（无改动，P14 撤回）
- `MeetMemo/ViewModels/MeetingViewModel.swift` — P15
- `MeetMemo/Providers/ProviderProtocols.swift` — STTProvider 协议加 `awaitPendingFinalization` + 默认实现
- `MeetMemo/Providers/DoubaoSTTProvider.swift` — `awaitPendingFinalization` 真实实现 + 内部时间戳追踪
- `MeetMemo/Services/ErrorHandler.swift` — 公开 `isPermanentAuthErrorMessage`

### 偏离原计划之处

- **P14 撤回**：节流方案会让 stop 后最后一段被 `MeetingViewModel.isRecordingMeeting` guard 跳过；且实际开销不构成瓶颈。
- **P6 简化**：未引入新的 `RecordingTimeline` 类型，因为 `elapsedRecordingMilliseconds()` 已经做了正确的事——只需在初始 connect 时调用而不是用静态 base。"全局时间基准"概念已隐含。
- **P11 大幅缩减**：原以为有双 disconnect 风险，trace 后确认无此问题。仅补一个 guard。

### 子代理报告的校准

子代理（Explore subagent）的初次分析中：
- 误判为 Critical 的 P3（Accumulator 并发）：@MainActor 隔离已经保证串行，**实际不是 bug**
- 误判为 High 的 P2（状态机）：`isActiveSession` 允许 `.starting → .recording`，**实际工作正常**
- 误判为 High 的 P12（ProcessTap）：`AudioProcessingPipeline` 内部已有 NSLock + isStopped 双检，**实际无风险**
- 数据源冲突 P15：经 `MeetingViewModel:377-409` 验证，**确实存在**

教训：subagent 不读 supporting context（如 `AudioProcessingPipeline.swift`、`MeetingViewModel:380~` 的 detached load）时会基于片段过度推断。下次类似场景，宁可分多轮让 subagent 把依赖项读全，不要让它一次性下结论。

### 验证

- `xcodebuild Debug` 在每个 Phase 后均通过 ✅
- 未启动 app 实测（CLAUDE.md 项目规则：build 验证编译，不启动应用）
- 建议用户做以下回归：
  1. 新建录音 → 跑 5 分钟双路（mic + system）→ 检查时间戳排序是否平稳（**P6**）
  2. 录音中段切换到其他 Meeting 再切回 → 直播 transcript 不应消失（**P15**）
  3. 长录音（>1h）期间触发一次 mic 故障（拔耳机），第二次故障仍能恢复（**P10**）
  4. 主动断网 → 恢复 → 检查 STT 是否在 4 次退避内重连成功，attempts 是否被 reset（**P9**）
  5. 停止录音瞬间盯紧最后一句话是否完整保留（**P7**）
