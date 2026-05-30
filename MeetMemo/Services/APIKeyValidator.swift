import Foundation

/// Validates service credentials for note generation.
final class APIKeyValidator {
    static let shared = APIKeyValidator()

    private init() {}

    func currentSTTConfig() -> STTProviderConfig {
        STTProviderConfig(
            locale: Locale(identifier: UserDefaultsManager.shared.sttLocaleIdentifier),
            engine: UserDefaultsManager.shared.sttEngine
        )
    }

    func currentLLMConfig() -> LLMProviderConfig {
        let providerConfig = KeychainHelper.shared.getProviderConfig() ?? Settings()
        return LLMProviderConfig(
            apiKey: providerConfig.llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: providerConfig.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: providerConfig.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func validateLLMConfig(_ config: LLMProviderConfig) async -> Result<Void, ProviderValidationError> {
        guard config.isConfigured else {
            return .failure(.missingLLMConfig)
        }

        guard let components = URLComponents(string: config.normalizedBaseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.isEmpty == false else {
            return .failure(.invalidURL)
        }

        if let issue = config.configurationIssue {
            return .failure(.httpError(issue))
        }

        return .success(())
    }

    func validateCurrentConfig() async -> Result<Void, ProviderValidationError> {
        let providerConfig = KeychainHelper.shared.getProviderConfig() ?? Settings()
        let llmConfig = LLMProviderConfig(
            apiKey: providerConfig.llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: providerConfig.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: providerConfig.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return await validateLLMConfig(llmConfig)
    }
}

enum ProviderValidationError: Error, LocalizedError {
    case missingLLMConfig
    case invalidURL
    case invalidResponse
    case networkError(String)
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .missingLLMConfig:
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
