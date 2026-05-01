import Foundation

protocol STTProvider: AnyObject {
    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect(config: STTProviderConfig) async throws
    func sendAudio(_ pcmData: Data)
    func sendLastAudio()
    func disconnect()
    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws
}

protocol STTProviderFactory {
    func makeProvider() -> STTProvider
}

struct DoubaoSTTProviderFactory: STTProviderFactory {
    func makeProvider() -> STTProvider {
        DoubaoSTTProvider()
    }
}

protocol LLMProvider {
    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error>

    func testConnection(config: LLMProviderConfig) async throws
}

