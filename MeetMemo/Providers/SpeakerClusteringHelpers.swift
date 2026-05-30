import Foundation

enum SpeakerClustering {
    /// Online incremental assignment: returns the speaker index that best matches the
    /// given embedding, creating a new one if no existing centroid is similar enough.
    /// `centroids` is updated in place — the matched centroid's running mean is refined
    /// to incorporate the new sample, and a fresh entry is appended when none qualifies.
    static func assignOnline(
        embedding: [Float],
        centroids: inout [(centroid: [Float], count: Int)],
        threshold: Float = 0.60
    ) -> Int {
        let normalized = normalize(embedding)

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
            for i in 0..<updated.count {
                updated[i] = updated[i] * oldWeight + normalized[i] * newWeight
            }
            centroids[bestIndex] = (centroid: normalize(updated), count: updatedCount)
            return bestIndex
        }

        centroids.append((centroid: normalized, count: 1))
        return centroids.count - 1
    }

    /// Offline refinement: complete-linkage agglomerative clustering over all collected
    /// embeddings. Returns the final speaker index per input position. `threshold` is the
    /// cosine similarity below which two clusters will not be merged (lower → fewer speakers).
    static func refineOffline(embeddings: [[Float]], threshold: Float = 0.55) -> [Int] {
        guard !embeddings.isEmpty else { return [] }
        let normalized = embeddings.map { normalize($0) }
        var clusters: [[Int]] = (0..<normalized.count).map { [$0] }

        while clusters.count > 1 {
            var bestPair: (Int, Int) = (-1, -1)
            var bestSimilarity: Float = -.infinity
            for i in 0..<(clusters.count - 1) {
                for j in (i + 1)..<clusters.count {
                    let sim = completeLinkageSimilarity(clusters[i], clusters[j], embeddings: normalized)
                    if sim > bestSimilarity {
                        bestSimilarity = sim
                        bestPair = (i, j)
                    }
                }
            }
            if bestSimilarity < threshold { break }
            let merged = clusters[bestPair.0] + clusters[bestPair.1]
            clusters.remove(at: bestPair.1)
            clusters[bestPair.0] = merged
        }

        var assignment = [Int](repeating: 0, count: normalized.count)
        for (clusterIndex, members) in clusters.enumerated() {
            for member in members {
                assignment[member] = clusterIndex
            }
        }
        return assignment
    }

    // MARK: - Math primitives

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "embedding dimensionality mismatch")
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for value in vector { sumSquares += value * value }
        let norm = sqrt(sumSquares)
        guard norm > .ulpOfOne else { return vector }
        return vector.map { $0 / norm }
    }

    private static func completeLinkageSimilarity(
        _ a: [Int],
        _ b: [Int],
        embeddings: [[Float]]
    ) -> Float {
        var minSimilarity: Float = .infinity
        for i in a {
            for j in b {
                let sim = cosineSimilarity(embeddings[i], embeddings[j])
                if sim < minSimilarity { minSimilarity = sim }
            }
        }
        return minSimilarity
    }
}
