import Foundation

struct ExtractedWebContext {
    let title: String
    let source: String
    let text: String
}

enum ContextExtractionError: LocalizedError {
    case invalidURL
    case unsupportedURL
    case requestFailed(Int)
    case emptyResponse
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接格式无效。"
        case .unsupportedURL:
            return "仅支持 http 或 https 链接。"
        case .requestFailed(let statusCode):
            return "网页读取失败，状态码：\(statusCode)。"
        case .emptyResponse:
            return "网页没有返回内容。"
        case .emptyContent:
            return "未能从网页中提取可用正文。"
        }
    }
}

final class ContextExtractorService {
    static let shared = ContextExtractorService()

    private let maxExtractedCharacters = 18_000

    private init() {}

    func extractWebPage(from urlString: String) async throws -> ExtractedWebContext {
        let url = try normalizedURL(from: urlString)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw ContextExtractionError.requestFailed(httpResponse.statusCode)
        }

        guard !data.isEmpty else {
            throw ContextExtractionError.emptyResponse
        }

        let html = decodeHTML(data)
        let title = extractFirstMatch(
            pattern: #"<title[^>]*>(.*?)</title>"#,
            from: html
        )
        let description = extractMetaContent(named: ["description", "og:description"], from: html)
        let bodyText = extractReadableText(from: html)

        var parts: [String] = []
        if let description, !description.isEmpty {
            parts.append("页面摘要：\(description)")
        }
        if !bodyText.isEmpty {
            parts.append(bodyText)
        }

        let text = clamp(parts.joined(separator: "\n\n"), limit: maxExtractedCharacters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextExtractionError.emptyContent
        }

        return ExtractedWebContext(
            title: title?.isEmpty == false ? title! : url.absoluteString,
            source: url.absoluteString,
            text: text
        )
    }

    func normalizedURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ContextExtractionError.invalidURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw ContextExtractionError.unsupportedURL
        }

        return url
    }

    private func decodeHTML(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func extractReadableText(from html: String) -> String {
        let jsonLDArticleText = extractJSONLDArticleBody(from: html)
        let articleBodyMeta = extractMetaContent(named: ["article:body", "twitter:description"], from: html)
        let candidates = extractContentCandidates(from: html)

        var extractedParts = [jsonLDArticleText, articleBodyMeta]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        extractedParts.append(contentsOf: candidates)

        let bestCandidate = extractedParts
            .map(cleanReadableHTML)
            .filter { !$0.isEmpty }
            .max { readableScore($0) < readableScore($1) }

        if let bestCandidate, bestCandidate.count >= 80 {
            return bestCandidate
        }

        return cleanReadableHTML(html)
    }

    private func extractContentCandidates(from html: String) -> [String] {
        let preferredTagPatterns = [
            #"(?is)<article\b[^>]*>(.*?)</article>"#,
            #"(?is)<main\b[^>]*>(.*?)</main>"#,
            #"(?is)<body\b[^>]*>(.*?)</body>"#
        ]

        var candidates: [String] = []
        for pattern in preferredTagPatterns {
            candidates.append(contentsOf: extractAllMatches(pattern: pattern, from: html))
        }

        let preferredContainerPattern = #"(?is)<(div|section)\b[^>]*(?:id|class)\s*=\s*["'][^"']*(?:article|content|entry|main|markdown|post|rich-text|story)[^"']*["'][^>]*>(.*?)</\1>"#
        candidates.append(contentsOf: extractAllMatches(pattern: preferredContainerPattern, from: html, groupIndex: 2))

        return candidates
    }

    private func cleanReadableHTML(_ html: String) -> String {
        var working = html
        working = remove(pattern: #"(?is)<(script|style|noscript|svg|canvas|iframe|header|footer|nav|aside)[^>]*>.*?</\1>"#, from: working)
        working = replace(pattern: #"(?i)<\s*br\s*/?\s*>"#, in: working, with: "\n")
        working = replace(pattern: #"(?i)</\s*(address|article|blockquote|dd|div|dl|dt|figcaption|figure|h[1-6]|li|main|ol|p|pre|section|table|td|th|tr|ul)\s*>"#, in: working, with: "\n")
        working = replace(pattern: #"(?i)<\s*li\b[^>]*>"#, in: working, with: "- ")
        working = remove(pattern: #"(?is)<!--.*?-->"#, from: working)
        working = remove(pattern: #"(?is)<[^>]+>"#, from: working)
        working = decodeEntities(working)
        working = collapseWhitespace(working)

        let lines = working
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        return lines.joined(separator: "\n")
    }

    private func extractMetaContent(named names: [String], from html: String) -> String? {
        let escapedNames = names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let patterns: [(pattern: String, groupIndex: Int)] = [
            (#"<meta\s+[^>]*(?:name|property)\s*=\s*["'](?:\#(escapedNames))["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#, 1),
            (#"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*(?:name|property)\s*=\s*["'](?:\#(escapedNames))["'][^>]*>"#, 1)
        ]

        for (pattern, groupIndex) in patterns {
            if let match = extractFirstMatch(pattern: pattern, from: html, groupIndex: groupIndex) {
                return match
            }
        }

        return nil
    }

    private func extractJSONLDArticleBody(from html: String) -> String? {
        let scripts = extractAllMatches(
            pattern: #"(?is)<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#,
            from: html
        )

        for script in scripts {
            let decoded = decodeEntities(script)
            guard let data = decoded.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }

            return firstJSONLDText(in: object, preferredKeys: ["articleBody", "description"])
        }

        return nil
    }

    private func firstJSONLDText(in object: Any, preferredKeys: [String]) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in preferredKeys {
                if let value = dictionary[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }

            for value in dictionary.values {
                if let nested = firstJSONLDText(in: value, preferredKeys: preferredKeys) {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = firstJSONLDText(in: value, preferredKeys: preferredKeys) {
                    return nested
                }
            }
        }

        return nil
    }

    private func extractFirstMatch(pattern: String, from text: String, groupIndex: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > groupIndex,
              let matchedRange = Range(match.range(at: groupIndex), in: text) else {
            return nil
        }

        return decodeEntities(String(text[matchedRange]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAllMatches(pattern: String, from text: String, groupIndex: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > groupIndex,
                  let matchedRange = Range(match.range(at: groupIndex), in: text) else {
                return nil
            }

            return String(text[matchedRange])
        }
    }

    private func readableScore(_ text: String) -> Int {
        let paragraphs = text.components(separatedBy: .newlines).filter { $0.count >= 20 }.count
        return text.count + paragraphs * 80
    }

    private func remove(pattern: String, from text: String) -> String {
        replace(pattern: pattern, in: text, with: "")
    }

    private func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private func decodeEntities(_ value: String) -> String {
        var result = value
        let namedEntities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]

        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        result = replaceNumericEntities(in: result)
        return result
    }

    private func replaceNumericEntities(in value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) else {
            return value
        }

        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length)).reversed()
        var result = value

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let token = nsValue.substring(with: match.range(at: 1))
            let radix = token.lowercased().hasPrefix("x") ? 16 : 10
            let scalarText = radix == 16 ? String(token.dropFirst()) : token

            guard let scalarValue = UInt32(scalarText, radix: radix),
                  let scalar = UnicodeScalar(scalarValue),
                  let range = Range(match.range, in: result) else {
                continue
            }

            result.replaceSubrange(range, with: String(Character(scalar)))
        }

        return result
    }

    private func collapseWhitespace(_ value: String) -> String {
        let normalizedNewlines = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let collapsedSpaces = replace(pattern: #"[ \t\f\v]+"#, in: normalizedNewlines, with: " ")
        let collapsedNewlines = replace(pattern: #"\n\s*\n\s*\n+"#, in: collapsedSpaces, with: "\n\n")
        return collapsedNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clamp(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }

        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "\n\n[内容过长，已截断]"
    }
}
