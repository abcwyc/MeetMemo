import CryptoKit
import Foundation

/// Manages the local sherpa-onnx model files (SenseVoice, Silero VAD, speaker embedding)
/// that back the `.sherpaSenseVoice` STT engine. Mirrors `SpeechModelInstaller` so the
/// settings UI can stay symmetrical between engines.
@MainActor
final class SherpaModelManager: ObservableObject {
    static let shared = SherpaModelManager()

    @Published var isReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double?
    @Published var installError: String?

    struct ModelFile {
        let key: String              // logical identifier used by the provider
        let fileName: String         // on-disk name (under modelDirectory)
        let urls: [URL]              // remote sources, tried in order
        let approximateBytes: Int64  // for weighted progress aggregation
        let sha256: String?          // optional integrity check, nil to skip
    }

    /// File list is intentionally small: SenseVoice (model + tokens), Silero VAD,
    /// and a CAM++-style speaker embedding extractor. Mirrors what
    /// `SherpaSTTProvider` will load at connect time.
    static let senseVoiceModel = ModelFile(
        key: "sense_voice_model",
        fileName: "sense-voice-small.int8.onnx",
        urls: [
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/sense-voice-small.int8.onnx")!,
            URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx")!,
        ],
        approximateBytes: 210 * 1024 * 1024,
        sha256: nil
    )

    static let tokensModelFile = ModelFile(
        key: "sense_voice_tokens",
        fileName: "tokens.txt",
        urls: [
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/tokens.txt")!,
            URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt")!,
        ],
        approximateBytes: 320 * 1024,
        sha256: nil
    )

    /// Silero VAD — shared by both the SenseVoice and Fun-ASR-Nano pipelines.
    static let vadModelFile = ModelFile(
        key: "vad",
        fileName: "silero-vad.onnx",
        urls: [
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/silero-vad.onnx")!,
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
        ],
        approximateBytes: 2 * 1024 * 1024,
        sha256: nil
    )

    /// CAM++ speaker embedding extractor — shared for diarization in both pipelines.
    static let speakerEmbeddingModelFile = ModelFile(
        key: "speaker_embedding",
        fileName: "3dspeaker-cam-plus.onnx",
        urls: [
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/3dspeaker-cam-plus.onnx")!,
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!,
        ],
        approximateBytes: 28 * 1024 * 1024,
        sha256: nil
    )

    static let sharedModelFiles: [ModelFile] = [
        tokensModelFile,
        vadModelFile,
        speakerEmbeddingModelFile,
    ]

    /// Fun-ASR-Nano (int8) real-time STT engine model. The ASR weights live under
    /// a `funasr-nano/` subdirectory; Silero VAD + CAM++ are reused from the shared set so
    /// diarization comes for free. ~1 GB total.
    static func funASRNanoFile(_ name: String, _ approximateBytes: Int64) -> ModelFile {
        ModelFile(
            key: "funasr_nano_\(name)",
            fileName: "funasr-nano/\(name)",
            urls: [
                URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30/resolve/main/\(name)")!,
                URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30/resolve/main/\(name)")!,
            ],
            approximateBytes: approximateBytes,
            sha256: nil
        )
    }

    static let funASRNanoModelFiles: [ModelFile] = [
        funASRNanoFile("encoder_adaptor.int8.onnx", 237_792_748),
        funASRNanoFile("embedding.int8.onnx", 155_584_380),
        funASRNanoFile("llm.int8.onnx", 600_356_593),
        funASRNanoFile("Qwen3-0.6B/tokenizer.json", 11_422_654),
        funASRNanoFile("Qwen3-0.6B/vocab.json", 2_776_833),
        funASRNanoFile("Qwen3-0.6B/merges.txt", 1_671_853),
        vadModelFile,
        speakerEmbeddingModelFile,
    ]

    /// Absolute path to the directory holding the Fun-ASR-Nano weights + tokenizer.
    var funASRNanoDirectory: URL {
        modelDirectory.appendingPathComponent("funasr-nano", isDirectory: true)
    }

    static let senseVoiceModelFiles: [ModelFile] = [senseVoiceModel] + sharedModelFiles

    let modelDirectory: URL
    private var activeDownloadSession: URLSession?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.modelDirectory = base.appendingPathComponent("MeetMemo/sherpa-onnx", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        Task { await self.refreshReadiness() }
    }

    func localURL(forKey key: String) -> URL? {
        guard let model = Self.senseVoiceModelFiles.first(where: { $0.key == key }) else { return nil }
        return modelDirectory.appendingPathComponent(model.fileName)
    }

    var activeSenseVoiceModelFileName: String {
        Self.senseVoiceModel.fileName
    }

    var activeApproximateBytes: Int64 {
        Self.senseVoiceModelFiles.reduce(Int64(0)) { $0 + $1.approximateBytes }
    }

    /// Pure check: are all the given files present on disk (and SHA-matched, if provided)?
    func modelFilesReady(_ files: [ModelFile]) -> Bool {
        for model in files {
            let url = modelDirectory.appendingPathComponent(model.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            if let expected = model.sha256,
               (try? Self.sha256Hex(of: url)) != expected.lowercased() {
                return false
            }
        }
        return true
    }

    /// Re-checks whether every required SenseVoice file is present on disk.
    func refreshReadiness() async {
        isReady = modelFilesReady(Self.senseVoiceModelFiles)
    }

    /// Guarantees every model file is on disk and (optionally) hash-verified.
    /// Throws if the user cancels or any file download fails.
    func ensureReadyForUse() async throws {
        await refreshReadiness()
        if isReady { return }
        try await installModelsIfNeeded()
        await refreshReadiness()
        guard isReady else {
            throw SherpaModelError.notReady
        }
    }

    /// Public entry point for the Settings UI "Install" button (SenseVoice).
    func installModelsIfNeeded() async throws {
        if isDownloading {
            while isDownloading { try? await Task.sleep(for: .milliseconds(250)) }
            return
        }

        isDownloading = true
        downloadProgress = 0
        installError = nil
        defer {
            isDownloading = false
            downloadProgress = nil
        }

        try await downloadModelFiles(Self.senseVoiceModelFiles) { [weak self] progress in
            self?.downloadProgress = progress
        }
    }

    /// Generic downloader shared by the SenseVoice and Fun-ASR-Nano pipelines. Reports
    /// aggregate [0, 1] progress through `onProgress` instead of mutating `self`, so each
    /// caller (with its own `@Published` state) stays isolated. Sets `installError` and
    /// throws on the first failed file.
    func downloadModelFiles(
        _ files: [ModelFile],
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.approximateBytes }
        var completedBytes: Int64 = 0

        for model in files {
            let destination = modelDirectory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                if let expected = model.sha256,
                   (try? Self.sha256Hex(of: destination)) == expected.lowercased() {
                    completedBytes += model.approximateBytes
                    onProgress(Double(completedBytes) / Double(totalBytes))
                    continue
                } else if model.sha256 == nil {
                    completedBytes += model.approximateBytes
                    onProgress(Double(completedBytes) / Double(totalBytes))
                    continue
                } else {
                    try? FileManager.default.removeItem(at: destination)
                }
            }

            do {
                try await downloadFile(
                    model: model,
                    destination: destination,
                    completedBaseBytes: completedBytes,
                    totalBytes: totalBytes,
                    onProgress: onProgress
                )
                completedBytes += model.approximateBytes
                onProgress(Double(completedBytes) / Double(totalBytes))
            } catch {
                let message = LanguageManager.shared.t(
                    "下载 \(model.fileName) 失败:\(error.localizedDescription)",
                    "Failed to download \(model.fileName): \(error.localizedDescription)"
                )
                installError = message
                throw SherpaModelError.downloadFailed(model.fileName, error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
    }

    // MARK: - Private

    private func downloadFile(
        model: ModelFile,
        destination: URL,
        completedBaseBytes: Int64,
        totalBytes: Int64,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var lastError: Error?
        for url in model.urls {
            do {
                try await downloadFile(
                    from: url,
                    model: model,
                    destination: destination,
                    completedBaseBytes: completedBaseBytes,
                    totalBytes: totalBytes,
                    onProgress: onProgress
                )
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SherpaModelError.downloadFailed(model.fileName, "No download source available")
    }

    private func downloadFile(
        from url: URL,
        model: ModelFile,
        destination: URL,
        completedBaseBytes: Int64,
        totalBytes: Int64,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // Files may live in subdirectories (e.g. funasr-nano/Qwen3-0.6B/tokenizer.json).
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temp = destination.appendingPathExtension("part")
        let resumeOffset = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0

        let delegate = ModelDownloadDelegate(tempURL: temp, resumeOffset: resumeOffset) { receivedBytes, expectedBytes in
            let expected = max(expectedBytes, model.approximateBytes)
            let fraction = (Double(completedBaseBytes) + Double(receivedBytes) * Double(model.approximateBytes) / Double(max(1, expected))) / Double(totalBytes)
            Task { @MainActor in
                onProgress(min(0.99, max(0, fraction)))
            }
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        activeDownloadSession = session
        defer {
            if activeDownloadSession === session {
                activeDownloadSession = nil
            }
            session.finishTasksAndInvalidate()
        }

        var request = URLRequest(url: url)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let response = try await delegate.download(request, using: session)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw SherpaModelError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        if let expectedSha = model.sha256 {
            let actual = try Self.sha256Hex(of: temp)
            if actual != expectedSha.lowercased() {
                try? FileManager.default.removeItem(at: temp)
                throw SherpaModelError.integrityCheckFailed(model.fileName)
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let tempURL: URL
    private let resumeOffset: Int64
    private let progressHandler: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URLResponse?, Error>?
    private var fileMoveError: Error?

    init(
        tempURL: URL,
        resumeOffset: Int64,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.tempURL = tempURL
        self.resumeOffset = resumeOffset
        self.progressHandler = progressHandler
    }

    func download(_ request: URLRequest, using session: URLSession) async throws -> URLResponse? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(resumeOffset + totalBytesWritten, resumeOffset + totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
            if resumeOffset > 0, statusCode == 206 {
                let input = try FileHandle(forReadingFrom: location)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: tempURL)
                defer { try? output.close() }
                try output.seekToEnd()
                while true {
                    let chunk = input.readData(ofLength: 1024 * 1024)
                    if chunk.isEmpty { break }
                    output.write(chunk)
                }
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                try FileManager.default.moveItem(at: location, to: tempURL)
            }
        } catch {
            fileMoveError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let fileMoveError {
            continuation?.resume(throwing: fileMoveError)
        } else {
            continuation?.resume(returning: task.response)
        }
        continuation = nil
    }
}

enum SherpaModelError: LocalizedError {
    case notReady
    case downloadFailed(String, String)
    case httpError(Int)
    case integrityCheckFailed(String)

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .notReady:
            return lang.t(
                "SenseVoice 模型尚未就绪,请先在设置中下载本地语音识别模型。",
                "SenseVoice models are not ready. Download the local speech recognition models from Settings first."
            )
        case .downloadFailed(let file, let detail):
            return lang.t("下载 \(file) 失败:\(detail)", "Failed to download \(file): \(detail)")
        case .httpError(let code):
            return lang.t("下载失败,HTTP \(code)", "Download failed with HTTP \(code)")
        case .integrityCheckFailed(let file):
            return lang.t("\(file) 校验失败,可能损坏。请重试。", "\(file) failed integrity check; please retry.")
        }
    }
}
