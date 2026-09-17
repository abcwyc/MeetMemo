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

final class UnavailableSTTProvider: STTProvider {
    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)?
    var onTranscriptCorrection: (([STTTranscriptCorrection]) -> Void)?
    var onError: ((String) -> Void)?

    private let message: String

    init(message: String) {
        self.message = message
    }

    func connect(config: STTProviderConfig) async throws {
        throw NSError(domain: "MeetMemo.STTProvider", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    func sendAudio(_ pcmData: Data) {}
    func sendLastAudio() {}
    func disconnect() {}

    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws {
        throw NSError(domain: "MeetMemo.STTProvider", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

struct UnavailableSTTProviderFactory: STTProviderFactory {
    let message: String

    func makeProvider() -> STTProvider {
        UnavailableSTTProvider(message: message)
    }
}

protocol LLMProvider {
    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error>

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error>

    func testConnection(config: LLMProviderConfig) async throws
}

struct LLMStructuredOutputRequest: Hashable, Sendable {
    let name: String
    let jsonSchema: String
    let maxTokens: Int

    /// Idle timeout for one non-streaming structured request. Several thousand
    /// output tokens from a slower model routinely take longer than a minute.
    static let requestTimeout: TimeInterval = 180

    init(name: String, jsonSchema: String, maxTokens: Int = 4096) {
        self.name = name
        self.jsonSchema = jsonSchema
        self.maxTokens = maxTokens
    }
}

struct LLMCompletionResponse: Hashable, Sendable {
    let content: String
    let finishReason: String?
    let requestID: String?
}

enum LLMCompletionError: LocalizedError {
    case emptyResponse
    case truncated
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "LLM 服务没有返回可用内容，请稍后重试。"
        case .truncated:
            return "LLM 输出达到长度上限，内容未完整生成。"
        case .invalidResponse:
            return "LLM 服务返回了无法识别的响应格式。"
        }
    }
}

extension LLMProvider {
    /// Compatibility path for providers and test doubles that do not expose
    /// a configurable output budget. Concrete network providers override it.
    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        chatCompletionsStreamThrowing(config: config, messages: messages)
    }

    /// Default compatibility path for test doubles and third-party providers.
    /// `LLMClient` overrides this with provider-native JSON schema/tool calling.
    func completeStructuredJSON(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request: LLMStructuredOutputRequest
    ) async throws -> LLMCompletionResponse {
        var content = ""
        let stream = chatCompletionsStreamThrowing(config: config, messages: messages)
        for try await chunk in stream {
            content += chunk
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMCompletionError.emptyResponse
        }
        return LLMCompletionResponse(content: content, finishReason: nil, requestID: nil)
    }
}
