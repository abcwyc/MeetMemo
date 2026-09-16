import Foundation

/// Serializes an edited table grid back into minimal, valid GFM pipe-table
/// markdown. Used when a table cell is edited via the live-preview table
/// overlay (`MarkdownLiveTableOverlayView`), to replace the table block's
/// raw source range in the editor.
///
/// Known limitation: does not escape literal "|" characters within cell
/// text, matching `MarkdownDocumentModel`'s cell parser (`parseCells`),
/// which also does not un-escape them — a cell containing a literal pipe
/// will not round-trip cleanly. Rare in meeting-notes content; a shared
/// escaping scheme for both sides is a natural follow-up if it comes up.
enum MarkdownTableSerializer {
    static func serialize(headers: [String], rows: [[String]]) -> String {
        let columnCount = max(headers.count, 1)
        let headerLine = rowLine(headers, columnCount: columnCount)
        let separatorLine = rowLine(Array(repeating: "---", count: columnCount), columnCount: columnCount)
        let dataLines = rows.map { rowLine($0, columnCount: columnCount) }
        return ([headerLine, separatorLine] + dataLines).joined(separator: "\n")
    }

    /// Pads/truncates `cells` to exactly `columnCount` entries so every
    /// row of a re-serialized table has a consistent column count, even if
    /// the in-memory grid drifted (e.g. a header edit added a column that a
    /// data row hasn't caught up to yet).
    private static func rowLine(_ cells: [String], columnCount: Int) -> String {
        var normalized = cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if normalized.count < columnCount {
            normalized.append(contentsOf: Array(repeating: "", count: columnCount - normalized.count))
        } else if normalized.count > columnCount {
            normalized = Array(normalized.prefix(columnCount))
        }
        return "| " + normalized.joined(separator: " | ") + " |"
    }
}
