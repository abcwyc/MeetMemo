@preconcurrency import AVFoundation
import Foundation

struct AudioFileTranscriptionResult {
    let chunks: [TranscriptChunk]
}

final class AudioFileTranscriber {
    static let shared = AudioFileTranscriber()

    private let sttProviderFactory: STTProviderFactory

    private init(sttProviderFactory: STTProviderFactory = DoubaoSTTProviderFactory()) {
        self.sttProviderFactory = sttProviderFactory
    }

    func transcribe(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let validationResult = await APIKeyValidator.shared.validateSTTConfig(APIKeyValidator.shared.currentSTTConfig())
        switch validationResult {
        case .success:
            break
        case .failure(let error):
            throw error
        }

        let state = AudioFileTranscriptionState()
        let provider = sttProviderFactory.makeProvider()

        provider.onTranscriptUpdate = { update in
            Task {
                await state.apply(update, source: .mic)
            }
        }

        provider.onError = { message in
            Task {
                await state.recordError(message, isTransportError: Self.isSocketTransportError(message))
            }
        }

        try await provider.connect(config: APIKeyValidator.shared.currentSTTConfig())
        defer {
            provider.disconnect()
        }

        try await streamAudioFile(url, to: provider, state: state, progress: progress)
        await state.beginFinalizing()
        progress?(1.0)
        provider.sendLastAudio()
        await provider.awaitPendingFinalization(timeout: 12)
        try await waitForFinalTranscript(state: state, timeout: 2)

        let chunks = await state.finalChunks()
        guard !chunks.isEmpty else {
            throw AudioFileTranscriberError.noTranscript
        }

        return AudioFileTranscriptionResult(chunks: chunks)
    }

    private func streamAudioFile(
        _ url: URL,
        to provider: STTProvider,
        state: AudioFileTranscriptionState,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        progress?(0.0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileTranscriberError.unsupportedAudioFormat
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileTranscriberError.unsupportedAudioFormat
        }

        let chunkDuration: TimeInterval = 0.1
        let readCapacity = AVAudioFrameCount(max(1, sourceFormat.sampleRate * chunkDuration))

        while file.framePosition < file.length {
            try Task.checkCancellation()
            if let error = await state.errorMessage {
                throw AudioFileTranscriberError.providerError(error)
            }

            let remainingFrames = AVAudioFrameCount(file.length - file.framePosition)
            let framesToRead = min(readCapacity, remainingFrames)

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                throw AudioFileTranscriberError.unsupportedAudioFormat
            }

            try file.read(into: inputBuffer, frameCount: framesToRead)
            guard inputBuffer.frameLength > 0 else { continue }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw AudioFileTranscriberError.unsupportedAudioFormat
            }

            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }

            guard status == .haveData || status == .inputRanDry || status == .endOfStream else {
                continue
            }

            guard let channelData = outputBuffer.int16ChannelData?[0], outputBuffer.frameLength > 0 else {
                continue
            }

            let frameCount = Int(outputBuffer.frameLength)
            let data = Data(bytes: channelData, count: frameCount * MemoryLayout<Int16>.size)
            provider.sendAudio(data)
            progress?(min(0.98, Double(file.framePosition) / Double(max(file.length, 1))))

            let audioDuration = Double(outputBuffer.frameLength) / targetFormat.sampleRate
            try await Task.sleep(nanoseconds: UInt64(audioDuration * 1_000_000_000))
        }
    }

    private func waitForFinalTranscript(
        state: AudioFileTranscriptionState,
        timeout: TimeInterval
    ) async throws {
        let start = Date()
        var lastCount = await state.updateCount
        var lastChange = Date()

        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()

            if let error = await state.errorMessage {
                throw AudioFileTranscriberError.providerError(error)
            }

            try await Task.sleep(for: .milliseconds(300))

            let currentCount = await state.updateCount
            if currentCount != lastCount {
                lastCount = currentCount
                lastChange = Date()
                continue
            }

            if Date().timeIntervalSince(lastChange) >= 1.8 {
                break
            }
        }
    }

    private static func isSocketTransportError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("socket is not connected")
            || normalized.contains("socket is not open")
            || normalized.contains("connection lost")
            || normalized.contains("network connection was lost")
    }
}

private actor AudioFileTranscriptionState {
    private var transcriptAccumulator = TranscriptUpdateAccumulator()
    private var errorMessageValue: String?
    private var updateCountValue = 0
    private var isFinalizing = false

    var errorMessage: String? {
        errorMessageValue
    }

    var updateCount: Int {
        updateCountValue
    }

    func finalChunks() -> [TranscriptChunk] {
        transcriptAccumulator.chunks.filter { $0.isFinal }
    }

    func beginFinalizing() {
        isFinalizing = true
    }

    func recordError(_ message: String, isTransportError: Bool) {
        if isFinalizing && isTransportError && !transcriptAccumulator.chunks.isEmpty {
            return
        }

        errorMessageValue = message
    }

    func apply(_ update: STTTranscriptUpdate, source: AudioSource) {
        updateCountValue += 1
        transcriptAccumulator.apply(update, source: source)
    }
}

enum AudioFileTranscriberError: LocalizedError {
    case unsupportedAudioFormat
    case noTranscript
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat:
            return LanguageManager.shared.t("不支持此音频格式。", "This audio format is not supported.")
        case .noTranscript:
            return LanguageManager.shared.t("未能从音频中识别出转录内容。", "No transcript could be recognized from this audio.")
        case .providerError(let message):
            return message
        }
    }
}
