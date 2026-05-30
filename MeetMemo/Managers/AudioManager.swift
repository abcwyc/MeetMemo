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
    @Published var warningMessage: String?
    @Published var micAudioLevel: Float = 0.0
    @Published var systemAudioLevel: Float = 0.0

    private var audioEngine = AVAudioEngine()
    private var sttProviderFactory: STTProviderFactory
    private var activeEngine: STTEngine
    private var micSTT: STTProvider?
    private var systemSTT: STTProvider?
    private var micAudioPipeline: AudioProcessingPipeline?
    private var systemAudioPipeline: AudioProcessingPipeline?
    private var startRecordingTask: Task<Void, Never>?
    private var micRestartTask: Task<Void, Never>?
    private let finalFlushTimeout: TimeInterval = 2.0
    private var recordingStartedAtUptime: TimeInterval?
    private var recordingBaseOffsetMilliseconds = 0
    private var recordingStateMachine = AudioRecordingStateMachine()
    private var isFinalizingStoppedRecording = false

    /// Tracks the active interim chunk id per source for replace-on-update semantics.
    private var activeInterimChunkId: [AudioSource: UUID] = [:]
    /// Wall-clock offset (ms) at the moment the first meaningful audio buffer arrives for each
    /// source. This anchors CMTime=0 to the correct position on the recording timeline, which
    /// is more accurate than capturing the offset at connectSTTProvider time.
    private var firstAudioOffsets: [AudioSource: Int] = [:]

    // Unique identifier for the current recording session
    private var sessionID = UUID()

    // ProcessTap properties
    private var processTap: ProcessTap?
    private let audioProcessController = AudioProcessController()
    private let permission = AudioRecordingPermission()
    private let tapQueue = DispatchQueue(label: "io.meetmemo.audiotap", qos: .userInitiated)
    private var isTapActive = false
    private var isRestartingSystemTap = false
    private var isTearingDownRecording = false

    private var micRetryCount = 0
    private let maxMicRetries = 3

    private var cancellables = Set<AnyCancellable>()
    /// `NotificationCenter.addObserver(forName:object:queue:using:)` returns an opaque token
    /// that must be passed back to `removeObserver`. We need to drop and re-register this
    /// each time `audioEngine` is replaced, because the observer is filtered by sender.
    private var audioEngineConfigObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    private override init() {
        let initialEngine = UserDefaultsManager.shared.sttEngine
        self.activeEngine = initialEngine
        self.sttProviderFactory = Self.factory(for: initialEngine)
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

    private var isStoppingOrTearingDown: Bool {
        isStoppingRecording || isTearingDownRecording
    }

    private func publishRecordingActivityState() {
        isRecording = recordingStateMachine.state.isRecordingVisible
        isRecoveringSTT = recordingStateMachine.state.isRecovering
        AudioLevelManager.shared.updateRecordingState(isRecording)
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
    /// the engine die mid-stream while the lid closes. We do not auto-resume on wake.
    private func registerSystemPowerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isStoppingOrTearingDown else { return }
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
        refreshSTTFactoryFromSettings()
        sessionID = UUID()
        let startedSessionID = sessionID
        recordingStateMachine.start(sessionID: startedSessionID)
        errorMessage = nil
        warningMessage = nil
        transcriptChunks = transcriptChunks.filter(\.isFinal)
        recordingBaseOffsetMilliseconds = Self.maximumTranscriptEndTime(in: transcriptChunks)
        recordingStartedAtUptime = ProcessInfo.processInfo.systemUptime
        activeInterimChunkId.removeAll()

        startRecordingTask?.cancel()
        startRecordingTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let micStarted = await self.startMicrophoneTap(sessionToken: startedSessionID)
            if micStarted, !Task.isCancelled, UserDefaultsManager.shared.enableSystemAudioSTT {
                await self.startSystemAudioTap(isInitialStart: true, sessionToken: startedSessionID)
            }
        }
    }

    /// Immediately tears down the current recording session without waiting for final STT output.
    /// Use only for hard resets and startup failures; normal user stops should call `stopRecording`.
    private func abortRecording() {
        print("Internal cleanup...")

        isTearingDownRecording = true
        defer { isTearingDownRecording = false }
        isFinalizingStoppedRecording = false

        stopStartRecordingTask()
        stopMicRestartTask()
        stopAudioPipelines()
        let stoppedSessionID = sessionID
        recordingStateMachine.stop(sessionID: stoppedSessionID)
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

        firstAudioOffsets.removeAll()
        cleanupAudioEngine()
        disconnectSTTProviders()
        recordingStateMachine.reset()
        isRecoveringSTT = false
        isStoppingRecording = false

        print("Internal cleanup completed")
    }

    private func restartMicrophone() {
        guard isRecording, !isStoppingOrTearingDown else { return }

        guard micRetryCount < maxMicRetries else {
            let message = "Microphone failed to recover after \(maxMicRetries) attempts."
            print("⛔️ \(message) Stopping recording.")
            errorMessage = message
            stopRecording()
            return
        }

        print("🔄 Restarting microphone capture (attempt \(micRetryCount + 1))")
        micRetryCount += 1
        let restartSessionID = sessionID

        cleanupAudioEngine()
        recordingStateMachine.markRecovering(sessionID: restartSessionID)
        publishRecordingActivityState()

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

            // Start the audio engine before awaiting the STT connection so the UI
            // shows recording state immediately. Tap is installed after STT connects;
            // the few hundred ms of audio captured before that is discarded (pipeline nil).
            audioEngine.prepare()
            try audioEngine.start()
            guard isActiveSession(sessionToken) else {
                cleanupAudioEngine()
                return false
            }
            markRecordingActive(sessionToken: sessionToken)

            _ = try await connectSTTProvider(for: .mic, offsetMilliseconds: elapsedRecordingMilliseconds())
            guard isActiveSession(sessionToken) else { return false }

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

            print("✅ Microphone tap started successfully")
            micRetryCount = 0
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
                newTap.invalidate()
                guard isActiveSession(activeSessionToken) else { return }
                let errorMsg = "Failed to activate system audio tap: \(tapError)"
                print("❌ \(errorMsg)")
                if isRestart {
                    // Restart failure: silently degrade to mic-only, don't bother user
                    systemSTT?.disconnect()
                    systemSTT = nil
                    isTapActive = false
                    print("⚠️ System audio tap restart failed, continuing mic-only")
                } else {
                    errorMessage = errorMsg
                    abortRecording()
                }
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
                newTap.invalidate()
                isTapActive = false
                if isRestart {
                    systemSTT?.disconnect()
                    systemSTT = nil
                    print("⚠️ System audio tap IO restart failed, continuing mic-only")
                } else {
                    errorMessage = errorMsg
                    abortRecording()
                }
            }
        } catch {
            guard isActiveSession(activeSessionToken) else { return }
            let errorMsg = ErrorHandler.shared.handleError(error)
            print("❌ Failed to connect system STT provider: \(errorMsg)")
            // System audio STT failure: degrade to mic-only without aborting recording.
            errorMessage = "系统音频转录不可用，已自动切换为仅麦克风模式。"
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

        guard isRecording, !isStoppingOrTearingDown else {
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

        try? await Task.sleep(for: .milliseconds(800))

        guard isRecording, !isStoppingOrTearingDown else {
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

            if !self.isRestartingSystemTap && !self.isStoppingOrTearingDown {
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

        stopStartRecordingTask()
        stopMicRestartTask()
        let stoppedSessionID = sessionID
        recordingStateMachine.stop(sessionID: stoppedSessionID)
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
        isFinalizingStoppedRecording = true

        recordingStateMachine.reset()
        isRecording = false
        isRecoveringSTT = false
        isStoppingRecording = false
        recordingStartedAtUptime = nil
        recordingBaseOffsetMilliseconds = 0
        AudioLevelManager.shared.updateRecordingState(false)

        let micProvider = micSTT
        let systemProvider = systemSTT
        let timeout = finalFlushTimeout
        Task { @MainActor [weak self] in
            guard let self else {
                completion?()
                return
            }

            var finalizationStatuses: [STTFinalizationStatus] = []
            await withTaskGroup(of: STTFinalizationStatus.self) { group in
                if let micProvider {
                    group.addTask { await micProvider.awaitPendingFinalization(timeout: timeout) }
                }
                if let systemProvider {
                    group.addTask { await systemProvider.awaitPendingFinalization(timeout: timeout) }
                }
                for await status in group {
                    finalizationStatuses.append(status)
                }
            }

            if finalizationStatuses.contains(where: \.mayHaveMissedTailAudio) {
                let message = "语音识别收尾超时，最后几秒转录可能未完成。"
                print("⚠️ \(message)")
                self.warningMessage = message
            } else if finalizationStatuses.contains(.resultDrainTimedOut) {
                let message = "语音识别结果流关闭较慢，已保存已收到的转录内容。"
                print("ℹ️ \(message)")
                self.warningMessage = message
            }

            // Offline corrections (e.g. sherpa-onnx speaker diarization refinement)
            // run while still on this stopped session so any speakerId/Tag updates
            // land before we tear the providers down.
            await withTaskGroup(of: Void.self) { group in
                if let micProvider, micProvider.capabilities.supportsCorrections {
                    group.addTask { await micProvider.applyOfflineRefinement() }
                }
                if let systemProvider, systemProvider.capabilities.supportsCorrections {
                    group.addTask { await systemProvider.applyOfflineRefinement() }
                }
                for await _ in group {}
            }

            guard self.sessionID == stoppedSessionID else {
                self.isFinalizingStoppedRecording = false
                completion?()
                return
            }

            self.disconnectSTTProviders()
            self.firstAudioOffsets.removeAll()
            self.isFinalizingStoppedRecording = false
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
            silenceThreshold: source == .system ? 0.005 : nil,
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
        publishRecordingActivityState()
        micRetryCount = 0
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
        if firstAudioOffsets[source] == nil {
            firstAudioOffsets[source] = elapsedRecordingMilliseconds()
        }
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
        let provider = sttProviderFactory.makeProvider()

        provider.onTranscriptUpdate = { [weak self] update in
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionToken else { return }
                // Use offset captured at first meaningful audio arrival; fall back to
                // connect-time offset if no audio has arrived yet for this source.
                let offset = self.firstAudioOffsets[source] ?? offsetMilliseconds
                self.handleTranscriptUpdate(
                    Self.offsetTranscriptUpdate(update, by: offset),
                    source: source
                )
            }
        }

        provider.onTranscriptCorrection = { [weak self] corrections in
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionToken else { return }
                let offset = self.firstAudioOffsets[source] ?? offsetMilliseconds
                self.applyCorrections(corrections, source: source, offsetMilliseconds: offset)
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

    private func refreshSTTFactoryFromSettings() {
        let requested = UserDefaultsManager.shared.sttEngine
        guard requested != activeEngine else { return }
        activeEngine = requested
        sttProviderFactory = Self.factory(for: requested)
    }

    private static func factory(for engine: STTEngine) -> STTProviderFactory {
        switch engine {
        case .appleSpeechAnalyzer:
            return SpeechAnalyzerSTTProviderFactory()
        case .sherpaSenseVoice:
            return SherpaSTTProviderFactory()
        }
    }

    private func applyCorrections(
        _ corrections: [STTTranscriptCorrection],
        source: AudioSource,
        offsetMilliseconds: Int
    ) {
        guard !corrections.isEmpty else { return }
        var didChange = false
        for correction in corrections {
            let adjustedStart = correction.startTime + offsetMilliseconds
            let adjustedEnd = correction.endTime + offsetMilliseconds
            for index in transcriptChunks.indices {
                let chunk = transcriptChunks[index]
                guard chunk.source == source,
                      chunk.isFinal,
                      chunk.startTime == adjustedStart,
                      chunk.endTime == adjustedEnd else { continue }
                let newChunk = TranscriptChunk(
                    id: chunk.id,
                    source: chunk.source,
                    text: chunk.text,
                    isFinal: chunk.isFinal,
                    speakerTag: correction.newSpeakerTag ?? chunk.speakerTag,
                    speakerId: correction.newSpeakerId,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime
                )
                transcriptChunks[index] = newChunk
                didChange = true
            }
        }
        if didChange {
            // touch the array to ensure SwiftUI republishes
            transcriptChunks = transcriptChunks
        }
    }

    private func stopMicRestartTask() {
        micRestartTask?.cancel()
        micRestartTask = nil
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
        if update.isFinal {
            if let id = activeInterimChunkId[source] {
                transcriptChunks.removeAll { $0.id == id }
                activeInterimChunkId[source] = nil
            }
            transcriptChunks.append(TranscriptChunk(
                source: source,
                text: update.text,
                isFinal: true,
                speakerTag: update.speakerTag,
                speakerId: update.speakerId,
                startTime: update.startTime,
                endTime: update.endTime
            ))
        } else {
            let id = activeInterimChunkId[source] ?? UUID()
            let chunk = TranscriptChunk(
                id: id,
                source: source,
                text: update.text,
                isFinal: false,
                speakerTag: update.speakerTag,
                speakerId: update.speakerId,
                startTime: update.startTime,
                endTime: update.endTime
            )
            if let idx = transcriptChunks.firstIndex(where: { $0.id == id }) {
                transcriptChunks[idx] = chunk
            } else {
                transcriptChunks.append(chunk)
                activeInterimChunkId[source] = id
            }
        }
    }

    private func handleSTTProviderError(_ message: String, source: AudioSource) {
        print("❌ STT provider error (\(source)): \(message)")
        if isStoppingOrTearingDown || isFinalizingStoppedRecording { return }

        if source == .system {
            print("⚠️ System audio STT failed, degrading to mic-only: \(message)")
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
            errorMessage = "系统音频转录不可用，已自动切换为仅麦克风模式。"
        } else {
            errorMessage = message
            if isRecording { stopRecording() }
        }
    }

    private func sendFinalAudioToSTTProviders() {
        micSTT?.sendLastAudio()
        systemSTT?.sendLastAudio()
    }

    /// All stop paths flush final audio via `sendFinalAudioToSTTProviders` and await
    /// `awaitPendingFinalization` before reaching here, so this only needs to tear down.
    private func disconnectSTTProviders() {
        micSTT?.disconnect()
        systemSTT?.disconnect()
        micSTT = nil
        systemSTT = nil
        activeInterimChunkId.removeAll()
    }

    nonisolated static func maximumTranscriptEndTime(in chunks: [TranscriptChunk]) -> Int {
        chunks.compactMap { $0.endTime ?? $0.startTime }.max() ?? 0
    }

    private func elapsedRecordingMilliseconds() -> Int {
        guard let recordingStartedAtUptime else { return recordingBaseOffsetMilliseconds }
        let elapsed = ProcessInfo.processInfo.systemUptime - recordingStartedAtUptime
        return recordingBaseOffsetMilliseconds + max(0, Int(elapsed * 1000))
    }

    nonisolated static func offsetTranscriptUpdate(_ update: STTTranscriptUpdate, by offsetMilliseconds: Int) -> STTTranscriptUpdate {
        guard offsetMilliseconds > 0 else { return update }

        return STTTranscriptUpdate(
            text: update.text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag,
            speakerId: update.speakerId,
            startTime: update.startTime.map { $0 + offsetMilliseconds },
            endTime: update.endTime.map { $0 + offsetMilliseconds }
        )
    }

    private func handleAudioEngineConfigurationChange() {
        print("🔔 Audio engine configuration changed - restarting mic")
        restartMicrophone()
    }
}
