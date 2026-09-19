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
                    AppLog.llm.debug("❌ LLM stream failed: \(error)")
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
        chatCompletionsStreamThrowing(
            config: config,
            messages: messages,
            maxTokens: 8192
        )
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        switch config.apiStyle {
        case .anthropicMessages:
            return AnthropicMessagesLLMProvider().chatCompletionsStreamThrowing(
                config: config,
                messages: messages,
                maxTokens: maxTokens
            )
        case .openAICompatibleChatCompletions:
            return OpenAICompatibleLLMProvider().chatCompletionsStreamThrowing(
                config: config,
                messages: messages,
                maxTokens: maxTokens
            )
        }
    }

    func completeStructuredJSON(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request: LLMStructuredOutputRequest
    ) async throws -> LLMCompletionResponse {
        switch config.apiStyle {
        case .anthropicMessages:
            return try await AnthropicMessagesLLMProvider().completeStructuredJSON(
                config: config,
                messages: messages,
                request: request
            )
        case .openAICompatibleChatCompletions:
            return try await OpenAICompatibleLLMProvider().completeStructuredJSON(
                config: config,
                messages: messages,
                request: request
            )
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
        chatCompletionsStreamThrowing(
            config: config,
            messages: messages,
            maxTokens: 8192
        )
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        maxTokens: Int
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
                    request.httpBody = try buildRequestBody(
                        config: config,
                        messages: messages,
                        stream: true,
                        maxTokens: maxTokens
                    )
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

    func completeStructuredJSON(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request: LLMStructuredOutputRequest
    ) async throws -> LLMCompletionResponse {
        do {
            return try await performStructuredCompletion(
                config: config,
                messages: messages,
                request: request,
                useTool: true
            )
        } catch let error as HTTPError where error.statusCode == 400 || error.statusCode == 422 {
            // Some Anthropic-compatible gateways do not implement tools. Keep a
            // non-streaming fallback so their ordinary JSON responses are still handled.
            return try await performStructuredCompletion(
                config: config,
                messages: messages,
                request: request,
                useTool: false
            )
        }
    }

    private func performStructuredCompletion(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request structuredRequest: LLMStructuredOutputRequest,
        useTool: Bool
    ) async throws -> LLMCompletionResponse {
        let url = try buildRequestURL(config: config)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        // Non-streaming: no bytes arrive until the whole JSON is generated, so
        // this idle timeout must cover the full generation time.
        urlRequest.timeoutInterval = LLMStructuredOutputRequest.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try buildStructuredRequestBody(
            config: config,
            messages: messages,
            request: structuredRequest,
            useTool: useTool
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderValidationError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw HTTPError(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMCompletionError.invalidResponse
        }
        if let error = root["error"] as? [String: Any] {
            throw NSError(
                domain: "LLMClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Unknown API error"]
            )
        }

        let stopReason = root["stop_reason"] as? String
        if stopReason == "max_tokens" {
            throw LLMCompletionError.truncated
        }

        let blocks = root["content"] as? [[String: Any]] ?? []
        for block in blocks where block["type"] as? String == "tool_use" {
            if let input = block["input"], JSONSerialization.isValidJSONObject(input) {
                let contentData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                if let content = String(data: contentData, encoding: .utf8), !content.isEmpty {
                    return LLMCompletionResponse(
                        content: content,
                        finishReason: stopReason,
                        requestID: httpResponse.value(forHTTPHeaderField: "request-id")
                            ?? httpResponse.value(forHTTPHeaderField: "x-request-id")
                    )
                }
            }
        }

        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMCompletionError.emptyResponse
        }
        return LLMCompletionResponse(
            content: text,
            finishReason: stopReason,
            requestID: httpResponse.value(forHTTPHeaderField: "request-id")
                ?? httpResponse.value(forHTTPHeaderField: "x-request-id")
        )
    }

    private func buildStructuredRequestBody(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request: LLMStructuredOutputRequest,
        useTool: Bool
    ) throws -> Data {
        let schema = try Self.schemaObject(from: request.jsonSchema)
        let systemMessage = messages.first(where: { $0.role == "system" })?.content
        let userMessages = messages.filter { $0.role != "system" }
        var body: [String: Any] = [
            "model": config.model,
            "messages": userMessages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": request.maxTokens,
            "stream": false,
            "temperature": 0
        ]
        if let systemMessage, !systemMessage.isEmpty {
            body["system"] = systemMessage
        }
        if useTool {
            body["tools"] = [[
                "name": request.name,
                "description": "Return the structured meeting extraction result.",
                "input_schema": schema
            ]]
            body["tool_choice"] = ["type": "tool", "name": request.name]
        }
        return try JSONSerialization.data(withJSONObject: body)
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
        maxTokens: Int = 8192
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
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "max_tokens" {
                    throw LLMCompletionError.truncated
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
        chatCompletionsStreamThrowing(
            config: config,
            messages: messages,
            maxTokens: 8192
        )
    }

    func chatCompletionsStreamThrowing(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        maxTokens: Int
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
                    request.httpBody = try buildRequestBody(
                        config: config,
                        messages: messages,
                        stream: true,
                        maxTokens: maxTokens
                    )

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

    func completeStructuredJSON(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request: LLMStructuredOutputRequest
    ) async throws -> LLMCompletionResponse {
        let modes: [OpenAIStructuredOutputMode] = [.jsonSchema, .jsonObject, .promptOnly]
        var lastCompatibilityError: Error?

        for mode in modes {
            do {
                return try await performStructuredCompletion(
                    config: config,
                    messages: messages,
                    request: request,
                    mode: mode,
                    includeTemperature: true
                )
            } catch let error as HTTPError where error.statusCode == 400 || error.statusCode == 422 {
                if error.message?.lowercased().contains("temperature") == true {
                    do {
                        return try await performStructuredCompletion(
                            config: config,
                            messages: messages,
                            request: request,
                            mode: mode,
                            includeTemperature: false
                        )
                    } catch let retryError as HTTPError where retryError.statusCode == 400 || retryError.statusCode == 422 {
                        lastCompatibilityError = retryError
                        continue
                    }
                }
                lastCompatibilityError = error
            }
        }

        throw lastCompatibilityError ?? LLMCompletionError.invalidResponse
    }

    private func performStructuredCompletion(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request structuredRequest: LLMStructuredOutputRequest,
        mode: OpenAIStructuredOutputMode,
        includeTemperature: Bool
    ) async throws -> LLMCompletionResponse {
        let url = try buildRequestURL(config: config)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        // Non-streaming: no bytes arrive until the whole JSON is generated, so
        // this idle timeout must cover the full generation time.
        urlRequest.timeoutInterval = LLMStructuredOutputRequest.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try buildStructuredRequestBody(
            config: config,
            messages: messages,
            request: structuredRequest,
            mode: mode,
            includeTemperature: includeTemperature
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderValidationError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw HTTPError(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMCompletionError.invalidResponse
        }
        if let error = root["error"] as? [String: Any] {
            throw NSError(
                domain: "LLMClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Unknown API error"]
            )
        }
        guard let first = (root["choices"] as? [[String: Any]])?.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMCompletionError.invalidResponse
        }

        let finishReason = first["finish_reason"] as? String
        if finishReason == "length" || finishReason == "max_tokens" {
            throw LLMCompletionError.truncated
        }
        guard let content = Self.contentText(from: message["content"]),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMCompletionError.emptyResponse
        }

        return LLMCompletionResponse(
            content: content,
            finishReason: finishReason,
            requestID: httpResponse.value(forHTTPHeaderField: "x-request-id")
                ?? httpResponse.value(forHTTPHeaderField: "request-id")
        )
    }

    private func buildStructuredRequestBody(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        request: LLMStructuredOutputRequest,
        mode: OpenAIStructuredOutputMode,
        includeTemperature: Bool
    ) throws -> Data {
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": request.maxTokens,
            "stream": false
        ]
        if includeTemperature {
            body["temperature"] = 0
        }

        switch mode {
        case .jsonSchema:
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": request.name,
                    "strict": true,
                    "schema": try Self.schemaObject(from: request.jsonSchema)
                ]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptOnly:
            break
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func contentText(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                if let nested = part["text"] as? [String: Any] {
                    return nested["value"] as? String
                }
                return nil
            }.joined()
        }
        return nil
    }

    private func buildRequestBody(
        config: LLMProviderConfig,
        messages: [ChatMessage],
        stream: Bool,
        maxTokens: Int = 8192
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

        if let finishReason = first["finish_reason"] as? String,
           finishReason == "length" || finishReason == "max_tokens" {
            throw LLMCompletionError.truncated
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

private enum OpenAIStructuredOutputMode {
    case jsonSchema
    case jsonObject
    case promptOnly
}

private extension LLMProvider {
    static func schemaObject(from json: String) throws -> Any {
        guard let data = json.data(using: .utf8) else {
            throw LLMCompletionError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func errorMessage(from data: Data) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
