import Foundation
import SwiftUI
import Combine

// Add notification name for meeting saved events
extension Notification.Name {
    static let meetingSaved = Notification.Name("MeetingSaved")
    static let meetingWillDelete = Notification.Name("MeetingWillDelete")
    static let meetingDeleted = Notification.Name("MeetingDeleted")
    static let meetingRenamed = Notification.Name("MeetingRenamed")
}

enum AINotesSubTab {
    case notes   // 会议纪要：markdown 格式纪要
    case digest  // 行动摘要：结构化纪要
}

enum MeetingViewTab: String, CaseIterable {
    case context = "Prep"
    case transcript = "Transcript"
    case enhancedNotes = "AI Notes"
    case summary = "Summary"

    static let displayOrder: [MeetingViewTab] = [.context, .transcript, .enhancedNotes]

    var chineseLabel: String {
        switch self {
        case .context: return "会议资料"
        case .transcript: return "转录原文"
        case .enhancedNotes: return "AI纪要"
        case .summary: return "摘要"
        }
    }

    func label(using langMgr: LanguageManager) -> String {
        switch self {
        case .context: return langMgr.t("会议资料", "Prep")
        case .transcript: return langMgr.t("转录原文", "Transcript")
        case .enhancedNotes: return langMgr.t("AI纪要", "AI Notes")
        case .summary: return langMgr.t("摘要", "Digest")
        }
    }
}



@MainActor
class MeetingViewModel: ObservableObject {
    @Published var meeting: Meeting
    @Published var isGeneratingNotes = false
    @Published var errorMessage: String?
    @Published private var recordingStateChanged = false // Trigger SwiftUI updates
    @Published var isValidatingKey = false // Indicates API key validation in progress
    @Published var isStartingRecording = false // Indicates recording start in progress
    @Published var isLoadingMeeting = false
    @Published var isExtractingFollowUpTasks = false
    @Published var isExtractingStructuredSummary = false
    @Published var structuredSummaryErrorMessage: String?
    @Published var syncingFollowUpTaskIds: Set<UUID> = []
    @Published var transcriptDisplayChunks: [TranscriptDisplayChunk] = []
    @Published private var hasStartedRecordingSession = false
    @Published var toolbarHasFinalTranscript = false
    @Published var toolbarHasGeneratedNotes = false
    @Published var toolbarHasStartedRecordingSession = false
    
    // Computed property to determine if Generate button should animate
    var shouldAnimateGenerateButton: Bool {
        let generateButtonEnabled = toolbarHasFinalTranscript && !isGeneratingNotes && !isRecording && !isStartingRecording
        let noEnhancedNotesYet = !toolbarHasGeneratedNotes
        return generateButtonEnabled && noEnhancedNotesYet
    }
    
    // Computed property to determine if Transcribe button should animate
    var shouldAnimateTranscribeButton: Bool {
        return !isRecording && !toolbarHasStartedRecordingSession && !isStartingRecording
    }
    
    // Computed property that always uses the direct RecordingSessionManager check
    var isRecording: Bool {
        return recordingSessionManager.isRecordingMeeting(meeting.id)
    }

    /// 用户已点结束录制，但 STT final flush 还在收尾——UI 据此显示 spinner。
    /// 只在当前 detail 对应的活动会议上为 true，避免影响其它详情页。
    var isStoppingRecording: Bool {
        return recordingSessionManager.isStoppingRecording
            && recordingSessionManager.activeMeetingId == meeting.id
    }

    var isRecoveringSTT: Bool {
        recordingSessionManager.isRecoveringSTT
            && recordingSessionManager.activeMeetingId == meeting.id
    }
    @Published var selectedTab: MeetingViewTab
    @Published var aiNotesSubTab: AINotesSubTab = .notes

    var notesOutputFormat: NotesOutputFormat {
        UserDefaultsManager.shared.notesOutputFormat
    }

    @Published var isDeleted = false
    @Published var templates: [NoteTemplate] = []
    @Published var selectedTemplateId: UUID?
    
    private let recordingSessionManager = RecordingSessionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var isNewMeeting = false
    private var hasCompletedInitialLoad = false
    private var isApplyingTemplateSelection = false
    private var hasLocalUnsavedChanges = false
    private var isApplyingLoadedMeeting = false
    private var isStreamingGeneratedNotes = false
    private var generationTask: Task<Void, Never>?
    private var activeGenerationMeetingId: UUID?
    private var generationCounter: Int = 0
    private var structuredExtractionToken: UUID?
    private var activeStructuredExtractionMeetingId: UUID?
    private var activeFollowUpExtractionMeetingId: UUID?
    
    // Computed property to check if meeting is empty
    var isEmpty: Bool {
        return meeting.transcriptChunks.isEmpty && 
               !meeting.hasMeetingContext &&
               meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    init(
        meeting: Meeting = Meeting(),
        initialSelectedTab: MeetingViewTab? = nil,
        initialHasTranscript: Bool? = nil,
        initialHasGeneratedNotes: Bool? = nil
    ) {
        print("🆕 Using provided meeting placeholder: \(meeting.id)")
        self.meeting = meeting
        self.transcriptDisplayChunks = meeting.transcriptDisplayChunks
        self.selectedTab = initialSelectedTab ?? Self.preferredInitialTab(for: meeting)
        self.hasStartedRecordingSession = !meeting.transcriptChunks.isEmpty
        self.toolbarHasFinalTranscript = initialHasTranscript ?? meeting.hasFinalTranscript
        self.toolbarHasGeneratedNotes = initialHasGeneratedNotes ?? !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.toolbarHasStartedRecordingSession = initialHasTranscript ?? !meeting.transcriptChunks.isEmpty

        // Detect if this is a new meeting based on content, not storage existence
        isNewMeeting = isEmpty

        loadFullMeetingIfNeeded()
        
        // Load templates and selected template
        loadTemplates()
        // Observe template selection: save to meeting and regenerate notes on changes (skip initial)
        $selectedTemplateId
            .dropFirst()
            .sink { [weak self] newTemplateId in
                guard let self = self else { return }
                self.meeting.templateId = newTemplateId
                if self.isApplyingTemplateSelection {
                    self.saveMeeting()
                    return
                }
                Task {
                    guard self.meeting.hasFinalTranscript,
                          NotesGenerator.shared.isConfigured() else {
                        self.saveMeeting()
                        return
                    }
                    await self.generateNotes()
                }
            }
            .store(in: &cancellables)
        
        // Trigger SwiftUI updates when recording state changes
        Publishers.CombineLatest(recordingSessionManager.$isRecording, recordingSessionManager.$activeMeetingId)
            .sink { [weak self] (isRecording, activeMeetingId) in
                guard let self = self else { return }
                
                // If recording started for this meeting, end starting state
                if isRecording && activeMeetingId == self.meeting.id {
                    self.isStartingRecording = false
                }
                // Toggle the dummy property to trigger SwiftUI re-render
                self.recordingStateChanged.toggle()
            }
            .store(in: &cancellables)
        
        // Update error message when recording session manager encounters errors
        recordingSessionManager.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] errorMessage in
                guard let self else { return }

                let isCurrentRecordingMeeting = self.recordingSessionManager.activeMeetingId == self.meeting.id
                    || self.recordingSessionManager.isRecordingMeeting(self.meeting.id)
                guard self.isStartingRecording || isCurrentRecordingMeeting else {
                    return
                }

                // Suppress non-critical, self-healing errors that should not distract the user
                let lowercased = errorMessage.lowercased()
                if errorMessage == ErrorMessage.sessionExpired || lowercased.contains("socket is not connected") {
                    print("ℹ️ Suppressed non-critical error: \(errorMessage)")
                    return
                }
                self.errorMessage = errorMessage
                print("🚨 Recording Session Manager Error: \(errorMessage)")
            }
            .store(in: &cancellables)
        
        // If currently recording this meeting, load live transcript chunks
        if recordingSessionManager.isRecordingMeeting(meeting.id) {
            self.meeting.transcriptChunks = recordingSessionManager.getTranscriptChunks(for: meeting.id)
            refreshTranscriptDisplayChunks()
            refreshToolbarSnapshot()
        }

        // Listen to real-time transcript updates for this meeting if it's being recorded
        recordingSessionManager.$activeRecordingTranscriptChunksUpdated
            .dropFirst()
            .sink { [weak self] updatedChunks in
                guard let self = self else { return }
                // Keep applying late final STT updates during the short background stop flush.
                if recordingSessionManager.hasActiveSession(for: self.meeting.id) {
                    self.meeting.transcriptChunks = updatedChunks
                    self.refreshTranscriptDisplayChunks()
                    self.refreshToolbarSnapshot()
                }
            }
            .store(in: &cancellables)
        

        
        // Auto-save when meeting properties change
        $meeting
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] meeting in
                guard let self else { return }
                guard !self.isApplyingLoadedMeeting else { return }
                guard !self.isStreamingGeneratedNotes else { return }

                self.hasLocalUnsavedChanges = true

                guard self.hasCompletedInitialLoad else { return }
                print("🔄 Auto-saving meeting: \(meeting.id) - title: '\(meeting.title)', context: '\(meeting.formattedMeetingContext.prefix(50))...'")
                self.saveMeeting()
            }
            .store(in: &cancellables)

        // Sync title when renamed externally (e.g. from sidebar context menu)
        NotificationCenter.default.publisher(for: .meetingRenamed)
            .receive(on: RunLoop.main)
            .compactMap { $0.object as? Meeting }
            .sink { [weak self] renamed in
                guard let self, renamed.id == self.meeting.id else { return }
                self.meeting.title = renamed.title
            }
            .store(in: &cancellables)

        // If this meeting is deleted from the sidebar while its detail view is
        // open, prevent the detail view's disappear/auto-save hooks from
        // recreating the just-deleted file.
        // willDelete 必须同步执行——否则 sink 会被推到下一个 run loop tick，
        // 而 ListVM 在 post 之后立刻调用 deleteMeetingSummary，待 sink 跑时
        // 文件已被删、deletedMeetingIDs 已 insert，saveMeeting 会被拦截。
        NotificationCenter.default.publisher(for: .meetingWillDelete)
            .compactMap { $0.object as? Meeting }
            .sink { [weak self] deleting in
                guard let self, deleting.id == self.meeting.id else { return }
                self.cancelGeneratingNotes(for: deleting.id)
                self.saveMeeting()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .meetingDeleted)
            .receive(on: RunLoop.main)
            .compactMap { $0.object as? Meeting }
            .sink { [weak self] deleted in
                guard let self, deleted.id == self.meeting.id else { return }
                self.cancelGeneratingNotes(for: deleted.id)
                self.hasLocalUnsavedChanges = false
                self.isDeleted = true
            }
            .store(in: &cancellables)
    }

    func switchToMeeting(
        _ meeting: Meeting,
        initialSelectedTab: MeetingViewTab? = nil,
        initialHasTranscript: Bool? = nil,
        initialHasGeneratedNotes: Bool? = nil
    ) {
        guard meeting.id != self.meeting.id else { return }

        deleteIfEmpty()

        print("🔁 Switching detail meeting: \(meeting.id)")
        isApplyingLoadedMeeting = true
        self.meeting = meeting
        self.transcriptDisplayChunks = meeting.transcriptDisplayChunks
        isApplyingLoadedMeeting = false

        errorMessage = nil
        isValidatingKey = false
        isStartingRecording = false
        isLoadingMeeting = false
        isGeneratingNotes = activeGenerationMeetingId == meeting.id
        isStreamingGeneratedNotes = activeGenerationMeetingId == meeting.id
        isExtractingFollowUpTasks = activeFollowUpExtractionMeetingId == meeting.id
        isExtractingStructuredSummary = activeStructuredExtractionMeetingId == meeting.id
        syncingFollowUpTaskIds = []
        hasLocalUnsavedChanges = false
        hasCompletedInitialLoad = false
        isDeleted = false
        isNewMeeting = isEmpty
        hasStartedRecordingSession = !meeting.transcriptChunks.isEmpty
        toolbarHasFinalTranscript = initialHasTranscript ?? meeting.hasFinalTranscript
        toolbarHasGeneratedNotes = initialHasGeneratedNotes ?? !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        toolbarHasStartedRecordingSession = initialHasTranscript ?? !meeting.transcriptChunks.isEmpty
        selectedTab = initialSelectedTab ?? Self.preferredInitialTab(for: meeting)
        aiNotesSubTab = .notes

        if recordingSessionManager.isRecordingMeeting(meeting.id) {
            self.meeting.transcriptChunks = recordingSessionManager.getTranscriptChunks(for: meeting.id)
            refreshTranscriptDisplayChunks()
            refreshToolbarSnapshot()
        }

        loadFullMeetingIfNeeded()
        loadTemplates()
    }

    
    var recordingButtonText: String {
        let lang = LanguageManager.shared
        if isStoppingRecording {
            return lang.t("补全中", "Finalizing")
        }
        if isRecoveringSTT {
            return lang.t("恢复中", "Recovering")
        }
        if isRecording {
            return lang.t("结束录制", "End Recording")
        }
        return toolbarHasStartedRecordingSession ? lang.t("继续录制", "Resume Recording") : lang.t("开始录制", "Start Recording")
    }

    var recordingButtonIconName: String {
        if isRecording {
            return "stop.circle.fill"
        }
        return toolbarHasStartedRecordingSession ? "record.circle" : "record.circle.fill"
    }

    var recordingStartedAt: Date? {
        guard isRecording else { return nil }
        return recordingSessionManager.activeRecordingStartedAt
    }

    var transcriptCharacterCount: Int {
        meeting.transcriptChunks.reduce(0) { total, chunk in
            total + chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
    }

    var hasGeneratedNotes: Bool {
        !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasStructuredSummaryContent: Bool {
        !meeting.oneLiner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !meeting.discussions.isEmpty ||
            !meeting.decisions.isEmpty ||
            !meeting.risks.isEmpty ||
            !meeting.openQuestions.isEmpty ||
            !meeting.milestones.isEmpty
    }

    var isStructuredSummaryStale: Bool {
        meeting.isStructuredSummaryStale
    }

    func showActionDigest() {
        selectedTab = .enhancedNotes
        aiNotesSubTab = .digest
        extractStructuredSummaryIfNeeded()
    }

    func extractStructuredSummaryIfNeeded() {
        guard hasGeneratedNotes, !hasStructuredSummaryContent, !isExtractingStructuredSummary else { return }
        Task { await extractStructuredSummary() }
    }

    func refreshStructuredSummary() {
        guard hasGeneratedNotes, !isExtractingStructuredSummary else { return }
        Task { await extractStructuredSummary() }
    }

    var canExportCurrentTabHTML: Bool {
        switch selectedTab {
        case .context:
            return meeting.hasMeetingContext
        case .transcript:
            return meeting.hasFinalTranscript
        case .enhancedNotes:
            switch aiNotesSubTab {
            case .notes:
                return !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .digest:
                return hasStructuredSummaryContent || !meeting.followUpTasks.isEmpty
            }
        case .summary:
            return !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    func toggleRecording() {
        // Prevent duplicate actions while validating API key, starting, or finalizing a stop.
        if isValidatingKey || isStartingRecording || isStoppingRecording { return }
        // Use the same computed isRecording property for perfect consistency
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func loadFullMeetingIfNeeded() {
        isLoadingMeeting = true

        Task { [weak self] in
            guard let self else { return }
            let meetingId = self.meeting.id
            let savedMeeting = await Task.detached {
                LocalStorageManager.shared.loadMeeting(id: meetingId)
            }.value

            guard let savedMeeting else {
                self.isLoadingMeeting = false
                self.hasCompletedInitialLoad = true
                return
            }
            guard self.meeting.id == meetingId else { return }

            print("🔄 Loaded full meeting: \(meetingId)")
            self.isApplyingLoadedMeeting = true
            let isLiveRecording = self.recordingSessionManager.isRecordingMeeting(meetingId)
            if isLiveRecording {
                // 直播录制中：transcriptChunks 以内存中的活跃片段为准，
                // 仅从磁盘合并其它持久化字段，避免覆盖最新的 final/interim。
                var merged = self.hasLocalUnsavedChanges
                    ? self.mergingLoadedMeeting(savedMeeting, withLocalEditsFrom: self.meeting)
                    : savedMeeting
                merged.transcriptChunks = self.recordingSessionManager.getTranscriptChunks(for: meetingId)
                self.meeting = merged
            } else {
                self.meeting = self.hasLocalUnsavedChanges
                    ? self.mergingLoadedMeeting(savedMeeting, withLocalEditsFrom: self.meeting)
                    : savedMeeting
            }
            self.isApplyingLoadedMeeting = false
            self.refreshTranscriptDisplayChunks()
            self.isNewMeeting = self.isEmpty
            self.hasStartedRecordingSession = !self.meeting.transcriptChunks.isEmpty
            self.refreshToolbarSnapshot()
            self.selectedTab = Self.preferredInitialTab(for: self.meeting)
            self.loadTemplates()
            self.isLoadingMeeting = false
            self.hasCompletedInitialLoad = true
        }
    }

    private func mergingLoadedMeeting(_ loaded: Meeting, withLocalEditsFrom local: Meeting) -> Meeting {
        var merged = loaded
        merged.title = local.title
        merged.userNotes = local.userNotes
        merged.contextItems = local.contextItems
        merged.generatedNotes = local.generatedNotes
        merged.templateId = local.templateId ?? loaded.templateId

        merged.transcriptChunks = local.transcriptChunks
            .mergingTranscriptCorrections(preservingMissingFinalChunksFrom: loaded.transcriptChunks)

        return merged
    }

    private static func preferredInitialTab(for meeting: Meeting) -> MeetingViewTab {
        let hasEnhancedNotes = !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasEnhancedNotes ? .enhancedNotes : .transcript
    }

    private func refreshTranscriptDisplayChunks() {
        transcriptDisplayChunks = meeting.transcriptDisplayChunks
    }

    private func refreshToolbarSnapshot() {
        toolbarHasFinalTranscript = meeting.hasFinalTranscript
        toolbarHasGeneratedNotes = !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        toolbarHasStartedRecordingSession = !meeting.transcriptChunks.isEmpty
    }

    var speakerNamingOptions: [TranscriptSpeakerNamingOption] {
        meeting.speakerNamingOptions
    }

    var speakerParticipantNames: [String] {
        normalizedSpeakerParticipantNames(
            UserDefaultsManager.shared.speakerParticipantNames
            + meeting.speakerParticipantNames
            + Array(meeting.speakerNameMappings.values)
        )
    }

    func applySpeakerNaming(participantNames: [String], mappings: [String: String]) {
        let normalizedParticipants = normalizedSpeakerParticipantNames(participantNames)
        UserDefaultsManager.shared.speakerParticipantNames = normalizedParticipants
        meeting.applySpeakerNaming(participantNames: normalizedParticipants, mappings: mappings)
        refreshTranscriptDisplayChunks()
        saveMeeting()
    }

    private func normalizedSpeakerParticipantNames(_ names: [String]) -> [String] {
        var seenNames = Set<String>()
        var result: [String] = []

        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            result.append(name)
        }

        return result
    }
    
    func startRecording() {
        guard !isStartingRecording else { return }
        isStartingRecording = true
        errorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch UserDefaultsManager.shared.sttEngine {
                case .appleSpeechAnalyzer:
                    try await SpeechModelInstaller.shared.ensureReadyForUse()
                case .sherpaSenseVoice:
                    try await SherpaModelManager.shared.ensureReadyForUse()
                }
                self.hasStartedRecordingSession = true
                self.toolbarHasStartedRecordingSession = true
                self.recordingSessionManager.startRecording(for: self.meeting.id, existingChunks: self.meeting.transcriptChunks)
            } catch {
                self.errorMessage = ErrorHandler.shared.handleError(error)
                self.isStartingRecording = false
            }
        }
    }
    
    func stopRecording() {
        recordingSessionManager.stopRecording()
        saveMeeting()
    }
    
    func loadTemplates() {
        templates = LocalStorageManager.shared.loadTemplates()
        isApplyingTemplateSelection = true
        defer { isApplyingTemplateSelection = false }

        if let meetingTemplateId = meeting.templateId,
           templates.contains(where: { $0.id == meetingTemplateId }) {
            selectedTemplateId = meetingTemplateId
            return
        }

        selectedTemplateId = fallbackTemplateId()
        meeting.templateId = selectedTemplateId
    }

    private func fallbackTemplateId() -> UUID? {
        if let defaultTemplate = templates.first(where: { $0.title == "标准会议" || $0.title == "Standard Meeting" }) {
            return defaultTemplate.id
        }

        return templates.first?.id
    }
    
    func generateNotes() async {
        guard generationTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runGenerateNotes()
        }
        generationTask = task
        await task.value
    }

    func cancelGeneratingNotes() {
        cancelGeneratingNotes(for: nil)
    }

    private func cancelGeneratingNotes(for meetingId: UUID?) {
        if let meetingId, activeGenerationMeetingId != meetingId {
            return
        }
        generationCounter += 1
        generationTask?.cancel()
        generationTask = nil
        activeGenerationMeetingId = nil
        isGeneratingNotes = false
        isStreamingGeneratedNotes = false
    }

    private func runGenerateNotes() async {
        guard meeting.hasFinalTranscript else {
            errorMessage = ErrorMessage.noTranscript
            return
        }

        isGeneratingNotes = true
        isStreamingGeneratedNotes = true
        errorMessage = nil
        generationCounter += 1
        let myGeneration = generationCounter
        let meetingId = meeting.id
        let meetingSnapshot = meeting
        activeGenerationMeetingId = meetingId
        let templateIdSnapshot = selectedTemplateId
        defer {
            if generationCounter == myGeneration {
                activeGenerationMeetingId = nil
                isGeneratingNotes = false
                isStreamingGeneratedNotes = false
                generationTask = nil
            }
        }

        let previousGeneratedNotes = meetingSnapshot.generatedNotes
        let previousOneLiner = meetingSnapshot.oneLiner
        var generatedMeeting = meetingSnapshot
        var receivedContent = false

        // Load settings for generation
        let userBlurb = UserDefaultsManager.shared.userBlurb
        let systemPrompt = UserDefaultsManager.shared.systemPrompt

        // Use streaming generation
        let stream = NotesGenerator.shared.generateNotesStream(
            meeting: meetingSnapshot,
            userBlurb: userBlurb,
            systemPrompt: systemPrompt,
            templateId: templateIdSnapshot
        )

        var hasError = false
        for await result in stream {
            guard generationCounter == myGeneration else {
                hasError = true
                break
            }

            if Task.isCancelled {
                if meeting.id == meetingId {
                    meeting.generatedNotes = previousGeneratedNotes
                    meeting.oneLiner = previousOneLiner
                    toolbarHasGeneratedNotes = !previousGeneratedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                hasError = true
                break
            }

            switch result {
            case .content(let chunk):
                if !receivedContent {
                    generatedMeeting.generatedNotes = ""
                    // Drop the stale one-liner so the AI-notes header card disappears
                    // immediately; extractStructuredSummary will repopulate after the
                    // new notes finish. Other structured fields stay visible on the
                    // digest tab until they're refreshed.
                    generatedMeeting.oneLiner = ""
                    if meeting.id == meetingId {
                        meeting.generatedNotes = ""
                        meeting.oneLiner = ""
                    }
                    receivedContent = true
                }
                generatedMeeting.generatedNotes += chunk
                if meeting.id == meetingId {
                    meeting.generatedNotes += chunk
                    toolbarHasGeneratedNotes = true
                }
            case .error(let error):
                if meeting.id == meetingId {
                    meeting.generatedNotes = previousGeneratedNotes
                    meeting.oneLiner = previousOneLiner
                    toolbarHasGeneratedNotes = !previousGeneratedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if meeting.id == meetingId {
                    errorMessage = error
                }
                hasError = true
                print("🚨 Note Generation Error: \(error)")
                break
            }
        }

        if Task.isCancelled {
            hasError = true
        }
        
        // Only save if there was no error
        if !hasError {
            if generatedMeeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let generated = await NotesGenerator.shared.generateTitle(meeting: generatedMeeting) {
                    guard generationCounter == myGeneration else { return }
                    generatedMeeting.title = generated
                }
            }
            guard generationCounter == myGeneration else { return }
            isStreamingGeneratedNotes = false
            savePersistedMeeting(generatedMeeting)
            if meeting.id == meetingId {
                meeting = generatedMeeting
                refreshToolbarSnapshot()
                selectedTab = .enhancedNotes
                aiNotesSubTab = .notes
            }
            Task { await self.extractStructuredSummary(from: generatedMeeting) }
        }
    }

    func saveMeeting() {
        if isDeleted || !hasCompletedInitialLoad { return }
        print("💾 Saving meeting: \(meeting.id)")
        let success = LocalStorageManager.shared.saveMeeting(meeting)
        print("💾 Save result: \(success ? "SUCCESS" : "FAILED")")
        if success {
            hasLocalUnsavedChanges = false
            NotificationCenter.default.post(name: .meetingSaved, object: meeting)
        }
    }

    private func savePersistedMeeting(_ meeting: Meeting) {
        print("💾 Saving background meeting: \(meeting.id)")
        let success = LocalStorageManager.shared.saveMeeting(meeting)
        print("💾 Background save result: \(success ? "SUCCESS" : "FAILED")")
        if success {
            if self.meeting.id == meeting.id {
                hasLocalUnsavedChanges = false
            }
            NotificationCenter.default.post(name: .meetingSaved, object: meeting)
        }
    }
    
    func copyCurrentTabContent() {
        NSPasteboard.general.clearContents()
        
        let content: String
        switch selectedTab {
        case .context:
            content = meeting.formattedMeetingContext
        case .transcript:
            content = meeting.formattedTranscript
        case .enhancedNotes:
            var enhancedContent = ""
            if !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enhancedContent += "# \(meeting.title)\n\n"
            }
            enhancedContent += meeting.generatedNotes
            content = enhancedContent
        case .summary:
            content = meeting.generatedNotes
        }
        
        NSPasteboard.general.setString(content, forType: .string)
    }

    func addTextContextItem() {
        meeting.contextItems.append(
            MeetingContextItem(
                kind: .text,
                title: LanguageManager.shared.t("手动补充", "Manual Context"),
                extractedText: ""
            )
        )
    }

    func addFileContextItem(url: URL, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        meeting.contextItems.append(
            MeetingContextItem(
                kind: .file,
                title: url.lastPathComponent,
                source: url.path,
                extractedText: trimmedText,
                extractionStatus: .succeeded,
                fetchedAt: Date()
            )
        )
    }

    func deleteContextItem(_ item: MeetingContextItem) {
        meeting.contextItems.removeAll { $0.id == item.id }
    }

    func extractStructuredSummary() async {
        await extractStructuredSummary(from: meeting)
    }

    private func extractStructuredSummary(from snapshot: Meeting) async {
        guard !isExtractingStructuredSummary else { return }

        // Pin the meeting identity at task start. The Task may outlive the active meeting
        // (user switches sidebar selection during the multi-second LLM call); on completion,
        // save the original meeting and only mirror results into the UI if it is still current.
        let token = UUID()
        let meetingId = snapshot.id
        structuredExtractionToken = token
        activeStructuredExtractionMeetingId = meetingId

        isExtractingStructuredSummary = meeting.id == meetingId
        structuredSummaryErrorMessage = nil
        defer {
            if structuredExtractionToken == token {
                activeStructuredExtractionMeetingId = nil
                isExtractingStructuredSummary = false
            }
        }

        do {
            let result = try await MeetingStructuredExtractor.shared.extract(from: snapshot)
            var updatedMeeting = snapshot
            // Don't overwrite oneLiner with empty — the model occasionally returns ""
            // despite the prompt rule, which would erase the header card entirely.
            // Fall back to the current value, then to the title.
            if !result.oneLiner.isEmpty {
                updatedMeeting.oneLiner = result.oneLiner
            } else if updatedMeeting.oneLiner.isEmpty {
                let trimmedTitle = updatedMeeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTitle.isEmpty {
                    updatedMeeting.oneLiner = trimmedTitle
                }
            }
            updatedMeeting.host = result.host
            updatedMeeting.location = result.location
            updatedMeeting.decisions = result.decisions
            updatedMeeting.risks = result.risks
            updatedMeeting.openQuestions = result.openQuestions
            updatedMeeting.discussions = result.discussions
            updatedMeeting.milestones = result.milestones
            updatedMeeting.structuredSummarySourceHash = updatedMeeting.structuredSummaryCurrentSourceHash
            updatedMeeting.structuredSummaryGeneratedAt = Date()
            savePersistedMeeting(updatedMeeting)
            if meeting.id == meetingId {
                meeting = updatedMeeting
            }
        } catch {
            if meeting.id == meetingId {
                structuredSummaryErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            print("⚠️ Structured extraction failed: \(error)")
        }
    }

    func exportHTML() {
        guard canExportCurrentTabHTML else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        let export = currentTabHTMLExport()
        panel.nameFieldStringValue = export.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export.html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "HTML 导出失败：\(error.localizedDescription)"
        }
    }

    private func currentTabHTMLExport() -> (fileName: String, html: String) {
        let baseName = sanitizedExportBaseName()

        switch selectedTab {
        case .context:
            return (
                "\(baseName)-会议资料.html",
                MeetingHTMLExporter.generateContextHTML(for: meeting)
            )
        case .transcript:
            return (
                "\(baseName)-转录原文.html",
                MeetingHTMLExporter.generateTranscriptHTML(
                    for: meeting,
                    displayChunks: transcriptDisplayChunks
                )
            )
        case .enhancedNotes:
            switch aiNotesSubTab {
            case .notes:
                return (
                    "\(baseName)-AI纪要.html",
                    MeetingHTMLExporter.generateNotesHTML(for: meeting)
                )
            case .digest:
                return (
                    "\(baseName)-摘要.html",
                    MeetingHTMLExporter.generateDigestHTML(for: meeting)
                )
            }
        case .summary:
            return (
                "\(baseName)-AI纪要.html",
                MeetingHTMLExporter.generateNotesHTML(for: meeting)
            )
        }
    }

    private func sanitizedExportBaseName() -> String {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = selectedTab == .transcript ? "转录原文" : (selectedTab == .context ? "会议资料" : "会议纪要")
        let rawName = title.isEmpty ? fallback : title
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = rawName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    func extractFollowUpTasks() async {
        guard !isExtractingFollowUpTasks else { return }
        let meetingId = meeting.id
        let snapshot = meeting
        activeFollowUpExtractionMeetingId = meetingId
        isExtractingFollowUpTasks = true
        errorMessage = nil
        defer {
            activeFollowUpExtractionMeetingId = nil
            isExtractingFollowUpTasks = false
        }

        do {
            let extractedTasks = try await FollowUpTaskExtractor.shared.extractTasks(from: snapshot)
            var updatedMeeting = snapshot
            mergeExtractedFollowUpTasks(extractedTasks, into: &updatedMeeting)
            savePersistedMeeting(updatedMeeting)
            if meeting.id == meetingId {
                meeting = updatedMeeting
            }
        } catch {
            if meeting.id == meetingId {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func populateFollowUpTasksFromStructuredSummaryIfNeeded() {
        guard meeting.followUpTasks.isEmpty else { return }

        let derivedTasks = derivedFollowUpTasksFromStructuredSummary()
        let appendedCount = mergeExtractedFollowUpTasks(derivedTasks)
        if appendedCount > 0 {
            saveMeeting()
        }
    }

    func addManualFollowUpTask(title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        meeting.followUpTasks.append(
            MeetingFollowUpTask(
                title: trimmedTitle,
                kind: .manual,
                isManual: true
            )
        )
        saveMeeting()
    }

    func addFollowUpTask(from question: MeetingOpenQuestion) {
        let title = question.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? question.question
            : question.nextStep
        var task = MeetingFollowUpTask(
            title: title,
            detail: question.question,
            sourceExcerpt: question.sourceExcerpt,
            kind: .confirmation,
            owner: question.owner,
            isManual: false
        )
        task.updatedAt = Date()
        if mergeExtractedFollowUpTasks([task]) > 0 {
            saveMeeting()
        }
    }

    func deleteFollowUpTask(_ task: MeetingFollowUpTask) {
        meeting.followUpTasks.removeAll { $0.id == task.id }
        saveMeeting()
    }

    func createReminder(for task: MeetingFollowUpTask, listIdentifier: String?) async {
        guard !syncingFollowUpTaskIds.contains(task.id) else { return }
        syncingFollowUpTaskIds.insert(task.id)
        errorMessage = nil
        defer { syncingFollowUpTaskIds.remove(task.id) }

        do {
            let result = try await ReminderManager.shared.createReminder(
                for: task,
                meeting: meeting,
                listIdentifier: listIdentifier
            )
            updateFollowUpTask(task.id) { updatedTask in
                updatedTask.reminderIdentifier = result.identifier
                updatedTask.reminderCalendarIdentifier = result.listIdentifier
                updatedTask.reminderCalendarTitle = result.listTitle
                updatedTask.updatedAt = Date()
            }
            saveMeeting()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func removeReminder(for task: MeetingFollowUpTask) async {
        guard !syncingFollowUpTaskIds.contains(task.id) else { return }
        syncingFollowUpTaskIds.insert(task.id)
        errorMessage = nil
        defer { syncingFollowUpTaskIds.remove(task.id) }

        do {
            if let identifier = task.reminderIdentifier {
                try await ReminderManager.shared.removeReminder(identifier: identifier)
            }
            clearReminderLink(for: task.id)
            saveMeeting()
        } catch ReminderManagerError.reminderNotFound {
            clearReminderLink(for: task.id)
            saveMeeting()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshReminderLinks() async {
        for task in meeting.followUpTasks {
            guard let identifier = task.reminderIdentifier,
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            do {
                let exists = try await ReminderManager.shared.reminderExists(identifier: identifier)
                if !exists {
                    clearReminderLink(for: task.id)
                }
            } catch {
                // Keep local state if permission is unavailable; explicit add/remove will surface the error.
            }
        }
    }

    private func derivedFollowUpTasksFromStructuredSummary() -> [MeetingFollowUpTask] {
        let questionTasks = meeting.openQuestions.map { question in
            MeetingFollowUpTask(
                title: question.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? question.question
                    : question.nextStep,
                detail: question.question,
                sourceExcerpt: question.sourceExcerpt,
                kind: .confirmation,
                owner: question.owner,
                isManual: false
            )
        }

        let milestoneTasks = meeting.milestones.map { milestone in
            let title = milestone.targetDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? milestone.title
                : "\(milestone.title)（\(milestone.targetDate)）"
            return MeetingFollowUpTask(
                title: title,
                detail: milestone.milestoneDescription,
                sourceExcerpt: milestone.sourceExcerpt,
                kind: .actionItem,
                isManual: false
            )
        }

        let decisionTasks = meeting.decisions.map { decision in
            MeetingFollowUpTask(
                title: "落实决策：\(decision.title)",
                detail: decision.reason,
                sourceExcerpt: decision.sourceExcerpt,
                kind: .followUp,
                owner: decision.owner,
                isManual: false
            )
        }

        return (questionTasks + milestoneTasks + decisionTasks).filter {
            !$0.trimmedTitle.isEmpty
        }
    }

    @discardableResult
    private func mergeExtractedFollowUpTasks(_ extractedTasks: [MeetingFollowUpTask]) -> Int {
        mergeExtractedFollowUpTasks(extractedTasks, into: &meeting)
    }

    @discardableResult
    private func mergeExtractedFollowUpTasks(_ extractedTasks: [MeetingFollowUpTask], into targetMeeting: inout Meeting) -> Int {
        var existingKeys = Set(targetMeeting.followUpTasks.map { normalizedTaskKey(for: $0) })
        var newTasks: [MeetingFollowUpTask] = []

        for task in extractedTasks {
            var sanitizedTask = task
            sanitizedTask.sourceExcerpt = nonDuplicateSourceExcerpt(
                sanitizedTask.sourceExcerpt,
                title: sanitizedTask.title,
                detail: sanitizedTask.detail
            )

            let key = normalizedTaskKey(for: sanitizedTask)
            guard !key.isEmpty, !existingKeys.contains(key) else { continue }
            existingKeys.insert(key)
            newTasks.append(sanitizedTask)
        }

        targetMeeting.followUpTasks.append(contentsOf: newTasks)
        return newTasks.count
    }

    private func normalizedTaskKey(for task: MeetingFollowUpTask) -> String {
        [
            task.title,
            task.owner,
            task.sourceExcerpt
        ]
        .map { normalizedTaskToken($0) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    private func normalizedTaskToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"'‘’。.!！?？"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func nonDuplicateSourceExcerpt(_ sourceExcerpt: String, title: String, detail: String) -> String {
        let trimmedExcerpt = sourceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExcerpt.isEmpty else { return "" }

        let normalizedExcerpt = normalizedTaskToken(trimmedExcerpt)
        let relatedTexts = [title, detail]
            .map { normalizedTaskToken($0) }
            .filter { !$0.isEmpty && $0.count >= 8 }

        let duplicatesVisibleText = relatedTexts.contains { related in
            normalizedExcerpt == related ||
            normalizedExcerpt.contains(related) ||
            related.contains(normalizedExcerpt)
        }

        return duplicatesVisibleText ? "" : trimmedExcerpt
    }

    private func updateFollowUpTask(_ id: UUID, update: (inout MeetingFollowUpTask) -> Void) {
        guard let index = meeting.followUpTasks.firstIndex(where: { $0.id == id }) else { return }
        update(&meeting.followUpTasks[index])
    }

    private func clearReminderLink(for taskId: UUID) {
        updateFollowUpTask(taskId) { task in
            task.reminderIdentifier = nil
            task.reminderCalendarIdentifier = nil
            task.reminderCalendarTitle = nil
            task.updatedAt = Date()
        }
    }
    
    func deleteMeeting() {
        // If this meeting is currently being recorded, stop the recording first
        if recordingSessionManager.isRecordingMeeting(meeting.id) {
            print("🛑 Stopping recording for meeting being deleted: \(meeting.id)")
            recordingSessionManager.stopRecording()
        }

        cancelGeneratingNotes(for: meeting.id)
        saveMeeting()
        
        let success = LocalStorageManager.shared.deleteMeeting(meeting)
        if success {
            isDeleted = true
            NotificationCenter.default.post(name: .meetingDeleted, object: meeting)
        }
    }
    
    func deleteIfEmpty() {
        guard !isDeleted else { return }
        guard hasCompletedInitialLoad else { return }
        if isEmpty && !isRecording {
            print("🗑️ Auto-deleting empty meeting")
            deleteMeeting()
        } else {
            saveMeeting()
        }
    }
} 
