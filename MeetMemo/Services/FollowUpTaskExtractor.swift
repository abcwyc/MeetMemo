import Foundation

enum FollowUpTaskExtractionError: LocalizedError {
    case missingNotes
    case llmNotConfigured
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingNotes:
            return "当前会议还没有可用于识别待办的 AI 纪要。"
        case .llmNotConfigured:
            return "LLM 服务尚未配置，无法自动识别待办。"
        case .invalidResponse:
            return "待办识别结果格式不正确，请稍后重试或手动补录。"
        }
    }
}

final class FollowUpTaskExtractor {
    static let shared = FollowUpTaskExtractor(client: LLMClient())

    private let client: LLMProvider

    init(client: LLMProvider) {
        self.client = client
    }

    func extractTasks(from meeting: Meeting) async throws -> [MeetingFollowUpTask] {
        let notes = meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            throw FollowUpTaskExtractionError.missingNotes
        }

        let config = APIKeyValidator.shared.currentLLMConfig()
        guard config.isConfigured else {
            throw FollowUpTaskExtractionError.llmNotConfigured
        }

        let validationResult = await APIKeyValidator.shared.validateLLMConfig(config)
        if case .failure(let error) = validationResult {
            throw error
        }

        let messages = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: Self.userPrompt(meeting: meeting, notes: notes))
        ]

        var response = ""
        let stream = client.chatCompletionsStreamThrowing(config: config, messages: messages)
        for try await chunk in stream {
            response += chunk
        }

        return try Self.decodeTasks(from: response)
    }

    private static let systemPrompt = """
你是一个会议待办识别助手。请从会议纪要中识别需要后续执行、确认或跟进的事项。
只输出 JSON，不要输出 Markdown、解释或代码块。
JSON 必须是数组，每个元素包含：
- title: 简短可执行任务标题
- detail: 任务补充说明，没有则为空字符串
- kind: 只能是 actionItem、confirmation、followUp
- sourceExcerpt: 会议纪要中的相关原文短句，尽量不超过 80 个中文字符
- dueDateText: 如果原文明确给出截止时间则填写原文，否则为空字符串

识别范围：
- 明确行动项
- 待确认事项
- 需要他人反馈、推进、补充材料、后续沟通的事项

不要把普通结论、背景描述、已经完成的事情或泛泛建议当成任务。
"""

    private static func userPrompt(meeting: Meeting, notes: String) -> String {
        """
会议标题：\(meeting.title.isEmpty ? "未命名会议" : meeting.title)
会议日期：\(meeting.date.formatted(date: .long, time: .shortened))

会议纪要：
\(notes)
"""
    }

    private static func decodeTasks(from response: String) throws -> [MeetingFollowUpTask] {
        let cleaned = extractJSONString(from: response)
        guard let data = cleaned.data(using: .utf8) else {
            throw FollowUpTaskExtractionError.invalidResponse
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([ExtractedFollowUpTask].self, from: data)
        return decoded.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            return MeetingFollowUpTask(
                title: title,
                detail: item.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceExcerpt: item.sourceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: FollowUpTaskKind(rawValue: item.kind) ?? .followUp,
                isManual: false
            )
        }
    }

    private static func extractJSONString(from response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              start <= end else {
            return cleaned
        }

        return String(cleaned[start...end])
    }
}

private struct ExtractedFollowUpTask: Decodable {
    let title: String
    let detail: String
    let kind: String
    let sourceExcerpt: String
    let dueDateText: String?
}
