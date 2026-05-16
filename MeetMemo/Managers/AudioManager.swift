// AudioManager.swift
// Unified audio manager for microphone and system audio capture

@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Manages audio capture from microphone and system audio and handles real-time transcription.
@MainActor
class AudioManager: NSObject, ObservableObject {
    static let shared = AudioManager()

    @Published var transcriptChunks: [TranscriptChunk] = []
    @Published var isRecording = false
    @Published var isRecoveringSTT = false
    /// 用户点击结束录制后、await STT final flush 完成前的中间态。
    /// 用于在 UI 上显示"处理中"指示，避免按钮看上去卡了几秒。
    @Published var isStoppingRecording: Bool = false
    @Published var errorMessage: String?
    @Published var micAudioLevel: Float = 0.0
    @Published var systemAudioLevel: Float = 0.0

    private var audioEngine = AVAudioEngine()
    private let sttProviderFactory: STTProviderFactory
    private var micSTT: STTProvider?
    private var systemSTT: STTProvider?
    private var micAudioPipeline: AudioProcessingPipeline?
    private var systemAudioPipeline: AudioProcessingPipeline?
    private var startRecordingTask: Task<Void, Never>?
    private var sttRotationTask: Task<Void, Never>?
    private var micRestartTask: Task<Void, Never>?
    private var rotatingSTTSources: Set<AudioSource> = []
    private let sttRotationInterval: UInt64 = 25 * 60 * 1_000_000_000
    /// stop / rotate 时等待 STT 最终结果的上限。安静期由 provider 内部判定；这里只是兜底。
    private let finalFlushTimeout: TimeInterval = 5.0
    private var recordingStartedAtUptime: TimeInterval?
    private var recordingBaseOffsetMilliseconds = 0
    private var recordingStateMachine = AudioRecordingStateMachine()

    // Unique identifier for the current recording session
    private var sessionID = UUID()

    // ProcessTap properties
    private var processTap: ProcessTap?
    private let audioProcessController = AudioProcessController()
    private let permission = AudioRecordingPermission()
    private let tapQueue = DispatchQueue(label: "io.meetmemo.audiotap", qos: .userInitiated)
    private var isTapActive = false
    private var isRestartingSystemTap = false

    private var micRetryCount = 0
    private let maxMicRetries = 3

    /// 各路 STT 的暂时错误重试计数，成功一次就重置。
    private var sttRecoveryAttempts: [AudioSource: Int] = [:]
    private var sttRecoveryTasks: [AudioSource: Task<Void, Never>] = [:]
    private let maxSTTRecoveryAttempts = 4

    /// 用于保护 STT provider 原子切换的锁
    private let sttProviderLock = NSLock()

    private var transcriptAccumulator = TranscriptUpdateAccumulator()
    private var rawTranscriptEvents = RawTranscriptEventRingBuffer(capacity: 20_000)
    private var cancellables = Set<AnyCancellable>()
    /// `NotificationCenter.addObserver(forName:object:queue:using:)` returns an opaque token
    /// that must be passed back to `removeObserver`. We need to drop and re-register this
    /// each time `audioEngine` is replaced, because the observer is filtered by sender.
    private var audioEngineConfigObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    private override init() {
        self.sttProviderFactory = DoubaoSTTProviderFactory()
        super.init()
        registerAudioEngineConfigObserver()
        registerSystemPowerObservers()

        audioProcessController.activate()

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isTapActive else { return }
                print("🎤 Running applications changed, checking if tap restart is needed.")
                Task {
                    await self.restartSystemAudioTapIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let audioEngineConfigObserver {
            center.removeObserver(audioEngineConfigObserver)
        }
        if let willSleepObserver {
            workspaceCenter.removeObserver(willSleepObserver)
        }
        if let didWakeObserver {
            workspaceCenter.removeObserver(didWakeObserver)
        }
    }

    private func registerAudioEngineConfigObserver() {
        if let audioEngineConfigObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigObserver)
        }
        audioEngineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioEngineConfigurationChange()
            }
        }
    }

    /// macOS posts `willSleepNotification` *before* sleep takes effect. We finalize the
    /// recording proactively so the user gets a clean final transcript instead of having
    /// the WebSocket / mic engine die mid-stream while the lid closes. We do not auto-resume
    /// on wake: the system audio + mic state after a sleep is unpredictable enough that the
    /// safer default is to surface a clear stop and let the user start a new session.
    private func registerSystemPowerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isStoppingRecording else { return }
                print("💤 System will sleep — finalizing recording before suspend.")
                self.errorMessage = "系统即将进入睡眠，已自动结束录音。"
                self.stopRecording()
            }
        }
        didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("☀️ System woke up. Recording was stopped at sleep; user must start again manually.")
        }
    }

    func startRecording() {
        print("Starting recording...")

        abortRecording()
        sessionID = UUID()
        let startedSessionID = sessionID
        recordingStateMachine.start(sessionID: startedSessionID)
        errorMessage = nil
        recordingStartedAtUptime = ProcessInfo.processInfo.systemUptime
        transcriptChunks = transcriptChunks.filter(\.isFinal)
        recordingBaseOffsetMilliseconds = Self.maximumTranscriptEndTime(in: transcriptChunks)
        transcriptAccumulator.reset(chunks: transcriptChunks)
        rawTranscriptEvents.removeAll()
        sttRecoveryAttempts.removeAll()
        sttRecoveryTasks.values.forEach { $0.cancel() }
        sttRecoveryTasks.removeAll()

        startRecordingTask?.cancel()
        startRecordingTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let micStarted = await self.startMicrophoneTap(sessionToken: startedSessionID)
            if micStarted, !Task.isCancelled {
                await self.startSystemAudioTap(isInitialStart: true, sessionToken: startedSessionID)
            }
            guard !Task.isCancelled else { return }
            if self.isRecording, self.sessionID == startedSessionID, !self.isStoppingRecording {
                self.startSTTRotationTimer(for: startedSessionID)
            }
        }
    }

    /// Immediately tears down the current recording session without waiting for final STT output.
    /// Use only for hard resets and startup failures; normal user stops should call `stopRecording`.
    private func abortRecording() {
        print("Internal cleanup...")

        stopSTTRotationTimer()
        stopStartRecordingTask()
        stopMicRestartTask()
        // 取消系统音频恢复任务与所有 STT 退避重连任务
        systemAudioRecoveryTask?.cancel()
        systemAudioRecoveryTask = nil
        sttRecoveryTasks.values.forEach { $0.cancel() }
        sttRecoveryTasks.removeAll()
        stopAudioPipelines()
        let stoppedSessionID = sessionID
        recordingStateMachine.stop(sessionID: stoppedSessionID)
        isStoppingRecording = true
        sessionID = UUID()
        isRecording = false
        recordingStartedAtUptime = nil
        recordingBaseOffsetMilliseconds = 0
        AudioLevelManager.shared.updateRecordingState(false)

        if isTapActive {
            systemAudioPipeline?.stop()
            systemAudioPipeline = nil
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated")
        }

        cleanupAudioEngine()
        disconnectSTTProviders()
        transcriptAccumulator.removeAllInterimState()
        recordingStateMachine.reset()
        isRecoveringSTT = false
        isStoppingRecording = false

        print("Internal cleanup completed")
    }

    private func restartMicrophone() {
        guard isRecording, !isStoppingRecording else { return }

        guard micRetryCount < maxMicRetries else {
            // Out of retries: avoid leaving `isRecoveringSTT` stuck on with no error surfaced.
            // Surface the failure and stop, so the UI exits the "recovering" state.
            let message = "Microphone failed to recover after \(maxMicRetries) attempts."
            print("⛔️ \(message) Stopping recording.")
            errorMessage = message
            isRecoveringSTT = false
            stopRecording()
            return
        }

        print("🔄 Restarting microphone capture (attempt \(micRetryCount + 1))")
        micRetryCount += 1
        let restartSessionID = sessionID

        cleanupAudioEngine()
        // markRecordingActive will clear this once the mic tap is back online.
        isRecoveringSTT = true

        micRestartTask?.cancel()
        micRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.startMicrophoneTapAfterRestart(sessionToken: restartSessionID)
        }
    }

    private func startMicrophoneTapAfterRestart(sessionToken: UUID) async {
        guard isActiveSession(sessionToken), isRecording else { return }
        _ = await startMicrophoneTap(sessionToken: sessionToken)
    }

    /// Starts a microphone tap using the STT provider.
    private func startMicrophoneTap(sessionToken: UUID) async -> Bool {
        print("🎤 Starting microphone tap...")

        guard isActiveSession(sessionToken) else { return false }

        do {
            // 用 connect 时刻的 elapsed 作为该路时间基准，避免 mic 与 system 因顺序 connect 而错位。
            _ = try await connectSTTProvider(for: .mic, offsetMilliseconds: elapsedRecordingMilliseconds())
            guard isActiveSession(sessionToken) else { return false }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: 16_000,
                                                   channels: 1,
                                                   interleaved: false) else {
                print("❌ Failed to create target audio format for mic tap")
                restartMicrophone()
                return false
            }

            guard let pipeline = makeAudioPipeline(
                source: .mic,
                sessionToken: sessionToken,
                inputFormat: recordingFormat,
                targetFormat: targetFormat
            ) else {
                print("❌ Failed to create audio pipeline for mic tap")
                restartMicrophone()
                return false
            }
            micAudioPipeline?.stop()
            micAudioPipeline = pipeline

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self else { return }

                guard buffer.frameLength > 0 else {
                    print("❌ Invalid mic buffer detected - restarting")
                    Task { @MainActor [weak self] in
                        self?.restartMicrophone()
                    }
                    return
                }

                self.micAudioPipeline?.enqueue(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            guard isActiveSession(sessionToken) else {
                cleanupAudioEngine()
                return false
            }
            print("✅ Microphone tap started successfully")
            micRetryCount = 0
            markRecordingActive(sessionToken: sessionToken)
            return true
        } catch {
            guard isActiveSession(sessionToken) else { return false }
            print("❌ Failed to start microphone tap: \(error)")
            errorMessage = ErrorHandler.shared.handleError(error)
            abortRecording()
            return false
        }
    }

    private func cleanupAudioEngine() {
        print("🧹 Cleaning up audio engine...")

        if audioEngine.isRunning {
            audioEngine.stop()
            print("⏹️ Audio engine stopped")
        }

        micAudioPipeline?.stop()
        micAudioPipeline = nil

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        print("🔇 Input tap removed")

        audioEngine.reset()
        print("🔄 Audio engine reset")

        audioEngine = AVAudioEngine()
        registerAudioEngineConfigObserver()
        print("✨ Fresh audio engine created")
    }

    private func startSystemAudioTap(isRestart: Bool = false, isInitialStart: Bool = false, sessionToken: UUID? = nil) async {
        print(isRestart ? "🎧 Restarting system audio tap logic..." : "🎧 Starting system audio tap for the first time...")
        let activeSessionToken = sessionToken ?? sessionID

        guard isActiveSession(activeSessionToken) || isRestart else { return }

        if !isRestart {
            guard await checkSystemAudioPermissions() else {
                guard isActiveSession(activeSessionToken) else { return }
                let errorMsg = "System audio recording permission denied."
                print("❌ \(errorMsg)")
                errorMessage = errorMsg
                abortRecording()
                return
            }
        }

        guard isRecording || isRestart || isInitialStart else {
            return
        }

        do {
            // 用 connect 时刻的 elapsed 作为该路时间基准，与 mic 共享 wall-clock 锚点。
            _ = try await connectSTTProvider(for: .system, offsetMilliseconds: elapsedRecordingMilliseconds())
            guard isActiveSession(activeSessionToken) else { return }

            let allProcessObjectIDs = audioProcessController.processes.map { $0.objectID }
            if allProcessObjectIDs.isEmpty {
                print("⚠️ No audio-producing processes found. System audio tap might not capture anything.")
            }

            let target = TapTarget.systemAudio(processObjectIDs: allProcessObjectIDs)
            let newTap = ProcessTap(target: target)
            newTap.activate()

            if let tapError = newTap.errorMessage {
                guard isActiveSession(activeSessionToken) else {
                    newTap.invalidate()
                    return
                }
                let errorMsg = "Failed to activate system audio tap: \(tapError)"
                print("❌ \(errorMsg)")
                errorMessage = errorMsg
                if !isRestart { abortRecording() }
                return
            }

            processTap = newTap
            isTapActive = true

            do {
                try startTapIO(newTap, sessionToken: activeSessionToken)
                guard isActiveSession(activeSessionToken) else {
                    newTap.invalidate()
                    isTapActive = false
                    return
                }

                if !isRestart {
                    markRecordingActive(sessionToken: activeSessionToken)
                }
                print("✅ System audio tap started successfully (isRestart: \(isRestart))")
            } catch {
                guard isActiveSession(activeSessionToken) else { return }
                let errorMsg = "Failed to start system audio tap IO: \(error.localizedDescription)"
                print("❌ \(errorMsg)")
                errorMessage = errorMsg
                newTap.invalidate()
                isTapActive = false
                if !isRestart { abortRecording() }
            }
        } catch {
            guard isActiveSession(activeSessionToken) else { return }
            let errorMsg = ErrorHandler.shared.handleError(error)
            print("❌ Failed to connect system STT provider: \(errorMsg)")
            if ErrorHandler.shared.isConcurrencyQuotaErrorMessage(errorMsg), isRecording {
                disableSystemAudioAfterConcurrencyLimit(message: errorMsg)
                return
            }
            errorMessage = errorMsg
            if !isRestart {
                abortRecording()
            }
        }
    }

    private func restartSystemAudioTapIfNeeded() async {
        let newProcessObjectIDs = Set(audioProcessController.processes.map { $0.objectID })
        let currentProcessObjectIDs: Set<AudioObjectID>

        if case .systemAudio(let processObjectIDs) = processTap?.target {
            currentProcessObjectIDs = Set(processObjectIDs)
        } else {
            currentProcessObjectIDs = []
        }

        if newProcessObjectIDs != currentProcessObjectIDs {
            print("Process list has changed. Restarting system audio tap.")
            await restartSystemAudioTap()
        } else {
            print("Process list is the same. No restart needed.")
        }
    }

    private func restartSystemAudioTap() async {
        print("🔄 Restarting system audio tap...")

        guard isRecording, !isStoppingRecording else {
            print("Recording was stopped, aborting tap restart.")
            return
        }

        isRestartingSystemTap = true
        defer { isRestartingSystemTap = false }

        if isTapActive {
            systemAudioPipeline?.stop()
            systemAudioPipeline = nil
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated for restart.")
        }

        try? await Task.sleep(for: .milliseconds(250))

        guard isRecording, !isStoppingRecording else {
            print("Recording was stopped during tap restart. Aborting.")
            return
        }

        await startSystemAudioTap(isRestart: true, sessionToken: sessionID)
    }

    @MainActor
    private func checkSystemAudioPermissions() async -> Bool {
        if permission.status == .authorized {
            return true
        }

        permission.request()

        for _ in 0..<10 {
            if permission.status == .authorized {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return permission.status == .authorized
    }

    private func startTapIO(_ tap: ProcessTap, sessionToken: UUID) throws {
        guard var streamDescription = tap.tapStreamDescription else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get audio format from tap."])
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioFormat from tap."])
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format for system tap."])
        }

        guard let pipeline = makeAudioPipeline(
            source: .system,
            sessionToken: sessionToken,
            inputFormat: format,
            targetFormat: targetFormat
        ) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio pipeline for system tap."])
        }
        systemAudioPipeline?.stop()
        systemAudioPipeline = pipeline

        try tap.run(on: tapQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self = self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                return
            }

            self.systemAudioPipeline?.enqueue(buffer)

        } invalidationHandler: { [weak self] _ in
            guard let self else { return }
            print("Audio tap was invalidated.")

            if !self.isRestartingSystemTap && !self.isStoppingRecording {
                print("Tap invalidated unexpectedly. Restarting system audio tap.")
                Task {
                    await self.restartSystemAudioTap()
                }
            } else {
                print("Tap invalidated as part of a restart. Not stopping recording.")
            }
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        guard isRecording
            || micSTT != nil
            || systemSTT != nil
            || isTapActive
            || recordingStateMachine.state.sessionID != nil else {
            completion?()
            return
        }

        stopSTTRotationTimer()
        stopStartRecordingTask()
        stopMicRestartTask()
        systemAudioRecoveryTask?.cancel()
        systemAudioRecoveryTask = nil
        sttRecoveryTasks.values.forEach { $0.cancel() }
        sttRecoveryTasks.removeAll()
        let stoppedSessionID = sessionID
        recordingStateMachine.stop(sessionID: stoppedSessionID)
        // 标记为"处理中"——isRecording 仍为 true，UI 可据此显示 spinner，
        // 不影响内部 isRecording 检查（任何 stop-aware 路径仍读 isStoppingRecording）。
        isStoppingRecording = true
        print("Stopping recording...")

        micAudioLevel = 0.0
        systemAudioLevel = 0.0
        AudioLevelManager.shared.updateMicLevel(0.0)
        AudioLevelManager.shared.updateSystemLevel(0.0)

        if isTapActive {
            systemAudioPipeline?.stop()
            systemAudioPipeline = nil
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated")
        }

        cleanupAudioEngine()
        micRetryCount = 0
        sendFinalAudioToSTTProviders()

        let micProvider = micSTT
        let systemProvider = systemSTT
        let timeout = finalFlushTimeout
        Task { @MainActor [weak self] in
            guard let self else {
                completion?()
                return
            }

            await withTaskGroup(of: Void.self) { group in
                if let micProvider {
                    group.addTask { await micProvider.awaitPendingFinalization(timeout: timeout) }
                }
                if let systemProvider {
                    group.addTask { await systemProvider.awaitPendingFinalization(timeout: timeout) }
                }
            }

            guard self.sessionID == stoppedSessionID else {
                completion?()
                return
            }

            self.disconnectSTTProviders()
            self.transcriptAccumulator.removeAllInterimState()
            self.recordingStateMachine.reset()
            self.isRecording = self.recordingStateMachine.state.isRecordingVisible
            self.isRecoveringSTT = false
            self.isStoppingRecording = false
            self.recordingStartedAtUptime = nil
            self.recordingBaseOffsetMilliseconds = 0
            AudioLevelManager.shared.updateRecordingState(false)
            print("Recording stopped")
            completion?()
        }
    }

    private func makeAudioPipeline(
        source: AudioSource,
        sessionToken: UUID,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> AudioProcessingPipeline? {
        AudioProcessingPipeline(
            source: source,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            onAudioData: { [weak self] data, source in
                Task { @MainActor [weak self] in
                    self?.sendAudioData(data, source: source, sessionToken: sessionToken)
                }
            },
            onAudioLevel: { [weak self] level, source in
                Task { @MainActor [weak self] in
                    self?.updateAudioLevel(level, source: source, sessionToken: sessionToken)
                }
            }
        )
    }

    private func markRecordingActive(sessionToken: UUID) {
        guard isActiveSession(sessionToken) else { return }
        recordingStateMachine.markRecording(sessionID: sessionToken)
        isRecording = recordingStateMachine.state.isRecordingVisible
        isRecoveringSTT = false
        // Reset mic retry counter so long sessions survive a second engine failure.
        micRetryCount = 0
        AudioLevelManager.shared.updateRecordingState(isRecording)
    }

    private func updateAudioLevel(_ level: Float, source: AudioSource, sessionToken: UUID) {
        guard isRecording, isActiveSession(sessionToken) else { return }
        switch source {
        case .mic:
            micAudioLevel = level
            AudioLevelManager.shared.updateMicLevel(level)
        case .system:
            systemAudioLevel = level
            AudioLevelManager.shared.updateSystemLevel(level)
        }
    }

    private func stopAudioPipelines() {
        micAudioPipeline?.stop()
        micAudioPipeline = nil
        systemAudioPipeline?.stop()
        systemAudioPipeline = nil
    }

    private func sendAudioData(_ data: Data, source: AudioSource, sessionToken: UUID) {
        guard isActiveSession(sessionToken) else { return }
        switch source {
        case .mic:
            micSTT?.sendAudio(data)
        case .system:
            systemSTT?.sendAudio(data)
        }
    }

    private func stopStartRecordingTask() {
        startRecordingTask?.cancel()
        startRecordingTask = nil
    }

    private func connectSTTProvider(for source: AudioSource, offsetMilliseconds: Int) async throws -> STTProvider {
        if let existing = provider(for: source) {
            return existing
        }

        let providerSessionID = sessionID
        let provider = try await makeConnectedSTTProvider(
            for: source,
            sessionToken: providerSessionID,
            offsetMilliseconds: offsetMilliseconds
        )
        guard isActiveSession(providerSessionID) else {
            provider.disconnect()
            throw URLError(.cancelled)
        }

        switch source {
        case .mic:
            micSTT = provider
        case .system:
            systemSTT = provider
        }

        return provider
    }

    private func makeConnectedSTTProvider(
        for source: AudioSource,
        sessionToken: UUID,
        offsetMilliseconds: Int
    ) async throws -> STTProvider {
        let config = APIKeyValidator.shared.currentSTTConfig()
        guard config.isConfigured else {
            throw ProviderValidationError.missingSTTConfig
        }

        let provider = sttProviderFactory.makeProvider()

        provider.onTranscriptUpdate = { [weak self] update in
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionToken else { return }
                self.rawTranscriptEvents.append(
                    RawTranscriptEvent(
                        sessionID: sessionToken,
                        source: source,
                        providerOffsetMilliseconds: offsetMilliseconds,
                        update: update,
                        receivedAt: Date()
                    )
                )
                self.handleTranscriptUpdate(
                    Self.offsetTranscriptUpdate(update, by: offsetMilliseconds),
                    source: source
                )
            }
        }

        provider.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionToken else { return }
                guard self.isCurrentProvider(provider, for: source) else {
                    print("ℹ️ Ignored STT error from retired \(source) provider: \(message)")
                    return
                }
                self.handleSTTProviderError(message, source: source)
            }
        }

        try await provider.connect(config: config)
        return provider
    }

    private func startSTTRotationTimer(for sessionToken: UUID) {
        sttRotationTask?.cancel()
        let interval = sttRotationInterval
        sttRotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.rotateSTTProvidersIfNeeded(sessionToken: sessionToken)
            }
        }
    }

    private func stopSTTRotationTimer() {
        sttRotationTask?.cancel()
        sttRotationTask = nil
        rotatingSTTSources.removeAll()
    }

    private func stopMicRestartTask() {
        micRestartTask?.cancel()
        micRestartTask = nil
    }

    private func rotateSTTProvidersIfNeeded(sessionToken: UUID) async {
        guard isRecording, !isStoppingRecording, sessionID == sessionToken else { return }

        if micSTT != nil {
            await rotateSTTProvider(for: .mic, sessionToken: sessionToken)
        }

        if systemSTT != nil {
            await rotateSTTProvider(for: .system, sessionToken: sessionToken)
        }
    }

    private func rotateSTTProvider(for source: AudioSource, sessionToken: UUID) async {
        guard isRecording,
              !isStoppingRecording,
              sessionID == sessionToken,
              !rotatingSTTSources.contains(source) else {
            return
        }

        // 在锁外先获取旧 provider 的引用
        var oldProvider: STTProvider?
        sttProviderLock.withLock {
            oldProvider = provider(for: source)
        }
        guard let unwrappedOldProvider = oldProvider else {
            return
        }

        rotatingSTTSources.insert(source)
        defer { rotatingSTTSources.remove(source) }

        print("🔁 Rotating STT provider for \(source)...")

        do {
            // 1. 先建立新连接
            let newProvider = try await makeConnectedSTTProvider(
                for: source,
                sessionToken: sessionToken,
                offsetMilliseconds: elapsedRecordingMilliseconds()
            )
            guard isRecording, !isStoppingRecording, sessionID == sessionToken else {
                newProvider.disconnect()
                return
            }

            // 2. 原子切换: 先设置新 provider，再处理旧 provider
            sttProviderLock.withLock {
                // 再次检查会话有效性
                guard isActiveSession(sessionToken) else {
                    newProvider.disconnect()
                    return
                }
                // 原子替换
                switch source {
                case .mic:
                    micSTT = newProvider
                case .system:
                    systemSTT = newProvider
                }
            }

            // 3. 清理旧连接
            unwrappedOldProvider.sendLastAudio()
            scheduleDisconnectAfterFinalFlush(unwrappedOldProvider)

            transcriptAccumulator.removeInterimState(for: source)
            errorMessage = nil
            print("✅ Rotated STT provider for \(source)")
        } catch {
            let errorMsg = ErrorHandler.shared.handleError(error)
            print("❌ Failed to rotate STT provider for \(source): \(errorMsg)")

            if source == .system, ErrorHandler.shared.isConcurrencyQuotaErrorMessage(errorMsg) {
                disableSystemAudioAfterConcurrencyLimit(message: errorMsg)
                return
            }

            // 恢复失败时，不要立即停止整个录音
            isRecoveringSTT = true
            do {
                let restoredProvider = try await makeConnectedSTTProvider(
                    for: source,
                    sessionToken: sessionToken,
                    offsetMilliseconds: elapsedRecordingMilliseconds()
                )
                sttProviderLock.withLock {
                    guard isActiveSession(sessionToken) else {
                        restoredProvider.disconnect()
                        return
                    }
                    switch source {
                    case .mic:
                        micSTT = restoredProvider
                    case .system:
                        systemSTT = restoredProvider
                    }
                }
                isRecoveringSTT = false
            } catch {
                let restoreError = ErrorHandler.shared.handleError(error)
                print("❌ Failed to restore \(source) STT provider after rotation failure: \(restoreError)")
                errorMessage = restoreError
                if source == .mic, isRecording {
                    stopRecording()
                }
            }
        }
    }

    private func elapsedRecordingMilliseconds() -> Int {
        guard let recordingStartedAtUptime else { return recordingBaseOffsetMilliseconds }
        let elapsed = ProcessInfo.processInfo.systemUptime - recordingStartedAtUptime
        return recordingBaseOffsetMilliseconds + max(0, Int(elapsed * 1000))
    }

    nonisolated static func maximumTranscriptEndTime(in chunks: [TranscriptChunk]) -> Int {
        chunks.compactMap { $0.endTime ?? $0.startTime }.max() ?? 0
    }

    nonisolated static func offsetTranscriptUpdate(_ update: STTTranscriptUpdate, by offsetMilliseconds: Int) -> STTTranscriptUpdate {
        guard offsetMilliseconds > 0 else { return update }

        return STTTranscriptUpdate(
            text: update.text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag,
            speakerId: update.speakerId,
            startTime: update.startTime.map { $0 + offsetMilliseconds },
            endTime: update.endTime.map { $0 + offsetMilliseconds },
            isCorrection: update.isCorrection,
            isLowConfidence: update.isLowConfidence
        )
    }

    private func provider(for source: AudioSource) -> STTProvider? {
        switch source {
        case .mic:
            return micSTT
        case .system:
            return systemSTT
        }
    }

    private func isCurrentProvider(_ provider: STTProvider, for source: AudioSource) -> Bool {
        self.provider(for: source) === provider
    }

    private func isActiveSession(_ token: UUID) -> Bool {
        sessionID == token && recordingStateMachine.state.isActiveSession(token)
    }

    private func handleTranscriptUpdate(_ update: STTTranscriptUpdate, source: AudioSource) {
        let timelineUpdate = Self.positionedLowConfidenceUpdate(
            update,
            fallbackMilliseconds: elapsedRecordingMilliseconds()
        )
        transcriptAccumulator.apply(timelineUpdate, source: source)
        transcriptChunks = transcriptAccumulator.chunks
    }

    func debugRawTranscriptEvents(sessionID: UUID? = nil) -> [RawTranscriptEvent] {
        let events = rawTranscriptEvents.events
        guard let sessionID else { return events }
        return events.filter { $0.sessionID == sessionID }
    }

    /// When a provider emits a low-confidence text-only fallback, it carries no timing.
    /// Without a startTime such chunks would land at the tail of the sorted transcript.
    /// Anchor them to the current global elapsed time so they appear where they actually arrived.
    nonisolated static func positionedLowConfidenceUpdate(
        _ update: STTTranscriptUpdate,
        fallbackMilliseconds: Int
    ) -> STTTranscriptUpdate {
        guard update.isLowConfidence,
              update.startTime == nil,
              update.endTime == nil else {
            return update
        }

        return STTTranscriptUpdate(
            text: update.text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag,
            speakerId: update.speakerId,
            startTime: fallbackMilliseconds,
            endTime: fallbackMilliseconds,
            isCorrection: update.isCorrection,
            isLowConfidence: update.isLowConfidence
        )
    }

    private func handleSTTProviderError(_ message: String, source: AudioSource) {
        print("❌ STT provider error (\(source)): \(message)")
        if isStoppingRecording {
            print("ℹ️ Ignored STT error while stopping \(source) provider.")
            return
        }

        // 永久错误：鉴权/凭证类，重连无意义，立即停止
        if ErrorHandler.shared.isPermanentAuthErrorMessage(message) {
            print("⛔️ Permanent STT auth error, stopping recording: \(message)")
            errorMessage = message
            if isRecording { stopRecording() }
            return
        }

        // 配额错误：系统流走降级，麦克风流仍停止
        if ErrorHandler.shared.isConcurrencyQuotaErrorMessage(message) {
            if source == .system, isRecording {
                disableSystemAudioAfterConcurrencyLimit(message: message)
                return
            }
            errorMessage = message
            if isRecording { stopRecording() }
            return
        }

        // 暂时错误：指数退避重连，超过上限后停止
        if isRecoverableSTTError(message) {
            scheduleSTTRecovery(for: source, lastErrorMessage: message)
            return
        }

        // 未分类错误：保守按永久错误处理
        errorMessage = message
        if isRecording { stopRecording() }
    }

    private func scheduleSTTRecovery(for source: AudioSource, lastErrorMessage: String) {
        let nextAttempt = (sttRecoveryAttempts[source] ?? 0) + 1
        guard nextAttempt <= maxSTTRecoveryAttempts else {
            print("⛔️ \(source) STT exceeded max recovery attempts (\(maxSTTRecoveryAttempts)). Stopping recording.")
            errorMessage = lastErrorMessage
            if isRecording { stopRecording() }
            return
        }

        sttRecoveryAttempts[source] = nextAttempt
        // 指数退避：第 1 次 0.5s，之后 1s/2s/4s
        let backoffSeconds: TimeInterval = pow(2.0, Double(nextAttempt - 1)) * 0.5
        let recoverySessionID = sessionID

        sttRecoveryTasks[source]?.cancel()
        sttRecoveryTasks[source] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(backoffSeconds))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.isActiveSession(recoverySessionID),
                  self.isRecording,
                  !self.isStoppingRecording else { return }
            print("♻️ Attempt #\(nextAttempt) recovering \(source) STT after \(backoffSeconds)s backoff")
            await self.recoverSTTProvider(for: source)
        }
    }

    /// 系统音频恢复任务
    private var systemAudioRecoveryTask: Task<Void, Never>?
    private let systemAudioRecoveryDelay: TimeInterval = 60  // 1分钟后尝试恢复

    private func disableSystemAudioAfterConcurrencyLimit(message: String) {
        print("ℹ️ Disabling system audio because STT concurrency quota was exceeded.")
        systemSTT?.disconnect()
        systemSTT = nil

        if isTapActive {
            systemAudioPipeline?.stop()
            systemAudioPipeline = nil
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
        }

        systemAudioLevel = 0
        AudioLevelManager.shared.updateSystemLevel(0)
        errorMessage = "\(message) 已自动切换为仅录制麦克风。"

        // 安排系统音频恢复任务
        scheduleSystemAudioRecovery()
    }

    private func scheduleSystemAudioRecovery() {
        systemAudioRecoveryTask?.cancel()
        systemAudioRecoveryTask = nil

        guard isRecording, !isStoppingRecording else {
            print("ℹ️ 已停止录音，跳过安排系统音频恢复")
            return
        }

        // 在调度时即刻锚定 sessionID，避免延迟期间被 stop 的新 UUID 错配
        let recoverySessionID = sessionID

        systemAudioRecoveryTask = Task { [weak self] in
            guard let self else { return }

            do {
                print("⏳ 系统音频将在 \(self.systemAudioRecoveryDelay) 秒后尝试恢复")
                try await Task.sleep(for: .seconds(self.systemAudioRecoveryDelay))

                guard !Task.isCancelled else { return }
                guard self.isActiveSession(recoverySessionID),
                      self.isRecording,
                      !self.isStoppingRecording else {
                    print("ℹ️ 恢复时录音已停止或会话已切换，取消系统音频恢复")
                    return
                }

                print("🔄 尝试恢复系统音频")
                await self.startSystemAudioTap(isRestart: true, sessionToken: recoverySessionID)
            } catch {
                if Task.isCancelled {
                    print("ℹ️ 系统音频恢复任务被取消")
                    return
                }
                print("❌ 系统音频恢复失败: \(error.localizedDescription)")
            }
        }
    }

    private func isRecoverableSTTError(_ message: String) -> Bool {
        let normalized = message.lowercased()

        // Doubao-side transient errors
        let providerPatterns = [
            "read result timeout",
            "server processing timeout",
            "execution timeout",
            "stream_volume_cal_tob",
            "the stream is done",
            "big asr send failed",
            "session expired",
            "fail to parse big asr response",
            "big asr response code 1021",
            "识别处理超时"
        ]
        // Generic transport-level transient errors (URLError descriptions, POSIX, etc.).
        // ErrorHandler maps URLError into user-facing strings like "Request timed out" and
        // "Cannot reach the service" — both of which should retry, not abort the recording.
        let transportPatterns = [
            "socket is not connected",
            "connection lost",
            "network connection lost",
            "request timeout",
            "request timed out",
            "timed out",
            "no internet",
            "cannot reach",
            "cannot connect to the service",
            "cannot find host",
            "secure connection failed",
            "network is down",
            "network is unreachable",
            "the network connection was lost",
            "software caused connection abort",
            "网络"
        ]
        for pattern in providerPatterns where normalized.contains(pattern) {
            return true
        }
        for pattern in transportPatterns where normalized.contains(pattern) {
            return true
        }
        return false
    }

    private func recoverSTTProvider(for source: AudioSource) async {
        guard isRecording, !isStoppingRecording else { return }

        print("♻️ Reconnecting STT provider for \(source)...")
        let recoverySessionID = sessionID
        recordingStateMachine.markRecovering(sessionID: recoverySessionID)
        isRecoveringSTT = true
        discardPendingAudio(for: source)

        switch source {
        case .mic:
            micSTT?.disconnect()
            micSTT = nil
        case .system:
            systemSTT?.disconnect()
            systemSTT = nil
        }

        do {
            _ = try await connectSTTProvider(for: source, offsetMilliseconds: elapsedRecordingMilliseconds())
            recordingStateMachine.markRecording(sessionID: recoverySessionID)
            sttRecoveryAttempts[source] = 0
            errorMessage = nil
            isRecoveringSTT = false
            print("✅ Reconnected STT provider for \(source)")
        } catch {
            let errorMsg = ErrorHandler.shared.handleError(error)
            print("❌ Failed to reconnect STT provider for \(source): \(errorMsg)")

            // 重连失败仍按错误分类处理（可能升级为永久 / 配额 / 继续退避）
            if ErrorHandler.shared.isPermanentAuthErrorMessage(errorMsg)
                || ErrorHandler.shared.isConcurrencyQuotaErrorMessage(errorMsg) {
                errorMessage = errorMsg
                if isRecording { stopRecording() }
                return
            }

            scheduleSTTRecovery(for: source, lastErrorMessage: errorMsg)
        }
    }

    private func sendFinalAudioToSTTProviders() {
        micSTT?.sendLastAudio()
        systemSTT?.sendLastAudio()
    }

    private func discardPendingAudio(for source: AudioSource) {
        switch source {
        case .mic:
            micAudioPipeline?.discardPendingAudio()
        case .system:
            systemAudioPipeline?.discardPendingAudio()
        }
    }

    /// All stop paths flush final audio via `sendFinalAudioToSTTProviders` and await
    /// `awaitPendingFinalization` before reaching here, so this only needs to tear down.
    private func disconnectSTTProviders() {
        micSTT?.disconnect()
        systemSTT?.disconnect()
        micSTT = nil
        systemSTT = nil
        transcriptAccumulator.removeAllInterimState()
    }

    private func scheduleDisconnectAfterFinalFlush(_ provider: STTProvider) {
        let timeout = finalFlushTimeout
        Task.detached {
            await provider.awaitPendingFinalization(timeout: timeout)
            provider.disconnect()
        }
    }

    private func handleAudioEngineConfigurationChange() {
        print("🔔 Audio engine configuration changed - restarting mic")
        restartMicrophone()
    }
}
