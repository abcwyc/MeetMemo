import Accelerate
import Foundation

enum SpeakerClustering {
    /// Default threshold for real-time online clustering (CAM++ cosine similarity).
    /// Lower than 0.60 to accommodate natural intra-speaker pitch and tone variance.
    static let defaultOnlineThreshold: Float = 0.50
    /// Default threshold for offline hierarchical refinement (centroid cosine similarity).
    static let defaultOfflineThreshold: Float = 0.48

    /// Online incremental assignment: returns the speaker index that best matches the
    /// given embedding, creating a new one if no existing centroid is similar enough.
    /// `centroids` is updated in place — the matched centroid's running mean is refined
    /// to incorporate the new sample, and a fresh entry is appended when none qualifies.
    ///
    /// If `allowNewSpeaker` is false (e.g. for short utterances < 0.8s), and no existing
    /// centroid matches above threshold, it assigns to the nearest existing speaker without
    /// updating that speaker's centroid (preventing noisy feature corruption).
    static func assignOnline(
        embedding: [Float],
        centroids: inout [(centroid: [Float], count: Int)],
        threshold: Float = defaultOnlineThreshold,
        allowNewSpeaker: Bool = true
    ) -> Int {
        guard !embedding.isEmpty else {
            return centroids.isEmpty ? 0 : 0
        }
        let normalized = normalize(embedding)
        guard !normalized.isEmpty else {
            return centroids.isEmpty ? 0 : 0
        }

        var bestIndex = -1
        var bestSimilarity: Float = -.infinity
        for (index, entry) in centroids.enumerated() {
            let sim = cosineSimilarity(normalized, entry.centroid)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestIndex = index
            }
        }

        if bestIndex >= 0, bestSimilarity >= threshold {
            let updatedCount = centroids[bestIndex].count + 1
            let countFloat = Float(updatedCount)
            let oldWeight = Float(centroids[bestIndex].count) / countFloat
            let newWeight: Float = 1.0 / countFloat
            var updated = centroids[bestIndex].centroid
            let dim = updated.count
            for i in 0..<dim {
                updated[i] = updated[i] * oldWeight + normalized[i] * newWeight
            }
            centroids[bestIndex] = (centroid: normalize(updated), count: updatedCount)
            return bestIndex
        }

        // For short or low-quality utterances, do not spawn a new speaker if we already have one.
        if !allowNewSpeaker, bestIndex >= 0 {
            return bestIndex
        }

        centroids.append((centroid: normalized, count: 1))
        return centroids.count - 1
    }

    /// Offline refinement: Centroid-linkage agglomerative hierarchical clustering (HAC)
    /// over all collected embeddings.
    ///
    /// Replaces the earlier complete-linkage implementation which suffered from extreme
    /// over-clustering (refusing to merge clusters when a single outlier pair was below threshold)
    /// and O(N^4) pairwise recomputation. Centroid-linkage operates on the cluster center of mass,
    /// robustly merging speech fragments from the same speaker while maintaining separation between
    /// distinct speakers.
    ///
    /// - Parameters:
    ///   - embeddings: List of raw embedding vectors from the meeting segments.
    ///   - threshold: Minimum cosine similarity of cluster centroids required to merge.
    ///   - maxSpeakers: Optional upper bound on the number of speakers to produce.
    /// - Returns: An array of final speaker IDs for each input embedding.
    static func refineOffline(
        embeddings: [[Float]],
        threshold: Float = defaultOfflineThreshold,
        maxSpeakers: Int? = nil
    ) -> [Int] {
        guard !embeddings.isEmpty else { return [] }
        if embeddings.count == 1 { return [0] }

        let normalized = embeddings.map { normalize($0) }
        guard let dim = normalized.first?.count, dim > 0 else {
            return [Int](repeating: 0, count: embeddings.count)
        }

        struct Cluster {
            var members: [Int]
            var centroid: [Float]
            var count: Int
        }

        var clusters = (0..<normalized.count).map { idx in
            Cluster(members: [idx], centroid: normalized[idx], count: 1)
        }

        while clusters.count > 1 {
            var bestPair: (Int, Int) = (-1, -1)
            var bestSimilarity: Float = -.infinity

            let clusterCount = clusters.count
            for i in 0..<(clusterCount - 1) {
                let centroidI = clusters[i].centroid
                for j in (i + 1)..<clusterCount {
                    let sim = cosineSimilarity(centroidI, clusters[j].centroid)
                    if sim > bestSimilarity {
                        bestSimilarity = sim
                        bestPair = (i, j)
                    }
                }
            }

            // Stop criteria
            if let max = maxSpeakers, clusters.count <= max, bestSimilarity < threshold {
                break
            }
            if maxSpeakers == nil, bestSimilarity < threshold {
                break
            }

            let i = bestPair.0
            let j = bestPair.1
            guard i >= 0, j >= 0 else { break }

            let countI = Float(clusters[i].count)
            let countJ = Float(clusters[j].count)
            let totalCount = countI + countJ

            var combinedCentroid = [Float](repeating: 0, count: dim)
            let ci = clusters[i].centroid
            let cj = clusters[j].centroid
            for k in 0..<dim {
                combinedCentroid[k] = (ci[k] * countI + cj[k] * countJ) / totalCount
            }

            clusters[i].centroid = normalize(combinedCentroid)
            clusters[i].count = Int(totalCount)
            clusters[i].members.append(contentsOf: clusters[j].members)
            clusters.remove(at: j)
        }

        var assignment = [Int](repeating: 0, count: normalized.count)
        for (clusterIndex, cluster) in clusters.enumerated() {
            for member in cluster.members {
                assignment[member] = clusterIndex
            }
        }
        return assignment
    }

    // MARK: - Math primitives (Accelerate-backed)

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > .ulpOfOne else { return vector }
        var scale = 1.0 / norm
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
