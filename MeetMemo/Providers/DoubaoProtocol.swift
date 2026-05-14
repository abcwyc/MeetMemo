import Foundation
import zlib

enum DoubaoMessageType: UInt8 {
    case fullClientRequest = 0x1
    case audioOnlyRequest = 0x2
    case fullServerResponse = 0x9
    case errorMessage = 0xF
}

enum DoubaoMessageFlags: UInt8 {
    case none = 0x0
    case sequencePositive = 0x1
    case lastWithoutSequence = 0x2
    case sequenceNegative = 0x3

    var includesSequenceNumber: Bool {
        self == .sequencePositive || self == .sequenceNegative
    }
}

enum DoubaoSerializationMethod: UInt8 {
    case none = 0x0
    case json = 0x1
}

enum DoubaoCompressionMethod: UInt8 {
    case none = 0x0
    case gzip = 0x1
}

struct DoubaoFrame {
    static let protocolVersion: UInt8 = 0x1
    static let headerSize: UInt8 = 0x1

    static func encodeFullClientRequest(json: Data) throws -> Data {
        let compressedJSON = try gzipCompress(json)
        var frame = buildHeader(
            messageType: .fullClientRequest,
            flags: .none,
            serialization: .json,
            compression: .gzip
        )
        appendUInt32(UInt32(compressedJSON.count), to: &frame)
        frame.append(compressedJSON)
        return frame
    }

    static func encodeAudioData(pcmData: Data, sequence: Int32, isLast: Bool) throws -> Data {
        let compressedAudio = try gzipCompress(pcmData)
        let sequenceValue = isLast ? -abs(sequence) : abs(sequence)

        var frame = buildHeader(
            messageType: .audioOnlyRequest,
            flags: isLast ? .sequenceNegative : .sequencePositive,
            serialization: .none,
            compression: .gzip
        )

        appendInt32(sequenceValue, to: &frame)
        appendUInt32(UInt32(compressedAudio.count), to: &frame)
        frame.append(compressedAudio)
        return frame
    }

    static func decode(_ data: Data) -> DoubaoResponse? {
        guard data.count >= 4 else { return nil }

        let protocolVersion = data[0] >> 4
        let headerSizeWords = Int(data[0] & 0x0F)
        guard protocolVersion == Self.protocolVersion,
              headerSizeWords > 0 else {
            return nil
        }

        let headerSize = headerSizeWords * 4
        guard data.count >= headerSize else { return nil }

        let messageTypeRaw = data[1] >> 4
        let flagRaw = data[1] & 0x0F
        let serializationRaw = data[2] >> 4
        let compressionRaw = data[2] & 0x0F

        guard let messageType = DoubaoMessageType(rawValue: messageTypeRaw) else {
            return nil
        }

        let flags = DoubaoMessageFlags(rawValue: flagRaw) ?? .none
        var offset = headerSize

        switch messageType {
        case .fullServerResponse:
            guard let sequence = readInt32(from: data, offset: &offset) else { return nil }

            guard let payloadSize = readUInt32(from: data, offset: &offset) else { return nil }
            let payloadLength = Int(payloadSize)
            guard offset + payloadLength <= data.count else { return nil }

            let payload = data.subdata(in: offset..<(offset + payloadLength))
            guard let decodedPayload = decodePayload(payload, serialization: serializationRaw, compression: compressionRaw) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let transcript = try? decoder.decode(DoubaoTranscriptEnvelope.self, from: decodedPayload)

            return DoubaoResponse(
                messageType: messageType,
                flags: flags,
                sequence: sequence,
                transcript: transcript,
                error: nil
            )

        case .errorMessage:
            guard let code = readUInt32(from: data, offset: &offset),
                  let messageSize = readUInt32(from: data, offset: &offset) else {
                return nil
            }

            let messageLength = Int(messageSize)
            guard offset + messageLength <= data.count else { return nil }

            let messageData = data.subdata(in: offset..<(offset + messageLength))
            let message = String(data: messageData, encoding: .utf8) ?? ""

            return DoubaoResponse(
                messageType: messageType,
                flags: flags,
                sequence: nil,
                transcript: nil,
                error: DoubaoServerError(code: code, message: message)
            )

        default:
            return nil
        }
    }

    private static func buildHeader(
        messageType: DoubaoMessageType,
        flags: DoubaoMessageFlags,
        serialization: DoubaoSerializationMethod,
        compression: DoubaoCompressionMethod
    ) -> Data {
        var data = Data()
        data.append((protocolVersion << 4) | headerSize)
        data.append((messageType.rawValue << 4) | flags.rawValue)
        data.append((serialization.rawValue << 4) | compression.rawValue)
        data.append(0x00)
        return data
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(from data: Data, offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    private static func readInt32(from data: Data, offset: inout Int) -> Int32? {
        guard offset + 4 <= data.count else { return nil }
        let rawValue = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let value = Int32(bitPattern: rawValue)
        offset += 4
        return value
    }

    private static func decodePayload(_ payload: Data, serialization: UInt8, compression: UInt8) -> Data? {
        guard serialization == DoubaoSerializationMethod.json.rawValue else {
            return nil
        }

        switch compression {
        case DoubaoCompressionMethod.none.rawValue:
            return payload
        case DoubaoCompressionMethod.gzip.rawValue:
            return try? gzipDecompress(payload)
        default:
            return nil
        }
    }

    private static func gzipCompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw DoubaoProtocolError.gzipCompressionFailed
        }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var output = Data(count: max(bound, 64))
        let outputCapacity = output.count

        let result = try data.withUnsafeBytes { inputBuffer -> Int32 in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw DoubaoProtocolError.gzipCompressionFailed
            }

            return try output.withUnsafeMutableBytes { outputBuffer -> Int32 in
                guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    throw DoubaoProtocolError.gzipCompressionFailed
                }

                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(outputCapacity)

                status = deflate(&stream, Z_FINISH)
                return status
            }
        }

        guard result == Z_STREAM_END else {
            throw DoubaoProtocolError.gzipCompressionFailed
        }

        output.removeSubrange(Int(stream.total_out)..<output.count)
        return output
    }

    private static func gzipDecompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        let status = inflateInit2_(
            &stream,
            MAX_WBITS + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw DoubaoProtocolError.gzipDecodingFailed
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 16 * 1024
        var output = Data()

        let result = try data.withUnsafeBytes { inputBuffer -> Int32 in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw DoubaoProtocolError.gzipDecodingFailed
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var inflateStatus: Int32 = Z_OK
            repeat {
                var chunk = Data(count: chunkSize)
                inflateStatus = try chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        throw DoubaoProtocolError.gzipDecodingFailed
                    }

                    stream.next_out = outputBase
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(chunk.prefix(produced))
                }
            } while inflateStatus == Z_OK

            return inflateStatus
        }

        guard result == Z_STREAM_END else {
            throw DoubaoProtocolError.gzipDecodingFailed
        }

        return output
    }
}

enum DoubaoProtocolError: Error {
    case gzipCompressionFailed
    case gzipDecodingFailed
}

struct DoubaoResponse {
    let messageType: DoubaoMessageType
    let flags: DoubaoMessageFlags
    let sequence: Int32?
    let transcript: DoubaoTranscriptEnvelope?
    let error: DoubaoServerError?
}

struct DoubaoTranscriptEnvelope: Decodable {
    let audioInfo: DoubaoAudioInfo?
    let result: DoubaoTranscriptResult?
}

struct DoubaoAudioInfo: Decodable {
    let duration: Int?
}

struct DoubaoTranscriptResult: Decodable {
    let text: String?
    let utterances: [DoubaoUtterance]?
}

struct DoubaoUtterance: Decodable {
    let text: String
    let definite: Bool?
    let words: [DoubaoWord]?
    let speakerTag: String?
    let speakerId: Int?
    let startTime: Int?
    let endTime: Int?

    private enum CodingKeys: String, CodingKey {
        case text
        case definite
        case words
        case speakerId = "speaker_id"
        case speaker
        case speakerDiarization = "speaker_diarization"
        case attribute
        case additions
        case startTime
        case endTime
        case startTimeSnake = "start_time"
        case endTimeSnake = "end_time"
    }

    private enum AdditionsCodingKeys: String, CodingKey {
        case speaker
        case speakerId = "speaker_id"
        case speakerDiarization = "speaker_diarization"
    }

    private enum AttributeCodingKeys: String, CodingKey {
        case speaker
        case speakerId = "speaker_id"
        case speakerDiarization = "speaker_diarization"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        definite = try container.decodeIfPresent(Bool.self, forKey: .definite)
        words = try container.decodeIfPresent([DoubaoWord].self, forKey: .words)
        startTime = try container.decodeIfPresent(Int.self, forKey: .startTime)
            ?? container.decodeIfPresent(Int.self, forKey: .startTimeSnake)
        endTime = try container.decodeIfPresent(Int.self, forKey: .endTime)
            ?? container.decodeIfPresent(Int.self, forKey: .endTimeSnake)

        // Decode additions so decodeSpeakerTag can read speaker_id from it.
        // Swift Decodable only decodes fields we explicitly ask for — not having .additions
        // in CodingKeys means additions is never decoded, so we must decode it explicitly here.
        let additionsContainer: KeyedDecodingContainer<AdditionsCodingKeys>?
        if let rawAdditions = try? container.decode([String: String].self, forKey: .additions) {
            // Manually decode additions using AdditionsCodingKeys from the raw string dict.
            // We check if speaker_id is present directly.
            if let sid = rawAdditions["speaker_id"], !sid.isEmpty {
                speakerTag = sid
                speakerId = Self.parseSpeakerId(from: sid)
                return
            }
            if let sp = rawAdditions["speaker"], !sp.isEmpty {
                speakerTag = sp
                speakerId = Self.parseSpeakerId(from: sp)
                return
            }
            additionsContainer = nil
        } else {
            additionsContainer = nil
        }
        speakerTag = Self.decodeSpeakerTag(from: container, additions: additionsContainer, words: words)
        speakerId = Self.parseSpeakerId(from: speakerTag)
    }

    private static func decodeSpeakerTag(
        from container: KeyedDecodingContainer<CodingKeys>,
        additions: KeyedDecodingContainer<AdditionsCodingKeys>?,
        words: [DoubaoWord]?
    ) -> String? {
        if let explicitSpeakerTag = decodeStringOrInt(from: container, key: .speakerId) {
            return explicitSpeakerTag
        }

        if let speakerTag = decodeStringOrInt(from: container, key: .speaker) {
            return speakerTag
        }

        if let additions {
            if let speakerTag = decodeStringOrInt(from: additions, key: .speakerId) {
                return speakerTag
            }

            if let speakerTag = decodeStringOrInt(from: additions, key: .speaker) {
                return speakerTag
            }

            if let speakerDiarization = decodeStringOrInt(from: additions, key: .speakerDiarization) {
                return speakerDiarization
            }
        }

        if let attribute = try? container.nestedContainer(keyedBy: AttributeCodingKeys.self, forKey: .attribute) {
            if let speakerTag = decodeStringOrInt(from: attribute, key: .speakerId) {
                return speakerTag
            }

            if let speakerTag = decodeStringOrInt(from: attribute, key: .speaker) {
                return speakerTag
            }

            if let speakerDiarization = decodeStringOrInt(from: attribute, key: .speakerDiarization) {
                return speakerDiarization
            }
        }

        if let wordSpeakerTag = words?.compactMap({ $0.speakerTag }).first(where: { !$0.isEmpty }) {
            return wordSpeakerTag
        }

        if let speakerDiarization = decodeStringOrInt(from: container, key: .speakerDiarization) {
            return speakerDiarization
        }

        return nil
    }

    private static func decodeStringOrInt<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        key: Key
    ) -> String? {
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(intValue)
        }

        return nil
    }

    private static func parseSpeakerId(from value: String?) -> Int? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let integer = Int(trimmed) {
            return integer
        }

        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }

        return Int(trimmed[range])
    }
}

struct DoubaoWord: Decodable {
    let text: String?
    let speakerTag: String?
    let speakerId: Int?

    private enum CodingKeys: String, CodingKey {
        case text
        case speakerId = "speaker_id"
        case speaker
        case attribute
    }

    private enum AttributeCodingKeys: String, CodingKey {
        case speaker
        case speakerId = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)

        if let speakerId = Self.decodeStringOrInt(from: container, key: .speakerId) {
            speakerTag = speakerId
            self.speakerId = Self.parseSpeakerId(from: speakerId)
            return
        }

        if let speaker = Self.decodeStringOrInt(from: container, key: .speaker) {
            speakerTag = speaker
            self.speakerId = Self.parseSpeakerId(from: speaker)
            return
        }

        if let attribute = try? container.nestedContainer(keyedBy: AttributeCodingKeys.self, forKey: .attribute) {
            if let speaker = Self.decodeStringOrInt(from: attribute, key: .speakerId) {
                speakerTag = speaker
                self.speakerId = Self.parseSpeakerId(from: speaker)
                return
            }

            if let speaker = Self.decodeStringOrInt(from: attribute, key: .speaker) {
                speakerTag = speaker
                self.speakerId = Self.parseSpeakerId(from: speaker)
                return
            }
        }

        speakerTag = nil
        speakerId = nil
    }

    private static func decodeStringOrInt<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        key: Key
    ) -> String? {
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(intValue)
        }

        return nil
    }

    private static func parseSpeakerId(from value: String?) -> Int? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let integer = Int(trimmed) {
            return integer
        }

        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }

        return Int(trimmed[range])
    }
}

struct DoubaoServerError: Error, Decodable {
    let code: UInt32
    let message: String
}
