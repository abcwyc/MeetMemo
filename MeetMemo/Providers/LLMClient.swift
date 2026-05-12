import Foundation

struct ChatMessage: Codable, Hashable {
    let role: String
    let content: String
}

final class LLMClient: LLMProvider {
    func chatCompletionsStream(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await chunk in chatCompletionsStreamThrowing(config: config, messages: messages) {
                        continuation.yield(chunk)
                    }
                } catch {
                    print("❌ LLM stream failed: \(error)")
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        switch config.apiStyle {
        case .anthropicMessages:
            return AnthropicMessagesLLMProvider().chatCompletionsStreamThrowing(config: config, messages: messages)
        case .openAICompatibleChatCompletions:
            return OpenAICompatibleLLMProvider().chatCompletionsStreamThrowing(config: config, messages: messages)
        }
    }

    func testConnection(config: LLMProviderConfig) async throws {
        switch config.apiStyle {
        case .anthropicMessages:
            try await AnthropicMessagesLLMProvider().testConnection(config: config)
        case .openAICompatibleChatCompletions:
            try await OpenAICompatibleLLMProvider().testConnection(config: config)
        }
    }
}

private final class AnthropicMessagesLLMProvider: LLMProvider {
    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try buildRequestURL(config: config)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try buildRequestBody(config: config, messages: messages, stream: true)
                    request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderValidationError.invalidResponse
                    }

                    if !(200...299).contains(httpResponse.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                        }

                        let bodyString = String(data: body, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        throw HTTPError(
                            statusCode: httpResponse.statusCode,
                            message: bodyString?.isEmpty == false
                                ? bodyString
                                : HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                        )
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }

                        if trimmed == "data: [DONE]" {
                            break
                        }

                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !payload.isEmpty,
                              let data = payload.data(using: .utf8) else { continue }

                        if let content = try Self.extractContent(from: data) {
                            continuation.yield(content)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func buildRequestURL(config: LLMProviderConfig) throws -> URL {
        return try config.requestURL(endpoint: "/v1/messages")
    }

    private func buildRequestBody(config: LLMProviderConfig, messages: [ChatMessage]) throws -> Data {
        try buildRequestBody(config: config, messages: messages, stream: true)
    }

    func testConnection(config: LLMProviderConfig) async throws {
        let url = try buildRequestURL(config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        request.httpBody = try buildRequestBody(
            config: config,
            messages: [
                ChatMessage(role: "user", content: "ping")
            ],
            stream: false,
            maxTokens: 1
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderValidationError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let bodyString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HTTPError(
                statusCode: httpResponse.statusCode,
                message: bodyString?.isEmpty == false
                    ? bodyString
                    : HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw NSError(domain: "LLMClient", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        }
    }

    private func buildRequestBody(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        stream: Bool,
        maxTokens: Int = 4096
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        let systemMessage = messages.first(where: { $0.role == "system" })?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessages = messages.filter { $0.role != "system" }

        let effectiveMessages = userMessages.isEmpty
            ? [ChatMessage(role: "user", content: "请根据上文内容生成会议纪要。")]
            : userMessages

        return try encoder.encode(AnthropicChatRequest(
            model: config.model,
            system: systemMessage?.isEmpty == false ? systemMessage : nil,
            messages: effectiveMessages,
            maxTokens: maxTokens,
            stream: stream
        ))
    }

    private static func extractContent(from data: Data) throws -> String? {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let error = event["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown API error"
            throw NSError(domain: "LLMClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        if let errorMessage = event["error"] as? String, !errorMessage.isEmpty {
            throw NSError(domain: "LLMClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: errorMessage
            ])
        }

        if let eventType = event["type"] as? String {
            switch eventType {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String, !text.isEmpty {
                        return text
                    }

                    if let text = delta["text_delta"] as? String, !text.isEmpty {
                        return text
                    }
                }
            case "error":
                let message = event["message"] as? String ?? "Unknown API error"
                throw NSError(domain: "LLMClient", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            default:
                break
            }
        }

        return nil
    }
}

private final class OpenAICompatibleLLMProvider: LLMProvider {
    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try buildRequestURL(config: config)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try buildRequestBody(config: config, messages: messages, stream: true)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ProviderValidationError.invalidResponse
                    }

                    if !(200...299).contains(httpResponse.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                        }

                        let bodyString = String(data: body, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        throw HTTPError(
                            statusCode: httpResponse.statusCode,
                            message: bodyString?.isEmpty == false
                                ? bodyString
                                : HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                        )
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }

                        if trimmed == "data: [DONE]" {
                            break
                        }

                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !payload.isEmpty,
                              let data = payload.data(using: .utf8) else { continue }

                        if let content = try Self.extractContent(from: data) {
                            continuation.yield(content)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func testConnection(config: LLMProviderConfig) async throws {
        let url = try buildRequestURL(config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        request.httpBody = try buildRequestBody(
            config: config,
            messages: [
                ChatMessage(role: "user", content: "ping")
            ],
            stream: false,
            maxTokens: 1
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderValidationError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let bodyString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HTTPError(
                statusCode: httpResponse.statusCode,
                message: bodyString?.isEmpty == false
                    ? bodyString
                    : HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "LLMClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func buildRequestURL(config: LLMProviderConfig) throws -> URL {
        try config.requestURL(endpoint: "/chat/completions")
    }

    private func buildRequestBody(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        stream: Bool,
        maxTokens: Int = 4096
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        return try encoder.encode(OpenAIChatCompletionsRequest(
            model: config.model,
            messages: messages,
            maxTokens: maxTokens,
            stream: stream
        ))
    }

    private static func extractContent(from data: Data) throws -> String? {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let error = event["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown API error"
            throw NSError(domain: "LLMClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        guard let choices = event["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }

        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            return content
        }

        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }

        return nil
    }
}

private struct AnthropicChatRequest: Encodable {
    let model: String
    let system: String?
    let messages: [ChatMessage]
    let maxTokens: Int
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct OpenAIChatCompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
    }
}
