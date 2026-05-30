import Foundation
import Speech

@MainActor
final class SpeechModelInstaller: ObservableObject {
    static let shared = SpeechModelInstaller()

    @Published var isModelReady = false
    @Published var isInstalling = false
    @Published var installProgress: Double?
    @Published var installError: String?
    @Published var speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @Published var resolvedLocaleIdentifier: String?

    var primaryLocale: Locale {
        Locale(identifier: UserDefaultsManager.shared.sttLocaleIdentifier)
    }

    var isSpeechAuthorized: Bool {
        speechAuthorizationStatus == .authorized
    }

    var speechAuthorizationLabel: String {
        let lang = LanguageManager.shared
        switch speechAuthorizationStatus {
        case .authorized:
            return lang.t("已授权", "Granted")
        case .denied:
            return lang.t("已拒绝", "Denied")
        case .restricted:
            return lang.t("受限制", "Restricted")
        case .notDetermined:
            return lang.t("未授权", "Not Granted")
        @unknown default:
            return lang.t("未知", "Unknown")
        }
    }

    private init() {
        Task { await checkModelAvailability() }
    }

    func checkModelAvailability() async {
        speechAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        installError = nil

        do {
            let locale = try await Self.resolvedLocale(for: primaryLocale)
            resolvedLocaleIdentifier = locale.identifier
            let transcriber = Self.makeTranscriber(locale: locale, includeTimeRange: false, includeVolatileResults: false)
            let status = await AssetInventory.status(forModules: [transcriber])
            isModelReady = status == .installed
            if status == .unsupported {
                throw SpeechModelInstallerError.localeNotSupported(primaryLocale)
            }
        } catch {
            isModelReady = false
            installError = error.localizedDescription
        }
    }

    func installModelIfNeeded() async {
        let status = await requestSpeechAuthorization()
        guard status == .authorized else {
            isModelReady = false
            installError = SpeechModelInstallerError.authorizationFailed(status).localizedDescription
            return
        }

        do {
            _ = try await installModelIfNeeded(for: primaryLocale)
        } catch {
            installError = error.localizedDescription
        }
    }

    func installModel() async {
        let status = await requestSpeechAuthorization()
        guard status == .authorized else {
            isModelReady = false
            installError = SpeechModelInstallerError.authorizationFailed(status).localizedDescription
            return
        }

        do {
            _ = try await installModelIfNeeded(for: primaryLocale, force: true)
        } catch {
            installError = error.localizedDescription
        }
    }

    func refreshSpeechAuthorizationStatus() {
        speechAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else {
            speechAuthorizationStatus = current
            return current
        }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        speechAuthorizationStatus = status
        return status
    }

    @discardableResult
    func ensureReadyForUse(for requestedLocale: Locale? = nil) async throws -> Locale {
        let status = await requestSpeechAuthorization()
        guard status == .authorized else {
            throw SpeechModelInstallerError.authorizationFailed(status)
        }

        return try await installModelIfNeeded(for: requestedLocale ?? primaryLocale)
    }

    @discardableResult
    private func installModelIfNeeded(for requestedLocale: Locale, force: Bool = false) async throws -> Locale {
        if isInstalling {
            while isInstalling {
                try await Task.sleep(for: .milliseconds(250))
            }
            await checkModelAvailability()
            if isModelReady {
                return try await Self.resolvedLocale(for: requestedLocale)
            }
        }

        isInstalling = true
        installProgress = nil
        installError = nil
        defer { isInstalling = false }

        do {
            let locale = try await Self.resolvedLocale(for: requestedLocale)
            resolvedLocaleIdentifier = locale.identifier
            let transcriber = Self.makeTranscriber(locale: locale, includeTimeRange: false, includeVolatileResults: false)
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .installed && !force {
                isModelReady = true
                return locale
            }

            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progress = request.progress
                installProgress = progress.fractionCompleted
                let progressTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        self?.installProgress = progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer {
                    progressTask.cancel()
                    installProgress = nil
                }
                try await request.downloadAndInstall()
            }
            await checkModelAvailability()
            guard isModelReady else {
                throw SpeechModelInstallerError.modelNotInstalled(locale)
            }
            return locale
        } catch {
            let message = LanguageManager.shared.t(
                "语音识别模型准备失败：\(error.localizedDescription)",
                "Speech model setup failed: \(error.localizedDescription)"
            )
            installError = message
            throw SpeechModelInstallerError.setupFailed(message)
        }
    }

    nonisolated static func makeTranscriber(
        locale: Locale,
        includeTimeRange: Bool,
        includeVolatileResults: Bool
    ) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: includeVolatileResults ? [.volatileResults] : [],
            attributeOptions: includeTimeRange ? [.audioTimeRange] : []
        )
    }

    nonisolated static func resolvedLocale(for requestedLocale: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechModelInstallerError.speechTranscriberUnavailable
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SpeechModelInstallerError.localeNotSupported(requestedLocale)
        }

        return locale
    }
}

enum SpeechModelInstallerError: LocalizedError {
    case speechTranscriberUnavailable
    case authorizationFailed(SFSpeechRecognizerAuthorizationStatus)
    case localeNotSupported(Locale)
    case modelNotInstalled(Locale)
    case setupFailed(String)

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .speechTranscriberUnavailable:
            return lang.t(
                "此设备不支持 macOS 内置语音识别。",
                "This device does not support macOS on-device speech recognition."
            )
        case .authorizationFailed(let status):
            switch status {
            case .denied:
                return lang.t(
                    "语音识别权限已被拒绝，请在系统设置中允许 MeetMemo 使用语音识别。",
                    "Speech recognition permission was denied. Allow MeetMemo to use Speech Recognition in System Settings."
                )
            case .restricted:
                return lang.t(
                    "此设备上的语音识别权限受限制。",
                    "Speech recognition is restricted on this device."
                )
            default:
                return lang.t(
                    "需要语音识别权限才能开始转录。",
                    "Speech recognition permission is required before transcription can start."
                )
            }
        case .localeNotSupported(let locale):
            return lang.t(
                "当前语音识别语言不受支持：\(locale.identifier)。",
                "The selected speech recognition language is not supported: \(locale.identifier)."
            )
        case .modelNotInstalled(let locale):
            return lang.t(
                "语音识别模型未安装：\(locale.identifier)。",
                "The speech recognition model is not installed: \(locale.identifier)."
            )
        case .setupFailed(let message):
            return message
        }
    }
}
