import Foundation

/// 控制送入 LLM 的转录文本长度，防止长会议（约 3 小时+）的 prompt 超出模型上下文窗口
/// 导致请求直接失败。当转录估算 token 超出预算时，保留开头与结尾、省略中间段——
/// 会议开头通常交代背景、结尾通常给出结论，中间细节相对可舍。
///
/// 估算采用偏大启发式（CJK 每字 ~1 token、其余按字符数 / 4，再上浮 ~10%），
/// 宁可提前压缩也不冒超出 context window 的风险。更彻底的 Map-Reduce 分块留待后续。
enum TranscriptBudget {
    /// 默认输入预算。按主流 128k~200k 上下文模型，留足 prompt 模板与输出余量后取 ~96k tokens。
    static let inputTokenBudget = 96_000

    /// 头部占用预算的比例，其余归尾部。开头的背景信息通常比结尾的收尾更值得多保留一些。
    private static let headBudgetRatio = 0.55

    /// 启发式估算文本的 token 数（偏大估计）。
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }
        let raw = Double(cjk) + Double(other) / 4.0
        return Int((raw * 1.1).rounded(.up))
    }

    /// 将文本裁剪到 token 预算内。未超预算原样返回；超出则保留首尾、省略中间。
    /// - Returns: 处理后的文本，以及是否发生了压缩（供调用方提示用户）。
    static func fit(_ text: String, tokenBudget: Int = inputTokenBudget) -> (text: String, didCompress: Bool) {
        guard tokenBudget > 0, estimateTokens(text) > tokenBudget else {
            return (text, false)
        }

        let lines = text.components(separatedBy: "\n")
        guard lines.count > 2 else {
            // 无法按行切分（例如整段被压成单行）时，退化为按字符截断首尾。
            return (hardTruncate(text, tokenBudget: tokenBudget), true)
        }

        // 预留省略标记自身的 token 开销。
        let markerReserve = 64
        let usable = max(0, tokenBudget - markerReserve)
        let headBudget = Int(Double(usable) * headBudgetRatio)
        let tailBudget = usable - headBudget

        var headLines: [String] = []
        var headTokens = 0
        var headIndex = 0
        while headIndex < lines.count {
            let cost = estimateTokens(lines[headIndex]) + 1 // +1 ≈ 换行符
            if headTokens + cost > headBudget, !headLines.isEmpty { break }
            headLines.append(lines[headIndex])
            headTokens += cost
            headIndex += 1
        }

        var tailLines: [String] = []
        var tailTokens = 0
        var tailIndex = lines.count - 1
        while tailIndex >= headIndex {
            let cost = estimateTokens(lines[tailIndex]) + 1
            if tailTokens + cost > tailBudget, !tailLines.isEmpty { break }
            tailLines.append(lines[tailIndex])
            tailTokens += cost
            tailIndex -= 1
        }
        tailLines.reverse()

        let omittedCount = tailIndex - headIndex + 1
        guard omittedCount > 0 else {
            // 首尾已覆盖全部行，没有实际省略到内容——返回原文，避免插入误导性标记。
            return (text, false)
        }

        let assembled = headLines + [omissionMarker(omittedLineCount: omittedCount)] + tailLines
        return (assembled.joined(separator: "\n"), true)
    }

    // MARK: - Helpers

    /// 极端兜底：单行超长，按字符比例保留首尾。
    private static func hardTruncate(_ text: String, tokenBudget: Int) -> String {
        let chars = Array(text)
        // 粗略反推字符上限：token 预算 × ~4 字符/token，再保守乘 0.9。
        let charBudget = max(2, Int(Double(tokenBudget) * 4.0 * 0.9))
        guard chars.count > charBudget else { return text }
        let head = Int(Double(charBudget) * headBudgetRatio)
        let tail = charBudget - head
        let headStr = String(chars.prefix(head))
        let tailStr = String(chars.suffix(tail))
        return headStr + "\n" + omissionMarker(omittedLineCount: 1) + "\n" + tailStr
    }

    /// 中间被省略时插入的占位行。两种语言版本均含省略号 "…"，便于识别与测试。
    private static func omissionMarker(omittedLineCount: Int) -> String {
        LanguageManager.shared.t(
            "…（中间 \(omittedLineCount) 段转录因长度超出模型上下文已省略，仅保留开头与结尾）…",
            "…(\(omittedLineCount) middle transcript segments omitted: content exceeds the model context; only the beginning and end are kept)…"
        )
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点
             0x3040...0x30FF,   // 平假名 / 片假名
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本汉字
             0xF900...0xFAFF,   // 兼容表意
             0xFF00...0xFFEF:   // 全角字符
            return true
        default:
            return false
        }
    }
}
