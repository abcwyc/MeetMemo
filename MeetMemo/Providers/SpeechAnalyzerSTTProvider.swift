import AVFoundation
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

    private let locale: Locale
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        super.init()
    }

    func connect(config: STTProviderConfig) async throws {
        disconnect()

        let transcriber = SpeechTranscriber(
            locale: config.locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
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

                    let update = STTTranscriptUpdate(
                        text: text,
                        isFinal: result.isFinal
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
        transcriber = nil
        analyzer = nil
        converter = nil
        analyzerFormat = nil
    }

    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws {
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(config.locale) else {
            throw SpeechAnalyzerError.modelNotInstalled(config.locale)
        }
    }

    func awaitPendingFinalization(timeout: TimeInterval) async {
        // Flush any buffered audio and force final result emission
        try? await withTimeout(seconds: timeout) {
            try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        // Wait for the results loop to complete naturally after finalization
        guard let resultsTask else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await resultsTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Private helpers

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
}

final class SpeechAnalyzerSTTProviderFactory: STTProviderFactory {
    let locale: Locale

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
    }

    func makeProvider() -> STTProvider {
        SpeechAnalyzerSTTProvider(locale: locale)
    }
}

enum SpeechAnalyzerError: LocalizedError {
    case modelNotInstalled(Locale)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let locale):
            return "语音识别模型未安装（\(locale.identifier)）。请在设置中检查语音识别状态后重试。"
        }
    }
}

// MARK: - Timeout helper

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
