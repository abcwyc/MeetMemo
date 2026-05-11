import Foundation

enum StructuredExtractionError: LocalizedError {
    case missingNotes
    case llmNotConfigured
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingNotes:
            return "当前会议还没有可用于结构化提取的 AI 纪要。"
        case .llmNotConfigured:
            return "LLM 服务尚未配置，无法提取结构化摘要。"
        case .invalidResponse:
            return "结构化摘要提取结果格式不正确，请稍后重试。"
        }
    }
}

struct StructuredSummaryResult {
    let oneLiner: String
    let decisions: [MeetingDecision]
    let risks: [MeetingRisk]
    let openQuestions: [MeetingOpenQuestion]
}

final class MeetingStructuredExtractor {
    static let shared = MeetingStructuredExtractor(client: LLMClient())

    private let client: LLMProvider

    init(client: LLMProvider) {
        self.client = client
    }

    func extract(from meeting: Meeting) async throws -> StructuredSummaryResult {
        let notes = meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            throw StructuredExtractionError.missingNotes
        }

        let config = APIKeyValidator.shared.currentLLMConfig()
        guard config.isConfigured else {
            throw StructuredExtractionError.llmNotConfigured
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

        return try Self.decodeResult(from: response)
    }

    private static let systemPrompt = """
你是一个会议纪要结构化提取助手。请从会议纪要中提取关键结构化信息。
只输出 JSON，不要输出 Markdown、解释或代码块。

JSON 必须是如下对象结构：
{
  "one_liner": "一句话概括本次会议最重要的结论或成果，不超过50字",
  "decisions": [
    {
      "title": "决策内容，简洁明确",
      "owner": "决策人或责任方，没有则为空字符串",
      "reason": "决策原因或背景，没有则为空字符串",
      "confidence": "high 或 medium 或 low",
      "source_excerpt": "会议纪要中支持该决策的相关原文短句，不超过80字，没有则为空字符串"
    }
  ],
  "risks": [
    {
      "title": "风险描述，简洁",
      "severity": "high 或 medium 或 low",
      "mitigation": "缓解措施，没有则为空字符串",
      "owner": "风险负责人，没有则为空字符串"
    }
  ],
  "open_questions": [
    {
      "question": "待确认问题描述",
      "owner": "负责确认的人，没有则为空字符串",
      "next_step": "下一步行动，没有则为空字符串"
    }
  ]
}

提取规则：
- decisions：只提取会议中明确达成、被多方认可的决策。不要把"建议"、"想法"、"讨论方向"误判为已确认决策。confidence 为 low 时表示你对该决策的判断不确定。
- risks：提取会议中明确提及的风险、阻塞项、潜在问题。
- open_questions：提取会议中尚未达成结论、需要后续确认或跟进的问题。
- 如果某类信息在会议中不存在，对应数组返回空数组 []。
- one_liner 必须存在，不能为空字符串。
"""

    private static func userPrompt(meeting: Meeting, notes: String) -> String {
        """
会议标题：\(meeting.title.isEmpty ? "未命名会议" : meeting.title)
会议日期：\(meeting.date.formatted(date: .long, time: .shortened))

会议纪要：
\(notes)
"""
    }

    private static func decodeResult(from response: String) throws -> StructuredSummaryResult {
        let cleaned = extractJSONString(from: response)
        guard let data = cleaned.data(using: .utf8) else {
            throw StructuredExtractionError.invalidResponse
        }

        let decoder = JSONDecoder()
        let raw: RawStructuredSummary
        do {
            raw = try decoder.decode(RawStructuredSummary.self, from: data)
        } catch {
            throw StructuredExtractionError.invalidResponse
        }

        let decisions = raw.decisions?.compactMap { item -> MeetingDecision? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let confidence = ["high", "medium", "low"].contains(item.confidence) ? item.confidence : "medium"
            return MeetingDecision(
                title: title,
                owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: item.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: confidence,
                sourceExcerpt: item.source_excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        let risks = raw.risks?.compactMap { item -> MeetingRisk? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let severity = ["high", "medium", "low"].contains(item.severity) ? item.severity : "medium"
            return MeetingRisk(
                title: title,
                severity: severity,
                mitigation: item.mitigation.trimmingCharacters(in: .whitespacesAndNewlines),
                owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        let openQuestions = raw.open_questions?.compactMap { item -> MeetingOpenQuestion? in
            let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            return MeetingOpenQuestion(
                question: question,
                owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                nextStep: item.next_step.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        return StructuredSummaryResult(
            oneLiner: raw.one_liner.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: decisions,
            risks: risks,
            openQuestions: openQuestions
        )
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

        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end else {
            return cleaned
        }

        return String(cleaned[start...end])
    }
}

// MARK: - Raw decodable types

private struct RawStructuredSummary: Decodable {
    let one_liner: String
    let decisions: [RawDecision]?
    let risks: [RawRisk]?
    let open_questions: [RawOpenQuestion]?
}

private struct RawDecision: Decodable {
    let title: String
    let owner: String
    let reason: String
    let confidence: String
    let source_excerpt: String
}

private struct RawRisk: Decodable {
    let title: String
    let severity: String
    let mitigation: String
    let owner: String
}

private struct RawOpenQuestion: Decodable {
    let question: String
    let owner: String
    let next_step: String
}
