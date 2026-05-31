@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

struct AudioFileTranscriptionResult {
    let chunks: [TranscriptChunk]
}

final class AudioFileTranscriber {
    static let shared = AudioFileTranscriber()

    private init() {}

    func transcribe(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let config = APIKeyValidator.shared.currentSTTConfig()
        switch config.engine {
        case .appleSpeechAnalyzer:
            return try await transcribeWithSpeechAnalyzer(url: url, progress: progress)
        case .sherpaSenseVoice:
            return try await transcribeWithProvider(
                SherpaSTTProviderFactory().makeProvider(),
                config: config,
                url: url,
                progress: progress
            )
        }
    }

    private func transcribeWithSpeechAnalyzer(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let locale = try await SpeechModelInstaller.shared.ensureReadyForUse()
        let state = AudioFileTranscriptionState()

        let transcriber = SpeechModelInstaller.makeTranscriber(
            locale: locale,
            includeTimeRange: true,
            includeVolatileResults: false
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let durationMilliseconds = Self.durationMilliseconds(for: file)
        progress?(0.05)

        let resultsTask = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let timeRange = SpeechAnalyzerSTTProvider.millisecondRange(from: result.range)
                if let endTime = timeRange?.end {
                    progress?(Self.progress(forEndTime: endTime, durationMilliseconds: durationMilliseconds))
                }
                await state.appendFinalChunk(
                    text: text,
                    startTime: timeRange?.start,
                    endTime: timeRange?.end
                )
            }
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await resultsTask.value
            progress?(1.0)
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let chunks = await state.finalChunks()
        guard !chunks.isEmpty else {
            throw AudioFileTranscriberError.noTranscript
        }

        return AudioFileTranscriptionResult(chunks: chunks)
    }

    private func transcribeWithProvider(
        _ provider: STTProvider,
        config: STTProviderConfig,
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let state = AudioFileProviderTranscriptionState()
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        provider.onTranscriptUpdate = { update in
            state.append(update)
        }
        provider.onTranscriptCorrection = { corrections in
            state.apply(corrections)
        }
        provider.onError = { message in
            state.recordError(message)
        }

        progress?(0.03)
        try await provider.connect(config: config)
        defer { provider.disconnect() }

        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw AudioFileTranscriberError.unsupportedAudioFormat
        }

        let totalFrames = max(1, file.length)
        let inputFrameCapacity: AVAudioFrameCount = 4096

        while file.framePosition < file.length {
            try Task.checkCancellation()

            let framesRemaining = AVAudioFrameCount(
                min(Int64(inputFrameCapacity), file.length - file.framePosition)
            )
            guard framesRemaining > 0,
                  let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: framesRemaining
                  ) else {
                break
            }

            try file.read(into: inputBuffer, frameCount: framesRemaining)
            guard inputBuffer.frameLength > 0 else { break }

            if let data = Self.convertToPCM16Data(
                inputBuffer,
                targetFormat: targetFormat,
                converter: converter
            ) {
                provider.sendAudio(data)
            }

            let fraction = Double(file.framePosition) / Double(totalFrames)
            progress?(min(0.92, max(0.03, 0.03 + fraction * 0.89)))
        }

        provider.sendLastAudio()
        _ = await provider.awaitPendingFinalization(timeout: 30)
        await provider.applyOfflineRefinement()
        await MainActor.run {}
        progress?(1.0)

        if let message = state.currentErrorMessage() {
            throw AudioFileTranscriberError.providerError(message)
        }

        let chunks = state.finalChunks()
        guard !chunks.isEmpty else {
            throw AudioFileTranscriberError.noTranscript
        }

        return AudioFileTranscriptionResult(chunks: chunks.sortedByTranscriptTimeline())
    }

    private static func convertToPCM16Data(
        _ inputBuffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> Data? {
        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Double(inputBuffer.frameLength) * targetFormat.sampleRate / inputBuffer.format.sampleRate)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream,
              let channelData = outputBuffer.int16ChannelData?[0] else {
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Data(bytes: channelData, count: frameCount * MemoryLayout<Int16>.size)
    }

    private static func durationMilliseconds(for file: AVAudioFile) -> Int {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 1 }
        return max(1, Int((Double(file.length) / sampleRate * 1000).rounded()))
    }

    private static func progress(forEndTime endTime: Int, durationMilliseconds: Int) -> Double {
        let fraction = min(1.0, max(0.0, Double(endTime) / Double(durationMilliseconds)))
        return min(0.95, max(0.05, 0.05 + fraction * 0.90))
    }
}

private actor AudioFileTranscriptionState {
    private var chunks: [TranscriptChunk] = []

    func finalChunks() -> [TranscriptChunk] {
        chunks
    }

    func appendFinalChunk(text: String, startTime: Int?, endTime: Int?) {
        chunks.append(TranscriptChunk(
            source: .mic,
            text: text,
            isFinal: true,
            startTime: startTime,
            endTime: endTime
        ))
    }
}

private final class AudioFileProviderTranscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [TranscriptChunk] = []
    private var errorMessage: String?

    func append(_ update: STTTranscriptUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let chunk = TranscriptChunk(
            source: .mic,
            text: text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag,
            speakerId: update.speakerId,
            startTime: update.startTime,
            endTime: update.endTime
        )

        lock.withLock {
            chunks.append(chunk)
        }
    }

    func apply(_ corrections: [STTTranscriptCorrection]) {
        guard !corrections.isEmpty else { return }

        lock.withLock {
            for correction in corrections {
                for index in chunks.indices {
                    let chunk = chunks[index]
                    guard chunk.isFinal,
                          chunk.startTime == correction.startTime,
                          chunk.endTime == correction.endTime else {
                        continue
                    }

                    chunks[index] = TranscriptChunk(
                        id: chunk.id,
                        timestamp: chunk.timestamp,
                        source: chunk.source,
                        text: chunk.text,
                        isFinal: chunk.isFinal,
                        speakerTag: correction.newSpeakerTag ?? chunk.speakerTag,
                        speakerId: correction.newSpeakerId,
                        startTime: chunk.startTime,
                        endTime: chunk.endTime,
                        isLowConfidence: chunk.isLowConfidence
                    )
                }
            }
        }
    }

    func recordError(_ message: String) {
        lock.withLock {
            errorMessage = message
        }
    }

    func finalChunks() -> [TranscriptChunk] {
        lock.withLock {
            chunks.filter(\.isFinal)
        }
    }

    func currentErrorMessage() -> String? {
        lock.withLock {
            errorMessage
        }
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
