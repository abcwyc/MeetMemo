import Foundation
import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var settings = Settings()
    @Published var activeAlert: AlertMessage?
    @Published var isTestingSTT = false
    @Published var isTestingLLM = false
    @Published var templates: [NoteTemplate] = []
    
    init() {
        loadTemplates()
        performProviderMigrationIfNeeded()
        loadProviderConfig()
    }
    
    /// Loads provider credentials from keychain.
    func loadProviderConfig() {
        settings.sttAppId = (KeychainHelper.shared.getSTTAppId() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        settings.sttAccessToken = (KeychainHelper.shared.getSTTAccessToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        settings.llmApiKey = (KeychainHelper.shared.getLLMApiKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let storedBaseURL = KeychainHelper.shared.getLLMBaseURL() ?? LLMProviderConfig.defaultBaseURL
        settings.llmBaseURL = storedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LLMProviderConfig.defaultBaseURL
            : storedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        settings.llmModel = (KeychainHelper.shared.getLLMModel() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func loadTemplates() {
        templates = LocalStorageManager.shared.loadTemplates()
        
        // Validate that the selected template still exists
        if let selectedId = settings.selectedTemplateId {
            if !templates.contains(where: { $0.id == selectedId }) {
                // Selected template was deleted, clear the selection
                settings.selectedTemplateId = nil
            }
        }
        
        // If no template is selected, select the first default template
        if settings.selectedTemplateId == nil {
            if let defaultTemplate = templates.first(where: { $0.title == "标准会议" || $0.title == "Standard Meeting" }) {
                settings.selectedTemplateId = defaultTemplate.id
            } else if let firstTemplate = templates.first {
                // Fallback to first available template
                settings.selectedTemplateId = firstTemplate.id
            }
        }
    }
    
    func saveSettings(showMessage: Bool = true) {
        let lang = LanguageManager.shared
        // Validate that systemPrompt contains all required template placeholders
        let requiredKeys = ["meeting_title", "meeting_date", "transcript", "user_blurb", "template_content"]
        let contextKeys = ["meeting_context", "user_notes"]
        let hasContextPlaceholder = contextKeys.contains { settings.systemPrompt.contains("{{\($0)}}") }
        let missing = requiredKeys.filter { !settings.systemPrompt.contains("{{\($0)}}") }
        if !missing.isEmpty || !hasContextPlaceholder {
            var missingPlaceholders = missing.map { "{{\($0)}}" }
            if !hasContextPlaceholder {
                missingPlaceholders.append("{{meeting_context}}")
            }
            if showMessage {
                activeAlert = AlertMessage(
                    title: lang.t("设置保存失败", "Settings Save Failed"),
                    message: lang.t(
                        "无法保存设置：系统提示词中缺少占位符 \(missingPlaceholders.joined(separator: ", "))",
                        "Cannot save settings: missing placeholders \(missingPlaceholders.joined(separator: ", ")) in system prompt"
                    )
                )
            }
            return
        }

        let normalizedBaseURL = settings.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LLMProviderConfig.defaultBaseURL
            : settings.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        settings.sttAppId = settings.sttAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.sttAccessToken = settings.sttAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.llmApiKey = settings.llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.llmBaseURL = normalizedBaseURL
        settings.llmModel = settings.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)

        let saves = [
            KeychainHelper.shared.saveSTTAppId(settings.sttAppId),
            KeychainHelper.shared.saveSTTAccessToken(settings.sttAccessToken),
            KeychainHelper.shared.saveLLMApiKey(settings.llmApiKey),
            KeychainHelper.shared.saveLLMBaseURL(settings.llmBaseURL),
            KeychainHelper.shared.saveLLMModel(settings.llmModel)
        ]
        let allSaved = saves.allSatisfy { $0 }

        if showMessage {
            if allSaved {
                activeAlert = AlertMessage(
                    title: lang.t("设置已保存", "Settings Saved"),
                    message: lang.t("设置保存成功！", "Settings saved successfully!")
                )
            } else {
                activeAlert = AlertMessage(
                    title: lang.t("设置保存失败", "Settings Save Failed"),
                    message: lang.t("保存设置时出错", "Error saving settings")
                )
            }
        }
    }

    func testSTTConnection() {
        let lang = LanguageManager.shared
        let config = currentEditableSTTConfig()

        guard config.isConfigured else {
            presentTestResult(
                title: lang.t("语音识别测试失败", "Speech Recognition Test Failed"),
                message: ErrorMessage.noAPIKey
            )
            return
        }

        isTestingSTT = true

        Task {
            await MainActor.run {
                self.isTestingSTT = true
            }

            do {
                try await DoubaoSTTProvider().testConnection(config: config)
                await MainActor.run {
                    self.presentTestResult(
                        title: lang.t("语音识别测试成功", "Speech Recognition Test Succeeded"),
                        message: lang.t("APP ID 和 Access Token 可以连通服务器。", "APP ID and Access Token connected to the server successfully.")
                    )
                }
            } catch {
                let message = ErrorHandler.shared.handleError(error)
                await MainActor.run {
                    self.presentTestResult(title: lang.t("语音识别测试失败", "Speech Recognition Test Failed"), message: message)
                }
            }

            await MainActor.run {
                self.isTestingSTT = false
            }
        }
    }

    func testLLMConnection() {
        let lang = LanguageManager.shared
        let config = currentEditableLLMConfig()

        guard config.isConfigured else {
            presentTestResult(
                title: lang.t("LLM 测试失败", "LLM Test Failed"),
                message: ErrorMessage.noAPIKey
            )
            return
        }

        isTestingLLM = true

        Task {
            await MainActor.run {
                self.isTestingLLM = true
            }

            let validation = await APIKeyValidator.shared.validateLLMConfig(config)
            guard case .success = validation else {
                let message: String
                switch validation {
                case .failure(let error):
                    message = error.localizedDescription
                case .success:
                    message = ErrorMessage.invalidURL
                }
                await MainActor.run {
                    self.presentTestResult(title: lang.t("LLM 测试失败", "LLM Test Failed"), message: message)
                }
                await MainActor.run {
                    self.isTestingLLM = false
                }
                return
            }

            do {
                try await LLMClient().testConnection(config: config)
                await MainActor.run {
                    self.presentTestResult(
                        title: lang.t("LLM 测试成功", "LLM Test Succeeded"),
                        message: lang.t("Base URL、API Key 和 Model Name 可以连通服务器。", "Base URL, API Key, and Model Name connected to the server successfully.")
                    )
                }
            } catch {
                let message = ErrorHandler.shared.handleError(error)
                await MainActor.run {
                    self.presentTestResult(title: lang.t("LLM 测试失败", "LLM Test Failed"), message: message)
                }
            }

            await MainActor.run {
                self.isTestingLLM = false
            }
        }
    }

    private func performProviderMigrationIfNeeded() {
        guard !UserDefaultsManager.shared.hasMigratedToV2Providers else {
            return
        }

        let legacyKey = KeychainHelper.shared.getAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasNewSTTConfig =
            !(KeychainHelper.shared.getSTTAppId()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty &&
            !(KeychainHelper.shared.getSTTAccessToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let hasNewLLMConfig =
            !(KeychainHelper.shared.getLLMApiKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty &&
            !(KeychainHelper.shared.getLLMModel()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty

        if !legacyKey.isEmpty && (!hasNewSTTConfig || !hasNewLLMConfig) {
            settings.hasCompletedOnboarding = false
        }

        UserDefaultsManager.shared.hasMigratedToV2Providers = true
    }

    private func currentEditableSTTConfig() -> STTProviderConfig {
        STTProviderConfig(
            appId: settings.sttAppId.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: settings.sttAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func currentEditableLLMConfig() -> LLMProviderConfig {
        let trimmedBaseURL = settings.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        return LLMProviderConfig(
            apiKey: settings.llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: trimmedBaseURL.isEmpty ? LLMProviderConfig.defaultBaseURL : trimmedBaseURL,
            model: settings.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func presentTestResult(title: String, message: String) {
        activeAlert = AlertMessage(title: title, message: message)
    }
    
    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        saveSettings(showMessage: false)
    }

    func skipOnboarding() {
        settings.hasCompletedOnboarding = true
    }
    
    func resetToDefaults() {
        settings.systemPrompt = Settings.defaultSystemPrompt()
    }
    
    func resetOnboarding() {
        settings.hasCompletedOnboarding = false
        saveSettings(showMessage: false)
        
        // Force app to restart or recreate views by posting a notification
        // This will cause ContentView to re-evaluate and show onboarding
        NotificationCenter.default.post(name: Notification.Name("OnboardingReset"), object: nil)
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
