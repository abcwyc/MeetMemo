import Foundation

/// STT provider backed by sherpa-onnx (SenseVoice-Small + Silero VAD + CAM++ speaker embedding).
///
/// Two-stage speaker labeling:
/// 1. Per VAD segment, extract a CAM++ embedding and assign a speaker id via
///    online centroid clustering. The result is emitted immediately as a final
///    `STTTranscriptUpdate` with the provisional `speakerId`.
/// 2. When the host calls `applyOfflineRefinement()` (after `awaitPendingFinalization`
///    returns), all collected embeddings are re-clustered offline with complete-linkage
///    HAC, and any segments whose final speaker id differs from the provisional one
///    are emitted as `STTTranscriptCorrection`s via `onTranscriptCorrection`.
///
/// NOTE: The actual sherpa-onnx Swift calls (OfflineRecognizer init, VAD accept,
/// EmbeddingExtractor compute) are gated behind the `SherpaOnnxRuntime` adapter and
/// activated only when the prebuilt xcframework is integrated into the Xcode project.
/// Until then, `connect` throws a friendly error so the host can fall back gracefully.
final class SherpaSTTProvider: STTProvider, @unchecked Sendable {
    var capabilities: STTProviderCapabilities {
        STTProviderCapabilities(
            supportsStableUtteranceTiming: true,
            supportsCorrections: true,
            supportsFinalizationFlush: true
        )
    }

    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)?
    var onTranscriptCorrection: (([STTTranscriptCorrection]) -> Void)?
    var onError: ((String) -> Void)?

    private struct SegmentRecord {
        let startMs: Int
        let endMs: Int
        let embedding: [Float]
        let provisionalSpeakerId: Int
    }

    private static let sampleRate = 16_000
    private static let fallbackDecodeSampleLimit = sampleRate * 30
    private static let leadingContextSamples = Int(Double(sampleRate) * 0.32)

    private var runtime: SherpaOnnxRuntime?
    private var ringBuffer: [Float] = []
    private var totalSamplesIngested: Int = 0
    private var emittedSegmentCount = 0
    private var lastEmittedEndSampleOffset = 0
    private var speakerCentroids: [(centroid: [Float], count: Int)] = []
    private var segmentLedger: [SegmentRecord] = []
    private let workQueue = DispatchQueue(label: "io.meetmemo.sherpa.stt", qos: .userInitiated)

    func connect(config: STTProviderConfig) async throws {
        disconnect()

        let modelDir: URL = try await Task { @MainActor in
            try await SherpaModelManager.shared.ensureReadyForUse()
            return SherpaModelManager.shared.modelDirectory
        }.value

        do {
            runtime = try SherpaOnnxRuntime.make(modelDirectory: modelDir)
        } catch {
            onError?(error.localizedDescription)
            throw error
        }
    }

    func sendAudio(_ pcmData: Data) {
        guard let runtime else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.processIncomingBytes(pcmData, runtime: runtime)
        }
    }

    func sendLastAudio() {
        guard let runtime else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            runtime.flushVAD()
            self.drainCompletedSegments(runtime: runtime, force: true)
        }
    }

    func disconnect() {
        runtime = nil
        ringBuffer.removeAll(keepingCapacity: false)
        totalSamplesIngested = 0
        emittedSegmentCount = 0
        lastEmittedEndSampleOffset = 0
        speakerCentroids.removeAll()
        segmentLedger.removeAll()
    }

    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws {
        try await Task { @MainActor in
            try await SherpaModelManager.shared.ensureReadyForUse()
        }.value
    }

    func awaitPendingFinalization(timeout: TimeInterval) async -> STTFinalizationStatus {
        await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: .completed)
            }
        }
    }

    func applyOfflineRefinement() async {
        let snapshot: [SegmentRecord] = await withCheckedContinuation { continuation in
            workQueue.async { [weak self] in
                continuation.resume(returning: self?.segmentLedger ?? [])
            }
        }
        guard snapshot.count >= 2 else { return }

        let embeddings = snapshot.map { $0.embedding }
        let refined = SpeakerClustering.refineOffline(embeddings: embeddings)

        var corrections: [STTTranscriptCorrection] = []
        for (index, record) in snapshot.enumerated() {
            let newId = refined[index]
            if newId != record.provisionalSpeakerId {
                corrections.append(STTTranscriptCorrection(
                    startTime: record.startMs,
                    endTime: record.endMs,
                    newSpeakerId: newId,
                    newSpeakerTag: Self.speakerTag(forId: newId)
                ))
            }
        }
        guard !corrections.isEmpty else { return }
        onTranscriptCorrection?(corrections)
    }

    // MARK: - Audio handling (runs on workQueue)

    private func processIncomingBytes(_ data: Data, runtime: SherpaOnnxRuntime) {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        var floats = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / Float(Int16.max)
            for i in 0..<sampleCount {
                floats[i] = Float(base[i]) * scale
            }
        }

        totalSamplesIngested += sampleCount
        ringBuffer.append(contentsOf: floats)
        if ringBuffer.count > Self.fallbackDecodeSampleLimit {
            ringBuffer.removeFirst(ringBuffer.count - Self.fallbackDecodeSampleLimit)
        }

        runtime.acceptWaveform(floats)
        drainCompletedSegments(runtime: runtime, force: false)
    }

    private func drainCompletedSegments(runtime: SherpaOnnxRuntime, force: Bool) {
        let segmentsBeforeDrain = emittedSegmentCount
        while let segment = runtime.nextCompletedSegment(force: force) {
            handle(segment: segmentWithLeadingContext(segment, runtime: runtime), runtime: runtime)
        }
        if force, emittedSegmentCount == segmentsBeforeDrain,
           let segment = makeUnemittedFallbackSegment(runtime: runtime) {
            handle(segment: segment, runtime: runtime)
        }
    }

    private func makeUnemittedFallbackSegment(runtime: SherpaOnnxRuntime) -> SherpaOnnxRuntime.Segment? {
        guard !ringBuffer.isEmpty else { return nil }

        let historyStartOffset = totalSamplesIngested - ringBuffer.count
        let fallbackStartOffset = max(historyStartOffset, lastEmittedEndSampleOffset)
        let startIndex = fallbackStartOffset - historyStartOffset
        guard startIndex >= 0, startIndex < ringBuffer.count else { return nil }

        let tailSamples = Array(ringBuffer[startIndex...])
        return runtime.decodeFallbackSegment(
            samples: tailSamples,
            startSampleOffset: fallbackStartOffset
        )
    }

    private func segmentWithLeadingContext(
        _ segment: SherpaOnnxRuntime.Segment,
        runtime: SherpaOnnxRuntime
    ) -> SherpaOnnxRuntime.Segment {
        let historyStartOffset = totalSamplesIngested - ringBuffer.count
        let contextStartOffset = max(
            historyStartOffset,
            lastEmittedEndSampleOffset,
            segment.startSampleOffset - Self.leadingContextSamples
        )
        guard contextStartOffset < segment.startSampleOffset else {
            return segment
        }

        let prefixStartIndex = contextStartOffset - historyStartOffset
        let prefixEndIndex = segment.startSampleOffset - historyStartOffset
        guard prefixStartIndex >= 0,
              prefixEndIndex <= ringBuffer.count,
              prefixStartIndex < prefixEndIndex else {
            return segment
        }

        let expandedSamples = Array(ringBuffer[prefixStartIndex..<prefixEndIndex]) + segment.samples
        let expanded = runtime.decodeFallbackSegment(
            samples: expandedSamples,
            startSampleOffset: contextStartOffset
        )
        return expanded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? segment : expanded
    }

    private func handle(segment: SherpaOnnxRuntime.Segment, runtime: SherpaOnnxRuntime) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        emittedSegmentCount += 1
        lastEmittedEndSampleOffset = max(lastEmittedEndSampleOffset, segment.endSampleOffset)

        let embedding = runtime.embedding(for: segment.samples)
        let speakerId = SpeakerClustering.assignOnline(
            embedding: embedding,
            centroids: &speakerCentroids
        )

        let startMs = Int(Double(segment.startSampleOffset) * 1000.0 / Double(Self.sampleRate))
        let endMs = Int(Double(segment.endSampleOffset) * 1000.0 / Double(Self.sampleRate))
        let tag = Self.speakerTag(forId: speakerId)

        segmentLedger.append(SegmentRecord(
            startMs: startMs,
            endMs: endMs,
            embedding: embedding,
            provisionalSpeakerId: speakerId
        ))

        let update = STTTranscriptUpdate(
            text: text,
            isFinal: true,
            speakerTag: tag,
            speakerId: speakerId,
            startTime: startMs,
            endTime: endMs
        )

        DispatchQueue.main.async { [weak self] in
            self?.onTranscriptUpdate?(update)
        }
    }

    private static func speakerTag(forId id: Int) -> String {
        let displayId = id + 1
        return LanguageManager.shared.t("发言人 \(displayId)", "Speaker \(displayId)")
    }
}

final class SherpaSTTProviderFactory: STTProviderFactory {
    func makeProvider() -> STTProvider {
        SherpaSTTProvider()
    }
}
