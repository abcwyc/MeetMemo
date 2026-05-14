import CryptoKit
import Foundation

enum AudioSource: String, Codable, CaseIterable {
    case mic = "MIC"
    case system = "SYS"
    
    var displayName: String {
        switch self {
        case .mic:
            return "mic"
        case .system:
            return "online"
        }
    }
    
    var copyPrefix: String {
        switch self {
        case .mic:
            return "mic"
        case .system:
            return "online"
        }
    }
    
    var icon: String {
        switch self {
        case .mic:
            return "mic.fill"
        case .system:
            return "speaker.wave.2.fill"
        }
    }
}

struct TranscriptChunk: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let text: String
    let isFinal: Bool
    let speakerTag: String?
    let speakerId: Int?
    let startTime: Int?
    let endTime: Int?
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: AudioSource,
        text: String,
        isFinal: Bool = false,
        speakerTag: String? = nil,
        speakerId: Int? = nil,
        startTime: Int? = nil,
        endTime: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.speakerTag = speakerTag
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
    }

    var speakerIdentityKey: String? {
        if let speakerTag {
            // Speaker tags may be raw labels ("A", "B") or provider-specific tokens.
            // Keep the audio source in the key so mic/system diarization buckets don't collapse together.
            return "\(source.rawValue):\(speakerTag)"
        }

        guard let speakerId else { return nil }
        return "\(source.rawValue):\(speakerId)"
    }
}

extension Array where Element == TranscriptChunk {
    func sortedByTranscriptTimeline() -> [TranscriptChunk] {
        sorted { lhs, rhs in
            switch (lhs.startTime, rhs.startTime) {
            case let (lhsStart?, rhsStart?) where lhsStart != rhsStart:
                return lhsStart < rhsStart
            case (.some, .some):
                switch (lhs.endTime, rhs.endTime) {
                case let (lhsEnd?, rhsEnd?) where lhsEnd != rhsEnd:
                    return lhsEnd < rhsEnd
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.timestamp < rhs.timestamp
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.timestamp < rhs.timestamp
            }
        }
    }

    func mergingTranscriptCorrections(
        preservingMissingFinalChunksFrom fallback: [TranscriptChunk]
    ) -> [TranscriptChunk] {
        let preferredIDs = Set(map(\.id))
        let missingFinalChunks = fallback.filter { chunk in
            chunk.isFinal && !preferredIDs.contains(chunk.id)
        }

        guard !missingFinalChunks.isEmpty else { return self }

        return (self + missingFinalChunks).sortedByTranscriptTimeline()
    }
}

struct TranscriptDisplayChunk: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let sourceLabel: String
    let text: String
    let isFinal: Bool
    let speakerLabel: String?
    let timeLabel: String
}

struct TranscriptSpeakerNamingOption: Identifiable, Hashable {
    let id: String
    let defaultLabel: String
    let currentName: String?
    let sampleTexts: [String]
}

enum FollowUpTaskKind: String, Codable, CaseIterable, Hashable {
    case actionItem
    case confirmation
    case followUp
    case manual

    var displayName: String {
        switch self {
        case .actionItem: return "行动项"
        case .confirmation: return "待确认"
        case .followUp: return "跟进"
        case .manual: return "手动补录"
        }
    }

    var englishDisplayName: String {
        switch self {
        case .actionItem: return "Action"
        case .confirmation: return "Confirm"
        case .followUp: return "Follow-up"
        case .manual: return "Manual"
        }
    }

    var icon: String {
        switch self {
        case .actionItem: return "checklist"
        case .confirmation: return "questionmark.circle"
        case .followUp: return "arrow.triangle.2.circlepath"
        case .manual: return "square.and.pencil"
        }
    }
}

struct MeetingFollowUpTask: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var detail: String
    var sourceExcerpt: String
    var kind: FollowUpTaskKind
    var dueDate: Date?
    var owner: String
    var isManual: Bool
    var reminderIdentifier: String?
    var reminderCalendarIdentifier: String?
    var reminderCalendarTitle: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        sourceExcerpt: String = "",
        kind: FollowUpTaskKind,
        dueDate: Date? = nil,
        owner: String = "",
        isManual: Bool = false,
        reminderIdentifier: String? = nil,
        reminderCalendarIdentifier: String? = nil,
        reminderCalendarTitle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sourceExcerpt = sourceExcerpt
        self.kind = kind
        self.dueDate = dueDate
        self.owner = owner
        self.isManual = isManual
        self.reminderIdentifier = reminderIdentifier
        self.reminderCalendarIdentifier = reminderCalendarIdentifier
        self.reminderCalendarTitle = reminderCalendarTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, sourceExcerpt, kind, dueDate, owner, isManual
        case reminderIdentifier, reminderCalendarIdentifier, reminderCalendarTitle
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        kind = try c.decodeIfPresent(FollowUpTaskKind.self, forKey: .kind) ?? .followUp
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        reminderIdentifier = try c.decodeIfPresent(String.self, forKey: .reminderIdentifier)
        reminderCalendarIdentifier = try c.decodeIfPresent(String.self, forKey: .reminderCalendarIdentifier)
        reminderCalendarTitle = try c.decodeIfPresent(String.self, forKey: .reminderCalendarTitle)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSyncedToReminders: Bool {
        !(reminderIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct MeetingDecision: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var owner: String
    var reason: String
    var confidence: String  // "high" | "medium" | "low"
    var sourceExcerpt: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        owner: String = "",
        reason: String = "",
        confidence: String = "medium",
        sourceExcerpt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.reason = reason
        self.confidence = confidence
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
    }
}

struct MeetingRisk: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var severity: String    // "high" | "medium" | "low"
    var mitigation: String
    var owner: String
    var sourceExcerpt: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        severity: String = "medium",
        mitigation: String = "",
        owner: String = "",
        sourceExcerpt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.mitigation = mitigation
        self.owner = owner
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, severity, mitigation, owner, sourceExcerpt, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "medium"
        mitigation = try c.decodeIfPresent(String.self, forKey: .mitigation) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct MeetingOpenQuestion: Codable, Identifiable, Hashable {
    var id: UUID
    var question: String
    var owner: String
    var nextStep: String
    var sourceExcerpt: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        question: String,
        owner: String = "",
        nextStep: String = "",
        sourceExcerpt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.owner = owner
        self.nextStep = nextStep
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, owner, nextStep, sourceExcerpt, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        nextStep = try c.decodeIfPresent(String.self, forKey: .nextStep) ?? ""
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct MeetingMilestone: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var milestoneDescription: String
    var targetDate: String
    var sourceExcerpt: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        milestoneDescription: String = "",
        targetDate: String = "",
        sourceExcerpt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.milestoneDescription = milestoneDescription
        self.targetDate = targetDate
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, milestoneDescription, targetDate, sourceExcerpt, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        milestoneDescription = try c.decodeIfPresent(String.self, forKey: .milestoneDescription) ?? ""
        targetDate = try c.decodeIfPresent(String.self, forKey: .targetDate) ?? ""
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct MeetingDiscussion: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var summary: String
    var consensus: String
    var hasConsensus: Bool
    var sourceExcerpt: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        summary: String = "",
        consensus: String = "",
        hasConsensus: Bool = false,
        sourceExcerpt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.consensus = consensus
        self.hasConsensus = hasConsensus
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, consensus, hasConsensus, sourceExcerpt, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        consensus = try c.decodeIfPresent(String.self, forKey: .consensus) ?? ""
        hasConsensus = try c.decodeIfPresent(Bool.self, forKey: .hasConsensus) ?? false
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct MeetingDiagram: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var htmlContent: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, htmlContent: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.htmlContent = htmlContent
        self.createdAt = createdAt
    }
}

struct CollapsedTranscriptChunk: Identifiable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let combinedText: String
    
    init(id: UUID = UUID(), timestamp: Date, source: AudioSource, combinedText: String) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.combinedText = combinedText
    }
}

enum MeetingContextKind: String, Codable, CaseIterable, Hashable {
    case text
    case link
    case file

    var displayName: String {
        switch self {
        case .text:
            return "文本"
        case .link:
            return "链接"
        case .file:
            return "文件"
        }
    }

    var englishDisplayName: String {
        switch self {
        case .text:
            return "Text"
        case .link:
            return "Link"
        case .file:
            return "File"
        }
    }

    var icon: String {
        switch self {
        case .text:
            return "text.alignleft"
        case .link:
            return "link"
        case .file:
            return "doc.text"
        }
    }
}

enum MeetingContextExtractionStatus: String, Codable, Hashable {
    case idle
    case extracting
    case succeeded
    case failed
}

struct MeetingContextItem: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: MeetingContextKind
    var title: String
    var source: String?
    var extractedText: String
    var extractionStatus: MeetingContextExtractionStatus
    var extractionError: String?
    var fetchedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: MeetingContextKind,
        title: String,
        source: String? = nil,
        extractedText: String,
        extractionStatus: MeetingContextExtractionStatus = .idle,
        extractionError: String? = nil,
        fetchedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.source = source
        self.extractedText = extractedText
        self.extractionStatus = extractionStatus
        self.extractionError = extractionError
        self.fetchedAt = fetchedAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case source
        case extractedText
        case extractionStatus
        case extractionError
        case fetchedAt
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(MeetingContextKind.self, forKey: .kind) ?? .text
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source)
        extractedText = try container.decodeIfPresent(String.self, forKey: .extractedText) ?? ""
        extractionStatus = try container.decodeIfPresent(MeetingContextExtractionStatus.self, forKey: .extractionStatus) ?? .idle
        extractionError = try container.decodeIfPresent(String.self, forKey: .extractionError)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var trimmedText: String {
        extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        switch kind {
        case .text:
            return "手动补充"
        case .link:
            return source ?? "链接"
        case .file:
            return source ?? "文件"
        }
    }
}

struct Meeting: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    var title: String
    var transcriptChunks: [TranscriptChunk]
    /// Legacy single text field retained for backward compatibility with older meeting files.
    var userNotes: String
    var contextItems: [MeetingContextItem]
    var generatedNotes: String
    var followUpTasks: [MeetingFollowUpTask]
    var templateId: UUID?  // Add property to track per-meeting template
    var speakerParticipantNames: [String]
    var speakerNameMappings: [String: String]
    var oneLiner: String
    var decisions: [MeetingDecision]
    var risks: [MeetingRisk]
    var openQuestions: [MeetingOpenQuestion]
    var discussions: [MeetingDiscussion]
    var milestones: [MeetingMilestone]
    var host: String
    var location: String
    var diagrams: [MeetingDiagram]
    var structuredSummarySourceHash: String
    var structuredSummaryGeneratedAt: Date?
    // MARK: - Data versioning
    /// Version of this Meeting record on disk. Useful for migration.
    var dataVersion: Int
    /// Current app data version. Increment whenever you make a breaking change to `Meeting` that requires migration.
    static let currentDataVersion = 8

    init(id: UUID = UUID(),
         date: Date = Date(),
         title: String = "",
         transcriptChunks: [TranscriptChunk] = [],
         userNotes: String = "",
         contextItems: [MeetingContextItem] = [],
         generatedNotes: String = "",
         followUpTasks: [MeetingFollowUpTask] = [],
         templateId: UUID? = nil,
         speakerParticipantNames: [String] = [],
         speakerNameMappings: [String: String] = [:],
         oneLiner: String = "",
         decisions: [MeetingDecision] = [],
         risks: [MeetingRisk] = [],
         openQuestions: [MeetingOpenQuestion] = [],
         discussions: [MeetingDiscussion] = [],
         milestones: [MeetingMilestone] = [],
         host: String = "",
         location: String = "",
         diagrams: [MeetingDiagram] = [],
         structuredSummarySourceHash: String = "",
         structuredSummaryGeneratedAt: Date? = nil,
         dataVersion: Int = Meeting.currentDataVersion) {
        self.id = id
        self.date = date
        self.title = title
        self.transcriptChunks = transcriptChunks
        self.userNotes = userNotes
        self.contextItems = Self.normalizedContextItems(contextItems, legacyUserNotes: userNotes, date: date)
        self.generatedNotes = generatedNotes
        self.followUpTasks = followUpTasks
        self.templateId = templateId
        self.speakerParticipantNames = Self.normalizedParticipantNames(speakerParticipantNames)
        self.speakerNameMappings = Self.normalizedSpeakerNameMappings(speakerNameMappings)
        self.oneLiner = oneLiner
        self.decisions = decisions
        self.risks = risks
        self.openQuestions = openQuestions
        self.discussions = discussions
        self.milestones = milestones
        self.host = host
        self.location = location
        self.diagrams = diagrams
        self.structuredSummarySourceHash = structuredSummarySourceHash
        self.structuredSummaryGeneratedAt = structuredSummaryGeneratedAt
        self.dataVersion = dataVersion
    }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case title
        case transcriptChunks
        case userNotes
        case contextItems
        case generatedNotes
        case followUpTasks
        case templateId
        case speakerParticipantNames
        case speakerNameMappings
        case oneLiner
        case decisions
        case risks
        case openQuestions
        case discussions
        case milestones
        case host
        case location
        case diagrams
        case structuredSummarySourceHash
        case structuredSummaryGeneratedAt
        case dataVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        transcriptChunks = try container.decodeIfPresent([TranscriptChunk].self, forKey: .transcriptChunks) ?? []
        userNotes = try container.decodeIfPresent(String.self, forKey: .userNotes) ?? ""
        let decodedContextItems = try container.decodeIfPresent([MeetingContextItem].self, forKey: .contextItems) ?? []
        contextItems = Self.normalizedContextItems(decodedContextItems, legacyUserNotes: userNotes, date: date)
        generatedNotes = try container.decodeIfPresent(String.self, forKey: .generatedNotes) ?? ""
        followUpTasks = try container.decodeIfPresent([MeetingFollowUpTask].self, forKey: .followUpTasks) ?? []
        templateId = try container.decodeIfPresent(UUID.self, forKey: .templateId)
        speakerParticipantNames = Self.normalizedParticipantNames(
            try container.decodeIfPresent([String].self, forKey: .speakerParticipantNames) ?? []
        )
        speakerNameMappings = Self.normalizedSpeakerNameMappings(
            try container.decodeIfPresent([String: String].self, forKey: .speakerNameMappings) ?? [:]
        )
        oneLiner = try container.decodeIfPresent(String.self, forKey: .oneLiner) ?? ""
        decisions = try container.decodeIfPresent([MeetingDecision].self, forKey: .decisions) ?? []
        risks = try container.decodeIfPresent([MeetingRisk].self, forKey: .risks) ?? []
        openQuestions = try container.decodeIfPresent([MeetingOpenQuestion].self, forKey: .openQuestions) ?? []
        discussions = try container.decodeIfPresent([MeetingDiscussion].self, forKey: .discussions) ?? []
        milestones = try container.decodeIfPresent([MeetingMilestone].self, forKey: .milestones) ?? []
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        diagrams = try container.decodeIfPresent([MeetingDiagram].self, forKey: .diagrams) ?? []
        structuredSummarySourceHash = try container.decodeIfPresent(String.self, forKey: .structuredSummarySourceHash) ?? ""
        structuredSummaryGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .structuredSummaryGeneratedAt)
        dataVersion = try container.decodeIfPresent(Int.self, forKey: .dataVersion) ?? 1
    }

    var structuredSummaryCurrentSourceHash: String {
        let sourceText = formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(sourceText.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var isStructuredSummaryStale: Bool {
        !structuredSummarySourceHash.isEmpty &&
        structuredSummarySourceHash != structuredSummaryCurrentSourceHash
    }

    var hasMeetingContext: Bool {
        contextItems.contains { !$0.trimmedText.isEmpty } ||
        !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var formattedMeetingContext: String {
        let usableItems = contextItems.filter { !$0.trimmedText.isEmpty }
        if usableItems.isEmpty {
            return userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return usableItems.map { item in
            var lines = [
                "<item type=\"\(item.kind.rawValue)\" title=\"\(item.displayTitle)\">"
            ]

            if let source = item.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                lines.append("来源：\(source)")
                lines.append("")
            }

            lines.append(item.trimmedText)
            lines.append("</item>")
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    mutating func syncLegacyUserNotesFromContext() {
        userNotes = formattedMeetingContext
    }

    private static func normalizedContextItems(
        _ items: [MeetingContextItem],
        legacyUserNotes: String,
        date: Date
    ) -> [MeetingContextItem] {
        if !items.isEmpty {
            return items
        }

        let trimmedLegacyNotes = legacyUserNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLegacyNotes.isEmpty else { return [] }

        return [
            MeetingContextItem(
                kind: .text,
                title: "手动补充",
                extractedText: trimmedLegacyNotes,
                createdAt: date
            )
        ]
    }
    
    // Computed property for backward compatibility with existing code
    var transcript: String {
        return transcriptChunks
            .sortedByTranscriptTimeline()
            .filter { $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }

    var hasFinalTranscript: Bool {
        transcriptChunks.contains {
            $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // Formatted transcript for copying and note generation with speaker/time labels
    var formattedTranscript: String {
        let finalChunks = transcriptDisplayChunks.filter { $0.isFinal }
        
        guard !finalChunks.isEmpty else { return "" }
        
        return finalChunks
            .map { chunk in
                let roleLabel = [chunk.sourceLabel, chunk.speakerLabel]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")

                if roleLabel.isEmpty {
                    return "\(chunk.timeLabel): \(chunk.text)"
                }

                return "\(roleLabel) · \(chunk.timeLabel): \(chunk.text)"
            }
            .joined(separator: "\n")
    }

    var transcriptDisplayChunks: [TranscriptDisplayChunk] {
        guard !transcriptChunks.isEmpty else { return [] }

        let speakerLabels = buildSpeakerLabelMap()
        var groupedChunks: [TranscriptDisplayChunk] = []
        var currentGroup: TranscriptDisplayGroup?

        for chunk in transcriptChunks.sortedByTranscriptTimeline() {
            let trimmedText = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }

            let displaySpeakerLabel = displaySpeakerLabel(for: chunk, labelMap: speakerLabels)
            let sourceLabel = chunk.source.displayName

            if var group = currentGroup, group.canAppend(chunk: chunk) {
                group.append(chunk: chunk, text: trimmedText)
                currentGroup = group
                continue
            }

            if let group = currentGroup {
                groupedChunks.append(group.makeDisplayChunk())
            }

            currentGroup = TranscriptDisplayGroup(
                id: chunk.id,
                timestamp: chunk.timestamp,
                source: chunk.source,
                sourceLabel: sourceLabel,
                speakerKey: chunk.speakerIdentityKey,
                speakerLabel: displaySpeakerLabel,
                textParts: [trimmedText],
                isFinal: chunk.isFinal,
                startTime: chunk.startTime,
                endTime: chunk.endTime
            )
        }

        if let group = currentGroup {
            groupedChunks.append(group.makeDisplayChunk())
        }

        return groupedChunks
    }

    // Collapsed chunks for UI display
    var collapsedTranscriptChunks: [CollapsedTranscriptChunk] {
        guard !transcriptChunks.isEmpty else { return [] }
        
        var result: [CollapsedTranscriptChunk] = []
        var currentSource: AudioSource?
        var currentTexts: [String] = []
        var currentTimestamp: Date?
        
        for chunk in transcriptChunks.sortedByTranscriptTimeline() {
            if chunk.source != currentSource {
                // Finish previous section if exists
                if let source = currentSource, !currentTexts.isEmpty, let timestamp = currentTimestamp {
                    let combinedText = currentTexts.joined(separator: " ")
                    result.append(CollapsedTranscriptChunk(
                        timestamp: timestamp,
                        source: source,
                        combinedText: combinedText
                    ))
                }
                
                // Start new section
                currentSource = chunk.source
                currentTexts = [chunk.text]
                currentTimestamp = chunk.timestamp
            } else {
                // Same source, add to current section
                currentTexts.append(chunk.text)
            }
        }
        
        // Finish last section
        if let source = currentSource, !currentTexts.isEmpty, let timestamp = currentTimestamp {
            let combinedText = currentTexts.joined(separator: " ")
            result.append(CollapsedTranscriptChunk(
                timestamp: timestamp,
                source: source,
                combinedText: combinedText
            ))
        }
        
        return result
    }
    
    // Separate computed properties for mic and system transcripts
    var micTranscript: String {
        return transcriptChunks
            .sortedByTranscriptTimeline()
            .filter { $0.source == .mic && $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }
    
    var systemTranscript: String {
        return transcriptChunks
            .sortedByTranscriptTimeline()
            .filter { $0.source == .system && $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }

    private func buildSpeakerLabelMap() -> [String: String] {
        var result: [String: String] = [:]
        var nextSpeakerIndex = 0

        for chunk in transcriptChunks.sortedByTranscriptTimeline() {
            guard let key = chunk.speakerIdentityKey, result[key] == nil else { continue }
            result[key] = Self.speakerLabel(for: nextSpeakerIndex)
            nextSpeakerIndex += 1
        }

        return result
    }

    private func displaySpeakerLabel(for chunk: TranscriptChunk, labelMap: [String: String]) -> String? {
        if let key = chunk.speakerIdentityKey,
           let customName = speakerNameMappings[key],
           !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customName
        }

        if let key = chunk.speakerIdentityKey, let label = labelMap[key] {
            return label
        }

        return nil
    }

    var speakerNamingOptions: [TranscriptSpeakerNamingOption] {
        let labelMap = buildSpeakerLabelMap()
        var sampleTextsByKey: [String: [String]] = [:]

        for chunk in transcriptChunks.sortedByTranscriptTimeline() {
            guard let key = chunk.speakerIdentityKey else { continue }
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            var samples = sampleTextsByKey[key] ?? []
            if samples.count < 2 {
                samples.append(text)
                sampleTextsByKey[key] = samples
            }
        }

        return labelMap
            .map { key, defaultLabel in
                TranscriptSpeakerNamingOption(
                    id: key,
                    defaultLabel: defaultLabel,
                    currentName: speakerNameMappings[key],
                    sampleTexts: sampleTextsByKey[key] ?? []
                )
            }
            .sorted { lhs, rhs in
                lhs.defaultLabel.localizedStandardCompare(rhs.defaultLabel) == .orderedAscending
            }
    }

    mutating func applySpeakerNaming(participantNames: [String], mappings: [String: String]) {
        let knownSpeakerKeys = Set(speakerNamingOptions.map(\.id))
        speakerParticipantNames = Self.normalizedParticipantNames(participantNames)
        speakerNameMappings = Self.normalizedSpeakerNameMappings(mappings)
            .filter { knownSpeakerKeys.contains($0.key) }
    }

    private static func normalizedParticipantNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(name)
        }

        return result
    }

    private static func normalizedSpeakerNameMappings(_ mappings: [String: String]) -> [String: String] {
        mappings.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !name.isEmpty else { return }
            result[key] = name
        }
    }

    private static func speakerLabel(for index: Int) -> String {
        "发言人 \(alphabeticLabel(for: index))"
    }

    private static func alphabeticLabel(for index: Int) -> String {
        var value = index
        var result = ""

        repeat {
            let remainder = value % 26
            let character = UnicodeScalar(65 + remainder).map(Character.init) ?? "A"
            result.insert(character, at: result.startIndex)
            value = value / 26 - 1
        } while value >= 0

        return result
    }

    private static func formattedTimeLabel(for chunk: TranscriptChunk) -> String {
        if let startTime = chunk.startTime, let endTime = chunk.endTime {
            return "\(formattedMilliseconds(startTime)) - \(formattedMilliseconds(endTime))"
        }

        if let startTime = chunk.startTime {
            return formattedMilliseconds(startTime)
        }

        if let endTime = chunk.endTime {
            return formattedMilliseconds(endTime)
        }

        return chunk.timestamp.formatted(date: .omitted, time: .shortened)
    }

    private static func formattedMilliseconds(_ milliseconds: Int) -> String {
        let clampedMilliseconds = max(0, milliseconds)
        let totalSeconds = clampedMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct MeetingSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    var title: String
    var templateId: UUID?
    var preview: String
    var searchableText: String
    var hasTranscript: Bool
    var hasGeneratedNotes: Bool
    var dataVersion: Int

    init(meeting: Meeting) {
        id = meeting.id
        date = meeting.date
        title = meeting.title
        templateId = meeting.templateId
        preview = Self.makePreview(from: meeting)
        searchableText = Self.makeSearchableText(from: meeting)
        hasTranscript = meeting.hasFinalTranscript
        hasGeneratedNotes = !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        dataVersion = meeting.dataVersion
    }

    var placeholderMeeting: Meeting {
        Meeting(
            id: id,
            date: date,
            title: title,
            templateId: templateId,
            dataVersion: dataVersion
        )
    }

    private static func makePreview(from meeting: Meeting) -> String {
        if !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }

        if !meeting.formattedMeetingContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(meeting.formattedMeetingContext.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }

        if let transcriptPreview = meeting.transcriptChunks.sortedByTranscriptTimeline().first(where: {
            $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return String(transcriptPreview.prefix(160))
        }

        return ""
    }

    private static func makeSearchableText(from meeting: Meeting) -> String {
        [
            meeting.title,
            String(meeting.formattedMeetingContext.prefix(500)),
            String(meeting.generatedNotes.prefix(500)),
            makePreview(from: meeting)
        ]
        .joined(separator: "\n")
    }
}

private struct TranscriptDisplayGroup {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let sourceLabel: String
    let speakerKey: String?
    let speakerLabel: String?
    var textParts: [String]
    var isFinal: Bool
    var startTime: Int?
    var endTime: Int?

    mutating func append(chunk: TranscriptChunk, text: String) {
        textParts.append(text)
        isFinal = isFinal && chunk.isFinal
        startTime = Self.mergedStartTime(with: chunk.startTime, current: startTime)
        endTime = Self.mergedEndTime(with: chunk.endTime, current: endTime)
    }

    func canAppend(chunk: TranscriptChunk) -> Bool {
        guard let currentKey = speakerKey, let chunkKey = chunk.speakerIdentityKey else {
            return false
        }

        return currentKey == chunkKey && source == chunk.source
    }

    func makeDisplayChunk() -> TranscriptDisplayChunk {
        TranscriptDisplayChunk(
            id: id,
            timestamp: timestamp,
            source: source,
            sourceLabel: sourceLabel,
            text: textParts.joined(separator: "\n"),
            isFinal: isFinal,
            speakerLabel: speakerLabel,
            timeLabel: Self.formattedTimeLabel(
                startTime: startTime,
                endTime: endTime,
                fallbackTimestamp: timestamp
            )
        )
    }

    private static func mergedStartTime(with newValue: Int?, current: Int?) -> Int? {
        switch (current, newValue) {
        case let (.some(current), .some(newValue)):
            return min(current, newValue)
        case (.none, .some(let newValue)):
            return newValue
        default:
            return current
        }
    }

    private static func mergedEndTime(with newValue: Int?, current: Int?) -> Int? {
        switch (current, newValue) {
        case let (.some(current), .some(newValue)):
            return max(current, newValue)
        case (.none, .some(let newValue)):
            return newValue
        default:
            return current
        }
    }

    private static func formattedTimeLabel(startTime: Int?, endTime: Int?, fallbackTimestamp: Date) -> String {
        if let startTime, let endTime {
            return "\(formattedMilliseconds(startTime)) - \(formattedMilliseconds(endTime))"
        }

        if let startTime {
            return formattedMilliseconds(startTime)
        }

        if let endTime {
            return formattedMilliseconds(endTime)
        }

        return fallbackTimestamp.formatted(date: .omitted, time: .shortened)
    }

    private static func formattedMilliseconds(_ milliseconds: Int) -> String {
        let clampedMilliseconds = max(0, milliseconds)
        let totalSeconds = clampedMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
