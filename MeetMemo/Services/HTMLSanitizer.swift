import Foundation

enum HTMLSanitizer {
    private static let allowedTags: Set<String> = [
        "div", "span", "p", "strong", "em", "b", "i",
        "ul", "ol", "li",
        "table", "thead", "tbody", "tr", "th", "td",
        "br"
    ]

    private static let allowedClasses: Set<String> = [
        "card",
        "badge", "badge-info", "badge-success", "badge-warning", "badge-danger", "badge-purple",
        "label",
        "timeline", "timeline-item", "timeline-dot", "dot-green", "dot-amber", "dot-red", "dot-blue",
        "flow", "flow-node", "flow-arrow",
        "grid-2", "grid-3", "grid-auto"
    ]

    static func sanitizeDiagramHTML(_ html: String) -> String {
        var cleaned = html.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = remove(pattern: #"(?is)<!--.*?-->"#, from: cleaned)
        cleaned = remove(pattern: #"(?is)<\s*(script|style|iframe|object|embed|link|meta|svg|canvas|img|video|audio|source)\b[^>]*>.*?<\s*/\s*\1\s*>"#, from: cleaned)
        cleaned = remove(pattern: #"(?is)<\s*(script|style|iframe|object|embed|link|meta|svg|canvas|img|video|audio|source)\b[^>]*\/?\s*>"#, from: cleaned)
        cleaned = replaceTags(in: cleaned)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceTags(in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)).reversed()
        var result = html

        for match in matches {
            let rawTag = nsHTML.substring(with: match.range)
            let replacement = sanitizedTag(rawTag) ?? ""
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }

    private static func sanitizedTag(_ rawTag: String) -> String? {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
        guard !trimmed.hasPrefix("</") else {
            let tagName = trimmed
                .dropFirst(2)
                .dropLast()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return allowedTags.contains(tagName) ? "</\(tagName)>" : nil
        }

        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tagName = inner.split(whereSeparator: { $0.isWhitespace }).first?.lowercased(),
              allowedTags.contains(tagName) else {
            return nil
        }

        if tagName == "br" {
            return "<br>"
        }

        let attributes = sanitizedAttributes(from: String(inner.dropFirst(tagName.count)))
        return attributes.isEmpty ? "<\(tagName)>" : "<\(tagName) \(attributes)>"
    }

    private static func sanitizedAttributes(from rawAttributes: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')"#,
            options: []
        ) else {
            return ""
        }

        let nsAttributes = rawAttributes as NSString
        var safeAttributes: [String] = []

        for match in regex.matches(in: rawAttributes, range: NSRange(location: 0, length: nsAttributes.length)) {
            let name = nsAttributes.substring(with: match.range(at: 1)).lowercased()
            let doubleQuotedRange = match.range(at: 3)
            let singleQuotedRange = match.range(at: 4)
            let value: String
            if doubleQuotedRange.location != NSNotFound {
                value = nsAttributes.substring(with: doubleQuotedRange)
            } else if singleQuotedRange.location != NSNotFound {
                value = nsAttributes.substring(with: singleQuotedRange)
            } else {
                continue
            }

            switch name {
            case "class":
                let classes = value
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                    .filter { allowedClasses.contains($0) }
                if !classes.isEmpty {
                    safeAttributes.append(#"class="\#(classes.joined(separator: " "))""#)
                }
            case "style":
                if isSafeInlineStyle(value) {
                    safeAttributes.append(#"style="\#(escapeAttribute(value))""#)
                }
            case "colspan", "rowspan":
                if let intValue = Int(value), (1...12).contains(intValue) {
                    safeAttributes.append(#"\#(name)="\#(intValue)""#)
                }
            default:
                continue
            }
        }

        return safeAttributes.joined(separator: " ")
    }

    private static func isSafeInlineStyle(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard !lowercased.contains("url("),
              !lowercased.contains("expression("),
              !lowercased.contains("@import"),
              !lowercased.contains("javascript:"),
              !lowercased.contains("<"),
              !lowercased.contains(">") else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 #.,:%;()_-+*/")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func remove(pattern: String, from text: String) -> String {
        replace(pattern: pattern, in: text, with: "")
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
