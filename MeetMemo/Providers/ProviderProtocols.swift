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

    /// 等待 sendLastAudio 之后服务端发回最终结果，或到达超时。
    /// 默认实现以 `timeout` 为上限阻塞，避免破坏未感知该接口的旧 provider。
    func awaitPendingFinalization(timeout: TimeInterval) async
}

extension STTProvider {
    var capabilities: STTProviderCapabilities {
        .basic
    }

    func awaitPendingFinalization(timeout: TimeInterval) async {
        try? await Task.sleep(for: .seconds(timeout))
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
