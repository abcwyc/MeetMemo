import Foundation

struct STTProviderConfig: Codable, Hashable {
    var appId: String
    var accessToken: String

    var isConfigured: Bool {
        !appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
