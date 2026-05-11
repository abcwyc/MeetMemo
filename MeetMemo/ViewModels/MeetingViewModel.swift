import Foundation
import SwiftUI
import Combine

// Add notification name for meeting saved events
extension Notification.Name {
    static let meetingSaved = Notification.Name("MeetingSaved")
    static let meetingDeleted = Notification.Name("MeetingDeleted")
    static let meetingRenamed = Notification.Name("MeetingRenamed")
}

enum MeetingViewTab: String, CaseIterable {
    case context = "Prep"
    case transcript = "Transcript"
    case enhancedNotes = "AI Notes"
    case summary = "Summary"

    static let displayOrder: [MeetingViewTab] = [.context, .transcript, .enhancedNotes, .summary]

    var chineseLabel: String {
        switch self {
        case .context: return "会议资料"
        case .transcript: return "转录原文"
        case .enhancedNotes: return "AI纪要"
        case .summary: return "摘要"
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
    @Published var syncingFollowUpTaskIds: Set<UUID> = []
    @Published var transcriptDisplayChunks: [TranscriptDisplayChunk] = []
    @Published private var hasStartedRecordingSession = false
    
    // Computed property to determine if Generate button should animate
    var shouldAnimateGenerateButton: Bool {
        let generateButtonEnabled = meeting.hasFinalTranscript && !isGeneratingNotes && !isRecording && !isStartingRecording
        let noEnhancedNotesYet = meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return generateButtonEnabled && noEnhancedNotesYet
    }
    
    // Computed property to determine if Transcribe button should animate
    var shouldAnimateTranscribeButton: Bool {
        return !isRecording && meeting.transcriptChunks.isEmpty && !isStartingRecording
    }
    
    // Computed property that always uses the direct RecordingSessionManager check
    var isRecording: Bool {
        return recordingSessionManager.isRecordingMeeting(meeting.id)
    }
    @Published var selectedTab: MeetingViewTab

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
    private var generationTask: Task<Void, Never>?
    private var generationCounter: Int = 0
    
    // Computed property to check if meeting is empty
    var isEmpty: Bool {
        return meeting.transcriptChunks.isEmpty && 
               !meeting.hasMeetingContext &&
               meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    init(meeting: Meeting = Meeting(), initialSelectedTab: MeetingViewTab? = nil) {
        print("🆕 Using provided meeting placeholder: \(meeting.id)")
        self.meeting = meeting
        self.transcriptDisplayChunks = meeting.transcriptDisplayChunks
        self.selectedTab = initialSelectedTab ?? Self.preferredInitialTab(for: meeting)
        self.hasStartedRecordingSession = !meeting.transcriptChunks.isEmpty

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
        }

        // Listen to real-time transcript updates for this meeting if it's being recorded
        recordingSessionManager.$activeRecordingTranscriptChunksUpdated
            .dropFirst()
            .sink { [weak self] updatedChunks in
                guard let self = self else { return }
                // Only update if this meeting is the active recording
                if recordingSessionManager.isRecordingMeeting(self.meeting.id) {
                    self.meeting.transcriptChunks = updatedChunks
                    self.refreshTranscriptDisplayChunks()
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
        NotificationCenter.default.publisher(for: .meetingDeleted)
            .receive(on: RunLoop.main)
            .compactMap { $0.object as? Meeting }
            .sink { [weak self] deleted in
                guard let self, deleted.id == self.meeting.id else { return }
                self.isDeleted = true
            }
            .store(in: &cancellables)
    }

    
    var recordingButtonText: String {
        let lang = LanguageManager.shared
        if isRecording {
            return lang.t("结束录制", "End Recording")
        }
        return hasStartedRecordingSession ? lang.t("继续录制", "Resume Recording") : lang.t("开始录制", "Start Recording")
    }

    var recordingButtonIconName: String {
        if isRecording {
            return "stop.circle.fill"
        }
        return hasStartedRecordingSession ? "record.circle" : "record.circle.fill"
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
    
    func toggleRecording() {
        // Prevent duplicate actions while validating API key or starting recording
        if isValidatingKey || isStartingRecording { return }
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

            print("🔄 Loaded full meeting: \(meetingId)")
            self.isApplyingLoadedMeeting = true
            self.meeting = self.hasLocalUnsavedChanges
                ? self.mergingLoadedMeeting(savedMeeting, withLocalEditsFrom: self.meeting)
                : savedMeeting
            self.isApplyingLoadedMeeting = false
            self.refreshTranscriptDisplayChunks()
            self.isNewMeeting = self.isEmpty
            self.hasStartedRecordingSession = !self.meeting.transcriptChunks.isEmpty
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

        if local.transcriptChunks.count > loaded.transcriptChunks.count {
            merged.transcriptChunks = local.transcriptChunks
        }

        return merged
    }

    private static func preferredInitialTab(for meeting: Meeting) -> MeetingViewTab {
        let hasEnhancedNotes = !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasEnhancedNotes ? .enhancedNotes : .transcript
    }

    private func refreshTranscriptDisplayChunks() {
        transcriptDisplayChunks = meeting.transcriptDisplayChunks
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
        // Validate transcription provider configuration before starting recording
        isValidatingKey = true
        isStartingRecording = true
        Task {
            let validationResult = await APIKeyValidator.shared.validateSTTConfig(APIKeyValidator.shared.currentSTTConfig())
            defer { isValidatingKey = false }

            switch validationResult {
            case .success():
                // Transcription config is valid, proceed with recording
                hasStartedRecordingSession = true
                recordingSessionManager.startRecording(for: meeting.id, existingChunks: meeting.transcriptChunks)
            case .failure(let error):
                // Show error message
                errorMessage = error.localizedDescription
                // Cancel starting if validation failed
                isStartingRecording = false
                print("❌ STT validation failed: \(error.localizedDescription)")
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
        generationCounter += 1
        generationTask?.cancel()
        generationTask = nil
        isGeneratingNotes = false
    }

    private func runGenerateNotes() async {
        guard meeting.hasFinalTranscript else {
            errorMessage = ErrorMessage.noTranscript
            return
        }

        isGeneratingNotes = true
        errorMessage = nil
        generationCounter += 1
        let myGeneration = generationCounter
        defer {
            if generationCounter == myGeneration {
                isGeneratingNotes = false
                generationTask = nil
            }
        }

        let previousGeneratedNotes = meeting.generatedNotes
        var receivedContent = false
        
        // Load settings for generation
        let userBlurb = UserDefaultsManager.shared.userBlurb
        let systemPrompt = UserDefaultsManager.shared.systemPrompt
        
        // Use streaming generation
        let stream = NotesGenerator.shared.generateNotesStream(
            meeting: meeting,
            userBlurb: userBlurb,
            systemPrompt: systemPrompt,
            templateId: selectedTemplateId
        )
        
        var hasError = false
        for await result in stream {
            if Task.isCancelled {
                meeting.generatedNotes = previousGeneratedNotes
                hasError = true
                break
            }

            switch result {
            case .content(let chunk):
                if !receivedContent {
                    meeting.generatedNotes = ""
                    receivedContent = true
                }
                meeting.generatedNotes += chunk
            case .error(let error):
                meeting.generatedNotes = previousGeneratedNotes
                errorMessage = error
                hasError = true
                print("🚨 Note Generation Error: \(error)")
                break
            }
        }
        
        // Only save if there was no error
        if !hasError {
            if meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let generated = await NotesGenerator.shared.generateTitle(meeting: meeting) {
                    meeting.title = generated
                }
            }
            saveMeeting()
            if meeting.oneLiner.isEmpty {
                Task { await self.extractStructuredSummary() }
            }
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
        guard !isExtractingStructuredSummary else { return }
        isExtractingStructuredSummary = true
        defer { isExtractingStructuredSummary = false }

        do {
            let result = try await MeetingStructuredExtractor.shared.extract(from: meeting)
            meeting.oneLiner = result.oneLiner
            meeting.decisions = result.decisions
            meeting.risks = result.risks
            meeting.openQuestions = result.openQuestions
            meeting.discussions = result.discussions
            meeting.milestones = result.milestones
        } catch {
            print("⚠️ Structured extraction failed: \(error)")
        }
    }

    func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        let safeName = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = safeName.isEmpty ? "会议纪要.html" : "\(safeName).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = MeetingHTMLExporter.generateHTML(for: meeting)
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "HTML 导出失败：\(error.localizedDescription)"
        }
    }

    func extractFollowUpTasks() async {
        guard !isExtractingFollowUpTasks else { return }
        isExtractingFollowUpTasks = true
        errorMessage = nil
        defer { isExtractingFollowUpTasks = false }

        do {
            let extractedTasks = try await FollowUpTaskExtractor.shared.extractTasks(from: meeting)
            mergeExtractedFollowUpTasks(extractedTasks)
            saveMeeting()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private func mergeExtractedFollowUpTasks(_ extractedTasks: [MeetingFollowUpTask]) {
        var existingKeys = Set(meeting.followUpTasks.map { normalizedTaskKey($0.title) })
        var newTasks: [MeetingFollowUpTask] = []

        for task in extractedTasks {
            let key = normalizedTaskKey(task.title)
            guard !key.isEmpty, !existingKeys.contains(key) else { continue }
            existingKeys.insert(key)
            newTasks.append(task)
        }

        meeting.followUpTasks.append(contentsOf: newTasks)
    }

    private func normalizedTaskKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
