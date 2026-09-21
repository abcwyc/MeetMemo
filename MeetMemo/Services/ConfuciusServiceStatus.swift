import Foundation

/// 本地 Confucius4-R2T2 MLX 服务（ws_server.py）的可达性状态。
///
/// 服务暴露 HTTP GET /status（同一端口 8272），返回：
/// {"service": "...", "model": "<量化档位目录名>", "active_connections": N}
@MainActor
final class ConfuciusServiceStatus: ObservableObject {
    static let shared = ConfuciusServiceStatus()

    @Published private(set) var isRunning = false
    @Published private(set) var isChecking = false
    /// 服务端实际加载的量化档位（如 "Confucius4-R2T2-mlx-8bit"），仅用于展示。
    @Published private(set) var modelName: String?
    @Published private(set) var activeConnections = 0
    @Published private(set) var lastCheckedAt: Date?

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func refresh() async {
        if isChecking { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: ConfuciusR2T2STTProvider.statusEndpoint)
            request.timeoutInterval = 2
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                markStopped()
                return
            }
            isRunning = true
            modelName = object["model"] as? String
            activeConnections = (object["active_connections"] as? Int) ?? 0
            lastCheckedAt = Date()
        } catch {
            markStopped()
        }
    }

    private func markStopped() {
        isRunning = false
        modelName = nil
        activeConnections = 0
        lastCheckedAt = Date()
    }
}
