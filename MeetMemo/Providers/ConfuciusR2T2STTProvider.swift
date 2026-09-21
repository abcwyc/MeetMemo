import Foundation

/// 本地 Confucius4-R2T2 (MLX) 流式引擎。
///
/// 连接 `~/VibeCode/r2t2-mlx` 中 `ws_server.py` 提供的本地 WebSocket 服务
/// （默认 ws://127.0.0.1:8272/asr_stream_api_v1）。协议：
/// 首帧 JSON header → int16 LE 单声道 16kHz PCM 二进制帧（任意节奏）→
/// EOS 字符串；服务端回包 `msg.text` 为增量文本，`reset: true` 为最终结果。
///
/// 无说话人分离（speakerTag/speakerId 恒为 nil）；时间戳基于已送入的采样数
/// 估算（capabilities.supportsStableUtteranceTiming = false）。
final class ConfuciusR2T2STTProvider: STTProvider, @unchecked Sendable {

    var capabilities: STTProviderCapabilities {
        STTProviderCapabilities(
            supportsStableUtteranceTiming: false,
            supportsCorrections: false,
            supportsFinalizationFlush: true
        )
    }

    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)?
    var onTranscriptCorrection: (([STTTranscriptCorrection]) -> Void)?
    var onError: ((String) -> Void)?

    static let defaultEndpoint = URL(string: "ws://127.0.0.1:8272/asr_stream_api_v1")!
    static let statusEndpoint = URL(string: "http://127.0.0.1:8273/status")!
    private static let eosString = "YOUDAO_ONETIME_ASR_STREAM_EOS"
    private static let connectTimeout: TimeInterval = 5

    /// 句末标点：收到即切分一个 final chunk，避免时间线出现超长段。
    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";"]
    /// 无标点时的兜底切分长度。
    private static let maxSegmentChars = 60

    private let session: URLSession

    /// 所有可变状态（socket、文本累积、计数、等待者）只在 stateQueue 上访问。
    private let stateQueue = DispatchQueue(label: "io.meetmemo.confucius.stt", qos: .userInitiated)
    private var socket: URLSessionWebSocketTask?
    private var pendingText = ""
    private var segmentStartMs: Int?
    private var samplesSent = 0
    private var finalResetReceived = false
    private var finalWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0  // 超时由调用侧控制
        self.session = URLSession(configuration: config)
    }

    // MARK: - STTProvider

    func connect(config: STTProviderConfig) async throws {
        disconnect()

        let socket = session.webSocketTask(with: Self.defaultEndpoint)
        stateQueue.sync { self.socket = socket }
        socket.resume()

        do {
            let header: [String: Any] = [
                "channels": 1,
                "sample_rate": 16_000,
                "requestId": UUID().uuidString,
                "language": "zhen",
                "use_vad": false,
                "mode": "slow",
            ]
            let headerData = try JSONSerialization.data(withJSONObject: header)
            guard let headerJSON = String(data: headerData, encoding: .utf8) else {
                throw ConfuciusServiceError.serverNotRunning
            }
            try await socket.send(.string(headerJSON))

            // 等待 "connected" 回包确认服务可用，失败给出可操作的错误提示。
            let first = try await Self.withTimeout(Self.connectTimeout) {
                try await socket.receive()
            }
            switch first {
            case .string(let text):
                guard Self.messageStatus(text) == "connected" else {
                    throw ConfuciusServiceError.serverNotRunning
                }
            default:
                throw ConfuciusServiceError.serverNotRunning
            }
        } catch {
            disconnect()
            onError?(ConfuciusServiceError.serverNotRunning.localizedDescription)
            throw ConfuciusServiceError.serverNotRunning
        }

        startReceiveLoop(on: socket)
    }

    func sendAudio(_ pcmData: Data) {
        stateQueue.async { [weak self] in
            self?.samplesSent += pcmData.count / 2
        }
        guard let socket = stateQueue.sync(execute: { socket }) else { return }
        socket.send(.data(pcmData)) { [weak self] (error: Error?) in
            if let error {
                self?.onError?("Confucius 发送音频失败: \(error.localizedDescription)")
            }
        }
    }

    func sendLastAudio() {
        guard let socket = stateQueue.sync(execute: { socket }) else { return }
        socket.send(.string(Self.eosString)) { [weak self] (error: Error?) in
            if let error {
                self?.onError?("Confucius 发送结束信号失败: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        let socket = stateQueue.sync {
            let socket = self.socket
            self.socket = nil
            markFinalResetLocked()
            return socket
        }
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws {
        var request = URLRequest(url: Self.statusEndpoint)
        request.timeoutInterval = timeout
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ConfuciusServiceError.serverNotRunning
        }
    }

    func awaitPendingFinalization(timeout: TimeInterval) async -> STTFinalizationStatus {
        let timedOut = await Self.sleepOrTimeout(timeout) { [weak self] in
            await self?.waitForFinalReset()
        }
        flushPendingAsFinal()
        return timedOut ? .finalizeTimedOut : .completed
    }

    // MARK: - 接收循环

    private func startReceiveLoop(on socket: URLSessionWebSocketTask) {
        Task { [weak self, socket] in
            while let self {
                let active: URLSessionWebSocketTask? = stateQueue.sync(execute: { socket })
                guard active === socket else { return }
                do {
                    let message = try await socket.receive()
                    self.handleMessage(message)
                } catch {
                    // 连接关闭（服务端发完 reset 后会主动关闭）。若尚未标记终态，
                    // 也在此标记，避免上层 finalization 挂起。
                    let wasActive: Bool = self.stateQueue.sync {
                        let active = self.socket === socket
                        if active {
                            self.socket = nil
                            self.markFinalResetLocked()
                        }
                        return active
                    }
                    if wasActive { return }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = object["msg"] as? [String: Any] else {
            return
        }

        if let increment = msg["text"] as? String, !increment.isEmpty {
            handleIncrement(increment)
        }
        if let reset = msg["reset"] as? Bool, reset {
            stateQueue.sync { markFinalResetLocked() }
        }
    }

    // MARK: - 文本切分

    private func handleIncrement(_ increment: String) {
        var text = ""
        var startMs = 0
        var endMs = 0
        var splitFinal = false

        stateQueue.sync {
            pendingText += increment
            endMs = Int(Double(samplesSent) * 1000.0 / 16_000.0)
            if segmentStartMs == nil { segmentStartMs = endMs }
            startMs = segmentStartMs ?? endMs
            text = pendingText
            if let last = text.last, Self.sentenceEnders.contains(last)
                || text.count >= Self.maxSegmentChars {
                splitFinal = true
            }
        }

        if splitFinal {
            flushPendingAsFinal()
        } else {
            // interim 更新携带当前段落全文（上层按同 id 整体替换 interim chunk）。
            onTranscriptUpdate?(STTTranscriptUpdate(
                text: text,
                isFinal: false,
                startTime: startMs,
                endTime: endMs
            ))
        }
    }

    /// 把当前累积文本作为 final chunk 发出并重置段落。
    private func flushPendingAsFinal() {
        var text = ""
        var startMs: Int?
        var endMs = 0
        stateQueue.sync {
            guard !pendingText.isEmpty else { return }
            text = pendingText
            startMs = segmentStartMs
            endMs = Int(Double(samplesSent) * 1000.0 / 16_000.0)
            pendingText = ""
            segmentStartMs = nil
        }
        guard !text.isEmpty else { return }
        onTranscriptUpdate?(STTTranscriptUpdate(
            text: text,
            isFinal: true,
            startTime: startMs ?? endMs,
            endTime: endMs
        ))
    }

    // MARK: - 终态等待

    /// 挂起直到收到 reset / 连接关闭 / disconnect。
    private func waitForFinalReset() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var alreadyDone = false
            stateQueue.sync {
                if finalResetReceived {
                    alreadyDone = true
                } else {
                    finalWaiters.append(continuation)
                }
            }
            if alreadyDone {
                continuation.resume()
            }
        }
    }

    /// 仅在 stateQueue 上调用。
    private func markFinalResetLocked() {
        finalResetReceived = true
        let waiters = finalWaiters
        finalWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - 工具

    private static func messageStatus(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["status"] as? String
    }

    /// 返回 true 表示超时（operation 未在限时内完成）。
    private static func sleepOrTimeout(
        _ timeout: TimeInterval,
        operation: @escaping () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return true
            }
            let result = await group.next() ?? true
            group.cancelAll()
            return result
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }
    }
}

struct ConfuciusR2T2STTProviderFactory: STTProviderFactory {
    func makeProvider() -> STTProvider {
        ConfuciusR2T2STTProvider()
    }
}

enum ConfuciusServiceError: LocalizedError {
    case serverNotRunning

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return LanguageManager.shared.t(
                "本地 Confucius4-R2T2 服务未运行。请在终端启动：cd ~/VibeCode/r2t2-mlx && .venv/bin/python ws_server.py",
                "Local Confucius4-R2T2 service is not running. Start it in Terminal: cd ~/VibeCode/r2t2-mlx && .venv/bin/python ws_server.py"
            )
        }
    }
}
