import Foundation

/// Small, deterministic state holder used by `AudioManager` to distinguish a live
/// microphone callback stream from an AVAudioEngine that still reports itself as
/// running but has stopped delivering buffers.
struct AudioCaptureHealthState {
    private(set) var monitoringStartedAt: TimeInterval?
    private(set) var lastMicBufferAt: TimeInterval?

    mutating func begin(at uptime: TimeInterval) {
        monitoringStartedAt = uptime
        lastMicBufferAt = nil
    }

    mutating func noteMicBuffer(at uptime: TimeInterval) {
        lastMicBufferAt = uptime
    }

    mutating func reset() {
        monitoringStartedAt = nil
        lastMicBufferAt = nil
    }

    func isMicStalled(at uptime: TimeInterval, timeout: TimeInterval) -> Bool {
        guard timeout > 0,
              let reference = lastMicBufferAt ?? monitoringStartedAt else {
            return false
        }
        return uptime - reference >= timeout
    }
}
