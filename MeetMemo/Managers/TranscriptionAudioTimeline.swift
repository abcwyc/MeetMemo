import Foundation

/// Keeps one audio source's STT input aligned with the recording timeline.
///
/// Local STT engines timestamp results by the number of samples they have ingested, so the
/// meeting-time of provider time 0 is `anchorMilliseconds`, and every sample fed after it
/// must correspond to real elapsed time. This type owns that invariant:
/// - chunks captured before the recognizer finishes loading are held in FIFO order;
/// - when capture restarts (a new capture id), the interruption is filled with zero PCM
///   measured against the wall clock;
/// - if the pending buffer overflows, the oldest audio is dropped and the anchor advances
///   by the same duration, so later timestamps stay correct.
struct TranscriptionAudioTimeline {
    static let sampleRate = 16_000
    static let bytesPerSample = 2
    /// Synthesized silence is emitted in chunks of this size to keep provider inputs small.
    static let silenceChunkSamples = sampleRate / 10

    let maxPendingBytes: Int
    let maxGapFillMilliseconds: Int

    private var startMilliseconds: Int?
    /// Samples dropped from the front of the pending buffer; they shift the anchor forward.
    private var droppedLeadingSamples = 0
    /// Samples on the timeline after the anchor, whether already sent or still pending.
    private(set) var samplesSinceAnchor = 0
    private var captureID: UUID?
    private(set) var pendingChunks: [Data] = []
    private var pendingByteCount = 0

    init(
        maxPendingBytes: Int,
        maxGapFillMilliseconds: Int = 10 * 60 * 1000
    ) {
        self.maxPendingBytes = maxPendingBytes
        self.maxGapFillMilliseconds = maxGapFillMilliseconds
    }

    var isStarted: Bool { startMilliseconds != nil }

    /// Recording time (ms) that corresponds to the provider's time 0.
    var anchorMilliseconds: Int? {
        startMilliseconds.map { $0 + Self.milliseconds(forSamples: droppedLeadingSamples) }
    }

    /// Starts the timeline with a chunk that finished arriving at `arrivalMilliseconds`.
    mutating func start(firstChunkByteCount: Int, arrivalMilliseconds: Int) {
        guard startMilliseconds == nil else { return }
        let chunkMilliseconds = Self.milliseconds(forSamples: firstChunkByteCount / Self.bytesPerSample)
        startMilliseconds = max(0, arrivalMilliseconds - chunkMilliseconds)
    }

    /// Places `data` on the timeline and returns the chunks to deliver, in order. When the
    /// chunk comes from a new capture (after a microphone or tap restart), zero PCM for the
    /// interruption is returned ahead of it.
    mutating func append(
        _ data: Data,
        captureID newCaptureID: UUID,
        arrivalMilliseconds: Int
    ) -> [Data] {
        guard let anchor = anchorMilliseconds else { return [] }
        var chunks: [Data] = []
        let dataSamples = data.count / Self.bytesPerSample

        if let captureID, captureID != newCaptureID {
            let expectedSamples = Self.samples(forMilliseconds: arrivalMilliseconds - anchor)
            let gapSamples = min(
                expectedSamples - samplesSinceAnchor - dataSamples,
                Self.samples(forMilliseconds: maxGapFillMilliseconds)
            )
            if gapSamples > 0 {
                chunks.append(contentsOf: Self.silenceChunks(samples: gapSamples))
                samplesSinceAnchor += gapSamples
            }
        }
        captureID = newCaptureID

        chunks.append(data)
        samplesSinceAnchor += dataSamples
        return chunks
    }

    /// Holds chunks until the recognizer is connected. Overflow drops the oldest audio and
    /// moves the anchor forward so the remaining samples keep their true position.
    mutating func bufferPending(_ chunks: [Data]) {
        for chunk in chunks {
            pendingChunks.append(chunk)
            pendingByteCount += chunk.count
        }
        while pendingByteCount > maxPendingBytes, !pendingChunks.isEmpty {
            let removed = pendingChunks.removeFirst()
            pendingByteCount -= removed.count
            let removedSamples = removed.count / Self.bytesPerSample
            droppedLeadingSamples += removedSamples
            samplesSinceAnchor -= removedSamples
        }
    }

    mutating func takePending() -> [Data] {
        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: false)
        pendingByteCount = 0
        return chunks
    }

    private static func silenceChunks(samples: Int) -> [Data] {
        var remaining = samples
        var chunks: [Data] = []
        while remaining > 0 {
            let count = min(remaining, silenceChunkSamples)
            chunks.append(Data(count: count * bytesPerSample))
            remaining -= count
        }
        return chunks
    }

    private static func milliseconds(forSamples samples: Int) -> Int {
        samples * 1000 / sampleRate
    }

    private static func samples(forMilliseconds milliseconds: Int) -> Int {
        milliseconds * sampleRate / 1000
    }
}
