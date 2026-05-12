import XCTest
@testable import MeetMemo

final class TranscriptChunkMergeTests: XCTestCase {
    func testPreferredChunkTextWinsWhenIDsMatch() {
        let id = UUID()
        let timestamp = Date()
        let oldChunk = TranscriptChunk(
            id: id,
            timestamp: timestamp,
            source: .mic,
            text: "old transcript",
            isFinal: true,
            startTime: 1_000,
            endTime: 2_000
        )
        let correctedChunk = TranscriptChunk(
            id: id,
            timestamp: timestamp,
            source: .mic,
            text: "corrected transcript",
            isFinal: true,
            startTime: 1_000,
            endTime: 2_000
        )

        let merged = [correctedChunk].mergingTranscriptCorrections(preservingMissingFinalChunksFrom: [oldChunk])

        XCTAssertEqual(merged.map(\.text), ["corrected transcript"])
    }

    func testMissingFinalChunksArePreservedInTimelineOrder() {
        let first = TranscriptChunk(
            source: .mic,
            text: "first",
            isFinal: true,
            startTime: 1_000,
            endTime: 2_000
        )
        let second = TranscriptChunk(
            source: .system,
            text: "second",
            isFinal: true,
            startTime: 3_000,
            endTime: 4_000
        )
        let staleInterim = TranscriptChunk(
            source: .mic,
            text: "interim",
            isFinal: false,
            startTime: 2_000,
            endTime: 2_500
        )

        let merged = [second].mergingTranscriptCorrections(
            preservingMissingFinalChunksFrom: [first, staleInterim]
        )

        XCTAssertEqual(merged.map(\.text), ["first", "second"])
    }
}
