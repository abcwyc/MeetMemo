import AVFoundation
import CoreMedia
import Foundation
import Speech

final class SpeechAnalyzerSTTProvider: NSObject, STTProvider {
    var capabilities: STTProviderCapabilities {
        STTProviderCapabilities(
            supportsStableUtteranceTiming: true,
            supportsCorrections: false,
            supportsFinalizationFlush: true
        )
    }

    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)?
    var onError: ((String) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var finalizationTask: Task<Bool, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func connect(config: STTProviderConfig) async throws {
        disconnect()

        let resolvedLocale = try await SpeechModelInstaller.shared.ensureReadyForUse(for: config.locale)
        let transcriber = SpeechModelInstaller.makeTranscriber(
            locale: resolvedLocale,
            includeTimeRange: true,
            includeVolatileResults: true
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Get the format the analyzer requires and build a converter from our 16kHz Int16 source
        if let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            analyzerFormat = targetFormat
            if targetFormat != sourceFormat {
                converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            }
        }

        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let timeRange = Self.millisecondRange(from: result.range)

                    let update = STTTranscriptUpdate(
                        text: text,
                        isFinal: result.isFinal,
                        startTime: timeRange?.start,
                        endTime: timeRange?.end
                    )
                    self.onTranscriptUpdate?(update)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.onError?(error.localizedDescription)
            }
        }

        analysisTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.onError?(error.localizedDescription)
            }
        }
    }

    func sendAudio(_ pcmData: Data) {
        guard let outputBuffer = makeOutputBuffer(from: pcmData) else { return }
        inputBuilder?.yield(AnalyzerInput(buffer: outputBuffer))
    }

    func sendLastAudio() {
        inputBuilder?.finish()
        inputBuilder = nil
    }

    func disconnect() {
        inputBuilder?.finish()
        inputBuilder = nil
        analysisTask?.cancel()
        analysisTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        transcriber = nil
        analyzer = nil
        converter = nil
        analyzerFormat = nil
    }

    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws {
        _ = try await SpeechModelInstaller.shared.ensureReadyForUse(for: config.locale)
    }

    func awaitPendingFinalization(timeout: TimeInterval) async -> STTFinalizationStatus {
        inputBuilder?.finish()
        inputBuilder = nil

        let startedAt = Date()
        let finalizeTask = makeFinalizationTask()
        guard let finalizeTask else { return .completed }

        guard let finalized = await Self.waitForTask(finalizeTask, timeout: timeout),
              finalized else {
            print("⚠️ SpeechAnalyzer finalization timed out after \(timeout)s.")
            return .finalizeTimedOut
        }

        guard let resultsTask else { return .completed }
        let remaining = max(0.5, timeout - Date().timeIntervalSince(startedAt))
        guard await Self.waitForTask(resultsTask, timeout: remaining) != nil else {
            print("⚠️ SpeechAnalyzer result drain timed out after finalization.")
            return .resultDrainTimedOut
        }

        return .completed
    }

    // MARK: - Private helpers

    private func makeFinalizationTask() -> Task<Bool, Never>? {
        if let finalizationTask {
            return finalizationTask
        }

        guard let analyzer else { return nil }
        let task = Task { [weak self, analyzer] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                self?.onError?(error.localizedDescription)
                return false
            }
        }
        finalizationTask = task
        return task
    }

    private static func waitForTask<Success>(_ task: Task<Success, Never>, timeout: TimeInterval) async -> Success? {
        await withTaskGroup(of: Success?.self) { group in
            group.addTask {
                .some(await task.value)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                task.cancel()  // unblock the awaiting child task so withTaskGroup can return
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func makeOutputBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0 else { return nil }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }
        inputBuffer.frameLength = frameCount
        data.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress else { return }
            inputBuffer.int16ChannelData![0].update(from: src, count: Int(frameCount))
        }

        guard let targetFormat = analyzerFormat, let conv = converter else {
            return inputBuffer
        }

        let outputCapacity = AVAudioFrameCount(
            Double(frameCount) * (targetFormat.sampleRate / sourceFormat.sampleRate)
        ) + 32

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = conv.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream,
              outputBuffer.frameLength > 0 else {
            return nil
        }

        return outputBuffer
    }

    static func millisecondRange(from range: CMTimeRange) -> (start: Int, end: Int)? {
        guard let start = milliseconds(from: range.start),
              let end = milliseconds(from: CMTimeRangeGetEnd(range)) else {
            return nil
        }
        return (start, max(start, end))
    }

    private static func milliseconds(from time: CMTime) -> Int? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }
}

final class SpeechAnalyzerSTTProviderFactory: STTProviderFactory {
    func makeProvider() -> STTProvider {
        SpeechAnalyzerSTTProvider()
    }
}
