// KeychainHelper.swift
// Secure storage helper for API keys and sensitive data

import Foundation
import LocalAuthentication
import Security

/// Manages secure storage of sensitive data using the macOS Keychain
class KeychainHelper {
    static let shared = KeychainHelper()
    
    private let serviceName = "youcai.meetmemo"
    private let providerConfigKey = "providerConfig"
    private let legacyProviderKeys = [
        "sttAppId",
        "sttAccessToken",
        "llmApiKey",
        "llmBaseURL",
        "llmModel"
    ]
    
    private init() {}

    // MARK: - Provider configuration

    func getProviderConfig() -> Settings? {
        if let settings: Settings = getCodable(forKey: providerConfigKey) {
            return settings
        }

        guard let legacySettings = getLegacyProviderConfigWithoutAuthentication() else {
            return nil
        }

        _ = saveProviderConfig(legacySettings)
        return legacySettings
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

    // MARK: - STT Provider
    func getSTTAppId() -> String? {
        getProviderConfig()?.sttAppId
    }

    func saveSTTAppId(_ value: String) -> Bool {
        var settings = getProviderConfig() ?? Settings()
        settings.sttAppId = value
        return saveProviderConfig(settings)
    }

    func getSTTAccessToken() -> String? {
        getProviderConfig()?.sttAccessToken
    }

    func saveSTTAccessToken(_ value: String) -> Bool {
        var settings = getProviderConfig() ?? Settings()
        settings.sttAccessToken = value
        return saveProviderConfig(settings)
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
        guard let data = getData(forKey: key, allowAuthentication: true) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
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
            sttAppId: values["sttAppId"] ?? "",
            sttAccessToken: values["sttAccessToken"] ?? "",
            llmApiKey: values["llmApiKey"] ?? "",
            llmBaseURL: values["llmBaseURL"] ?? LLMProviderConfig.defaultBaseURL,
            llmModel: values["llmModel"] ?? ""
        )
    }

    private func getData(forKey key: String, allowAuthentication: Bool) -> Data? {
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
        
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
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
