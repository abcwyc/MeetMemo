import CryptoKit
import Foundation

/// 本地 Confucius4-R2T2 (MLX) 引擎的模型下载管理。
///
/// 从用户自托管镜像下载量化模型（按机器内存自动选档）到
/// `Application Support/MeetMemo/confucius-r2t2/<tier>/`，供外部
/// `ws_server.py` 自动发现加载。下载器复刻 `SherpaModelManager` 的
/// 断点续传 + SHA256 校验模式（自包含实现，避免改动现有引擎的关键路径）。
@MainActor
final class ConfuciusModelManager: ObservableObject {
    static let shared = ConfuciusModelManager()

    @Published private(set) var isReady = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var installError: String?

    struct ModelFile {
        let fileName: String
        let bytes: Int64
        let sha256: String
    }

    struct Tier {
        let directoryName: String
        let shortName: String
        let displayName: String
        let gigabytes: String
        let files: [ModelFile]
    }

    // swiftlint:disable:next line_length
    static let tier8bit = Tier(
        directoryName: "MeetMemo-Confucius4-R2T2-mlx-8bit",
        shortName: "8bit",
        displayName: "8bit（无损）",
        gigabytes: "2.6GB",
        files: files(
            weights: ("ed996f6a0762cd24fa9ae1a0622c67644886f9c53a69d97a669ef015fea67518", 2_755_024_453),
            notice: ("00b471ae2e8be6b3882f658ac44433c739cd562ea0bafb13df3e71e17c8909f5", 2_015),
            quantConfig: ("bd523142ff2ef4c80bc118d9361304d87ca2565cc64cf47068089c4ef442f200", 71)
        )
    )

    static let tier4bitEnc = Tier(
        directoryName: "MeetMemo-Confucius4-R2T2-mlx-4bit-enc",
        shortName: "4bit",
        displayName: "4bit（低内存）",
        gigabytes: "1.5GB",
        files: files(
            weights: ("e701e6a2b504ee0a26c3dbc2a57f2509d1657893d08a84ad31fd9d5396512649", 1_600_478_193),
            notice: ("d5a74ca74ab682c5a1d85122aa20328cd59dd5bf02510167717df592967b490c", 2_019),
            quantConfig: ("050bdf4f0e0dcf52fad63afe985f7413defce931b049896031c75d195be639dd", 70)
        )
    )

    /// 两档共有的小文件（内容一致，哈希相同）；三个随档位不同的文件显式传入。
    private static func files(
        weights: (String, Int64),
        notice: (String, Int64),
        quantConfig: (String, Int64)
    ) -> [ModelFile] {
        [
            .init(fileName: "LICENSE-NETEASE", bytes: 11_071, sha256: "4d9321cdad58182faa878b015de7d60069881614ddd7571de70f751a9b8e3811"),
            .init(fileName: "LICENSE-NETEASE-zh", bytes: 7_733, sha256: "18b438311ebb842c15a7c91d9db59034efdaf6fff0d105031ef7baf5eeed275"),
            .init(fileName: "NOTICE.md", bytes: notice.1, sha256: notice.0),
            .init(fileName: "added_tokens.json", bytes: 1_566, sha256: "de40784677cbd1843cabe5fbee078c7e042cd0b62155f0810af5a13842e5722a"),
            .init(fileName: "chat_template.json", bytes: 1_161, sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
            .init(fileName: "config.json", bytes: 6_195, sha256: "829b3b9cea085a46459353609774b08e4898924253ae6d623c2b4cd855386b23"),
            .init(fileName: "generation_config.json", bytes: 142, sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
            .init(fileName: "merges.txt", bytes: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            .init(fileName: "model.safetensors", bytes: weights.1, sha256: weights.0),
            .init(fileName: "preprocessor_config.json", bytes: 330, sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
            .init(fileName: "quant_config.json", bytes: quantConfig.1, sha256: quantConfig.0),
            .init(fileName: "special_tokens_map.json", bytes: 1_008, sha256: "7b376c510ccf9d88bb9bbee41dfc5052122e16e0dec1124a8d8983c59259a9f3"),
            .init(fileName: "tokenizer.json", bytes: 11_429_499, sha256: "0499602714160467f2d68b910651d6216020689f1e016be87a2d0019ee3baeab"),
            .init(fileName: "tokenizer_config.json", bytes: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            .init(fileName: "vocab.json", bytes: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ]
    }

    static let downloadBase = "https://file.348580.xyz/drive"

    /// 按物理内存选档：≤10GB 用 4bit+enc，否则 8bit。
    static func preferredTier() -> Tier {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        return totalBytes <= 10 * 1024 * 1024 * 1024 ? tier4bitEnc : tier8bit
    }

    let modelRoot: URL
    var tierDirectory: URL {
        modelRoot.appendingPathComponent(Self.preferredTier().directoryName, isDirectory: true)
    }

    var activeTier: Tier { Self.preferredTier() }

    private var activeDownloadSession: URLSession?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.modelRoot = base.appendingPathComponent("MeetMemo/confucius-r2t2", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        Task { await self.refreshReadiness() }
    }

    // MARK: - 就绪检查

    /// 快速检查：文件存在且大小一致（哈希校验只在下载完成时做一次，
    /// 避免每次刷新都对 2.6GB 权重做全文件 SHA256）。
    func filesReady(_ tier: Tier) -> Bool {
        let dir = modelRoot.appendingPathComponent(tier.directoryName, isDirectory: true)
        for file in tier.files {
            let url = dir.appendingPathComponent(file.fileName)
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
                  size == file.bytes else {
                return false
            }
        }
        return true
    }

    func refreshReadiness() async {
        isReady = filesReady(activeTier)
    }

    // MARK: - 下载

    func installModels() async throws {
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

        let tier = activeTier
        let dir = modelRoot.appendingPathComponent(tier.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let totalBytes = tier.files.reduce(Int64(0)) { $0 + $1.bytes }
        var completedBytes: Int64 = 0

        do {
            for file in tier.files {
                let destination = dir.appendingPathComponent(file.fileName)
                if FileManager.default.fileExists(atPath: destination.path),
                   (try? Self.sha256Hex(of: destination)) == file.sha256 {
                    completedBytes += file.bytes
                    downloadProgress = min(0.99, Double(completedBytes) / Double(totalBytes))
                    continue
                }

                try await downloadFile(
                    from: URL(string: "\(Self.downloadBase)/\(tier.directoryName)/\(file.fileName)")!,
                    sha256: file.sha256,
                    destination: destination,
                    completedBaseBytes: completedBytes,
                    fileBytes: file.bytes,
                    totalBytes: totalBytes
                )
                completedBytes += file.bytes
                downloadProgress = min(0.99, Double(completedBytes) / Double(totalBytes))
            }
            isReady = true
        } catch {
            installError = LanguageManager.shared.t(
                "下载 \(tier.shortName) 模型失败：\(error.localizedDescription)",
                "Failed to download the \(tier.shortName) model: \(error.localizedDescription)"
            )
            throw error
        }
    }

    func cancelDownload() {
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
    }

    // MARK: - 下载单文件（复刻 SherpaModelManager 的断点续传模式）

    private func downloadFile(
        from url: URL,
        sha256: String,
        destination: URL,
        completedBaseBytes: Int64,
        fileBytes: Int64,
        totalBytes: Int64
    ) async throws {
        let temp = destination.appendingPathExtension("part")
        let resumeOffset = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0

        let delegate = ConfuciusDownloadDelegate(tempURL: temp, resumeOffset: resumeOffset) { received, expected in
            let expectedTotal = max(expected, fileBytes)
            let fraction = (Double(completedBaseBytes)
                + Double(received) * Double(fileBytes) / Double(max(1, expectedTotal)))
                / Double(totalBytes)
            Task { @MainActor in
                self.downloadProgress = min(0.99, max(0, fraction))
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
            throw ConfuciusModelError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let actual = try Self.sha256Hex(of: temp)
        guard actual == sha256 else {
            try? FileManager.default.removeItem(at: temp)
            throw ConfuciusModelError.integrityCheckFailed
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    static func sha256Hex(of url: URL) throws -> String {
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

enum ConfuciusModelError: LocalizedError {
    case httpError(Int)
    case integrityCheckFailed

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .httpError(let code):
            return lang.t("下载失败，HTTP \(code)", "Download failed with HTTP \(code)")
        case .integrityCheckFailed:
            return lang.t(
                "模型文件校验失败，可能已损坏，请重试。",
                "Model file failed integrity check; please retry."
            )
        }
    }
}

private final class ConfuciusDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
