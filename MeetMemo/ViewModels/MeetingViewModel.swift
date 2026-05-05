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
    case enhancedNotes = "Smart Notes"

    static let displayOrder: [MeetingViewTab] = [.context, .transcript, .enhancedNotes]

    var chineseLabel: String {
        switch self {
        case .context: return "会前资料"
        case .transcript: return "转录原文"
        case .enhancedNotes: return "智能纪要"
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
                // Suppress non-critical, self-healing errors that should not distract the user
                let lowercased = errorMessage.lowercased()
                if errorMessage == ErrorMessage.sessionExpired || lowercased.contains("socket is not connected") {
                    print("ℹ️ Suppressed non-critical error: \(errorMessage)")
                    return
                }
                self?.errorMessage = errorMessage
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
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] meeting in
                guard self?.hasCompletedInitialLoad == true else { return }
                print("🔄 Auto-saving meeting: \(meeting.id) - title: '\(meeting.title)', context: '\(meeting.formattedMeetingContext.prefix(50))...'")
                self?.saveMeeting()
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
            self.meeting = savedMeeting
            self.refreshTranscriptDisplayChunks()
            self.isNewMeeting = self.isEmpty
            self.hasStartedRecordingSession = !savedMeeting.transcriptChunks.isEmpty
            self.selectedTab = Self.preferredInitialTab(for: savedMeeting)
            self.loadTemplates()
            self.isLoadingMeeting = false
            self.hasCompletedInitialLoad = true
        }
    }

    private static func preferredInitialTab(for meeting: Meeting) -> MeetingViewTab {
        let hasEnhancedNotes = !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasEnhancedNotes ? .enhancedNotes : .transcript
    }

    private func refreshTranscriptDisplayChunks() {
        transcriptDisplayChunks = meeting.transcriptDisplayChunks
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
                recordingSessionManager.startRecording(for: meeting.id)
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
        guard meeting.hasFinalTranscript else {
            errorMessage = ErrorMessage.noTranscript
            return
        }

        isGeneratingNotes = true
        errorMessage = nil
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
        }
        
        isGeneratingNotes = false
    }
    
    func saveMeeting() {
        if isDeleted || !hasCompletedInitialLoad { return }
        print("💾 Saving meeting: \(meeting.id)")
        let success = LocalStorageManager.shared.saveMeeting(meeting)
        print("💾 Save result: \(success ? "SUCCESS" : "FAILED")")
        if success {
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
            
            // Add title as h1 header if title is set
            if !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enhancedContent += "# \(meeting.title)\n\n"
            }
            
            // Add the generated notes
            enhancedContent += meeting.generatedNotes
            
            content = enhancedContent
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
