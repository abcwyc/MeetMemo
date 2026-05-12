import Foundation

enum AudioRecordingState: Equatable {
    case idle
    case starting(UUID)
    case recording(UUID)
    case stopping(UUID)
    case recovering(UUID)
    case failed(UUID?, String)

    var sessionID: UUID? {
        switch self {
        case .idle:
            return nil
        case .starting(let id),
             .recording(let id),
             .stopping(let id),
             .recovering(let id):
            return id
        case .failed(let id, _):
            return id
        }
    }

    var isRecordingVisible: Bool {
        if case .recording = self { return true }
        if case .recovering = self { return true }
        return false
    }

    var isStopping: Bool {
        if case .stopping = self { return true }
        return false
    }

    func isActiveSession(_ id: UUID) -> Bool {
        sessionID == id && !isStopping
    }
}

struct AudioRecordingStateMachine {
    private(set) var state: AudioRecordingState = .idle

    mutating func start(sessionID: UUID) {
        state = .starting(sessionID)
    }

    mutating func markRecording(sessionID: UUID) {
        guard state.isActiveSession(sessionID) else { return }
        state = .recording(sessionID)
    }

    mutating func markRecovering(sessionID: UUID) {
        guard state.isActiveSession(sessionID) else { return }
        state = .recovering(sessionID)
    }

    mutating func stop(sessionID: UUID) {
        state = .stopping(sessionID)
    }

    mutating func fail(sessionID: UUID?, message: String) {
        state = .failed(sessionID, message)
    }

    mutating func reset() {
        state = .idle
    }
}
