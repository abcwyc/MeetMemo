import Foundation
import SwiftUI
import Combine

/// Manages recording sessions at the app level to persist across navigation
@MainActor
class RecordingSessionManager: ObservableObject {
    static let shared = RecordingSessionManager()
    
    @Published var isRecording = false
    @Published var isRecoveringSTT = false
    /// 点击结束录制后、await STT final flush 完成前的中间态。镜像自 AudioManager。
    @Published var isStoppingRecording = false
    @Published var activeMeetingId: UUID?
    @Published var errorMessage: String?
    @Published var warningMessage: String?
    @Published var activeRecordingTranscriptChunksUpdated: [TranscriptChunk] = []
    @Published var activeRecordingStartedAt: Date?
    
    private let audioManager = AudioManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let transcriptUpdateSubject = PassthroughSubject<[TranscriptChunk], Never>()
    private var isStoppingFromSessionManager = false
    private var hasObservedAudioRecordingStart = false
    private var activeSessionToken: UUID?

    // Store transcript chunks for the active recording session
    private var activeRecordingTranscriptChunks: [TranscriptChunk] = []

    private init() {
        setupAudioManagerBindings()
        setupDebouncedSaving()
    }
    
    private func setupAudioManagerBindings() {
        audioManager.$isStoppingRecording
            .sink { [weak self] value in
                self?.isStoppingRecording = value
            }
            .store(in: &cancellables)

        audioManager.$isRecoveringSTT
            .sink { [weak self] value in
                self?.isRecoveringSTT = value
            }
            .store(in: &cancellables)

        // Bind to audio manager state
        audioManager.$isRecording
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.isRecording = isRecording

                if isRecording {
                    self.hasObservedAudioRecordingStart = true
                    return
                }

                guard self.activeMeetingId != nil,
                      !self.isStoppingFromSessionManager,
                      self.hasObservedAudioRecordingStart else {
                    return
                }

                print("🧹 Audio manager stopped unexpectedly. Cleaning up recording session.")
                self.finishActiveSession(saveFinalTranscript: true)
            }
            .store(in: &cancellables)
        
        audioManager.$errorMessage
            .sink { [weak self] errorMessage in
                guard let self else { return }
                self.errorMessage = errorMessage

                guard errorMessage != nil,
                      self.activeMeetingId != nil,
                      !self.isRecording,
                      !self.isStoppingFromSessionManager else {
                    return
                }

                print("🧹 Audio manager reported a startup error. Cleaning up recording session.")
                self.finishActiveSession(saveFinalTranscript: true)
            }
            .store(in: &cancellables)

        audioManager.$warningMessage
            .sink { [weak self] warningMessage in
                self?.warningMessage = warningMessage
            }
            .store(in: &cancellables)
        
        // When transcript chunks change, store them for the active recording and send to debouncer
        audioManager.$transcriptChunks
            .sink { [weak self] newChunks in
                guard let self,
                      self.activeMeetingId != nil,
                      self.isRecording || self.isStoppingFromSessionManager else {
                    return
                }
                self.activeRecordingTranscriptChunks = newChunks
                self.activeRecordingTranscriptChunksUpdated = newChunks

                self.transcriptUpdateSubject.send(newChunks)
            }
            .store(in: &cancellables)
    }

    private func setupDebouncedSaving() {
        transcriptUpdateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] chunks in
                guard let self = self, let activeMeetingId = self.activeMeetingId else { return }
                print("💾 Debounced save triggered for meeting: \(activeMeetingId.uuidString)")
                self.updateActiveMeetingTranscript(meetingId: activeMeetingId, chunks: chunks)
            }
            .store(in: &cancellables)
    }
    
    func startRecording(for meetingId: UUID, existingChunks: [TranscriptChunk] = []) {
        // 会议录音与语音输入互斥：开始录音前先静默停止正在进行的语音输入。
        VoiceInputManager.shared.cancelForRecording()
        print("🎙️ Starting recording for meeting: \(meetingId)")

        let resumableChunks = existingChunks
            .filter(\.isFinal)
            .sortedByTranscriptTimeline()
        activeRecordingTranscriptChunks = resumableChunks
        audioManager.transcriptChunks = resumableChunks

        activeMeetingId = meetingId
        activeSessionToken = UUID()
        activeRecordingStartedAt = Date()
        hasObservedAudioRecordingStart = false
        audioManager.startRecording()
    }
    
    func stopRecording() {
        let stoppedMeetingId = activeMeetingId
        let stoppedSessionToken = activeSessionToken
        print("🛑 Stopping recording for meeting: \(stoppedMeetingId?.uuidString ?? "unknown")")

        isStoppingFromSessionManager = true
        audioManager.stopRecording { [weak self] in
            guard let self else { return }
            guard self.activeMeetingId == stoppedMeetingId,
                  self.activeSessionToken == stoppedSessionToken else {
                self.isStoppingFromSessionManager = false
                return
            }
            self.finishActiveSession(saveFinalTranscript: true)
            self.isStoppingFromSessionManager = false
        }
    }

    private func finishActiveSession(saveFinalTranscript: Bool) {
        if saveFinalTranscript, let activeMeetingId = activeMeetingId {
            updateActiveMeetingTranscript(meetingId: activeMeetingId, chunks: activeRecordingTranscriptChunks)
        }

        activeMeetingId = nil
        activeSessionToken = nil
        activeRecordingStartedAt = nil
        activeRecordingTranscriptChunks = []
        hasObservedAudioRecordingStart = false
    }
    
    func isRecordingMeeting(_ meetingId: UUID) -> Bool {
        return isRecording && activeMeetingId == meetingId
    }

    func hasActiveSession(for meetingId: UUID) -> Bool {
        activeMeetingId == meetingId
    }
    
    private func updateActiveMeetingTranscript(meetingId: UUID, chunks: [TranscriptChunk]) {
        if var meeting = LocalStorageManager.shared.loadMeeting(id: meetingId) {
            meeting.transcriptChunks = chunks

            let success = LocalStorageManager.shared.saveMeeting(meeting)
            if success {
                print("✅ Saved meeting transcript: \(meetingId.uuidString)")
                NotificationCenter.default.post(name: .meetingSaved, object: meeting)
            } else {
                print("❌ Failed to save meeting transcript: \(meetingId.uuidString)")
            }
        }
    }
    
    func getActiveRecordingTranscriptChunks() -> [TranscriptChunk] {
        return activeRecordingTranscriptChunks
    }
    
    /// Get transcript chunks for a specific meeting, ensuring proper data separation
    func getTranscriptChunks(for meetingId: UUID) -> [TranscriptChunk] {
        if isRecording && activeMeetingId == meetingId {
            // Return live transcript chunks for the active recording
            return activeRecordingTranscriptChunks
        } else {
            // Load saved transcript chunks from storage for non-active meetings
            if let savedMeeting = LocalStorageManager.shared.loadMeeting(id: meetingId) {
                return savedMeeting.transcriptChunks
            }
            return []
        }
    }
} 
