import Foundation

struct TranscriptUpdateAccumulator {
    private struct InterimTranscriptState {
        var text: String
        var speakerTag: String?
        var speakerId: Int?
        var startTime: Int?
        var endTime: Int?
    }

    private(set) var chunks: [TranscriptChunk]
    private var interimStates: [String: InterimTranscriptState] = [:]
    private var latestInterimKeyBySource: [AudioSource: String] = [:]

    init(chunks: [TranscriptChunk] = []) {
        self.chunks = chunks
    }

    mutating func reset(chunks: [TranscriptChunk] = []) {
        self.chunks = chunks
        interimStates.removeAll()
        latestInterimKeyBySource.removeAll()
    }

    mutating func removeInterimState(for source: AudioSource) {
        guard let latestKey = latestInterimKeyBySource.removeValue(forKey: source) else { return }
        interimStates.removeValue(forKey: latestKey)
    }

    mutating func removeAllInterimState() {
        interimStates.removeAll()
        latestInterimKeyBySource.removeAll()
    }

    mutating func apply(_ update: STTTranscriptUpdate, source: AudioSource) {
        let resolvedUpdate = resolved(update, source: source)

        if update.isCorrection,
           let finalIndex = matchingChunkIndex(for: resolvedUpdate, source: source, isFinal: true) {
            chunks[finalIndex] = TranscriptChunk(
                id: chunks[finalIndex].id,
                timestamp: chunks[finalIndex].timestamp,
                source: source,
                text: resolvedUpdate.text,
                isFinal: true,
                speakerTag: resolvedUpdate.speakerTag,
                speakerId: resolvedUpdate.speakerId,
                startTime: resolvedUpdate.startTime,
                endTime: resolvedUpdate.endTime
            )
            removeMatchingInterims(for: resolvedUpdate, source: source)
            sortChunksByTimeline()
            return
        }

        if resolvedUpdate.isFinal {
            removeMatchingInterims(for: resolvedUpdate, source: source)
            removeSupersededIncrementalChunks(for: resolvedUpdate, source: source)

            if let finalIndex = matchingChunkIndex(for: resolvedUpdate, source: source, isFinal: true) {
                chunks[finalIndex] = TranscriptChunk(
                    id: chunks[finalIndex].id,
                    timestamp: chunks[finalIndex].timestamp,
                    source: source,
                    text: resolvedUpdate.text,
                    isFinal: true,
                    speakerTag: resolvedUpdate.speakerTag,
                    speakerId: resolvedUpdate.speakerId,
                    startTime: resolvedUpdate.startTime,
                    endTime: resolvedUpdate.endTime
                )
            } else {
                chunks.append(TranscriptChunk(
                    timestamp: Date(),
                    source: source,
                    text: resolvedUpdate.text,
                    isFinal: true,
                    speakerTag: resolvedUpdate.speakerTag,
                    speakerId: resolvedUpdate.speakerId,
                    startTime: resolvedUpdate.startTime,
                    endTime: resolvedUpdate.endTime
                ))
            }
            sortChunksByTimeline()
            return
        }

        let interimChunk = TranscriptChunk(
            timestamp: Date(),
            source: source,
            text: resolvedUpdate.text,
            isFinal: false,
            speakerTag: resolvedUpdate.speakerTag,
            speakerId: resolvedUpdate.speakerId,
            startTime: resolvedUpdate.startTime,
            endTime: resolvedUpdate.endTime
        )

        removeMatchingInterims(for: resolvedUpdate, source: source)
        removeSupersededIncrementalChunks(for: resolvedUpdate, source: source)

        let interimKey = key(for: source, startTime: resolvedUpdate.startTime, endTime: resolvedUpdate.endTime)
        interimStates[interimKey] = InterimTranscriptState(
            text: resolvedUpdate.text,
            speakerTag: resolvedUpdate.speakerTag,
            speakerId: resolvedUpdate.speakerId,
            startTime: resolvedUpdate.startTime,
            endTime: resolvedUpdate.endTime
        )
        latestInterimKeyBySource[source] = interimKey

        chunks.append(interimChunk)
        sortChunksByTimeline()
    }

    private func resolved(_ update: STTTranscriptUpdate, source: AudioSource) -> STTTranscriptUpdate {
        let updateKey = key(for: source, startTime: update.startTime, endTime: update.endTime)
        let inheritedState = interimStates[updateKey]
            ?? latestInterimKeyBySource[source].flatMap { interimStates[$0] }

        return STTTranscriptUpdate(
            text: update.text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag ?? inheritedState?.speakerTag,
            speakerId: update.speakerId ?? inheritedState?.speakerId,
            startTime: update.startTime ?? inheritedState?.startTime,
            endTime: update.endTime ?? inheritedState?.endTime,
            isCorrection: update.isCorrection
        )
    }

    private func matchingChunkIndex(
        for update: STTTranscriptUpdate,
        source: AudioSource,
        isFinal: Bool
    ) -> Int? {
        chunks.lastIndex {
            $0.source == source
                && $0.isFinal == isFinal
                && $0.startTime == update.startTime
                && $0.endTime == update.endTime
        }
    }

    private mutating func removeMatchingInterims(for update: STTTranscriptUpdate, source: AudioSource) {
        let updateKey = key(for: source, startTime: update.startTime, endTime: update.endTime)
        interimStates.removeValue(forKey: updateKey)
        if latestInterimKeyBySource[source] == updateKey {
            latestInterimKeyBySource.removeValue(forKey: source)
        }

        chunks.removeAll {
            $0.source == source
                && !$0.isFinal
                && (($0.startTime == update.startTime && $0.endTime == update.endTime)
                    || Self.intervalsOverlap($0, update))
        }
    }

    private mutating func removeSupersededIncrementalChunks(for update: STTTranscriptUpdate, source: AudioSource) {
        let updateText = Self.normalizedText(update.text)
        guard updateText.count >= 4 else { return }
        let now = Date()

        chunks.removeAll { chunk in
            guard chunk.source == source else { return false }
            guard Self.speakersAreCompatible(chunk, update) else { return false }

            let chunkText = Self.normalizedText(chunk.text)
            guard chunkText != updateText else { return false }
            guard Self.areIncrementalVersions(chunkText, updateText) else { return false }

            if Self.intervalsOverlap(chunk, update) {
                return true
            }

            if abs(now.timeIntervalSince(chunk.timestamp)) <= 90 {
                return true
            }

            guard let chunkEnd = chunk.endTime ?? chunk.startTime,
                  let updateStart = update.startTime else {
                return false
            }

            return abs(updateStart - chunkEnd) <= 10_000
        }
    }

    private static func areIncrementalVersions(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 4, rhs.count >= 4 else { return false }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            return true
        }

        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        let commonPrefix = zip(shorter, longer).prefix { $0 == $1 }.count
        let requiredPrefix = max(12, Int(ceil(Double(shorter.count) * 0.8)))
        return commonPrefix >= min(shorter.count, requiredPrefix)
    }

    private static func speakersAreCompatible(_ chunk: TranscriptChunk, _ update: STTTranscriptUpdate) -> Bool {
        let chunkSpeaker = chunk.speakerTag ?? chunk.speakerId.map(String.init)
        let updateSpeaker = update.speakerTag ?? update.speakerId.map(String.init)
        return chunkSpeaker == nil || updateSpeaker == nil || chunkSpeaker == updateSpeaker
    }

    private static func normalizedText(_ text: String) -> String {
        String(
            text.lowercased()
                .unicodeScalars
                .filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || Self.isCJKUnifiedIdeograph(scalar)
                }
                .map(Character.init)
        )
    }

    private static func isCJKUnifiedIdeograph(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    private func key(for source: AudioSource, startTime: Int?, endTime: Int?) -> String {
        "\(source.rawValue):\(startTime ?? -1):\(endTime ?? -1)"
    }

    private static func intervalsOverlap(_ chunk: TranscriptChunk, _ update: STTTranscriptUpdate) -> Bool {
        guard let chunkStart = chunk.startTime,
              let chunkEnd = chunk.endTime,
              let updateStart = update.startTime,
              let updateEnd = update.endTime else {
            return false
        }

        return max(chunkStart, updateStart) < min(chunkEnd, updateEnd)
    }

    private mutating func sortChunksByTimeline() {
        chunks = chunks.sortedByTranscriptTimeline()
    }
}
