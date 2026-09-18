import Foundation
import XCTest
@testable import MeetMemo

final class EvidenceLedgerOptimizationTests: XCTestCase {
    func testEvidenceExtractionIsBoundedConcurrentOrderedAndCached() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetMemoEvidenceLedgerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        let tracker = EvidenceRequestTracker()
        let provider = DelayedEvidenceProvider(tracker: tracker)
        let generator = NotesGenerator(
            client: provider,
            evidenceCache: EvidenceLedgerCache(directoryURL: cacheDirectory)
        )
        let config = LLMProviderConfig(
            apiKey: "test-key",
            baseURL: "https://example.com/v1",
            model: "test-model"
        )
        let transcript = (1...4)
            .map { "SOURCE-\($0) " + String(repeating: "中", count: 18_000) }
            .joined(separator: "\n")
        let chunkCount = TranscriptBudget.chunks(transcript).count
        XCTAssertGreaterThan(chunkCount, 3)

        let first = try await generator.buildEvidenceLedger(config: config, transcript: transcript)
        let firstSnapshot = await tracker.snapshot()

        XCTAssertEqual(firstSnapshot.requestCount, chunkCount)
        XCTAssertGreaterThan(firstSnapshot.maximumActiveRequests, 1)
        XCTAssertLessThanOrEqual(
            firstSnapshot.maximumActiveRequests,
            NotesGenerator.maxConcurrentEvidenceRequests
        )
        XCTAssertEqual(
            first,
            (1...chunkCount)
                .map { "## 分段 \($0)/\(chunkCount)\nledger-\($0)" }
                .joined(separator: "\n\n")
        )

        let second = try await generator.buildEvidenceLedger(config: config, transcript: transcript)
        let secondSnapshot = await tracker.snapshot()

        XCTAssertEqual(second, first)
        XCTAssertEqual(secondSnapshot.requestCount, firstSnapshot.requestCount)
    }

    func testCacheKeyChangesWithTranscriptModelAndPrompt() {
        let config = LLMProviderConfig(
            apiKey: "first-secret",
            baseURL: "https://example.com/v1/",
            model: "model-a"
        )
        let original = EvidenceLedgerCache.key(
            config: config,
            transcript: "原始转录",
            extractionPrompt: "prompt-v1",
            chunkTokenBudget: 20_000
        )

        var sameInputsWithDifferentKey = config
        sameInputsWithDifferentKey.apiKey = "second-secret"
        XCTAssertEqual(
            original,
            EvidenceLedgerCache.key(
                config: sameInputsWithDifferentKey,
                transcript: "原始转录",
                extractionPrompt: "prompt-v1",
                chunkTokenBudget: 20_000
            )
        )

        var changedModel = config
        changedModel.model = "model-b"
        XCTAssertNotEqual(
            original,
            EvidenceLedgerCache.key(
                config: changedModel,
                transcript: "原始转录",
                extractionPrompt: "prompt-v1",
                chunkTokenBudget: 20_000
            )
        )
        XCTAssertNotEqual(
            original,
            EvidenceLedgerCache.key(
                config: config,
                transcript: "修改后的转录",
                extractionPrompt: "prompt-v1",
                chunkTokenBudget: 20_000
            )
        )
        XCTAssertNotEqual(
            original,
            EvidenceLedgerCache.key(
                config: config,
                transcript: "原始转录",
                extractionPrompt: "prompt-v2",
                chunkTokenBudget: 20_000
            )
        )
    }
}

private actor EvidenceRequestTracker {
    private var activeRequests = 0
    private var maximumActiveRequests = 0
    private var requestCount = 0

    func beginRequest() {
        activeRequests += 1
        requestCount += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
    }

    func endRequest() {
        activeRequests -= 1
    }

    func snapshot() -> (requestCount: Int, maximumActiveRequests: Int) {
        (requestCount, maximumActiveRequests)
    }
}

private final class DelayedEvidenceProvider: LLMProvider, @unchecked Sendable {
    private let tracker: EvidenceRequestTracker

    init(tracker: EvidenceRequestTracker) {
        self.tracker = tracker
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        let index = Self.chunkIndex(from: messages.last?.content ?? "")

        return AsyncThrowingStream { continuation in
            Task {
                await tracker.beginRequest()
                do {
                    try await Task.sleep(nanoseconds: 80_000_000)
                    continuation.yield("ledger-\(index)")
                    await tracker.endRequest()
                    continuation.finish()
                } catch {
                    await tracker.endRequest()
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func testConnection(config: LLMProviderConfig) async throws {}

    private static func chunkIndex(from message: String) -> Int {
        guard let range = message.range(of: #"index="\d+""#, options: .regularExpression),
              let value = Int(message[range].dropFirst(7).dropLast()) else {
            return -1
        }
        return value
    }
}
