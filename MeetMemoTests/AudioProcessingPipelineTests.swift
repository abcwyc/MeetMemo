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
            onAudioData: { audio in
                output.setData(audio.data)
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
            onAudioData: { _ in unexpectedAudio.fulfill() },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)

        wait(for: [unexpectedAudio], timeout: 0.2)
    }

    func testSilentBuffersAreForwardedAndFlagged() async throws {
        let format = try Self.int16Format()
        let recorder = PipelineOutputRecorder()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: format,
            targetFormat: format,
            silenceThreshold: 0.0015,
            onAudioData: { recorder.append($0) },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [0, 0, 0, 0]))
        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [8_000, -8_000, 8_000, -8_000]))
        await pipeline.drain()

        let outputs = recorder.outputs
        XCTAssertEqual(outputs.map(\.data.count), [8, 8])
        XCTAssertEqual(outputs.map(\.isSilent), [true, false])
    }

    func testBackpressureDropIsReplacedBySilenceInPlace() async throws {
        let format = try Self.int16Format()
        let recorder = PipelineOutputRecorder()
        let firstDelivery = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: format,
            targetFormat: format,
            maxPendingBuffers: 1,
            onAudioData: { output in
                let isFirst = recorder.append(output) == 1
                if isFirst {
                    firstDelivery.signal()
                    releaseFirstDelivery.wait()
                }
            },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [100, 100]))
        XCTAssertEqual(firstDelivery.wait(timeout: .now() + 1), .success)
        // The first buffer is still being delivered, so this one is dropped.
        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [200, 200, 200]))
        releaseFirstDelivery.signal()
        try await waitUntil { pipeline.hasNoPendingBuffers }
        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [300, 300]))
        await pipeline.drain()

        let outputs = recorder.outputs
        XCTAssertEqual(outputs.map { $0.data.count / 2 }, [2, 3, 2])
        XCTAssertEqual(Self.samples(in: outputs[0].data), [100, 100])
        XCTAssertEqual(Self.samples(in: outputs[1].data), [0, 0, 0])
        XCTAssertTrue(outputs[1].isSilent)
        XCTAssertEqual(Self.samples(in: outputs[2].data), [300, 300])
    }

    func testDrainDeliversQueuedAudioAndRejectsLaterInput() async throws {
        let format = try Self.int16Format()
        let recorder = PipelineOutputRecorder()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .mic,
            inputFormat: format,
            targetFormat: format,
            onAudioData: { output in
                Thread.sleep(forTimeInterval: 0.01)
                recorder.append(output)
            },
            onAudioLevel: { _, _ in }
        ))

        for _ in 0..<10 {
            pipeline.enqueue(try Self.int16Buffer(format: format, samples: [1, 2, 3, 4]))
        }
        await pipeline.drain()
        XCTAssertEqual(recorder.outputs.count, 10)

        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [1, 2, 3, 4]))
        await pipeline.drain()
        XCTAssertEqual(recorder.outputs.count, 10)
    }

    func testStopDiscardsQueuedAudio() async throws {
        let format = try Self.int16Format()
        let recorder = PipelineOutputRecorder()
        let firstDelivery = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .mic,
            inputFormat: format,
            targetFormat: format,
            onAudioData: { output in
                if recorder.append(output) == 1 {
                    firstDelivery.signal()
                    releaseFirstDelivery.wait()
                }
            },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [1, 1]))
        XCTAssertEqual(firstDelivery.wait(timeout: .now() + 1), .success)
        pipeline.enqueue(try Self.int16Buffer(format: format, samples: [2, 2]))
        pipeline.stop()
        releaseFirstDelivery.signal()
        await pipeline.drain()

        XCTAssertEqual(recorder.outputs.count, 1)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    private static func int16Format() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
    }

    private static func int16Buffer(format: AVAudioFormat, samples: [Int16]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }

    private static func samples(in data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
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

private final class PipelineOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AudioProcessingPipeline.Output] = []

    var outputs: [AudioProcessingPipeline.Output] {
        lock.withLock { recorded }
    }

    @discardableResult
    func append(_ output: AudioProcessingPipeline.Output) -> Int {
        lock.withLock {
            recorded.append(output)
            return recorded.count
        }
    }
}
