import Foundation

enum VoiceInputTextNormalizer {
    static func normalize(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s+"#, with: "", options: .regularExpression)

        // 只无条件删除纯语气词；「这个/那个/就是/然后/like」是常见正文词，
        // 不在此移除，避免「我要这个。」被删成「我要。」。它们只在叠词重复时收敛（见下）。
        let fillerPatterns = [
            #"(^|[，。！？；：、\s])(?:嗯+|呃+|额+|唔+|诶+)(?=[，。！？；：、\s]|$)"#,
            #"(^|[,.!?;:\s])(?:um+|uh+|er+)(?=[,.!?;:\s]|$)"#
        ]
        for pattern in fillerPatterns {
            text = text.replacingOccurrences(of: pattern, with: "$1", options: [.regularExpression, .caseInsensitive])
        }

        // 叠词收敛：仅把连续重复的口头语（「然后然后」「这个这个」）压成一个，单次出现保留。
        text = text.replacingOccurrences(of: #"(然后|就是|这个|那个)([，、\s]*(\1))+"#, with: "$1", options: .regularExpression)

        // 先把语音命令转成标点/换行，再统一清理空白，
        // 否则「你好 句号」会因转换发生在空格清理之后而残留成「你好 。」。
        text = applyVoiceCommands(text)

        text = text.replacingOccurrences(of: #"([。！？!?])\1+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([，,])\1+"#, with: "$1", options: .regularExpression)
        // 用 [ \t] 而非 \s，避免清理标点周围空格时误吃换行命令产生的 \n。
        text = text.replacingOccurrences(of: #"[ \t]+([，。！？；：、,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([，。！？；：、])[ \t]+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)

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
