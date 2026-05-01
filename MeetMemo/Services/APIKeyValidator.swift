import Foundation

/// Validates service credentials for transcription and note generation.
final class APIKeyValidator {
    static let shared = APIKeyValidator()

    private init() {}

    func currentSTTConfig() -> STTProviderConfig {
        STTProviderConfig(
            appId: (KeychainHelper.shared.getSTTAppId() ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: (KeychainHelper.shared.getSTTAccessToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func currentLLMConfig() -> LLMProviderConfig {
        LLMProviderConfig(
            apiKey: (KeychainHelper.shared.getLLMApiKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: (KeychainHelper.shared.getLLMBaseURL() ?? LLMProviderConfig.defaultBaseURL).trimmingCharacters(in: .whitespacesAndNewlines),
            model: (KeychainHelper.shared.getLLMModel() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func validateSTTConfig(_ config: STTProviderConfig) async -> Result<Void, ProviderValidationError> {
        guard config.isConfigured else {
            return .failure(.missingSTTConfig)
        }

        return .success(())
    }

    func validateLLMConfig(_ config: LLMProviderConfig) async -> Result<Void, ProviderValidationError> {
        guard config.isConfigured else {
            return .failure(.missingLLMConfig)
        }

        guard let components = URLComponents(string: config.normalizedBaseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            return .failure(.invalidURL)
        }

        if let issue = config.configurationIssue {
            return .failure(.httpError(issue))
        }

        return .success(())
    }

    func validateCurrentConfig() async -> Result<Void, ProviderValidationError> {
        let sttConfig = currentSTTConfig()
        let llmConfig = currentLLMConfig()

        let sttValidation = await validateSTTConfig(sttConfig)
        guard case .success = sttValidation else {
            return sttValidation
        }

        return await validateLLMConfig(llmConfig)
    }
}

enum ProviderValidationError: Error, LocalizedError {
    case missingSTTConfig
    case missingLLMConfig
    case invalidURL
    case invalidResponse
    case networkError(String)
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .missingSTTConfig, .missingLLMConfig:
            return ErrorMessage.noAPIKey
        case .invalidURL:
            return ErrorMessage.invalidURL
        case .invalidResponse:
            return ErrorMessage.noModelsAvailable
        case .networkError(let message):
            return message
        case .httpError(let message):
            return message
        }
    }
}
