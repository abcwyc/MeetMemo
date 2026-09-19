@preconcurrency import AVFoundation
import Foundation

/// Converts captured PCM to the STT target format off the capture thread.
///
/// The emitted stream keeps a continuous sample clock: silent buffers are forwarded (and
/// flagged) rather than discarded, and buffers dropped under backpressure are replaced by
/// zero PCM of the same duration. Local STT engines derive timestamps from the number of
/// samples ingested, so any gap here would permanently shift that source's timeline.
final class AudioProcessingPipeline: @unchecked Sendable {
    struct Output: Sendable {
        let data: Data
        let source: AudioSource
        /// True when the buffer's RMS fell below the pipeline's silence threshold, or when
        /// the data is synthesized zero PCM filling a gap.
        let isSilent: Bool
    }

    typealias AudioDataHandler = @Sendable (Output) -> Void
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
    /// Input frames dropped under backpressure since the last accepted buffer. They are
    /// re-inserted as zero PCM immediately before that next buffer, keeping them in place.
    private var droppedInputFrames: AVAudioFrameCount = 0
    /// Fractional output frames carried between gap fills so repeated resampling rounding
    /// does not accumulate drift.
    private var gapFrameRemainder = 0.0
    private var isAcceptingInput = true
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

    var hasNoPendingBuffers: Bool {
        stateLock.withLock { pendingBuffers == 0 }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let precedingGapFrames: AVAudioFrameCount? = stateLock.withLock {
            guard isAcceptingInput, !isStopped else { return nil }
            guard pendingBuffers < maxPendingBuffers else {
                droppedBuffers += 1
                droppedInputFrames += buffer.frameLength
                if droppedBuffers == 1 || droppedBuffers % 50 == 0 {
                    AppLog.audio.debug("⚠️ Dropped \(self.droppedBuffers) \(self.source.rawValue) audio buffers because the processing queue is backlogged; gaps are filled with silence.")
                }
                return nil
            }

            pendingBuffers += 1
            let gap = droppedInputFrames
            droppedInputFrames = 0
            return gap
        }

        guard let precedingGapFrames else { return }
        guard let copiedBuffer = Self.copyBuffer(buffer, format: inputFormat) else {
            // Keep the timeline intact even if this buffer can't be copied.
            stateLock.withLock {
                droppedInputFrames += precedingGapFrames + buffer.frameLength
            }
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
            if precedingGapFrames > 0 {
                self.emitSilence(inputFrames: precedingGapFrames)
            }
            self.process(copiedBuffer)
        }
    }

    /// Stops accepting new buffers and waits until every buffer already queued has been
    /// converted and handed to `onAudioData`. Use on a graceful stop so the final words
    /// reach the recognizer before end-of-stream.
    func drain() async {
        stateLock.withLock {
            isAcceptingInput = false
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// Discards queued work immediately. Use for hard resets where the audio is unwanted.
    func stop() {
        stateLock.withLock {
            isAcceptingInput = false
            isStopped = true
            pendingBuffers = 0
            droppedInputFrames = 0
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rmsLevel(in: buffer)
        onAudioLevel(rms, source)

        let isSilent = silenceThreshold.map { rms < $0 } ?? false

        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            emitSilence(inputFrames: buffer.frameLength)
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
              status == .haveData || status == .inputRanDry || status == .endOfStream,
              let channelData = outputBuffer.int16ChannelData?[0] else {
            emitSilence(inputFrames: buffer.frameLength)
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }

        onAudioData(Output(data: Data(bytes: channelData, count: frameCount * 2), source: source, isSilent: isSilent))
    }

    /// Emits zero PCM covering `inputFrames` of input-format audio. Runs on `queue`.
    private func emitSilence(inputFrames: AVAudioFrameCount) {
        let exactFrames = Double(inputFrames) * targetFormat.sampleRate / inputFormat.sampleRate + gapFrameRemainder
        let frameCount = Int(exactFrames.rounded(.down))
        gapFrameRemainder = exactFrames - Double(frameCount)
        guard frameCount > 0 else { return }
        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        onAudioData(Output(data: Data(count: frameCount * max(bytesPerFrame, 1)), source: source, isSilent: true))
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
