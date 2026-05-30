import Foundation

protocol STTProvider: AnyObject {
    var capabilities: STTProviderCapabilities { get }
    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect(config: STTProviderConfig) async throws
    func sendAudio(_ pcmData: Data)
    func sendLastAudio()
    func disconnect()
    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws

    /// Waits for the provider to emit all final results after `sendLastAudio`, up to `timeout`.
    @discardableResult
    func awaitPendingFinalization(timeout: TimeInterval) async -> Bool
}

extension STTProvider {
    var capabilities: STTProviderCapabilities { .basic }

    @discardableResult
    func awaitPendingFinalization(timeout: TimeInterval) async -> Bool {
        try? await Task.sleep(for: .seconds(timeout))
        return true
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
