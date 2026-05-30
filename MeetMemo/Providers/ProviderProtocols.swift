import Foundation

protocol STTProvider: AnyObject {
    var capabilities: STTProviderCapabilities { get }
    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)? { get set }
    var onTranscriptCorrection: (([STTTranscriptCorrection]) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect(config: STTProviderConfig) async throws
    func sendAudio(_ pcmData: Data)
    func sendLastAudio()
    func disconnect()
    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws

    /// Waits for the provider to emit all final results after `sendLastAudio`, up to `timeout`.
    @discardableResult
    func awaitPendingFinalization(timeout: TimeInterval) async -> STTFinalizationStatus

    /// Runs any post-recording corrections (e.g. offline speaker diarization refinement)
    /// and emits the result via `onTranscriptCorrection`. Default no-op.
    func applyOfflineRefinement() async
}

extension STTProvider {
    var capabilities: STTProviderCapabilities { .basic }

    @discardableResult
    func awaitPendingFinalization(timeout: TimeInterval) async -> STTFinalizationStatus {
        try? await Task.sleep(for: .seconds(timeout))
        return .completed
    }

    func applyOfflineRefinement() async {}
}

enum STTFinalizationStatus: Hashable {
    case completed
    case finalizeTimedOut
    case resultDrainTimedOut

    var mayHaveMissedTailAudio: Bool {
        if case .finalizeTimedOut = self { return true }
        return false
    }
}

struct STTProviderCapabilities: Hashable {
    let supportsStableUtteranceTiming: Bool
    let supportsCorrections: Bool
    let supportsFinalizationFlush: Bool

    static let basic = STTProviderCapabilities(
        supportsStableUtteranceTiming: false,
        supportsCorrections: false,
        supportsFinalizationFlush: false
    )
}

/// A retroactive update to an already-emitted final transcript chunk.
/// Currently used by sherpa-onnx provider to revise `speakerId`/`speakerTag`
/// after a stop-of-recording offline diarization pass.
struct STTTranscriptCorrection: Hashable {
    let startTime: Int
    let endTime: Int
    let newSpeakerId: Int
    let newSpeakerTag: String?
}

protocol STTProviderFactory {
    func makeProvider() -> STTProvider
}

protocol LLMProvider {
    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error>

    func testConnection(config: LLMProviderConfig) async throws
}
