import AVFoundation
import XCTest
@testable import MeetMemo

final class AudioProcessingPipelineTests: XCTestCase {
    func testInterleavedInt16BufferIsCopiedAndConverted() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4))
        inputBuffer.frameLength = 4

        let audioBuffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        let samples = try XCTUnwrap(audioBuffers.first?.mData?.assumingMemoryBound(to: Int16.self))
        samples[0] = 1_000
        samples[1] = -1_000
        samples[2] = 2_000
        samples[3] = -2_000

        let receivedAudio = expectation(description: "pipeline emits converted audio")
        let receivedLevel = expectation(description: "pipeline emits an audio level")
        let output = CapturedPipelineOutput()

        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .mic,
            inputFormat: inputFormat,
            targetFormat: outputFormat,
            onAudioData: { data, _ in
                output.setData(data)
                receivedAudio.fulfill()
            },
            onAudioLevel: { level, _ in
                output.setLevel(level)
                receivedLevel.fulfill()
            }
        ))

        pipeline.enqueue(inputBuffer)

        wait(for: [receivedAudio, receivedLevel], timeout: 1)
        XCTAssertEqual(output.data.count, 8)
        XCTAssertGreaterThan(output.level, 0)
    }

    func testBackloggedPipelineDropsBeforeProcessing() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        inputBuffer.frameLength = 4
        inputBuffer.floatChannelData?[0][0] = 0.5

        let unexpectedAudio = expectation(description: "backlogged pipeline does not emit audio")
        unexpectedAudio.isInverted = true

        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: format,
            targetFormat: format,
            maxPendingBuffers: 0,
            onAudioData: { _, _ in unexpectedAudio.fulfill() },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)

        wait(for: [unexpectedAudio], timeout: 0.2)
    }
}

private final class CapturedPipelineOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedData = Data()
    private var capturedLevel: Float = 0

    var data: Data {
        lock.withLock { capturedData }
    }

    var level: Float {
        lock.withLock { capturedLevel }
    }

    func setData(_ data: Data) {
        lock.withLock {
            capturedData = data
        }
    }

    func setLevel(_ level: Float) {
        lock.withLock {
            capturedLevel = level
        }
    }
}
