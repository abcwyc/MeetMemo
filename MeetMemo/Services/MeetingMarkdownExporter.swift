import Foundation

struct MeetingMarkdownExporter {
    /// Generates a portable Markdown document while keeping the AI-generated notes unchanged.
    static func generateNotesMarkdown(for meeting: Meeting, exportDate: Date = Date()) -> String {
        let title = nonEmptyValue(meeting.title) ?? "会议纪要"
        var frontMatter = [
            "---",
            "title: \(yamlQuoted(title))",
            "date: \(yamlQuoted(iso8601String(from: meeting.date)))"
        ]

        if let location = nonEmptyValue(meeting.location) {
            frontMatter.append("location: \(yamlQuoted(location))")
        }
        if let host = nonEmptyValue(meeting.host) {
            frontMatter.append("host: \(yamlQuoted(host))")
        }
        if !meeting.speakerParticipantNames.isEmpty {
            frontMatter.append("attendees:")
            frontMatter.append(contentsOf: meeting.speakerParticipantNames.map { "  - \(yamlQuoted($0))" })
        }
        frontMatter.append("exported_at: \(yamlQuoted(iso8601String(from: exportDate)))")
        frontMatter.append("---")

        let notes = meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontMatter + ["", notes, ""]).joined(separator: "\n")
    }

    private static func nonEmptyValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
