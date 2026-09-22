import Foundation
import XCTest
@testable import MeetMemo

/// 验证纪要生成在单轮输出达到模型上限时会自动续写补全，而不是直接报错。
final class NotesGenerationContinuationTests: XCTestCase {
    private static let testConfig = LLMProviderConfig(
        apiKey: "test-key",
        baseURL: "https://example.com/v1",
        model: "test-model"
    )
    private static let baseMessages = [
        ChatMessage(role: "system", content: "你是会议纪要助手。"),
        ChatMessage(role: "user", content: "请生成会议纪要。")
    ]

    private func makeGenerator(_ provider: LLMProvider) -> NotesGenerator {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetMemoNotesContinuationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        return NotesGenerator(
            client: provider,
            evidenceCache: EvidenceLedgerCache(directoryURL: cacheDirectory)
        )
    }

    func testTruncatedAnswerResumesViaContinuationRound() async throws {
        let provider = ScriptedNotesProvider(rounds: [
            .contentThenTruncated(["# 会议纪要\n", "\n## 第一部分\n决策 A。"]),
            .finish(["\n## 第二部分\n行动项 B。"])
        ])
        let generator = makeGenerator(provider)

        var collected = ""
        try await generator.streamAnswerWithContinuation(
            config: Self.testConfig,
            messages: Self.baseMessages,
            sanitizer: NotesStreamSanitizer()
        ) { chunk in
            collected += chunk
        }

        XCTAssertEqual(
            collected,
            "# 会议纪要\n\n## 第一部分\n决策 A。\n## 第二部分\n行动项 B。"
        )

        let requests = provider.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].messages.map(\.role), ["system", "user"])
        XCTAssertEqual(
            requests[1].messages.map(\.role),
            ["system", "user", "assistant", "user"]
        )
        XCTAssertEqual(requests[1].messages[2].content, "# 会议纪要\n\n## 第一部分\n决策 A。")
        XCTAssertTrue(
            requests[1].messages[3].content.contains("继续输出"),
            "续写轮应以明确的继续指令结尾"
        )
    }

    func testRejectedBudgetFallsBackOnceAndContinuationsKeepFallbackBudget() async throws {
        let provider = ScriptedNotesProvider(rounds: [
            .rejectBudget("max_tokens must be at most 8192"),
            .contentThenTruncated(["# 纪要\n第一段。"]),
            .finish(["\n第二段。"])
        ])
        let generator = makeGenerator(provider)

        var collected = ""
        try await generator.streamAnswerWithContinuation(
            config: Self.testConfig,
            messages: Self.baseMessages,
            sanitizer: NotesStreamSanitizer()
        ) { chunk in
            collected += chunk
        }

        XCTAssertEqual(collected, "# 纪要\n第一段。\n第二段。")
        XCTAssertEqual(
            provider.recordedRequests.map { $0.maxTokens },
            [NotesGenerator.notesOutputTokenBudget, 8_192, 8_192]
        )
    }

    func testStalledContinuationSurfacesTruncationError() async throws {
        let provider = ScriptedNotesProvider(rounds: [
            .contentThenTruncated(["# 纪要\n"]),
            .contentThenTruncated([])
        ])
        let generator = makeGenerator(provider)

        do {
            try await generator.streamAnswerWithContinuation(
                config: Self.testConfig,
                messages: Self.baseMessages,
                sanitizer: NotesStreamSanitizer()
            ) { _ in }
            XCTFail("无进展的续写应以截断错误结束")
        } catch let error as LLMCompletionError {
            XCTAssertEqual(error.localizedDescription, LLMCompletionError.truncated.localizedDescription)
        }
        XCTAssertEqual(provider.recordedRequests.count, 2, "无新增内容时不应再发起更多轮请求")
    }

    func testContinuationStopsAtMaxRounds() async throws {
        var script: [ScriptedRound] = (0..<NotesGenerator.maxGenerationRounds)
            .map { .contentThenTruncated(["第\($0 + 1)段\n"]) }
        script.append(.finish(["不应被请求"]))
        let provider = ScriptedNotesProvider(rounds: script)
        let generator = makeGenerator(provider)

        do {
            try await generator.streamAnswerWithContinuation(
                config: Self.testConfig,
                messages: Self.baseMessages,
                sanitizer: NotesStreamSanitizer()
            ) { _ in }
            XCTFail("持续截断时应达到轮数上限并抛出错误")
        } catch let error as LLMCompletionError {
            XCTAssertEqual(error.localizedDescription, LLMCompletionError.truncated.localizedDescription)
        }
        XCTAssertEqual(
            provider.recordedRequests.count,
            NotesGenerator.maxGenerationRounds,
            "总轮数不应超过 maxGenerationRounds"
        )
    }
}

private enum ScriptedRound {
    case contentThenTruncated([String])
    case finish([String])
    case rejectBudget(String)
}

/// 按请求次序回放脚本；记录每轮收到的消息与输出预算供断言使用。
private final class ScriptedNotesProvider: LLMProvider, @unchecked Sendable {
    private let rounds: [ScriptedRound]
    private let lock = NSLock()
    private(set) var recordedRequests: [(messages: [ChatMessage], maxTokens: Int)] = []

    init(rounds: [ScriptedRound]) {
        self.rounds = rounds
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let index = recordedRequests.count
        recordedRequests.append((messages, maxTokens))
        let round = index < rounds.count ? rounds[index] : .finish([])
        lock.unlock()

        return AsyncThrowingStream { continuation in
            Task {
                switch round {
                case .contentThenTruncated(let chunks):
                    for chunk in chunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish(throwing: LLMCompletionError.truncated)
                case .finish(let chunks):
                    for chunk in chunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                case .rejectBudget(let message):
                    continuation.finish(throwing: HTTPError(statusCode: 400, message: message))
                }
            }
        }
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        chatCompletionsStreamThrowing(config: config, messages: messages, maxTokens: 8_192)
    }

    func testConnection(config: LLMProviderConfig) async throws {}
}
