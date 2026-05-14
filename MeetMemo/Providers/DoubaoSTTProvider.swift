import Foundation

final class DoubaoSTTProvider: STTProvider, @unchecked Sendable {
    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)? {
        get { callbackLock.withLock { onTranscriptUpdateHandler } }
        set { callbackLock.withLock { onTranscriptUpdateHandler = newValue } }
    }

    var onError: ((String) -> Void)? {
        get { callbackLock.withLock { onErrorHandler } }
        set { callbackLock.withLock { onErrorHandler = newValue } }
    }

    private let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private let resourceId = "volc.seedasr.sauc.duration"
    private let maximumWebSocketMessageSize = 64 * 1024 * 1024
    private let maximumPendingAudioBytes = 10 * 1024 * 1024
    private let stateLock = NSLock()
    private let utteranceTrackerLock = NSLock()
    private let callbackLock = NSLock()

    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var currentConnectID: String?
    private var isDisconnecting = false
    private var didSendFinalAudio = false
    private var didSendFinalAudioAt: Date?
    private var lastTranscriptAt: Date?
    private var isConnected = false
    private var nextAudioSequence: Int32 = 2
    private var pendingAudioBytes = 0
    private var droppedAudioFrameCount = 0
    private var onTranscriptUpdateHandler: ((STTTranscriptUpdate) -> Void)?
    private var onErrorHandler: ((String) -> Void)?

    /// Tracks seen utterances by (startTime, endTime) to detect changes in full-result mode.
    /// When result_type is "full", the server sends ALL utterances each time. We diff against
    /// the last known state so we only emit updates for new or changed utterances.
    private var utteranceTracker = UtteranceDiffTracker()

    func connect(config: STTProviderConfig) async throws {
        guard config.isConfigured else {
            throw ProviderValidationError.missingSTTConfig
        }

        disconnect()

        let connectID = UUID().uuidString
        let request = buildRequest(config: config, connectID: connectID)
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumWebSocketMessageSize

        stateLock.withLock {
            self.session = session
            self.socketTask = task
            self.currentConnectID = connectID
            self.isDisconnecting = false
            self.didSendFinalAudio = false
            self.didSendFinalAudioAt = nil
            self.lastTranscriptAt = nil
            self.isConnected = false
            self.nextAudioSequence = 2
            self.pendingAudioBytes = 0
            self.droppedAudioFrameCount = 0
        }

        task.resume()

        let fullRequest = try buildFullClientRequest()
        do {
            try await send(data: fullRequest, on: task)
        } catch {
            disconnect()
            throw error
        }

        stateLock.withLock {
            if currentConnectID == connectID {
                isConnected = true
            }
        }

        startReceiving(on: task, connectID: connectID)
    }

    func sendAudio(_ pcmData: Data) {
        sendAudioFrame(pcmData, isLast: false)
    }

    func sendLastAudio() {
        sendAudioFrame(Data(), isLast: true)
    }

    /// 等待服务端最终转录结果送达或超时。检测规则：
    /// 1) 如未发过 sendLastAudio，立即返回。
    /// 2) 收到 sendLastAudio 之后的首个转录回包，并保持 300ms 无新回包，认为已收齐。
    /// 3) 始终以 `timeout` 为上限退出，避免阻塞 stop 流程。
    func awaitPendingFinalization(timeout: TimeInterval) async {
        let quietWindow: TimeInterval = 0.3
        let pollInterval = UInt64(0.05 * 1_000_000_000)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let (sentAt, transcriptAt, disconnecting): (Date?, Date?, Bool) = stateLock.withLock {
                (didSendFinalAudioAt, lastTranscriptAt, isDisconnecting)
            }

            if disconnecting { return }
            guard let sentAt else { return }

            if let transcriptAt, transcriptAt > sentAt,
               Date().timeIntervalSince(transcriptAt) >= quietWindow {
                return
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    func disconnect() {
        let task: URLSessionWebSocketTask? = stateLock.withLock {
            isDisconnecting = true
            didSendFinalAudio = true
            isConnected = false
            pendingAudioBytes = 0
            droppedAudioFrameCount = 0
            let t = socketTask
            socketTask = nil
            session = nil
            currentConnectID = nil
            return t
        }

        utteranceTrackerLock.withLock {
            utteranceTracker.reset()
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    func testConnection(config: STTProviderConfig, timeout: TimeInterval = 5) async throws {
        guard config.isConfigured else {
            throw ProviderValidationError.missingSTTConfig
        }

        let testState = ConnectionTestState()
        let testProvider = DoubaoSTTProvider()
        testProvider.onError = { message in
            Task {
                await testState.recordError(message)
            }
        }

        try await testProvider.connect(config: config)
        defer { testProvider.disconnect() }

        let pollingInterval: UInt64 = 250_000_000
        let iterations = max(1, Int(timeout * 1_000_000_000 / Double(pollingInterval)))

        for _ in 0..<iterations {
            if let message = await testState.errorMessage {
                throw NSError(domain: "DoubaoSTTProvider", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }

            try await Task.sleep(nanoseconds: pollingInterval)
        }
    }

    private func buildRequest(config: STTProviderConfig, connectID: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.addValue(config.appId, forHTTPHeaderField: "X-Api-App-Key")
        request.addValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.addValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.addValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }

    private func buildFullClientRequest() throws -> Data {
        let payload = DoubaoFullClientRequest(
            user: DoubaoFullClientRequest.User(uid: "user"),
            audio: DoubaoFullClientRequest.Audio(format: "pcm", rate: 16_000, bits: 16, channel: 1),
            request: DoubaoFullClientRequest.Request(
                modelName: "bigmodel",
                resultType: "full",
                showUtterances: true,
                enableItn: true,
                enablePunc: true,
                enableNonstream: true,
                enableSpeakerInfo: true,
                ssdVersion: "200"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let jsonData = try encoder.encode(payload)
        return try DoubaoFrame.encodeFullClientRequest(json: jsonData)
    }

    private func send(data: Data, on task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.data(data)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func sendAudioFrame(_ pcmData: Data, isLast: Bool) {
        let pendingBytes = pcmData.count
        let captured: (task: URLSessionWebSocketTask, sequence: Int32, pendingBytes: Int)? = stateLock.withLock {
            guard !isDisconnecting, !didSendFinalAudio, let socketTask else { return nil }
            if !isLast, pendingAudioBytes + pendingBytes > maximumPendingAudioBytes {
                droppedAudioFrameCount += 1
                if droppedAudioFrameCount == 1 || droppedAudioFrameCount % 50 == 0 {
                    print("⚠️ Dropped \(droppedAudioFrameCount) STT audio frames because WebSocket send backlog is high.")
                }
                return nil
            }

            let seq = nextAudioSequence
            nextAudioSequence &+= 1
            pendingAudioBytes += pendingBytes
            if isLast {
                didSendFinalAudio = true
                didSendFinalAudioAt = Date()
            }
            return (socketTask, seq, pendingBytes)
        }

        guard let (task, sequence, capturedPendingBytes) = captured else { return }

        let frame: Data
        do {
            frame = try DoubaoFrame.encodeAudioData(pcmData: pcmData, sequence: sequence, isLast: isLast)
        } catch {
            stateLock.withLock {
                pendingAudioBytes = max(0, pendingAudioBytes - capturedPendingBytes)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onError?(ErrorHandler.shared.handleError(error))
            }
            return
        }

        task.send(.data(frame)) { [weak self] error in
            guard let self else { return }
            self.stateLock.withLock {
                self.pendingAudioBytes = max(0, self.pendingAudioBytes - capturedPendingBytes)
            }
            if let error, (error as? URLError)?.code != .cancelled {
                DispatchQueue.main.async {
                    self.onError?(ErrorHandler.shared.handleError(error))
                }
            }
        }
    }

    private func startReceiving(on task: URLSessionWebSocketTask, connectID: String) {
        Task { [weak self] in
            guard let self else { return }
            while self.isCurrentConnection(connectID) {
                do {
                    let message = try await task.receive()
                    guard self.isCurrentConnection(connectID) else { break }
                    self.handle(message)
                } catch {
                    guard self.isCurrentConnection(connectID) else { break }
                    let isExpectedClose = (error as? URLError)?.code == .cancelled
                        || self.stateLock.withLock { self.isDisconnecting }
                    if !isExpectedClose {
                        DispatchQueue.main.async {
                            self.onError?(ErrorHandler.shared.handleError(error))
                        }
                    }
                    break
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            guard let response = DoubaoFrame.decode(data) else { return }
            switch response.messageType {
            case .fullServerResponse:
                handleTranscriptResponse(response)
            case .errorMessage:
                handleErrorResponse(response)
            default:
                break
            }

        case .string(let string):
            let message = Self.normalizeServerMessage(string)
            DispatchQueue.main.async {
                self.onError?(message)
            }

        @unknown default:
            break
        }
    }

    private func handleTranscriptResponse(_ response: DoubaoResponse) {
        guard let utterances = response.transcript?.result?.utterances, !utterances.isEmpty else {
            if let text = response.transcript?.result?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                stateLock.withLock { lastTranscriptAt = Date() }
                DispatchQueue.main.async {
                    self.onTranscriptUpdate?(STTTranscriptUpdate(
                        text: text,
                        isFinal: true,
                        speakerTag: nil,
                        speakerId: nil,
                        startTime: nil,
                        endTime: nil,
                        isCorrection: false
                    ))
                }
            }
            return
        }

        let changes = utteranceTrackerLock.withLock {
            utteranceTracker.diff(utterances)
        }

        var didEmit = false
        for change in changes {
            switch change {
            case .new(let utterance), .updated(let utterance):
                let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let isCorrection: Bool
                if case .updated = change {
                    isCorrection = true
                } else {
                    isCorrection = false
                }

                didEmit = true
                DispatchQueue.main.async {
                    self.onTranscriptUpdate?(STTTranscriptUpdate(
                        text: text,
                        isFinal: utterance.definite ?? false,
                        speakerTag: utterance.speakerTag,
                        speakerId: utterance.speakerId,
                        startTime: utterance.startTime,
                        endTime: utterance.endTime,
                        isCorrection: isCorrection
                    ))
                }
            }
        }

        if didEmit {
            stateLock.withLock { lastTranscriptAt = Date() }
        }
    }

    private func handleErrorResponse(_ response: DoubaoResponse) {
        guard let error = response.error else { return }
        let message = ErrorHandler.shared.handleDoubaoError(code: Int(error.code), message: error.message)
        DispatchQueue.main.async {
            self.onError?(message)
        }
    }

    private func isCurrentConnection(_ connectID: String) -> Bool {
        stateLock.lock()
        let matches = currentConnectID == connectID && socketTask != nil
        stateLock.unlock()
        return matches
    }

    private static func normalizeServerMessage(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return trimmed
        }

        if let error = json["error"] {
            if let errorString = error as? String {
                return errorString.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let errorDict = error as? [String: Any] {
                if let message = errorDict["message"] as? String {
                    return message.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if let detail = errorDict["detail"] as? String {
                    return detail.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        if let message = json["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }
}

private actor ConnectionTestState {
    private var errorMessageValue: String?

    func recordError(_ message: String) {
        errorMessageValue = message
    }

    var errorMessage: String? {
        errorMessageValue
    }
}

/// Tracks utterances across full-result responses. With result_type="full", the server
/// sends ALL utterances on every response. This tracker diffs against the previous state
/// so only new or changed utterances are emitted.
///
/// The key for each utterance is (start_time, end_time). When a previously seen utterance
/// has its text or speaker tag updated (e.g. by the nonstream second-pass or by the
/// speaker clustering algorithm), it is emitted again as an .updated change.
struct UtteranceDiffTracker {
    enum Change {
        case new(DoubaoUtterance)
        case updated(DoubaoUtterance)
    }

    private struct UtteranceSnapshot: Hashable {
        let text: String
        let speakerTag: String?
        let speakerId: Int?
        let definite: Bool
    }

    /// Maps (startTime, endTime) → last known snapshot
    private var seen: [String: UtteranceSnapshot] = [:]

    private static func key(for utterance: DoubaoUtterance) -> String {
        let start = utterance.startTime ?? -1
        let end = utterance.endTime ?? -1
        return "\(start):\(end)"
    }

    mutating func diff(_ utterances: [DoubaoUtterance]) -> [Change] {
        var changes: [Change] = []
        var currentKeys: Set<String> = []

        for utterance in utterances {
            let k = Self.key(for: utterance)
            currentKeys.insert(k)

            let snapshot = UtteranceSnapshot(
                text: utterance.text,
                speakerTag: utterance.speakerTag,
                speakerId: utterance.speakerId,
                definite: utterance.definite ?? false
            )

            if let prev = seen[k] {
                if prev != snapshot {
                    changes.append(.updated(utterance))
                    seen[k] = snapshot
                }
            } else {
                changes.append(.new(utterance))
                seen[k] = snapshot
            }
        }

        // Prune utterances that disappeared (shouldn't normally happen with "full",
        // but protects against stale entries)
        for k in seen.keys where !currentKeys.contains(k) {
            seen.removeValue(forKey: k)
        }

        return changes
    }

    mutating func reset() {
        seen.removeAll()
    }
}

private struct DoubaoFullClientRequest: Encodable {
    struct User: Encodable {
        let uid: String
    }

    struct Audio: Encodable {
        let format: String
        let rate: Int
        let bits: Int
        let channel: Int
    }

    struct Request: Encodable {
        let modelName: String
        let resultType: String
        let showUtterances: Bool
        let enableItn: Bool
        let enablePunc: Bool
        let enableNonstream: Bool
        let enableSpeakerInfo: Bool
        let ssdVersion: String

        private enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case resultType = "result_type"
            case showUtterances = "show_utterances"
            case enableItn = "enable_itn"
            case enablePunc = "enable_punc"
            case enableNonstream = "enable_nonstream"
            case enableSpeakerInfo = "enable_speaker_info"
            case ssdVersion = "ssd_version"
        }
    }

    let user: User
    let audio: Audio
    let request: Request
}

struct STTTranscriptUpdate {
    let text: String
    let isFinal: Bool
    let speakerTag: String?
    let speakerId: Int?
    let startTime: Int?
    let endTime: Int?
    /// When true, this update corrects a previously emitted final chunk (e.g. speaker tag
    /// or text was revised by the second-pass or clustering algorithm). The receiver should
    /// replace the existing chunk matching (source, startTime, endTime) rather than append.
    let isCorrection: Bool
}
