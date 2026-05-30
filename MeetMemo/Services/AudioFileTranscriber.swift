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
