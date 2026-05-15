import Foundation

enum StructuredExtractionError: LocalizedError {
    case missingNotes
    case llmNotConfigured
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingNotes:
            return "当前会议还没有可用于结构化提取的转录原文。"
        case .llmNotConfigured:
            return "LLM 服务尚未配置，无法提取结构化摘要。"
        case .invalidResponse:
            return "结构化摘要提取结果格式不正确，请稍后重试。"
        case .timedOut:
            return "结构化摘要提取超时，请稍后重试。"
        }
    }
}

struct StructuredSummaryResult {
    let oneLiner: String
    let host: String
    let location: String
    let decisions: [MeetingDecision]
    let risks: [MeetingRisk]
    let openQuestions: [MeetingOpenQuestion]
    let discussions: [MeetingDiscussion]
    let milestones: [MeetingMilestone]
}

final class MeetingStructuredExtractor {
    static let shared = MeetingStructuredExtractor(client: LLMClient())

    private let client: LLMProvider

    init(client: LLMProvider) {
        self.client = client
    }

    /// Default per-call timeout. Structured extraction returns a short JSON payload, so 60s
    /// is generous; mainly guards against a hung connection.
    static let defaultTimeout: TimeInterval = 60

    func extract(from meeting: Meeting, timeout: TimeInterval = defaultTimeout) async throws -> StructuredSummaryResult {
        let transcript = meeting.compactTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
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
            ChatMessage(
                role: "user",
                content: Self.userPrompt(
                    meeting: meeting,
                    generatedNotes: meeting.generatedNotes,
                    transcript: transcript
                )
            )
        ]

        let client = self.client
        return try await withThrowingTaskGroup(of: StructuredSummaryResult.self) { group in
            group.addTask {
                var response = ""
                let stream = client.chatCompletionsStreamThrowing(config: config, messages: messages)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    response += chunk
                }
                return try Self.decodeResult(from: response)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw StructuredExtractionError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw StructuredExtractionError.invalidResponse
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static let systemPrompt = """
你是一个会议转录结构化提取助手。请只从会议转录原文中提取关键结构化信息。
只输出 JSON，不要输出 Markdown、解释或代码块。

JSON 必须是如下对象结构：
{
  "one_liner": "30到50字的会议总结，说明主要讨论内容，并尽量带出关键决策或待办",
  "host": "会议主持人或发起人，从会议转录原文中提取，无法判断则为空字符串",
  "location": "会议地点，如'线上'、'北京办公室'等，无法判断则为空字符串",
  "discussions": [
    {
      "title": "议题或讨论主题的简洁标题",
      "summary": "该议题的讨论过程摘要，包括主要观点和分歧（如有），不超过120字",
      "consensus": "该议题最终达成的共识或明确结论，没有则为空字符串",
      "has_consensus": true,
      "source_excerpt": "会议转录原文中支持该议题的相关原文短句，不超过80字，没有则为空字符串"
    }
  ],
  "decisions": [
    {
      "title": "决策内容，简洁明确",
      "owner": "决策人或责任方，没有则为空字符串",
      "reason": "决策原因或背景，没有则为空字符串",
      "confidence": "high 或 medium 或 low",
      "source_excerpt": "会议转录原文中支持该决策的相关原文短句，不超过80字，没有则为空字符串"
    }
  ],
  "risks": [
    {
      "title": "风险描述，简洁",
      "severity": "high 或 medium 或 low",
      "mitigation": "缓解措施，没有则为空字符串",
      "owner": "风险负责人，没有则为空字符串",
      "source_excerpt": "会议转录原文中支持该风险的相关原文短句，不超过80字，没有则为空字符串"
    }
  ],
  "open_questions": [
    {
      "question": "待确认问题描述",
      "owner": "负责确认的人，没有则为空字符串",
      "next_step": "下一步行动，没有则为空字符串",
      "source_excerpt": "会议转录原文中支持该问题的相关原文短句，不超过80字，没有则为空字符串"
    }
  ],
  "milestones": [
    {
      "title": "里程碑名称，简洁",
      "description": "主要交付内容或目标，没有则为空字符串",
      "target_date": "目标时间，直接使用原文表述如'5月底'、'下周五'，没有则为空字符串",
      "source_excerpt": "会议转录原文中支持该里程碑的相关原文短句，不超过80字，没有则为空字符串"
    }
  ]
}

提取规则：
- discussions：只提取会议中最重要的实质议题（0-3 条）。summary 侧重「讨论了什么、有何分歧或不同观点」，consensus 侧重「最终达成了什么共识或结论」。has_consensus 为 true 时 consensus 不能为空。纯粹的信息汇报或结论宣布不视为议题讨论。若无法区分具体议题，返回空数组 []。
- milestones：提取会议中提及的具体交付节点或上线计划（通常有时间节点）。与 decisions 的区别在于 milestones 侧重「交付时间线」，decisions 侧重「方向选择」。没有明确时间节点的目标不算里程碑。若无里程碑信息，返回空数组 []。
- decisions：只提取会议中明确达成、被多方认可的决策。不要把"建议"、"想法"、"讨论方向"误判为已确认决策。confidence 为 low 时表示你对该决策的判断不确定。
- risks：提取会议中明确提及的风险、阻塞项、潜在问题。
- open_questions：提取会议中尚未达成结论、需要后续确认或跟进的问题。
- 如果某类信息在会议中不存在，对应数组返回空数组 []。
- one_liner 必须存在，不能为空字符串，控制在30到50个汉字左右。
- one_liner 要帮助读者快速回忆这次会议讨论了什么；优先写清核心议题，并尽量补充最关键的决策、结论或待办，不要只写成标题式短语。
- host 和 location 若无法从转录原文中判断，返回空字符串。
- 「AI 会议纪要」只用于帮助定位重点，不可作为事实依据。
- 只能使用「会议转录原文」作为事实依据。不要参考 AI 纪要、会议资料或其他外部信息。
- source_excerpt 必须摘自会议转录原文。不要为无依据的信息编造 source_excerpt。
"""

    private static func userPrompt(meeting: Meeting, generatedNotes: String, transcript: String) -> String {
        let trimmedNotes = generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
会议标题：\(meeting.title.isEmpty ? "未命名会议" : meeting.title)
会议日期：\(meeting.date.formatted(date: .long, time: .shortened))

AI 会议纪要（仅用于快速定位重点，不可作为事实依据）：
\(trimmedNotes.isEmpty ? "无" : trimmedNotes)

会议转录原文（唯一事实依据，已省略时间戳和音源标签）：
\(transcript)
"""
    }

    static func decodeResult(from response: String) throws -> StructuredSummaryResult {
        let cleaned = extractJSONString(from: response)
        guard let data = cleaned.data(using: .utf8) else {
            throw StructuredExtractionError.invalidResponse
        }

        let decoder = JSONDecoder()
        let raw: RawStructuredSummary
        do {
            raw = try decoder.decode(RawStructuredSummary.self, from: data)
        } catch {
            print("⚠️ Structured extraction decode failed: \(error)")
            print("⚠️ Structured extraction response prefix: \(String(cleaned.prefix(800)))")
            throw StructuredExtractionError.invalidResponse
        }

        let discussions = raw.discussions?.compactMap { item -> MeetingDiscussion? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return MeetingDiscussion(
                title: title,
                summary: item.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                consensus: item.consensus.trimmingCharacters(in: .whitespacesAndNewlines),
                hasConsensus: item.has_consensus,
                sourceExcerpt: (item.source_excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        let decisions = raw.decisions?.compactMap { item -> MeetingDecision? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let confidence = ["high", "medium", "low"].contains(item.confidence) ? item.confidence : "medium"
            return MeetingDecision(
                title: title,
                owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: item.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: confidence,
                sourceExcerpt: (item.source_excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
                owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceExcerpt: (item.source_excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        let openQuestions = raw.open_questions?.compactMap { item -> MeetingOpenQuestion? in
            let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            return MeetingOpenQuestion(
                question: question,
                owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                nextStep: item.next_step.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceExcerpt: (item.source_excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        let milestones = raw.milestones?.compactMap { item -> MeetingMilestone? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return MeetingMilestone(
                title: title,
                milestoneDescription: item.description.trimmingCharacters(in: .whitespacesAndNewlines),
                targetDate: item.target_date.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceExcerpt: (item.source_excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } ?? []

        return StructuredSummaryResult(
            oneLiner: raw.one_liner.trimmingCharacters(in: .whitespacesAndNewlines),
            host: (raw.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            location: (raw.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: decisions,
            risks: risks,
            openQuestions: openQuestions,
            discussions: discussions,
            milestones: milestones
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
    let host: String?
    let location: String?
    let discussions: [RawDiscussion]?
    let decisions: [RawDecision]?
    let risks: [RawRisk]?
    let open_questions: [RawOpenQuestion]?
    let milestones: [RawMilestone]?

    private enum CodingKeys: String, CodingKey {
        case one_liner, host, location, discussions, decisions, risks, open_questions, milestones
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        one_liner = c.lossyString(forKey: .one_liner)
        host = c.lossyOptionalString(forKey: .host)
        location = c.lossyOptionalString(forKey: .location)
        discussions = c.lossyArray(RawDiscussion.self, forKey: .discussions)
        decisions = c.lossyArray(RawDecision.self, forKey: .decisions)
        risks = c.lossyArray(RawRisk.self, forKey: .risks)
        open_questions = c.lossyArray(RawOpenQuestion.self, forKey: .open_questions)
        milestones = c.lossyArray(RawMilestone.self, forKey: .milestones)
    }
}

private struct RawDiscussion: Decodable {
    let title: String
    let summary: String
    let consensus: String
    let has_consensus: Bool
    let source_excerpt: String?

    private enum CodingKeys: String, CodingKey {
        case title, summary, consensus, has_consensus, source_excerpt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lossyString(forKey: .title)
        summary = c.lossyString(forKey: .summary)
        consensus = c.lossyString(forKey: .consensus)
        has_consensus = c.lossyBool(forKey: .has_consensus)
        source_excerpt = c.lossyOptionalString(forKey: .source_excerpt)
    }
}

private struct RawDecision: Decodable {
    let title: String
    let owner: String
    let reason: String
    let confidence: String
    let source_excerpt: String?

    private enum CodingKeys: String, CodingKey {
        case title, owner, reason, confidence, source_excerpt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lossyString(forKey: .title)
        owner = c.lossyString(forKey: .owner)
        reason = c.lossyString(forKey: .reason)
        confidence = c.lossyString(forKey: .confidence, defaultValue: "medium")
        source_excerpt = c.lossyOptionalString(forKey: .source_excerpt)
    }
}

private struct RawRisk: Decodable {
    let title: String
    let severity: String
    let mitigation: String
    let owner: String
    let source_excerpt: String?

    private enum CodingKeys: String, CodingKey {
        case title, severity, mitigation, owner, source_excerpt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lossyString(forKey: .title)
        severity = c.lossyString(forKey: .severity, defaultValue: "medium")
        mitigation = c.lossyString(forKey: .mitigation)
        owner = c.lossyString(forKey: .owner)
        source_excerpt = c.lossyOptionalString(forKey: .source_excerpt)
    }
}

private struct RawOpenQuestion: Decodable {
    let question: String
    let owner: String
    let next_step: String
    let source_excerpt: String?

    private enum CodingKeys: String, CodingKey {
        case question, owner, next_step, source_excerpt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = c.lossyString(forKey: .question)
        owner = c.lossyString(forKey: .owner)
        next_step = c.lossyString(forKey: .next_step)
        source_excerpt = c.lossyOptionalString(forKey: .source_excerpt)
    }
}

private struct RawMilestone: Decodable {
    let title: String
    let description: String
    let target_date: String
    let source_excerpt: String?

    private enum CodingKeys: String, CodingKey {
        case title, description, target_date, source_excerpt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lossyString(forKey: .title)
        description = c.lossyString(forKey: .description)
        target_date = c.lossyString(forKey: .target_date)
        source_excerpt = c.lossyOptionalString(forKey: .source_excerpt)
    }
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []

        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                _ = try? container.decode(JSONValue.self)
            }
        }

        self.elements = elements
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? single.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}

private extension KeyedDecodingContainer {
    func lossyString(forKey key: Key, defaultValue: String = "") -> String {
        lossyOptionalString(forKey: key) ?? defaultValue
    }

    func lossyOptionalString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func lossyBool(forKey key: Key, defaultValue: Bool = false) -> Bool {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if ["true", "yes", "1", "是", "有"].contains(normalized) { return true }
            if ["false", "no", "0", "否", "无"].contains(normalized) { return false }
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        return defaultValue
    }

    func lossyArray<Element: Decodable>(_ type: Element.Type, forKey key: Key) -> [Element]? {
        if let value = try? decodeIfPresent([Element].self, forKey: key) {
            return value
        }
        if let lossy = try? decodeIfPresent(LossyDecodableArray<Element>.self, forKey: key) {
            return lossy.elements
        }
        return nil
    }
}

private extension String {
    var escapedHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
