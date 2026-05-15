import Foundation

/// Captures the provider transcript update *before* the manager applied any global time offset,
/// so the same fixture can be replayed under a different offset by a test harness. Includes the
/// session and provider offset that were active when the event was received, allowing consumers
/// to filter by session and reconstruct the global timeline.
struct RawTranscriptEvent: Hashable {
    let sessionID: UUID
    let source: AudioSource
    let providerOffsetMilliseconds: Int
    let update: STTTranscriptUpdate
    let receivedAt: Date
}

struct RawTranscriptEventRingBuffer {
    private let capacity: Int
    private(set) var events: [RawTranscriptEvent] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ event: RawTranscriptEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    mutating func removeAll() {
        events.removeAll(keepingCapacity: true)
    }
}
