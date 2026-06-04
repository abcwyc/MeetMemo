import Foundation

enum VoiceInputTextNormalizer {
    static func normalize(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s+"#, with: "", options: .regularExpression)

        let fillerPatterns = [
            #"(^|[，。！？；：、\s])(?:嗯+|啊+|呃+|额+|唔+|诶+|哎+|那个|这个|就是|然后)(?=[，。！？；：、\s]|$)"#,
            #"(^|[,.!?;:\s])(?:um+|uh+|er+|ah+|like)(?=[,.!?;:\s]|$)"#
        ]
        for pattern in fillerPatterns {
            text = text.replacingOccurrences(of: pattern, with: "$1", options: [.regularExpression, .caseInsensitive])
        }

        text = text.replacingOccurrences(of: #"(然后|就是)([，、\s]*(\1))+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([。！？!?])\1+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([，,])\1+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([，。！？；：、,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([，。！？；：、])\s+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        text = applyVoiceCommands(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyVoiceCommands(_ text: String) -> String {
        // 仅在命令词独立出现（前后为空白/标点或处于串首尾）时才替换，
        // 避免把正文里的同形词（如「这个句号用得好」「periodic」）误改。
        let boundary = "[\\s，。！？；：、,.!?;:]"
        let replacements: [(String, String)] = [
            ("新的一行", "\n"),
            ("换行", "\n"),
            ("逗号", "，"),
            ("句号", "。"),
            ("问号", "？"),
            ("感叹号", "！"),
            ("冒号", "："),
            ("分号", "；"),
            ("空格", " "),
            ("question mark", "?"),
            ("exclamation mark", "!"),
            ("comma", ","),
            ("period", ".")
        ]

        var result = text
        for (source, target) in replacements {
            let escapedSource = NSRegularExpression.escapedPattern(for: source)
            let pattern = "(^|\(boundary))\(escapedSource)(?=$|\(boundary))"
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1\(target)",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }
}
