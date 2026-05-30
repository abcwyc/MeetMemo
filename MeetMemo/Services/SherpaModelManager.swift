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
    static let modelFiles: [ModelFile] = [
        ModelFile(
            key: "sense_voice_model",
            fileName: "sense-voice-small.int8.onnx",
            urls: [
                URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx")!,
                URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx")!,
            ],
            approximateBytes: 210 * 1024 * 1024,
            sha256: nil
        ),
        ModelFile(
            key: "sense_voice_tokens",
            fileName: "tokens.txt",
            urls: [
                URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt")!,
                URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt")!,
            ],
            approximateBytes: 320 * 1024,
            sha256: nil
        ),
        ModelFile(
            key: "vad",
            fileName: "silero-vad.onnx",
            urls: [
                URL(string: "https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
                URL(string: "https://gh.llkk.cc/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
                URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
            ],
            approximateBytes: 2 * 1024 * 1024,
            sha256: nil
        ),
        ModelFile(
            key: "speaker_embedding",
            fileName: "3dspeaker-cam-plus.onnx",
            urls: [
                URL(string: "https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!,
                URL(string: "https://gh.llkk.cc/https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!,
                URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!,
            ],
            approximateBytes: 28 * 1024 * 1024,
            sha256: nil
        ),
    ]

    let modelDirectory: URL
    private var downloadTask: Task<Void, Never>?
    private let session: URLSession

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.modelDirectory = base.appendingPathComponent("MeetMemo/sherpa-onnx", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        Task { await self.refreshReadiness() }
    }

    func localURL(forKey key: String) -> URL? {
        guard let model = Self.modelFiles.first(where: { $0.key == key }) else { return nil }
        return modelDirectory.appendingPathComponent(model.fileName)
    }

    /// Re-checks whether every required file is present on disk (and matches its SHA, if provided).
    func refreshReadiness() async {
        var allReady = true
        for model in Self.modelFiles {
            let url = modelDirectory.appendingPathComponent(model.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                allReady = false; break
            }
            if let expected = model.sha256,
               (try? Self.sha256Hex(of: url)) != expected.lowercased() {
                allReady = false; break
            }
        }
        isReady = allReady
    }

    /// Guarantees every model file is on disk and (optionally) hash-verified.
    /// Throws if the user cancels or any file download fails.
    func ensureReadyForUse() async throws {
        if isReady { return }
        try await installModelsIfNeeded()
        await refreshReadiness()
        guard isReady else {
            throw SherpaModelError.notReady
        }
    }

    /// Public entry point for the Settings UI "Install" button.
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

        let totalBytes = Self.modelFiles.reduce(Int64(0)) { $0 + $1.approximateBytes }
        var completedBytes: Int64 = 0

        for model in Self.modelFiles {
            let destination = modelDirectory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                if let expected = model.sha256,
                   (try? Self.sha256Hex(of: destination)) == expected.lowercased() {
                    completedBytes += model.approximateBytes
                    downloadProgress = Double(completedBytes) / Double(totalBytes)
                    continue
                } else if model.sha256 == nil {
                    completedBytes += model.approximateBytes
                    downloadProgress = Double(completedBytes) / Double(totalBytes)
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
                    totalBytes: totalBytes
                )
                completedBytes += model.approximateBytes
                downloadProgress = Double(completedBytes) / Double(totalBytes)
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
        downloadTask?.cancel()
    }

    // MARK: - Private

    private func downloadFile(
        model: ModelFile,
        destination: URL,
        completedBaseBytes: Int64,
        totalBytes: Int64
    ) async throws {
        var lastError: Error?
        for url in model.urls {
            do {
                try await downloadFile(
                    from: url,
                    model: model,
                    destination: destination,
                    completedBaseBytes: completedBaseBytes,
                    totalBytes: totalBytes
                )
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: destination.appendingPathExtension("part"))
            }
        }
        throw lastError ?? SherpaModelError.downloadFailed(model.fileName, "No download source available")
    }

    private func downloadFile(
        from url: URL,
        model: ModelFile,
        destination: URL,
        completedBaseBytes: Int64,
        totalBytes: Int64
    ) async throws {
        let request = URLRequest(url: url)
        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw SherpaModelError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let expected = max(httpResponse.expectedContentLength, model.approximateBytes)
        let temp = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var fileBytesReceived: Int64 = 0
        var lastReportedFraction: Double = -1

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                fileBytesReceived += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let fraction = (Double(completedBaseBytes) + Double(fileBytesReceived) * Double(model.approximateBytes) / Double(max(1, expected))) / Double(totalBytes)
                if fraction - lastReportedFraction >= 0.005 {
                    lastReportedFraction = fraction
                    downloadProgress = min(0.99, max(0, fraction))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            fileBytesReceived += Int64(buffer.count)
        }
        try? handle.close()

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
