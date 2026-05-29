import Foundation

struct STTTranscriptUpdate: Hashable {
    let text: String
    let isFinal: Bool
    let speakerTag: String?
    let speakerId: Int?
    let startTime: Int?
    let endTime: Int?

    init(
        text: String,
        isFinal: Bool,
        speakerTag: String? = nil,
        speakerId: Int? = nil,
        startTime: Int? = nil,
        endTime: Int? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.speakerTag = speakerTag
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
    }
}
