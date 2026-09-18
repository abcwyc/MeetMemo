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
    /// Carries the meeting the chunks belong to: the debounce fires up to 2s later, by
    /// which time a different meeting may be the active one.
    private let transcriptUpdateSubject = PassthroughSubject<(meetingId: UUID, chunks: [TranscriptChunk]), Never>()
    private var isStoppingFromSessionManager = false
    private var hasObservedAudioRecordingStart = false
    private var activeSessionToken: UUID?
    private let transcriptPersistenceQueue = DispatchQueue(
        label: "io.meetmemo.transcript-persistence",
        qos: .utility
    )

    // Store transcript chunks for the active recording session
    private var activeRecordingTranscriptChunks: [TranscriptChunk] = []

    private init() {
        setupAudioManagerBindings()
        setupDebouncedSaving()
    }
    
    private func setupAudioManagerBindings() {
        audioManager.$isStoppingRecording
            .sink { [weak self] value in
                guard let self else { return }
                // Keep the whole app in the finalizing state until the last transcript
                // snapshot has also reached disk, not merely until the STT providers stop.
                if self.isStoppingFromSessionManager && !value {
                    return
                }
                if !value,
                   let activeMeetingId = self.activeMeetingId,
                   let activeSessionToken = self.activeSessionToken,
                   !self.audioManager.isRecording,
                   self.hasObservedAudioRecordingStart {
                    // Sleep, capture failure, and other AudioManager-owned stops do not use
                    // RecordingSessionManager.stopRecording's completion. Finish them here,
                    // after the provider flush has ended, using the same durable save path.
                    self.isStoppingFromSessionManager = true
                    self.isStoppingRecording = true
                    self.finalizeStoppedSession(
                        meetingId: activeMeetingId,
                        sessionToken: activeSessionToken
                    )
                    return
                }
                self.isStoppingRecording = value
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
                      !self.isStoppingRecording,
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
                      let activeMeetingId = self.activeMeetingId,
                      self.isRecording || self.isStoppingFromSessionManager else {
                    return
                }
                self.activeRecordingTranscriptChunks = newChunks
                self.activeRecordingTranscriptChunksUpdated = newChunks

                self.transcriptUpdateSubject.send((activeMeetingId, newChunks))
            }
            .store(in: &cancellables)
    }

    private func setupDebouncedSaving() {
        transcriptUpdateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self = self, let activeMeetingId = self.activeMeetingId else { return }
                // A session that has since finished already saved its final transcript;
                // never write its chunks into whichever meeting is recording now.
                guard update.meetingId == activeMeetingId else { return }
                print("💾 Debounced save triggered for meeting: \(activeMeetingId.uuidString)")
                self.enqueueTranscriptSave(meetingId: activeMeetingId, chunks: update.chunks)
            }
            .store(in: &cancellables)
    }

    /// True while a recording is starting, active, or flushing its final transcript.
    /// Callers must treat this as a global single-session lock.
    var isSessionBusy: Bool {
        Self.sessionIsBusy(
            activeMeetingId: activeMeetingId,
            isRecording: isRecording,
            isStoppingRecording: isStoppingRecording,
            isStoppingFromSessionManager: isStoppingFromSessionManager
        )
    }

    nonisolated static func sessionIsBusy(
        activeMeetingId: UUID?,
        isRecording: Bool,
        isStoppingRecording: Bool,
        isStoppingFromSessionManager: Bool
    ) -> Bool {
        activeMeetingId != nil || isRecording || isStoppingRecording || isStoppingFromSessionManager
    }

    @discardableResult
    func startRecording(for meetingId: UUID, existingChunks: [TranscriptChunk] = []) -> Bool {
        guard !isSessionBusy else {
            print("⚠️ Refusing to start recording while another session is active or finalizing.")
            return false
        }

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
        return true
    }
    
    func stopRecording() {
        let stoppedMeetingId = activeMeetingId
        let stoppedSessionToken = activeSessionToken
        print("🛑 Stopping recording for meeting: \(stoppedMeetingId?.uuidString ?? "unknown")")

        isStoppingFromSessionManager = true
        isStoppingRecording = true
        audioManager.stopRecording { [weak self] in
            guard let self else { return }
            guard let stoppedMeetingId,
                  let stoppedSessionToken,
                  self.activeMeetingId == stoppedMeetingId,
                  self.activeSessionToken == stoppedSessionToken else {
                self.isStoppingFromSessionManager = false
                self.isStoppingRecording = false
                return
            }
            self.finalizeStoppedSession(
                meetingId: stoppedMeetingId,
                sessionToken: stoppedSessionToken
            )
        }
    }

    private func finalizeStoppedSession(meetingId: UUID, sessionToken: UUID) {
        let finalChunks = activeRecordingTranscriptChunks
        Task { [weak self] in
            guard let self else { return }
            _ = await self.persistTranscript(meetingId: meetingId, chunks: finalChunks)
            guard self.activeMeetingId == meetingId,
                  self.activeSessionToken == sessionToken else {
                self.isStoppingFromSessionManager = false
                self.isStoppingRecording = false
                return
            }
            self.finishActiveSession(saveFinalTranscript: false)
            self.isStoppingFromSessionManager = false
            self.isStoppingRecording = false
        }
    }

    private func finishActiveSession(saveFinalTranscript: Bool) {
        if saveFinalTranscript, let activeMeetingId = activeMeetingId {
            enqueueTranscriptSave(
                meetingId: activeMeetingId,
                chunks: activeRecordingTranscriptChunks
            )
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
    
    private func enqueueTranscriptSave(meetingId: UUID, chunks: [TranscriptChunk]) {
        transcriptPersistenceQueue.async { [weak self] in
            let result = Self.saveTranscriptSnapshot(meetingId: meetingId, chunks: chunks)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.publishTranscriptSaveResult(result, meetingId: meetingId)
                }
            }
        }
    }

    /// Serializes transcript persistence off the main actor. FIFO ordering ensures a final
    /// stop snapshot cannot be overtaken by an older debounced snapshot.
    private func persistTranscript(meetingId: UUID, chunks: [TranscriptChunk]) async -> Bool {
        let result: (success: Bool, meeting: Meeting?) = await withCheckedContinuation { continuation in
            transcriptPersistenceQueue.async {
                continuation.resume(returning: Self.saveTranscriptSnapshot(
                    meetingId: meetingId,
                    chunks: chunks
                ))
            }
        }

        publishTranscriptSaveResult(result, meetingId: meetingId)
        return result.success
    }

    nonisolated private static func saveTranscriptSnapshot(
        meetingId: UUID,
        chunks: [TranscriptChunk]
    ) -> (success: Bool, meeting: Meeting?) {
        guard var meeting = LocalStorageManager.shared.loadMeeting(id: meetingId) else {
            return (false, nil)
        }
        meeting.transcriptChunks = chunks
        let success = LocalStorageManager.shared.saveMeeting(meeting)
        return (success, success ? meeting : nil)
    }

    private func publishTranscriptSaveResult(
        _ result: (success: Bool, meeting: Meeting?),
        meetingId: UUID
    ) {
        if let meeting = result.meeting {
            print("✅ Saved meeting transcript: \(meetingId.uuidString)")
            NotificationCenter.default.post(name: .meetingSaved, object: meeting)
        } else {
            print("❌ Failed to save meeting transcript: \(meetingId.uuidString)")
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
