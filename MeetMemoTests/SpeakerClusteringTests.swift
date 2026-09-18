import XCTest
import Accelerate
@testable import MeetMemo

final class SpeakerClusteringTests: XCTestCase {

    func testCosineSimilarityAndNormalize() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]
        let v3: [Float] = [2.0, 0.0, 0.0]

        let norm1 = SpeakerClustering.normalize(v1)
        let norm3 = SpeakerClustering.normalize(v3)

        XCTAssertEqual(SpeakerClustering.cosineSimilarity(norm1, norm3), 1.0, accuracy: 1e-5)
        XCTAssertEqual(SpeakerClustering.cosineSimilarity(norm1, v2), 0.0, accuracy: 1e-5)
    }

    func testAssignOnlineSameSpeakerUpdatesCentroid() {
        var centroids: [(centroid: [Float], count: Int)] = []

        // Speaker 1 utterance 1
        var emb1 = [Float](repeating: 0, count: 64)
        emb1[0] = 1.0
        let id1 = SpeakerClustering.assignOnline(
            embedding: emb1,
            centroids: &centroids
        )
        XCTAssertEqual(id1, 0)
        XCTAssertEqual(centroids.count, 1)

        // Speaker 1 utterance 2 (slight acoustic variation, sim ~ 0.85)
        var emb2 = emb1
        emb2[1] = 0.3
        let id2 = SpeakerClustering.assignOnline(
            embedding: emb2,
            centroids: &centroids
        )
        XCTAssertEqual(id2, 0, "Same speaker should be assigned to existing centroid 0")
        XCTAssertEqual(centroids.count, 1)
        XCTAssertEqual(centroids[0].count, 2)
    }

    func testAssignOnlineDifferentSpeakersCreatesNewCentroid() {
        var centroids: [(centroid: [Float], count: Int)] = []

        var emb1 = [Float](repeating: 0, count: 64)
        emb1[0] = 1.0
        _ = SpeakerClustering.assignOnline(embedding: emb1, centroids: &centroids)

        // Speaker 2 (orthogonal direction)
        var emb2 = [Float](repeating: 0, count: 64)
        emb2[10] = 1.0
        let id2 = SpeakerClustering.assignOnline(embedding: emb2, centroids: &centroids)

        XCTAssertEqual(id2, 1, "Orthogonal embedding should spawn new speaker ID 1")
        XCTAssertEqual(centroids.count, 2)
    }

    func testAssignOnlineShortSegmentDoesNotSpawnNewSpeaker() {
        var centroids: [(centroid: [Float], count: Int)] = []

        var emb1 = [Float](repeating: 0, count: 64)
        emb1[0] = 1.0
        _ = SpeakerClustering.assignOnline(embedding: emb1, centroids: &centroids)

        // Noisy short segment (sim < threshold) with allowNewSpeaker = false
        var noisyShort = [Float](repeating: 0, count: 64)
        noisyShort[20] = 1.0 // orthogonal/unrelated
        let idShort = SpeakerClustering.assignOnline(
            embedding: noisyShort,
            centroids: &centroids,
            allowNewSpeaker: false
        )

        XCTAssertEqual(idShort, 0, "Short segment should not spawn a new speaker; attaches to nearest")
        XCTAssertEqual(centroids.count, 1, "Centroid count must remain 1")
        XCTAssertEqual(centroids[0].count, 1, "Noisy short segment must not pollute centroid running average")
    }

    func testRefineOfflineMergesFragmentedUtterancesFromSameSpeaker() {
        // Prototype: 2 real speakers, but with 5 utterances each that have slight intra-speaker variance.
        // Under old Complete Linkage, this would fragment into 6-8 clusters.
        // Under Centroid Linkage, it cleanly merges into exactly 2 speakers.
        var baseA = [Float](repeating: 0, count: 64)
        var baseB = [Float](repeating: 0, count: 64)
        baseA[0] = 1.0; baseA[1] = 0.5
        baseB[10] = 1.0; baseB[11] = 0.5
        baseA = SpeakerClustering.normalize(baseA)
        baseB = SpeakerClustering.normalize(baseB)

        var embeddings: [[Float]] = []
        for _ in 0..<5 {
            var v = baseA
            for k in 0..<64 { v[k] += Float.random(in: -0.2...0.2) }
            embeddings.append(SpeakerClustering.normalize(v))
        }
        for _ in 0..<5 {
            var v = baseB
            for k in 0..<64 { v[k] += Float.random(in: -0.2...0.2) }
            embeddings.append(SpeakerClustering.normalize(v))
        }

        let result = SpeakerClustering.refineOffline(embeddings: embeddings, threshold: 0.48)
        let uniqueSpeakers = Set(result)

        XCTAssertEqual(uniqueSpeakers.count, 2, "10 utterances from 2 speakers must converge to 2 clusters, got \(uniqueSpeakers.count)")
        XCTAssertEqual(Set(result[0..<5]).count, 1, "First 5 utterances should all share the same speaker ID")
        XCTAssertEqual(Set(result[5..<10]).count, 1, "Last 5 utterances should all share the same speaker ID")
        XCTAssertNotEqual(result[0], result[5], "Speaker A and Speaker B must have different IDs")
    }

    func testRefineOfflineKeepsThreeDistinctSpeakersSeparated() {
        var base1 = [Float](repeating: 0, count: 128); base1[0] = 1.0
        var base2 = [Float](repeating: 0, count: 128); base2[40] = 1.0
        var base3 = [Float](repeating: 0, count: 128); base3[80] = 1.0

        var embeddings: [[Float]] = []
        for _ in 0..<4 {
            var v = base1; for k in 0..<128 { v[k] += Float.random(in: -0.15...0.15) }
            embeddings.append(SpeakerClustering.normalize(v))
        }
        for _ in 0..<4 {
            var v = base2; for k in 0..<128 { v[k] += Float.random(in: -0.15...0.15) }
            embeddings.append(SpeakerClustering.normalize(v))
        }
        for _ in 0..<4 {
            var v = base3; for k in 0..<128 { v[k] += Float.random(in: -0.15...0.15) }
            embeddings.append(SpeakerClustering.normalize(v))
        }

        let result = SpeakerClustering.refineOffline(embeddings: embeddings, threshold: 0.48)
        XCTAssertEqual(Set(result).count, 3, "3 distinct speakers must produce exactly 3 clusters")
    }

    func testRefineOfflinePerformanceOnLargeSequence() {
        // 100 segments of 512-dim CAM++ vectors from the same speaker
        var base = [Float](repeating: 0, count: 512)
        base[0] = 1.0
        base = SpeakerClustering.normalize(base)

        var embeddings: [[Float]] = []
        for _ in 0..<100 {
            var v = base
            for k in 0..<512 { v[k] += Float.random(in: -0.01...0.01) }
            embeddings.append(SpeakerClustering.normalize(v))
        }

        let start = ProcessInfo.processInfo.systemUptime
        let result = SpeakerClustering.refineOffline(embeddings: embeddings)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(Set(result).count, 1)
        XCTAssertLessThan(elapsed, 0.25, "100 segments should cluster in well under 250ms (got \(elapsed * 1000)ms)")
    }
}
