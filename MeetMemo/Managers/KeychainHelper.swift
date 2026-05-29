// KeychainHelper.swift
// Secure storage helper for API keys and sensitive data

import Foundation
import LocalAuthentication
import Security

enum ProviderConfigLoadResult {
    case success(Settings)
    case notFound
    case authenticationFailed
    case unavailable(OSStatus)
}

/// Manages secure storage of sensitive data using the macOS Keychain
class KeychainHelper {
    static let shared = KeychainHelper()
    
    private let serviceName = "youcai.meetmemo"
    private let providerConfigKey = "providerConfig"
    private let legacyProviderKeys = [
        "llmApiKey",
        "llmBaseURL",
        "llmModel"
    ]
    
    private init() {}

    // MARK: - Provider configuration

    func getProviderConfig() -> Settings? {
        guard case .success(let settings) = loadProviderConfig() else {
            return nil
        }

        return settings
    }

    func loadProviderConfig() -> ProviderConfigLoadResult {
        switch getCodableResult(forKey: providerConfigKey) as KeychainLookupResult<Settings> {
        case .success(let settings):
            return .success(settings)
        case .notFound:
            break
        case .authenticationFailed:
            return .authenticationFailed
        case .unavailable(let status):
            return .unavailable(status)
        case .decodeFailed:
            return .unavailable(errSecDecode)
        }

        guard let legacySettings = getLegacyProviderConfigWithoutAuthentication() else {
            return .notFound
        }

        _ = saveProviderConfig(legacySettings)
        return .success(legacySettings)
    }

    func saveProviderConfig(_ settings: Settings) -> Bool {
        saveCodable(settings, forKey: providerConfigKey)
    }
    
    /// Gets the API key directly from keychain
    /// - Returns: The API key string if found, nil otherwise
    func getAPIKey() -> String? {
        return get(forKey: "openAIKey")
    }

    func getAPIKeyWithoutAuthentication() -> String? {
        guard let data = getData(forKey: "openAIKey", allowAuthentication: false) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
    
    /// Saves the API key to keychain
    /// - Parameter apiKey: The API key to save
    /// - Returns: True if the save was successful, false otherwise
    func saveAPIKey(_ apiKey: String) -> Bool {
        return save(apiKey, forKey: "openAIKey")
    }

    // MARK: - LLM Provider
    func getLLMApiKey() -> String? {
        getProviderConfig()?.llmApiKey
    }

    func saveLLMApiKey(_ value: String) -> Bool {
        var settings = getProviderConfig() ?? Settings()
        settings.llmApiKey = value
        return saveProviderConfig(settings)
    }

    func getLLMBaseURL() -> String? {
        getProviderConfig()?.llmBaseURL
    }

    func saveLLMBaseURL(_ value: String) -> Bool {
        var settings = getProviderConfig() ?? Settings()
        settings.llmBaseURL = value
        return saveProviderConfig(settings)
    }

    func getLLMModel() -> String? {
        getProviderConfig()?.llmModel
    }

    func saveLLMModel(_ value: String) -> Bool {
        var settings = getProviderConfig() ?? Settings()
        settings.llmModel = value
        return saveProviderConfig(settings)
    }
    
    /// Saves a string value to the keychain
    /// - Parameters:
    ///   - value: The string value to save
    ///   - key: The key to save the value under
    /// - Returns: True if the save was successful, false otherwise
    func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        return saveData(data, forKey: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            return saveData(data, forKey: key)
        } catch {
            return false
        }
    }

    private func saveData(_ data: Data, forKey key: String) -> Bool {
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName
        ]

        let exists = SecItemCopyMatching(lookupQuery as CFDictionary, nil) == errSecSuccess
        if exists {
            let updates: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(lookupQuery as CFDictionary, updates as CFDictionary) == errSecSuccess
        } else {
            var addQuery = lookupQuery
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
    }
    
    /// Retrieves a string value from the keychain
    /// - Parameter key: The key to retrieve the value for
    /// - Returns: The string value if found, nil otherwise
    func get(forKey key: String) -> String? {
        guard let data = getData(forKey: key, allowAuthentication: true) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func getCodable<T: Decodable>(forKey key: String) -> T? {
        guard case .success(let value) = getCodableResult(forKey: key) as KeychainLookupResult<T> else {
            return nil
        }

        return value
    }

    private func getCodableResult<T: Decodable>(forKey key: String) -> KeychainLookupResult<T> {
        switch getDataResult(forKey: key, allowAuthentication: true) {
        case .success(let data):
            do {
                return .success(try JSONDecoder().decode(T.self, from: data))
            } catch {
                return .decodeFailed
            }
        case .notFound:
            return .notFound
        case .authenticationFailed:
            return .authenticationFailed
        case .unavailable(let status):
            return .unavailable(status)
        case .decodeFailed:
            return .decodeFailed
        }
    }

    private func getLegacyProviderConfigWithoutAuthentication() -> Settings? {
        let values = legacyProviderKeys.reduce(into: [String: String]()) { result, key in
            guard let data = getData(forKey: key, allowAuthentication: false),
                  let value = String(data: data, encoding: .utf8) else {
                return
            }

            result[key] = value
        }

        let hasLegacyConfig = values.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard hasLegacyConfig else {
            return nil
        }

        return Settings(
            llmApiKey: values["llmApiKey"] ?? "",
            llmBaseURL: values["llmBaseURL"] ?? "",
            llmModel: values["llmModel"] ?? ""
        )
    }

    private func getData(forKey key: String, allowAuthentication: Bool) -> Data? {
        guard case .success(let data) = getDataResult(forKey: key, allowAuthentication: allowAuthentication) else {
            return nil
        }

        return data
    }

    private func getDataResult(forKey key: String, allowAuthentication: Bool) -> KeychainLookupResult<Data> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        if !allowAuthentication {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            switch status {
            case errSecItemNotFound:
                return .notFound
            case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
                return .authenticationFailed
            default:
                return .unavailable(status)
            }
        }

        guard let data = item as? Data else {
            return .decodeFailed
        }

        return .success(data)
    }
    
    /// Deletes a value from the keychain
    /// - Parameter key: The key to delete
    /// - Returns: True if the deletion was successful, false otherwise
    func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}

private enum KeychainLookupResult<Value> {
    case success(Value)
    case notFound
    case authenticationFailed
    case unavailable(OSStatus)
    case decodeFailed
}
