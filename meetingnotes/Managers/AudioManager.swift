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
    @Published var errorMessage: String?
    @Published var micAudioLevel: Float = 0.0
    @Published var systemAudioLevel: Float = 0.0

    private var audioEngine = AVAudioEngine()
    private let sttProviderFactory: STTProviderFactory
    private var micSTT: STTProvider?
    private var systemSTT: STTProvider?

    // Unique identifier for the current recording session
    private var sessionID = UUID()

    // ProcessTap properties
    private var processTap: ProcessTap?
    private let audioProcessController = AudioProcessController()
    private let permission = AudioRecordingPermission()
    private let tapQueue = DispatchQueue(label: "io.meetingnotes.audiotap", qos: .userInitiated)
    private var isTapActive = false
    private var isRestartingSystemTap = false

    private var micRetryCount = 0
    private let maxMicRetries = 3

    private struct InterimTranscriptState {
        var text: String
        var speakerTag: String?
        var speakerId: Int?
        var startTime: Int?
        var endTime: Int?
    }

    private var currentInterim: [AudioSource: InterimTranscriptState] = [:]
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        self.sttProviderFactory = DoubaoSTTProviderFactory()
        super.init()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: audioEngine,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioEngineConfigurationChange()
            }
        }

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
        NotificationCenter.default.removeObserver(self)
    }

    func startRecording() {
        print("Starting recording...")

        sessionID = UUID()
        DispatchQueue.main.async {
            self.errorMessage = nil
        }

        stopRecordingInternal()

        Task {
            let validationResult = await APIKeyValidator.shared.validateSTTConfig(APIKeyValidator.shared.currentSTTConfig())
            switch validationResult {
            case .failure(let error):
                let errorMsg = error.localizedDescription
                print("❌ STT validation failed: \(errorMsg)")
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                }
            case .success:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    Task {
                        let micStarted = await self.startMicrophoneTap()
                        if micStarted {
                            await self.startSystemAudioTap()
                        }
                    }
                }
            }
        }
    }

    private func stopRecordingInternal() {
        print("Internal cleanup...")

        isRecording = false
        AudioLevelManager.shared.updateRecordingState(false)

        if isTapActive {
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated")
        }

        cleanupAudioEngine()
        disconnectSTTProviders(sendLastAudio: false)
        currentInterim.removeAll()

        print("Internal cleanup completed")
    }

    private func restartMicrophone() {
        guard isRecording, micRetryCount < maxMicRetries else { return }

        print("🔄 Restarting microphone capture (attempt \(micRetryCount + 1))")
        micRetryCount += 1

        cleanupAudioEngine()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            Task {
                _ = await self.startMicrophoneTap()
            }
        }
    }

    /// Starts a microphone tap using the STT provider.
    private func startMicrophoneTap() async -> Bool {
        print("🎤 Starting microphone tap...")

        do {
            _ = try await connectSTTProvider(for: .mic)

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

            guard let converter = AVAudioConverter(from: recordingFormat, to: targetFormat) else {
                print("❌ Failed to create audio converter for mic tap")
                restartMicrophone()
                return false
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self else { return }

                guard buffer.frameLength > 0, buffer.floatChannelData != nil else {
                    print("❌ Invalid mic buffer detected - restarting")
                    self.restartMicrophone()
                    return
                }

                if let ch = buffer.floatChannelData?[0] {
                    let frameCount = Int(buffer.frameLength)
                    let samples = UnsafeBufferPointer(start: ch, count: frameCount)
                    let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(max(frameCount, 1)))

                    DispatchQueue.main.async {
                        self.micAudioLevel = rms
                        AudioLevelManager.shared.updateMicLevel(rms)
                    }
                }

                self.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat, source: .mic)
            }

            audioEngine.prepare()
            try audioEngine.start()
            print("✅ Microphone tap started successfully")
            micRetryCount = 0
            isRecording = true
            AudioLevelManager.shared.updateRecordingState(true)
            return true
        } catch {
            print("❌ Failed to start microphone tap: \(error)")
            errorMessage = ErrorHandler.shared.handleError(error)
            stopRecordingInternal()
            return false
        }
    }

    private func cleanupAudioEngine() {
        print("🧹 Cleaning up audio engine...")

        if audioEngine.isRunning {
            audioEngine.stop()
            print("⏹️ Audio engine stopped")
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        print("🔇 Input tap removed")

        audioEngine.reset()
        print("🔄 Audio engine reset")

        audioEngine = AVAudioEngine()
        print("✨ Fresh audio engine created")
    }

    private func startSystemAudioTap(isRestart: Bool = false) async {
        print(isRestart ? "🎧 Restarting system audio tap logic..." : "🎧 Starting system audio tap for the first time...")

        if !isRestart {
            guard await checkSystemAudioPermissions() else {
                let errorMsg = "System audio recording permission denied."
                print("❌ \(errorMsg)")
                errorMessage = errorMsg
                stopRecording()
                return
            }
        }

        guard isRecording || isRestart else {
            return
        }

        do {
            _ = try await connectSTTProvider(for: .system)

            let allProcessObjectIDs = audioProcessController.processes.map { $0.objectID }
            if allProcessObjectIDs.isEmpty {
                print("⚠️ No audio-producing processes found. System audio tap might not capture anything.")
            }

            let target = TapTarget.systemAudio(processObjectIDs: allProcessObjectIDs)
            let newTap = ProcessTap(target: target)
            newTap.activate()

            if let tapError = newTap.errorMessage {
                let errorMsg = "Failed to activate system audio tap: \(tapError)"
                print("❌ \(errorMsg)")
                errorMessage = errorMsg
                if !isRestart { stopRecording() }
                return
            }

            processTap = newTap
            isTapActive = true

            do {
                try startTapIO(newTap)

                if !isRestart {
                    isRecording = true
                    AudioLevelManager.shared.updateRecordingState(true)
                }
                print("✅ System audio tap started successfully (isRestart: \(isRestart))")
            } catch {
                let errorMsg = "Failed to start system audio tap IO: \(error.localizedDescription)"
                print("❌ \(errorMsg)")
                errorMessage = errorMsg
                newTap.invalidate()
                isTapActive = false
                if !isRestart { stopRecording() }
            }
        } catch {
            let errorMsg = ErrorHandler.shared.handleError(error)
            print("❌ Failed to connect system STT provider: \(errorMsg)")
            errorMessage = errorMsg
            if !isRestart {
                stopRecording()
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

        guard isRecording else {
            print("Recording was stopped, aborting tap restart.")
            return
        }

        isRestartingSystemTap = true
        defer { isRestartingSystemTap = false }

        if isTapActive {
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated for restart.")
        }

        try? await Task.sleep(for: .milliseconds(250))

        guard isRecording else {
            print("Recording was stopped during tap restart. Aborting.")
            return
        }

        await startSystemAudioTap(isRestart: true)
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

    private func startTapIO(_ tap: ProcessTap) throws {
        guard var streamDescription = tap.tapStreamDescription else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get audio format from tap."])
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioFormat from tap."])
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false)!

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter for system tap."])
        }

        try tap.run(on: tapQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self = self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                return
            }

            if let ch = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                let samples = UnsafeBufferPointer(start: ch, count: frameCount)
                let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(max(frameCount, 1)))

                DispatchQueue.main.async {
                    self.systemAudioLevel = rms
                    AudioLevelManager.shared.updateSystemLevel(rms)
                }
            }

            self.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat, source: .system)

        } invalidationHandler: { [weak self] _ in
            guard let self else { return }
            print("Audio tap was invalidated.")

            if !self.isRestartingSystemTap {
                print("Tap invalidated unexpectedly. Restarting system audio tap.")
                Task {
                    await self.restartSystemAudioTap()
                }
            } else {
                print("Tap invalidated as part of a restart. Not stopping recording.")
            }
        }
    }

    func stopRecording() {
        isRecording = false
        AudioLevelManager.shared.updateRecordingState(false)
        print("Stopping recording...")

        micAudioLevel = 0.0
        systemAudioLevel = 0.0
        AudioLevelManager.shared.updateMicLevel(0.0)
        AudioLevelManager.shared.updateSystemLevel(0.0)

        if isTapActive {
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated")
        }

        cleanupAudioEngine()
        micRetryCount = 0
        disconnectSTTProviders(sendLastAudio: true)
        currentInterim.removeAll()

        print("Recording stopped")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat, source: AudioSource) {
        let processBuffer = buffer

        // Convert to target format (16kHz int16 mono) in a single step.
        let outputFrameCapacity = AVAudioFrameCount(Double(processBuffer.frameLength) * targetFormat.sampleRate / processBuffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return processBuffer
        }

        guard status == .haveData, error == nil else {
            return
        }

        guard let channelData = outputBuffer.int16ChannelData?[0] else {
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        let data = Data(bytes: channelData, count: frameCount * 2)

        sendAudioData(data, source: source)
    }

    private func sendAudioData(_ data: Data, source: AudioSource) {
        switch source {
        case .mic:
            micSTT?.sendAudio(data)
        case .system:
            systemSTT?.sendAudio(data)
        }
    }

    private func connectSTTProvider(for source: AudioSource) async throws -> STTProvider {
        if let existing = provider(for: source) {
            return existing
        }

        let config = APIKeyValidator.shared.currentSTTConfig()
        guard config.isConfigured else {
            throw ProviderValidationError.missingSTTConfig
        }

        let provider = sttProviderFactory.makeProvider()
        let sessionToken = sessionID

        provider.onTranscriptUpdate = { [weak self] update in
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionToken else { return }
                self.handleTranscriptUpdate(update, source: source)
            }
        }

        provider.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionToken else { return }
                self.handleSTTProviderError(message, source: source)
            }
        }

        try await provider.connect(config: config)

        switch source {
        case .mic:
            micSTT = provider
        case .system:
            systemSTT = provider
        }

        return provider
    }

    private func provider(for source: AudioSource) -> STTProvider? {
        switch source {
        case .mic:
            return micSTT
        case .system:
            return systemSTT
        }
    }

    private func handleTranscriptUpdate(_ update: STTTranscriptUpdate, source: AudioSource) {
        let inheritedState = currentInterim[source]
        let resolvedUpdate = STTTranscriptUpdate(
            text: update.text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag ?? inheritedState?.speakerTag,
            speakerId: update.speakerId ?? inheritedState?.speakerId,
            startTime: update.startTime ?? inheritedState?.startTime,
            endTime: update.endTime ?? inheritedState?.endTime,
            isCorrection: update.isCorrection
        )

        // Handle corrections: replace the matching final chunk with the updated version.
        if update.isCorrection {
            if let idx = transcriptChunks.lastIndex(where: {
                $0.source == source && $0.isFinal &&
                $0.startTime == resolvedUpdate.startTime &&
                $0.endTime == resolvedUpdate.endTime
            }) {
                let updated = TranscriptChunk(
                    id: transcriptChunks[idx].id,
                    timestamp: transcriptChunks[idx].timestamp,
                    source: source,
                    text: resolvedUpdate.text,
                    isFinal: true,
                    speakerTag: resolvedUpdate.speakerTag,
                    speakerId: resolvedUpdate.speakerId,
                    startTime: resolvedUpdate.startTime,
                    endTime: resolvedUpdate.endTime
                )
                transcriptChunks[idx] = updated
                if let interimIdx = transcriptChunks.lastIndex(where: { !$0.isFinal && $0.source == source }) {
                    transcriptChunks.remove(at: interimIdx)
                }
            }
            return
        }

        if update.isFinal {
            transcriptChunks.removeAll { !$0.isFinal && $0.source == source }

            let chunk = TranscriptChunk(
                timestamp: Date(),
                source: source,
                text: resolvedUpdate.text,
                isFinal: true,
                speakerTag: resolvedUpdate.speakerTag,
                speakerId: resolvedUpdate.speakerId,
                startTime: resolvedUpdate.startTime,
                endTime: resolvedUpdate.endTime
            )
            transcriptChunks.append(chunk)
            currentInterim.removeValue(forKey: source)
        } else {
            currentInterim[source] = InterimTranscriptState(
                text: resolvedUpdate.text,
                speakerTag: resolvedUpdate.speakerTag,
                speakerId: resolvedUpdate.speakerId,
                startTime: resolvedUpdate.startTime,
                endTime: resolvedUpdate.endTime
            )

            if let lastIndex = transcriptChunks.lastIndex(where: { !$0.isFinal && $0.source == source }) {
                transcriptChunks.remove(at: lastIndex)
            }

            let chunk = TranscriptChunk(
                timestamp: Date(),
                source: source,
                text: resolvedUpdate.text,
                isFinal: false,
                speakerTag: resolvedUpdate.speakerTag,
                speakerId: resolvedUpdate.speakerId,
                startTime: resolvedUpdate.startTime,
                endTime: resolvedUpdate.endTime
            )
            transcriptChunks.append(chunk)
        }
    }

    private func handleSTTProviderError(_ message: String, source: AudioSource) {
        print("❌ STT provider error (\(source)): \(message)")
        if isRecoverableSTTError(message) {
            print("ℹ️ Recoverable STT error detected, restarting \(source) provider.")
            Task { [weak self] in
                guard let self else { return }
                await self.recoverSTTProvider(for: source)
            }
            return
        }

        errorMessage = message

        if isRecording {
            stopRecording()
        }
    }

    private func isRecoverableSTTError(_ message: String) -> Bool {
        let normalized = message.lowercased()

        return normalized.contains("read result timeout")
            || normalized.contains("session expired")
            || normalized.contains("socket is not connected")
            || normalized.contains("connection lost")
            || normalized.contains("request timeout")
    }

    private func recoverSTTProvider(for source: AudioSource) async {
        guard isRecording else { return }

        print("♻️ Reconnecting STT provider for \(source)...")

        switch source {
        case .mic:
            micSTT?.disconnect()
            micSTT = nil
        case .system:
            systemSTT?.disconnect()
            systemSTT = nil
        }

        do {
            _ = try await connectSTTProvider(for: source)
            errorMessage = nil
            print("✅ Reconnected STT provider for \(source)")
        } catch {
            let errorMsg = ErrorHandler.shared.handleError(error)
            print("❌ Failed to reconnect STT provider for \(source): \(errorMsg)")
            errorMessage = errorMsg

            if isRecording {
                stopRecording()
            }
        }
    }

    private func disconnectSTTProviders(sendLastAudio: Bool) {
        let micProvider = micSTT
        let systemProvider = systemSTT

        if sendLastAudio {
            micProvider?.sendLastAudio()
            systemProvider?.sendLastAudio()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                micProvider?.disconnect()
                systemProvider?.disconnect()
            }
        } else {
            micProvider?.disconnect()
            systemProvider?.disconnect()
        }

        micSTT = nil
        systemSTT = nil
        currentInterim.removeAll()
    }

    private func handleAudioEngineConfigurationChange() {
        print("🔔 Audio engine configuration changed - restarting mic")
        restartMicrophone()
    }
}
