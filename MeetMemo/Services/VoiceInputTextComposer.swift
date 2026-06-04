import Foundation

/// 将多段最终转写片段拼接成一段连贯文本。
///
/// STT 引擎按句/段输出独立的 final 片段，直接 `joined(separator: "")` 会让英文相邻片段
/// 粘连（"hello" + "world" → "helloworld"）。这里做语言感知拼接：
/// - 拉丁字母/数字词边界之间补一个空格（典型英文单词间隔）
/// - CJK 任一侧不补空格（沿用中文无空格排版）
/// - 标点任一侧不补空格（保持标点贴合）
///
/// 标点命令转换、口头语清洗等仍由 `VoiceInputTextNormalizer` 负责，本类只管片段拼接。
enum VoiceInputTextComposer {
    static func compose(_ parts: [String]) -> String {
        var result = ""
        for rawPart in parts {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let prev = result.last,
               let next = part.first,
               needsSpace(between: prev, and: next) {
                result.append(" ")
            }
            result.append(part)
        }
        return result
    }

    /// 仅当边界两侧都是拉丁字母/数字时补空格。CJK、标点、空白任一侧都不补。
    private static func needsSpace(between left: Character, and right: Character) -> Bool {
        isLatinWordChar(left) && isLatinWordChar(right)
    }

    private static func isLatinWordChar(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else {
            return false
        }
        return character.isLetter || character.isNumber
    }
}
