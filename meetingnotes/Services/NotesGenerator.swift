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
            Task {
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
                    ChatMessage(role: "user", content: "请根据系统提示和会议记录生成会议纪要，并直接输出结果。")
                ]

                do {
                    let stream = client.chatCompletionsStreamThrowing(config: config, messages: messages)
                    var receivedContent = false

                    for try await chunk in stream {
                        receivedContent = true
                        continuation.yield(.content(chunk))
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
        }
    }

    /// Generates a concise meeting title from the transcript using the configured LLM.
    /// Returns nil if the title cannot be generated (e.g. empty transcript or provider not configured).
    func generateTitle(meeting: Meeting) async -> String? {
        let config = APIKeyValidator.shared.currentLLMConfig()
        guard config.isConfigured else { return nil }

        let transcript = meeting.formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }

        let truncated = String(transcript.prefix(3000))
        let messages = [
            ChatMessage(role: "system", content: "根据以下会议记录，生成一个简洁的中文会议标题（不超过20个字）。只输出标题本身，不要引号、标点或其他任何内容。"),
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

        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Validates if the LLM provider is configured
    /// - Returns: True if API key and model exist, false otherwise
    func isConfigured() -> Bool {
        APIKeyValidator.shared.currentLLMConfig().isConfigured
    }
}
