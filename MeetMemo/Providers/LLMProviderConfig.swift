import Foundation

struct LLMProviderConfig: Codable, Hashable {
    var apiKey: String
    var baseURL: String = ""
    var model: String
    /// Runtime routing metadata, shared by all requests for one meeting.
    var sessionID: String? = nil

    private static let utilitySessionID = UUID().uuidString

    func applyGoRoutingHeaders(to request: inout URLRequest) {
        guard let url = request.url,
              url.host?.lowercased() == "opencode.ai",
              url.path.hasPrefix("/zen/go/") else { return }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        request.setValue("MeetMemo/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID ?? Self.utilitySessionID, forHTTPHeaderField: "x-opencode-session")
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    var apiStyle: LLMAPIStyle {
        let lowercasedBaseURL = normalizedBaseURL.lowercased()
        if lowercasedBaseURL.contains("anthropic.com") || lowercasedBaseURL.hasSuffix("/v1/messages") {
            return .anthropicMessages
        }

        return .openAICompatibleChatCompletions
    }

    var configurationIssue: String? {
        guard let components = URLComponents(string: normalizedBaseURL),
              let host = components.host?.lowercased() else {
            return nil
        }

        let path = components.path.lowercased()

        if host == "ark.cn-beijing.volces.com", path == "/api/coding" || path == "/api/coding/" {
            return "当前 Base URL 少了 API 版本号。火山方舟普通模型请填写 https://ark.cn-beijing.volces.com/api/v3；Coding Plan 请填写 https://ark.cn-beijing.volces.com/api/coding/v3；如果使用 Kimi 官方 API，请填写 https://api.moonshot.cn/v1，并使用对应的 API Key。"
        }

        return nil
    }

    func requestURL(endpoint: String) throws -> URL {
        let normalizedEndpoint = endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
        let lowercasedBase = normalizedBaseURL.lowercased()
        let lowercasedEndpoint = normalizedEndpoint.lowercased()

        if lowercasedBase.hasSuffix(lowercasedEndpoint) {
            guard let url = URL(string: normalizedBaseURL) else {
                throw ProviderValidationError.invalidURL
            }
            guard url.scheme?.lowercased() == "https" else {
                throw ProviderValidationError.invalidURL
            }
            return url
        }

        let finalString: String
        if lowercasedEndpoint.hasPrefix("/v1/"), lowercasedBase.hasSuffix("/v1") {
            finalString = normalizedBaseURL + String(normalizedEndpoint.dropFirst(3))
        } else {
            finalString = normalizedBaseURL + normalizedEndpoint
        }

        guard let url = URL(string: finalString) else {
            throw ProviderValidationError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw ProviderValidationError.invalidURL
        }
        return url
    }
}

enum LLMAPIStyle: String, Codable, Hashable {
    case anthropicMessages
    case openAICompatibleChatCompletions
}
