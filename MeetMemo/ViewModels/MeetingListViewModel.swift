import Foundation
import SwiftUI
import Combine

@MainActor
class MeetingListViewModel: ObservableObject {
    @Published var meetings: [MeetingSummary] = []
    @Published var isLoading = false
    @Published var isImportingAudio = false
    @Published var audioImportProgress: Double?
    @Published var errorMessage: String?
    @Published var searchText: String = ""
    
    private var cancellables = Set<AnyCancellable>()
    private let recordingSessionManager = RecordingSessionManager.shared
    private var audioImportTask: Task<Meeting?, Never>?
    
    // Computed property to filter meetings based on search text
    var filteredMeetings: [MeetingSummary] {
        guard !searchText.isEmpty else { return meetings }
        
        return meetings.filter { meeting in
            meeting.searchableText.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    init() {
        loadMeetings(showLoadingIndicator: true)
        
        // Listen for saved meeting notifications to refresh the list
        NotificationCenter.default.publisher(for: .meetingSaved)
            .sink { [weak self] notification in
                print("🔔 Meeting saved notification received. Reloading meetings list...")
                guard let self else { return }

                if let meeting = notification.object as? Meeting {
                    self.upsertMeeting(MeetingSummary(meeting: meeting))
                } else {
                    self.loadMeetings()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .meetingDeleted)
            .sink { [weak self] notification in
                print("🔔 Meeting deleted notification received. Reloading meetings list...")
                guard let self else { return }

                if let meeting = notification.object as? Meeting {
                    self.removeMeeting(meeting)
                } else {
                    self.loadMeetings()
                }
            }
            .store(in: &cancellables)
    }
    
    func loadMeetings(showLoadingIndicator: Bool = false) {
        if showLoadingIndicator {
            isLoading = true
        }
        errorMessage = nil
        
        Task { [weak self] in
            let loadedMeetings = await Task.detached(priority: .userInitiated) {
                LocalStorageManager.shared.loadMeetingSummaries()
            }.value
            print("📋 Loaded \(loadedMeetings.count) meetings")

            guard let self else { return }
            self.meetings = loadedMeetings
            if showLoadingIndicator {
                self.isLoading = false
            }
        }
    }
    
    func deleteMeeting(_ meeting: MeetingSummary) {
        if recordingSessionManager.isRecordingMeeting(meeting.id) {
            print("🛑 Stopping recording for meeting being deleted from sidebar: \(meeting.id)")
            recordingSessionManager.stopRecording()
        }

        let success = LocalStorageManager.shared.deleteMeetingSummary(meeting)
        if success {
            meetings.removeAll { $0.id == meeting.id }
            NotificationCenter.default.post(name: .meetingDeleted, object: meeting.placeholderMeeting)
        } else {
            errorMessage = "Failed to delete meeting"
            loadMeetings()
        }
    }

    func renameMeeting(_ meeting: MeetingSummary, title: String) {
        var updatedSummary = meeting
        updatedSummary.title = title
        updatedSummary.searchableText = [title, meeting.searchableText].joined(separator: "\n")
        upsertMeeting(updatedSummary)

        if var fullMeeting = LocalStorageManager.shared.loadMeeting(id: meeting.id) {
            fullMeeting.title = title
            _ = LocalStorageManager.shared.saveMeeting(fullMeeting)
            NotificationCenter.default.post(name: .meetingRenamed, object: fullMeeting)
        } else {
            NotificationCenter.default.post(name: .meetingRenamed, object: updatedSummary.placeholderMeeting)
        }
    }

    private func upsertMeeting(_ meeting: MeetingSummary) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    private func removeMeeting(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
    }
    
    func createNewMeeting() -> Meeting {
        let newMeeting = Meeting()
        meetings.insert(MeetingSummary(meeting: newMeeting), at: 0)
        _ = LocalStorageManager.shared.saveMeeting(newMeeting)
        return newMeeting
    }

    func importAudioFile(url: URL) async -> Meeting? {
        guard audioImportTask == nil else { return nil }

        let task = Task { [weak self] () -> Meeting? in
            guard let self else { return nil }
            return await self.runImportAudioFile(url: url)
        }
        audioImportTask = task
        let meeting = await task.value
        audioImportTask = nil
        return meeting
    }

    func cancelAudioImport() {
        audioImportTask?.cancel()
        audioImportTask = nil
        isImportingAudio = false
        audioImportProgress = nil
    }

    private func runImportAudioFile(url: URL) async -> Meeting? {
        guard !isImportingAudio else { return nil }

        isImportingAudio = true
        audioImportProgress = 0
        errorMessage = nil
        defer {
            isImportingAudio = false
            audioImportProgress = nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try await AudioFileTranscriber.shared.transcribe(url: url) { [weak self] progress in
                Task { @MainActor in
                    self?.audioImportProgress = progress
                }
            }
            let title = url.deletingPathExtension().lastPathComponent
            let meeting = Meeting(
                title: title.isEmpty ? LanguageManager.shared.t("导入的会议", "Imported Meeting") : title,
                transcriptChunks: result.chunks
            )

            let success = LocalStorageManager.shared.saveMeeting(meeting)
            guard success else {
                errorMessage = LanguageManager.shared.t("保存导入会议失败。", "Failed to save the imported meeting.")
                return nil
            }

            upsertMeeting(MeetingSummary(meeting: meeting))
            NotificationCenter.default.post(name: .meetingSaved, object: meeting)
            return meeting
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
} 
