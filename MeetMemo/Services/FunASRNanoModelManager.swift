import Foundation

@MainActor
final class FunASRNanoModelManager: ObservableObject {
    static let shared = FunASRNanoModelManager()

    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var lastDevice: String?
    @Published private(set) var downloadProgress: Double?
    @Published var errorMessage: String?

    private init() {
        Task { await refreshReadiness() }
    }

    func refreshReadiness() async {
        isReady = SherpaModelManager.shared.modelFilesReady(SherpaModelManager.funASRNanoModelFiles)
        if isReady { lastDevice = "CPU (sherpa-onnx)" }
    }

    /// Downloads the Fun-ASR-Nano int8 model set (~1 GB) via the shared sherpa-onnx
    /// downloader. Silero VAD + CAM++ are part of the set and reused for diarization.
    func prepareModels() async {
        guard !isPreparing else { return }
        isPreparing = true
        downloadProgress = 0
        errorMessage = nil
        defer {
            isPreparing = false
            downloadProgress = nil
        }

        do {
            try await SherpaModelManager.shared.downloadModelFiles(
                SherpaModelManager.funASRNanoModelFiles
            ) { [weak self] progress in
                self?.downloadProgress = progress
            }
            await refreshReadiness()
            if !isReady {
                errorMessage = LanguageManager.shared.t(
                    "模型下载后校验未通过，请重试。",
                    "Models failed verification after download. Please retry."
                )
            }
        } catch {
            isReady = false
            errorMessage = ErrorHandler.shared.handleError(error)
        }
    }

    var cacheSizeText: String {
        let bytes = Self.directorySize(SherpaModelManager.shared.funASRNanoDirectory)
        guard bytes > 0 else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

enum FunASRNanoError: LocalizedError {
    case modelsNotReady

    var errorDescription: String? {
        switch self {
        case .modelsNotReady:
            return LanguageManager.shared.t(
                "Fun-ASR-Nano 模型尚未下载。请先在设置中下载模型。",
                "Fun-ASR-Nano models are not downloaded yet. Download them in Settings first."
            )
        }
    }
}
