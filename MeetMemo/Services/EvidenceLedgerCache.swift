import CryptoKit
import Foundation

/// Persistent cache for the expensive long-transcript evidence pass.
///
/// Entries are derived data stored in the app's Caches directory. The key includes
/// every input that can affect extraction, so changing the transcript, provider,
/// model, chunking policy, or extraction prompt automatically invalidates a hit.
actor EvidenceLedgerCache {
    static let shared = EvidenceLedgerCache()

    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directoryURL = base
                .appendingPathComponent("MeetMemo", isDirectory: true)
                .appendingPathComponent("EvidenceLedgers", isDirectory: true)
        }

        try? FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )
    }

    static func key(
        config: LLMProviderConfig,
        transcript: String,
        extractionPrompt: String,
        chunkTokenBudget: Int
    ) -> String {
        let material = [
            "provider=\(config.apiStyle.rawValue)",
            "baseURL=\(config.normalizedBaseURL)",
            "model=\(config.model.trimmingCharacters(in: .whitespacesAndNewlines))",
            "chunkTokenBudget=\(chunkTokenBudget)",
            "extractionPrompt=\(extractionPrompt)",
            "transcript=\(transcript)"
        ].joined(separator: "\n")

        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func value(forKey key: String) -> String? {
        let fileURL = directoryURL.appendingPathComponent(key).appendingPathExtension("md")
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    func store(_ value: String, forKey key: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fileURL = directoryURL.appendingPathComponent(key).appendingPathExtension("md")
        try? value.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
