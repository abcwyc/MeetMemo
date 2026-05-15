// NotesGenerator.swift
// Handles AI-powered note generation using the configured LLM provider

import Foundation

/// Result type for note generation streaming
enum GenerationResult {
    case content(String)
    case error(String)
}

/// Generates meeting notes using the configured LLM provider
final class NotesGenerator {
    static let shared = NotesGenerator(client: LLMClient())

    private let client: LLMProvider

    init(client: LLMProvider) {
        self.client = client
    }

    /// Generates meeting notes from meeting data using template-based system prompt with streaming
    /// - Parameters:
    ///   - meeting: The meeting object containing all necessary data
    ///   - userBlurb: Information about the user for context
    ///   - systemPrompt: The system prompt template with placeholders
    ///   - templateId: Optional template ID to use for generating notes
    /// - Returns: AsyncStream of partial generated notes
    func generateNotesStream(
        meeting: Meeting,
        userBlurb: String,
        systemPrompt: String,
        templateId: UUID? = nil
    ) -> AsyncStream<GenerationResult> {
        AsyncStream<GenerationResult> { continuation in
            let generationTask = Task {
                let config = APIKeyValidator.shared.currentLLMConfig()
                let validationResult = await APIKeyValidator.shared.validateLLMConfig(config)
                switch validationResult {
                case .failure(let error):
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                    return
                case .success:
                    break
                }

                let templates = LocalStorageManager.shared.loadTemplates()
                var templateContent = ""
                if let templateId = templateId,
                   let template = templates.first(where: { $0.id == templateId }) {
                    templateContent = template.formattedContent
                }

                if templateContent.isEmpty,
                   let fallbackTemplate = templates.first(where: { $0.title == "标准会议" || $0.title == "Standard Meeting" }) ?? templates.first {
                    templateContent = fallbackTemplate.formattedContent
                }

                if templateContent.isEmpty {
                    continuation.yield(.error(ErrorMessage.noTemplate))
                    continuation.finish()
                    return
                }

                if meeting.formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.yield(.error(ErrorMessage.noTranscript))
                    continuation.finish()
                    return
                }

                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .full
                dateFormatter.timeStyle = .short

                let templateVariables: [String: String] = [
                    "meeting_title": meeting.title.isEmpty ? "Untitled Meeting" : meeting.title,
                    "meeting_date": dateFormatter.string(from: meeting.date),
                    "transcript": meeting.formattedTranscript,
                    "user_blurb": userBlurb,
                    "meeting_context": meeting.formattedMeetingContext,
                    "user_notes": meeting.formattedMeetingContext,
                    "template_content": templateContent
                ]

                let systemContent = Settings.processTemplate(systemPrompt, with: templateVariables)
                let messages = [
                    ChatMessage(role: "system", content: systemContent),
                    ChatMessage(
                        role: "user",
                        content: "请根据系统提示和会议记录生成会议纪要。直接以 Markdown 标题、列表或分隔线开头，不要任何寒暄、引导语或「以下是…」「好的」「作为您的助理」之类的说明文字。"
                    )
                ]

                do {
                    let stream = client.chatCompletionsStreamThrowing(config: config, messages: messages)
                    let sanitizer = NotesStreamSanitizer()
                    var receivedContent = false

                    for try await chunk in stream {
                        receivedContent = true
                        let cleaned = sanitizer.process(chunk)
                        if !cleaned.isEmpty {
                            continuation.yield(.content(cleaned))
                        }
                    }

                    let tail = sanitizer.flush()
                    if !tail.isEmpty {
                        continuation.yield(.content(tail))
                    }

                    if !receivedContent {
                        continuation.yield(.error("No content was returned by the model."))
                    }

                    continuation.finish()
                } catch {
                    let errorMessage = ErrorHandler.shared.handleError(error)
                    continuation.yield(.error(errorMessage))
                    continuation.finish()
                }
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                continuation.yield(.error("生成会议纪要超时，请稍后重试。"))
                continuation.finish()
                generationTask.cancel()
            }

            continuation.onTermination = { _ in
                generationTask.cancel()
                timeoutTask.cancel()
            }
        }
    }

    /// Generates a concise meeting title from the generated notes when available,
    /// falling back to the transcript before notes exist.
    /// Returns nil if the title cannot be generated (e.g. empty source content or provider not configured).
    func generateTitle(meeting: Meeting) async -> String? {
        let config = APIKeyValidator.shared.currentLLMConfig()
        guard config.isConfigured else { return nil }

        let generatedNotes = meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = meeting.formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceContent = generatedNotes.isEmpty ? transcript : generatedNotes
        guard !sourceContent.isEmpty else { return nil }

        let truncated = String(sourceContent.prefix(6000))
        let messages = [
            ChatMessage(
                role: "system",
                content: """
根据以下会议内容生成一个中文会议标题。

目标：让人一眼看出这场会议的主体是什么，而不只是知道它是一场“讨论”或“沟通”。

要求：
- 优先突出会议主体，例如具体项目、产品、客户、功能、方案、事件或问题。
- 尽量使用“主体 + 核心议题/动作”的结构，例如“行动摘要生成方案评审”“新版转写链路上线排期”。
- 避免只输出“项目沟通会”“需求讨论会”“周会纪要”这类泛化标题。
- 如果存在多个议题，选择影响最大、结论最明确或占比最高的主线。
- 标题控制在 12 到 24 个汉字之间，必要时可略短，但不要为了简短牺牲主体信息。
- 只输出标题本身，不要引号、标点或其他任何内容。
"""
            ),
            ChatMessage(role: "user", content: truncated)
        ]

        var title = ""
        do {
            let stream = client.chatCompletionsStreamThrowing(config: config, messages: messages)
            for try await chunk in stream {
                title += chunk
            }
        } catch {
            return nil
        }

        let cleaned = Self.sanitizeTitle(title)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Models routinely violate the "no quotes / no punctuation / no prefix" rule in the
    /// system prompt, returning things like `《xxx》`, `"xxx"`, `会议标题：xxx`, or `xxx。`.
    /// This strips those wrappers so the saved title is clean.
    static func sanitizeTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        // Collapse to the first non-empty line in case the model wrapped output in a
        // multi-line block (e.g. heading + body).
        if let firstLine = s.split(whereSeparator: { $0.isNewline }).first {
            s = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop leading markdown heading markers (`#`, `##`, …) and bold/italic emphasis.
        while s.first == "#" {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")

        // Drop labelled prefixes the model sometimes adds.
        let prefixes = [
            "会议标题：", "会议标题:",
            "标题：", "标题:",
            "Title：", "Title:", "title：", "title:"
        ]
        for prefix in prefixes where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        // Peel matching wrapping characters (quotes, brackets, book-title marks) until
        // they no longer balance at both ends.
        let wrappingPairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"),
            ("\u{201C}", "\u{201D}"),
            ("\u{2018}", "\u{2019}"),
            ("《", "》"),
            ("「", "」"),
            ("『", "』"),
            ("【", "】"),
            ("[", "]"),
            ("(", ")"),
            ("（", "）")
        ]
        while let first = s.first, let last = s.last, s.count >= 2,
              wrappingPairs.contains(where: { $0.0 == first && $0.1 == last }) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Trim trailing punctuation (Chinese + ASCII) — common when the model treats the
        // title as a sentence.
        let trailingPunctuation: Set<Character> = [".", "。", "!", "！", "?", "？", "、", ",", "，", ";", "；", ":", "："]
        while let last = s.last, trailingPunctuation.contains(last) {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return s
    }

    /// Validates if the LLM provider is configured
    /// - Returns: True if API key and model exist, false otherwise
    func isConfigured() -> Bool {
        APIKeyValidator.shared.currentLLMConfig().isConfigured
    }
}

/// Strips the LLM's conversational preamble (e.g. "好的，作为您的专业会议助理…") from
/// the beginning of a streamed Markdown response. Buffers initial chunks until either a
/// Markdown signal appears or the buffer exceeds `maxBuffer`, at which point everything
/// is flushed unchanged. Once the start has been resolved, all subsequent chunks pass
/// through untouched.
final class NotesStreamSanitizer {
    private var buffer = ""
    private var passthrough = false
    private let maxBuffer = 800

    /// Returns the cleaned chunk to yield. May be empty while still buffering.
    func process(_ chunk: String) -> String {
        if passthrough { return chunk }

        buffer += chunk

        let leadingTrimmed = buffer.drop { $0.isWhitespace }
        if Self.startsWithMarkdownSignal(leadingTrimmed) {
            passthrough = true
            let output = String(leadingTrimmed)
            buffer = ""
            return output
        }

        if let markerIndex = Self.firstMarkdownLineIndex(in: buffer) {
            passthrough = true
            let output = String(buffer[markerIndex...])
            buffer = ""
            return output
        }

        if buffer.count >= maxBuffer {
            passthrough = true
            let output = buffer
            buffer = ""
            return output
        }

        return ""
    }

    /// Returns any remaining buffered content. Call once when the stream ends.
    func flush() -> String {
        let output = buffer
        buffer = ""
        passthrough = true
        return output
    }

    private static func startsWithMarkdownSignal(_ s: Substring) -> Bool {
        guard let first = s.first else { return false }
        if first == "#" || first == "|" || first == ">" { return true }
        if s.hasPrefix("---") || s.hasPrefix("```") { return true }
        if first == "-" || first == "*" || first == "+" {
            let after = s.dropFirst()
            return after.first == " " || after.first == "\n"
        }
        if first.isNumber {
            return s.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
        return false
    }

    private static func firstMarkdownLineIndex(in text: String) -> String.Index? {
        var searchStart = text.startIndex
        while let newlineIdx = text[searchStart...].firstIndex(of: "\n") {
            let lineStart = text.index(after: newlineIdx)
            guard lineStart < text.endIndex else { return nil }
            let lineSub = text[lineStart...].drop { $0 == " " || $0 == "\t" }
            if startsWithMarkdownSignal(lineSub) {
                // Return the start of the line itself (before any indent) so
                // that downstream Markdown parsers see the original column.
                return lineStart
            }
            searchStart = lineStart
        }
        return nil
    }
}
