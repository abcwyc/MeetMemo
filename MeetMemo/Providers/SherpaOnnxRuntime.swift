import Foundation

/// Thin adapter around the sherpa-onnx Swift C-API wrapper.
///
/// This file is the **only** place that touches sherpa-onnx types directly.
/// `SherpaSTTProvider` calls into this adapter, so it can stay decoupled from
/// whether the underlying framework is currently linked in.
///
/// The runtime ships with two parallel implementations gated by the
/// `SHERPA_ONNX_ENABLED` Swift compilation condition:
///
/// - **Disabled (default)** — `make(modelDirectory:)` throws
///   `SherpaOnnxRuntimeError.frameworkUnavailable`. The host UI surfaces a
///   friendly message and the user can keep using the macOS built-in engine.
/// - **Enabled** — Drives the real `SherpaOnnxOfflineRecognizer` +
///   `SherpaOnnxVoiceActivityDetectorWrapper` +
///   `SherpaOnnxSpeakerEmbeddingExtractorWrapper` against the model files
///   downloaded by `SherpaModelManager`.
///
/// See `Frameworks/swift-wrapper/` for the matching `SherpaOnnx.swift` wrapper
/// and bridging header that need to be added to the Xcode target before
/// turning the `SHERPA_ONNX_ENABLED` flag on.
final class SherpaOnnxRuntime {
    struct Segment {
        let samples: [Float]
        let text: String
        let startSampleOffset: Int
        let endSampleOffset: Int
    }

#if SHERPA_ONNX_ENABLED
    private let recognizer: SherpaOnnxOfflineRecognizer
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper
    private let embeddingExtractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper

    private init(
        recognizer: SherpaOnnxOfflineRecognizer,
        vad: SherpaOnnxVoiceActivityDetectorWrapper,
        embeddingExtractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper
    ) {
        self.recognizer = recognizer
        self.vad = vad
        self.embeddingExtractor = embeddingExtractor
    }

    static func make(modelDirectory: URL, senseVoiceModelFileName: String) throws -> SherpaOnnxRuntime {
        let modelPath = modelDirectory.appendingPathComponent(senseVoiceModelFileName).path
        let tokensPath = modelDirectory.appendingPathComponent("tokens.txt").path
        let vadPath = modelDirectory.appendingPathComponent("silero-vad.onnx").path
        let embPath = modelDirectory.appendingPathComponent("3dspeaker-cam-plus.onnx").path

        for path in [modelPath, tokensPath, vadPath, embPath] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaOnnxRuntimeError.modelFileMissing(path)
            }
        }

        // SenseVoice offline recognizer.
        let senseVoiceCfg = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath,
            language: "auto",
            useInverseTextNormalization: true
        )
        let modelCfg = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "sense_voice",
            senseVoice: senseVoiceCfg
        )
        let featCfg = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var recognizerCfg = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featCfg,
            modelConfig: modelCfg,
            decodingMethod: "greedy_search"
        )
        let recognizer = withUnsafePointer(to: &recognizerCfg) { ptr in
            SherpaOnnxOfflineRecognizer(config: ptr)
        }

        let vad = Self.makeVad(vadPath: vadPath)
        let emb = Self.makeSpeakerEmbeddingExtractor(modelPath: embPath)
        return SherpaOnnxRuntime(recognizer: recognizer, vad: vad, embeddingExtractor: emb)
    }

    /// Fun-ASR-Nano offline recognizer + the same Silero VAD / CAM++ pipeline used by
    /// SenseVoice. Backs the Fun-ASR-Nano real-time STT engine. ASR weights live under
    /// `modelDirectory/funasr-nano/`; VAD + speaker embedding are reused from the root.
    static func makeFunASRNano(
        modelDirectory: URL,
        language: String = "",
        hotwords: String = ""
    ) throws -> SherpaOnnxRuntime {
        let funDir = modelDirectory.appendingPathComponent("funasr-nano", isDirectory: true)
        let encoderPath = funDir.appendingPathComponent("encoder_adaptor.int8.onnx").path
        let llmPath = funDir.appendingPathComponent("llm.int8.onnx").path
        let embeddingPath = funDir.appendingPathComponent("embedding.int8.onnx").path
        let tokenizerDir = funDir.appendingPathComponent("Qwen3-0.6B", isDirectory: true).path
        let vadPath = modelDirectory.appendingPathComponent("silero-vad.onnx").path
        let spkPath = modelDirectory.appendingPathComponent("3dspeaker-cam-plus.onnx").path

        for path in [encoderPath, llmPath, embeddingPath, tokenizerDir, vadPath, spkPath] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaOnnxRuntimeError.modelFileMissing(path)
            }
        }

        let funCfg = sherpaOnnxOfflineFunASRNanoModelConfig(
            encoderAdaptor: encoderPath,
            llm: llmPath,
            embedding: embeddingPath,
            tokenizer: tokenizerDir,
            language: language,
            itn: true,
            hotwords: hotwords
        )
        let modelCfg = sherpaOnnxOfflineModelConfig(
            tokens: "",
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "",
            funasrNano: funCfg
        )
        let featCfg = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var recognizerCfg = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featCfg,
            modelConfig: modelCfg,
            decodingMethod: "greedy_search"
        )
        let recognizer = withUnsafePointer(to: &recognizerCfg) { ptr in
            SherpaOnnxOfflineRecognizer(config: ptr)
        }

        let vad = Self.makeVad(vadPath: vadPath)
        let emb = Self.makeSpeakerEmbeddingExtractor(modelPath: spkPath)
        return SherpaOnnxRuntime(recognizer: recognizer, vad: vad, embeddingExtractor: emb)
    }

    /// Silero VAD — keep the start trigger permissive; callers add leading context before
    /// decoding to preserve soft utterance starts.
    private static func makeVad(vadPath: String) -> SherpaOnnxVoiceActivityDetectorWrapper {
        let sileroCfg = sherpaOnnxSileroVadModelConfig(
            model: vadPath,
            threshold: 0.18,
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.12,
            windowSize: 512,
            maxSpeechDuration: 15.0
        )
        var vadCfg = sherpaOnnxVadModelConfig(
            sileroVad: sileroCfg,
            sampleRate: 16_000,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        return withUnsafePointer(to: &vadCfg) { ptr in
            SherpaOnnxVoiceActivityDetectorWrapper(config: ptr, buffer_size_in_seconds: 60.0)
        }
    }

    private static func makeSpeakerEmbeddingExtractor(modelPath: String) -> SherpaOnnxSpeakerEmbeddingExtractorWrapper {
        var embCfg = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: modelPath,
            numThreads: 1,
            debug: 0,
            provider: "cpu"
        )
        return withUnsafePointer(to: &embCfg) { ptr in
            SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: ptr)
        }
    }

    func acceptWaveform(_ samples: [Float]) {
        vad.acceptWaveform(samples: samples)
    }

    func flushVAD() {
        vad.flush()
    }

    func nextCompletedSegment(force: Bool) -> Segment? {
        guard !vad.isEmpty() else { return nil }
        let seg = vad.front()
        let startOffset = seg.start
        let samples = seg.samples
        let endOffset = startOffset + samples.count
        vad.pop()

        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        return Segment(
            samples: samples,
            text: result.text,
            startSampleOffset: startOffset,
            endSampleOffset: endOffset
        )
    }

    func decodeFallbackSegment(samples: [Float], startSampleOffset: Int) -> Segment {
        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        return Segment(
            samples: samples,
            text: result.text,
            startSampleOffset: startSampleOffset,
            endSampleOffset: startSampleOffset + samples.count
        )
    }

    func embedding(for samples: [Float]) -> [Float] {
        let stream = embeddingExtractor.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: 16_000)
        stream.inputFinished()
        guard embeddingExtractor.isReady(stream: stream) else { return [] }
        return embeddingExtractor.compute(stream: stream)
    }
#else
    static func make(modelDirectory: URL, senseVoiceModelFileName: String) throws -> SherpaOnnxRuntime {
        _ = modelDirectory
        _ = senseVoiceModelFileName
        throw SherpaOnnxRuntimeError.frameworkUnavailable
    }

    func acceptWaveform(_ samples: [Float]) { _ = samples }
    func flushVAD() {}
    func nextCompletedSegment(force: Bool) -> Segment? { _ = force; return nil }
    func decodeFallbackSegment(samples: [Float], startSampleOffset: Int) -> Segment {
        Segment(
            samples: samples,
            text: "",
            startSampleOffset: startSampleOffset,
            endSampleOffset: startSampleOffset + samples.count
        )
    }
    func embedding(for samples: [Float]) -> [Float] { _ = samples; return [] }
#endif
}

enum SherpaOnnxRuntimeError: LocalizedError {
    case frameworkUnavailable
    case modelFileMissing(String)

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .frameworkUnavailable:
            return lang.t(
                "sherpa-onnx 引擎尚未启用。请运行 scripts/fetch_sherpa_frameworks.sh，按 Frameworks/swift-wrapper/ 下的指引完成 Xcode 集成（添加 xcframework、bridging header，开启 SHERPA_ONNX_ENABLED）。",
                "sherpa-onnx engine is not yet enabled. Run scripts/fetch_sherpa_frameworks.sh and follow the integration steps under Frameworks/swift-wrapper/ (embed the xcframework, set the bridging header, define SHERPA_ONNX_ENABLED)."
            )
        case .modelFileMissing(let path):
            return lang.t(
                "未找到 sherpa-onnx 模型文件：\(path)。请在设置中重新下载本地 SenseVoice 模型。",
                "Missing sherpa-onnx model file: \(path). Re-download the local SenseVoice models from Settings."
            )
        }
    }
}
