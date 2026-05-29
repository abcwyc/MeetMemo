import Foundation
import Speech

@MainActor
final class SpeechModelInstaller: ObservableObject {
    static let shared = SpeechModelInstaller()

    @Published var isModelReady = false
    @Published var isInstalling = false
    @Published var installError: String?

    var primaryLocale: Locale {
        Locale(identifier: UserDefaultsManager.shared.sttLocaleIdentifier)
    }

    private init() {
        Task { await checkModelAvailability() }
    }

    func checkModelAvailability() async {
        let installed = await SpeechTranscriber.installedLocales
        isModelReady = installed.contains(primaryLocale)
    }

    func installModelIfNeeded() async {
        await checkModelAvailability()
        guard !isModelReady else { return }
        await installModel()
    }

    func installModel() async {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil
        defer { isInstalling = false }

        do {
            let transcriber = SpeechTranscriber(
                locale: primaryLocale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            await checkModelAvailability()
        } catch {
            installError = LanguageManager.shared.t(
                "语音识别模型安装失败：\(error.localizedDescription)",
                "Speech model installation failed: \(error.localizedDescription)"
            )
        }
    }
}
