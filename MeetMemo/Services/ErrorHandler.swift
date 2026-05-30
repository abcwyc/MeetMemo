// ErrorHandler.swift
// Centralized error handling service for network, provider, and protocol errors

import Foundation

/// Centralized error handling service
class ErrorHandler {
    static let shared = ErrorHandler()
    
    private init() {}
    
    /// Handles errors from provider calls and network requests
    /// - Parameter error: The error to handle
    /// - Returns: User-friendly error message
    func handleError(_ error: Error) -> String {
        // Handle network errors
        if let urlError = error as? URLError {
            return handleNetworkError(urlError)
        }
        
        // Handle HTTP response errors
        if let httpError = error as? HTTPError {
            return handleHTTPError(httpError)
        }
        
        // Handle provider API errors by checking error description
        let errorDescription = normalizedErrorDetail(error.localizedDescription).lowercased()
        if errorDescription.contains("message too long") {
            return "转写服务返回的消息过大。请升级到最新版本后重试，或将超长会议分段录制。"
        }

        if isConcurrencyQuotaDetail(errorDescription) {
            return ErrorMessage.sttConcurrencyQuotaExceeded
        }

        if let providerError = categorizeProviderError(errorDescription) {
            return providerError
        }

        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        
        // Generic error fallback
        return "An unexpected error occurred: \(error.localizedDescription)"
    }
    
    /// Handles WebSocket close codes
    /// - Parameter closeCode: WebSocket close code
    /// - Returns: User-friendly error message
    func handleWebSocketCloseCode(_ closeCode: Int) -> String {
        switch closeCode {
        case 1000: return "Connection closed normally"
        case 1001: return ErrorMessage.connectionLost
        case 1002: return "Connection protocol error. Please try again."
        case 1003: return ErrorMessage.unsupportedData
        case 1008: return "API policy violation. Please check your API key and account status."
        case 1011: return ErrorMessage.apiServerError
        case 4000: return ErrorMessage.badRequest
        case 4001: return ErrorMessage.invalidAPIKey
        case 4002: return ErrorMessage.accessForbidden
        case 4003: return ErrorMessage.apiEndpointNotFound
        case 4004: return "Invalid API method. Please update the app."
        case 4005: return ErrorMessage.requestTimeout
        case 4006: return ErrorMessage.requestTooLarge
        case 4007: return ErrorMessage.rateLimited
        case 4008: return ErrorMessage.insufficientFunds
        default:   return "Connection error (code \(closeCode)). Please try again."
        }
    }
    
    /// Handles HTTP status codes
    /// - Parameter statusCode: HTTP status code
    /// - Parameter message: Optional error message
    /// - Returns: User-friendly error message
    func handleHTTPStatusCode(_ statusCode: Int, message: String? = nil) -> String {
        let detail = normalizedErrorDetail(message)

        if isConcurrencyQuotaDetail(detail) {
            return ErrorMessage.sttConcurrencyQuotaExceeded
        }

        switch statusCode {
        case 200...299:
            return ErrorMessage.success
        case 400:
            return ErrorMessage.badRequest
        case 401:
            return ErrorMessage.invalidAPIKey
        case 402:
            return ErrorMessage.insufficientFunds
        case 403:
            if isModelUnsupportedDetail(detail) {
                return ErrorMessage.modelNotSupported
            }

            if isInvalidAPIKeyDetail(detail) {
                return ErrorMessage.invalidAPIKey
            }

            return ErrorMessage.accessForbidden
        case 404:
            if isModelUnsupportedDetail(detail) {
                return ErrorMessage.modelNotSupported
            }

            if !detail.isEmpty && !isHTMLResponse(detail) {
                return "\(ErrorMessage.apiEndpointNotFound) \(detail)"
            }

            return ErrorMessage.apiEndpointNotFound
        case 429:
            return ErrorMessage.rateLimited
        case 500...599:
            return ErrorMessage.apiServerError
        default:
            return "HTTP error \(statusCode): \(message ?? "Unknown error")"
        }
    }
    
    /// Determines if an error should trigger a retry
    /// - Parameter error: The error to check
    /// - Returns: True if the error is retryable
    func shouldRetry(_ error: Error) -> Bool {
        // Network errors are generally retryable
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .networkConnectionLost, .cannotConnectToHost:
                return true
            default:
                return false
            }
        }
        
        // Handle POSIX socket errors (e.g., "Socket is not connected")
        if let nsError = error as NSError?, nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case 57: // ENOTCONN - Socket is not connected
                return true
            default:
                return false
            }
        }
        
        // WebSocket close codes
        if let closeCode = (error as NSError?)?.userInfo["closeCode"] as? Int {
            return closeCode < 4000 // Only retry for non-API errors
        }
        
        return false
    }
    
    // MARK: - Private Methods
    
    private func handleNetworkError(_ urlError: URLError) -> String {
        switch urlError.code {
        case .notConnectedToInternet:
            return "No internet connection. Please check your network and try again."
        case .timedOut:
            return "Request timed out. Please try again."
        case .cannotFindHost:
            return "Cannot reach the service. Please check your internet connection."
        case .cannotConnectToHost:
            return "Cannot connect to the service. Please check your internet connection."
        case .networkConnectionLost:
            return "Network connection lost. Please try again."
        case .httpTooManyRedirects:
            return "Too many redirects. Please try again later."
        case .secureConnectionFailed:
            return "Secure connection failed. Please check your internet connection."
        case .serverCertificateUntrusted:
            return "Server certificate untrusted. Please try again."
        default:
            return "Network error: \(urlError.localizedDescription)"
        }
    }
    
    private func handleHTTPError(_ httpError: HTTPError) -> String {
        return handleHTTPStatusCode(httpError.statusCode, message: httpError.message)
    }

    private func categorizeProviderError(_ errorDescription: String) -> String? {
        let detail = errorDescription.lowercased()

        if isModelUnsupportedDetail(detail) {
            return ErrorMessage.modelNotSupported
        } else if isInvalidAPIKeyDetail(detail) {
            return ErrorMessage.invalidAPIKey
        } else if detail.contains("insufficient") || detail.contains("402") {
            return ErrorMessage.insufficientFunds
        } else if detail.contains("rate limit") || detail.contains("429") {
            return ErrorMessage.rateLimited
        } else if detail.contains("server error") || detail.contains("500") {
            return ErrorMessage.apiServerError
        } else if detail.contains("forbidden") || detail.contains("403") {
            return ErrorMessage.accessForbidden
        } else if detail.contains("not found") || detail.contains("404") {
            return ErrorMessage.apiEndpointNotFound
        }
        
        return nil
    }

    func isConcurrencyQuotaErrorMessage(_ message: String) -> Bool {
        isConcurrencyQuotaDetail(normalizedErrorDetail(message))
    }

    /// 永久性的鉴权/配置错误——重连无意义，应立即停止录音。
    func isPermanentAuthErrorMessage(_ message: String) -> Bool {
        isInvalidAPIKeyDetail(normalizedErrorDetail(message))
    }

    private func normalizedErrorDetail(_ message: String?) -> String {
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed
        }

        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let detail = error["detail"] as? String {
                return detail.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let type = error["type"] as? String, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return type.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let error = json["error"] as? String {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let message = json["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private func isHTMLResponse(_ detail: String) -> Bool {
        let normalized = detail.lowercased()
        return normalized.contains("<html")
            || normalized.contains("<!doctype html")
            || normalized.contains("<head>")
            || normalized.contains("<body>")
    }

    private func isModelUnsupportedDetail(_ detail: String) -> Bool {
        let normalized = detail.lowercased()

        return normalized.contains("unsupportedmodel")
            || normalized.contains("does not support the coding plan feature")
            || normalized.contains("model_not_found")
            || normalized.contains("model not support")
            || normalized.contains("model does not support")
            || normalized.contains("model or endpoint")
            || normalized.contains("does not exist or you do not have access to it")
            || normalized.contains("当前模型不支持")
            || normalized.contains("模型不支持")
            || normalized.contains("不支持 coding plan")
            || normalized.contains("没有该模型权限")
            || normalized.contains("无该模型权限")
    }

    private func isInvalidAPIKeyDetail(_ detail: String) -> Bool {
        let normalized = detail.lowercased()

        return normalized.contains("unauthorized")
            || normalized.contains("authenticationerror")
            || normalized.contains("api key")
            || normalized.contains("api key format is incorrect")
            || normalized.contains("missing or invalid")
            || normalized.contains("invalid api key")
            || normalized.contains("ak/sk")
            || normalized.contains("鉴权凭证")
            || normalized.contains("凭证无效")
            || normalized.contains("key is missing or invalid")
    }

    private func isConcurrencyQuotaDetail(_ detail: String) -> Bool {
        let normalized = detail.lowercased()
        return (normalized.contains("quota exceeded") && normalized.contains("concurrency"))
            || normalized.contains("并发额度")
    }

}

/// HTTP error type
struct HTTPError: Error {
    let statusCode: Int
    let message: String?
    
    init(statusCode: Int, message: String? = nil) {
        self.statusCode = statusCode
        self.message = message
    }
}

/// Common error messages
enum ErrorMessage {
    static let noAPIKey = "LLM 服务凭证未配置。请在设置中配置 Base URL、API Key 和 Model Name。"
    static let noTemplate = "No template content found. Please select a valid template."
    static let noTranscript = "No transcript available. Please record some audio first."
    static let connectionTimeout = "服务连接超时。请稍后重试。"
    static let configurationFailed = "Failed to configure transcription session."
    static let invalidURL = "Base URL 不正确。请填写可访问的 LLM 服务根地址。"
    static let noModelsAvailable = "No models available with your API key. Please check your account status."

    // Centralized messages used across handlers
    static let success = "Success"
    static let badRequest = "Bad request. Please check your input."
    static let invalidAPIKey = "LLM 凭证无效，请检查 Base URL、API Key 和 Model Name。"
    static let modelNotSupported = "当前模型不可用或当前账号没有该模型权限。请检查 Model Name 是否正确。"
    static let insufficientFunds = "账户余额不足，请充值。"
    static let accessForbidden = "访问被拒绝。请检查凭证权限。"
    static let apiEndpointNotFound = "API 端点不存在。请检查服务地址。OpenAI 兼容服务需要填写基础地址，例如火山方舟 https://ark.cn-beijing.volces.com/api/v3，火山方舟 Coding Plan https://ark.cn-beijing.volces.com/api/coding/v3，Kimi 官方 https://api.moonshot.cn/v1。"
    static let rateLimited = "API 请求频率超限，请稍后再试。"
    static let sttConcurrencyQuotaExceeded = "服务并发额度已达上限。请结束其他任务后稍后重试。"
    static let apiServerError = "服务端错误，请稍后再试。"
    static let requestTimeout = "Request timeout. Please try again."
    static let requestTooLarge = "Request too large. Please try again."
    static let unsupportedData = "Unsupported data format. Please update the app."
    static let connectionLost = "Connection lost. Please try again."
    static let sessionExpired = "Session expired and has been automatically renewed. Transcription will continue."
}
