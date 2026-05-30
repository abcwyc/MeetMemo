@preconcurrency import AVFoundation
import Foundation

final class AudioProcessingPipeline: @unchecked Sendable {
    typealias AudioDataHandler = @Sendable (Data, AudioSource) -> Void
    typealias AudioLevelHandler = @Sendable (Float, AudioSource) -> Void

    private let source: AudioSource
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let onAudioData: AudioDataHandler
    private let onAudioLevel: AudioLevelHandler
    private let silenceThreshold: Float?
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private let maxPendingBuffers: Int

    private var pendingBuffers = 0
    private var droppedBuffers = 0
    private var isStopped = false

    init?(
        source: AudioSource,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        maxPendingBuffers: Int = 96,
        silenceThreshold: Float? = nil,
        onAudioData: @escaping AudioDataHandler,
        onAudioLevel: @escaping AudioLevelHandler
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return nil
        }

        self.source = source
        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.onAudioData = onAudioData
        self.onAudioLevel = onAudioLevel
        self.silenceThreshold = silenceThreshold
        self.maxPendingBuffers = maxPendingBuffers
        self.queue = DispatchQueue(label: "io.meetmemo.audio.pipeline.\(source.rawValue)", qos: .userInitiated)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let didReserveBuffer: Bool = stateLock.withLock {
            guard !isStopped else { return false }
            guard pendingBuffers < maxPendingBuffers else {
                droppedBuffers += 1
                if droppedBuffers == 1 || droppedBuffers % 50 == 0 {
                    print("⚠️ Dropped \(droppedBuffers) \(source.rawValue) audio buffers because the processing queue is backlogged.")
                }
                return false
            }

            pendingBuffers += 1
            return true
        }

        guard didReserveBuffer else { return }
        guard let copiedBuffer = Self.copyBuffer(buffer, format: inputFormat) else {
            releasePendingBuffer()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.releasePendingBuffer()
            }

            guard self.stateLock.withLock({
                !self.isStopped
            }) else { return }
            self.process(copiedBuffer)
        }
    }

    func stop() {
        stateLock.withLock {
            isStopped = true
            pendingBuffers = 0
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rmsLevel(in: buffer)
        onAudioLevel(rms, source)

        if let threshold = silenceThreshold, rms < threshold { return }

        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream else {
            return
        }

        guard let channelData = outputBuffer.int16ChannelData?[0] else {
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }

        onAudioData(Data(bytes: channelData, count: frameCount * 2), source)
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in 0..<sourceBuffers.count {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                return nil
            }

            let bytesToCopy = min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
            memcpy(destinationData, sourceData, bytesToCopy)
            destinationBuffer.mDataByteSize = UInt32(bytesToCopy)
            destinationBuffers[index] = destinationBuffer
        }

        return copy
    }

    private func releasePendingBuffer() {
        stateLock.withLock {
            pendingBuffers = max(0, pendingBuffers - 1)
        }
    }

    private static func rmsLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else {
            return 0
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        var sumOfSquares = 0.0
        var sampleCount = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            accumulateSamples(in: audioBuffers, as: Float.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                Double($0)
            }
        case .pcmFormatFloat64:
            accumulateSamples(in: audioBuffers, as: Double.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                $0
            }
        case .pcmFormatInt16:
            accumulateSamples(in: audioBuffers, as: Int16.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                Double($0) / Double(Int16.max)
            }
        case .pcmFormatInt32:
            accumulateSamples(in: audioBuffers, as: Int32.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                Double($0) / Double(Int32.max)
            }
        default:
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(sampleCount)))
    }

    private static func accumulateSamples<T>(
        in audioBuffers: UnsafeMutableAudioBufferListPointer,
        as sampleType: T.Type,
        sumOfSquares: inout Double,
        sampleCount: inout Int,
        normalize: (T) -> Double
    ) {
        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { continue }
            let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<T>.size
            let typedData = data.assumingMemoryBound(to: T.self)
            for index in 0..<samples {
                let sample = normalize(typedData[index])
                sumOfSquares += sample * sample
            }
            sampleCount += samples
        }
    }
}
