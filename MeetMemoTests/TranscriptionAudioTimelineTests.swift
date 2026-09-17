import XCTest
@testable import MeetMemo

final class TranscriptionAudioTimelineTests: XCTestCase {
    private let captureA = UUID()
    private let captureB = UUID()

    func testAnchorIsStartOfFirstChunk() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: 1_000_000)
        // 100 ms of audio that finished arriving at 5 s.
        timeline.start(firstChunkByteCount: Self.bytes(milliseconds: 100), arrivalMilliseconds: 5_000)

        XCTAssertEqual(timeline.anchorMilliseconds, 4_900)
    }

    func testAppendBeforeStartIsIgnored() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: 1_000_000)

        let chunks = timeline.append(Self.audio(milliseconds: 100), captureID: captureA, arrivalMilliseconds: 100)

        XCTAssertTrue(chunks.isEmpty)
        XCTAssertNil(timeline.anchorMilliseconds)
    }

    func testSameCaptureIsNeverPaddedEvenWhenArrivalIsLate() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: 1_000_000)
        timeline.start(firstChunkByteCount: Self.bytes(milliseconds: 100), arrivalMilliseconds: 100)

        _ = timeline.append(Self.audio(milliseconds: 100), captureID: captureA, arrivalMilliseconds: 100)
        let chunks = timeline.append(Self.audio(milliseconds: 100), captureID: captureA, arrivalMilliseconds: 3_000)

        XCTAssertEqual(chunks.map(\.count), [Self.bytes(milliseconds: 100)])
        XCTAssertEqual(timeline.samplesSinceAnchor, 3_200)
    }

    func testCaptureRestartFillsInterruptionWithSilence() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: 1_000_000)
        timeline.start(firstChunkByteCount: Self.bytes(milliseconds: 1_000), arrivalMilliseconds: 1_000)
        _ = timeline.append(Self.audio(milliseconds: 1_000), captureID: captureA, arrivalMilliseconds: 1_000)

        // Capture restarted; its first 100 ms chunk finished arriving at 2.5 s.
        let chunks = timeline.append(Self.audio(milliseconds: 100), captureID: captureB, arrivalMilliseconds: 2_500)

        let silence = chunks.dropLast()
        XCTAssertEqual(silence.reduce(0) { $0 + $1.count }, Self.bytes(milliseconds: 1_400))
        XCTAssertTrue(silence.allSatisfy { $0.allSatisfy { $0 == 0 } })
        XCTAssertTrue(silence.allSatisfy { $0.count <= TranscriptionAudioTimeline.silenceChunkSamples * 2 })
        XCTAssertEqual(chunks.last?.count, Self.bytes(milliseconds: 100))
        XCTAssertEqual(timeline.samplesSinceAnchor, 2_500 * 16)
    }

    func testCaptureRestartGapFillIsClamped() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: 1_000_000, maxGapFillMilliseconds: 500)
        timeline.start(firstChunkByteCount: Self.bytes(milliseconds: 100), arrivalMilliseconds: 100)
        _ = timeline.append(Self.audio(milliseconds: 100), captureID: captureA, arrivalMilliseconds: 100)

        _ = timeline.append(Self.audio(milliseconds: 100), captureID: captureB, arrivalMilliseconds: 60_000)

        XCTAssertEqual(timeline.samplesSinceAnchor, (100 + 500 + 100) * 16)
    }

    func testPendingAudioIsReturnedInArrivalOrder() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: 1_000_000)
        timeline.start(firstChunkByteCount: 4, arrivalMilliseconds: 0)
        let first = Data([1, 0, 1, 0])
        let second = Data([2, 0, 2, 0])

        timeline.bufferPending(timeline.append(first, captureID: captureA, arrivalMilliseconds: 0))
        timeline.bufferPending(timeline.append(second, captureID: captureA, arrivalMilliseconds: 0))

        XCTAssertEqual(timeline.takePending(), [first, second])
        XCTAssertTrue(timeline.takePending().isEmpty)
    }

    func testPendingOverflowAdvancesAnchorByDroppedAudio() {
        var timeline = TranscriptionAudioTimeline(maxPendingBytes: Self.bytes(milliseconds: 200))
        timeline.start(firstChunkByteCount: Self.bytes(milliseconds: 100), arrivalMilliseconds: 1_100)

        for _ in 0..<3 {
            timeline.bufferPending(timeline.append(Self.audio(milliseconds: 100), captureID: captureA, arrivalMilliseconds: 0))
        }

        XCTAssertEqual(timeline.anchorMilliseconds, 1_100)
        XCTAssertEqual(timeline.takePending().count, 2)
        XCTAssertEqual(timeline.samplesSinceAnchor, 200 * 16)
    }

    private static func bytes(milliseconds: Int) -> Int {
        milliseconds * 16 * 2
    }

    private static func audio(milliseconds: Int) -> Data {
        Data(repeating: 1, count: bytes(milliseconds: milliseconds))
    }
}
