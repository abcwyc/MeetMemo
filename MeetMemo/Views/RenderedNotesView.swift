import Foundation
import SwiftUI

struct RenderedNotesView: View {
    let text: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(text)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    renderBlock(block)
                }
            }
            .padding()
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .blank:
            Spacer(minLength: 4)
        case .line(let line):
            renderLine(line)
        case .table(let table):
            MarkdownTableView(table: table)
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            EmptyView()
        } else if let level = headingLevel(for: trimmed) {
            let content = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
            Text(inlineMarkdown(content))
                .font(.system(size: headingSize(for: level), weight: headingWeight(for: level)))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 4 : 0)
        } else if let (indentLevel, bullet, content) = listItemInfo(for: line) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bullet)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inlineMarkdown(content))
                    .foregroundColor(.secondary)
            }
            .padding(.leading, CGFloat(indentLevel * 18))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(inlineMarkdown(trimmed))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingLevel(for line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var count = 0
        for char in line {
            if char == "#" {
                count += 1
            } else if char == " " {
                return min(count, 6)
            } else {
                return nil
            }
        }
        return nil
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 15
        default: return 14
        }
    }

    private func headingWeight(for level: Int) -> Font.Weight {
        switch level {
        case 1: return .semibold
        case 2: return .semibold
        default: return .medium
        }
    }

    private func listItemInfo(for line: String) -> (indentLevel: Int, bullet: String, content: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indentLevel = leadingSpaces / 4
        let remaining = String(line.dropFirst(leadingSpaces))

        if remaining.hasPrefix("- ") {
            return (indentLevel, getBullet(for: indentLevel), String(remaining.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else if remaining.hasPrefix("* ") {
            return (indentLevel, getBullet(for: indentLevel), String(remaining.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else if let dotIndex = remaining.firstIndex(of: "."),
                  let num = Int(remaining[remaining.startIndex..<dotIndex]),
                  remaining[dotIndex..<remaining.endIndex].hasPrefix(". ") {
            let contentStart = remaining.index(dotIndex, offsetBy: 2)
            return (indentLevel, "\(num).", String(remaining[contentStart...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func getBullet(for level: Int) -> String {
        switch level % 3 {
        case 0: return "•"
        case 1: return "◦"
        case 2: return "▪︎"
        default: return "-"
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    private var columnWidth: CGFloat {
        switch table.columnCount {
        case 0...3: return 220
        case 4: return 180
        default: return 150
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(table.headers, isHeader: true)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            )
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableRow(_ row: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                Text(inlineMarkdown(cellText(in: row, at: column)))
                    .font(isHeader ? .system(.body, weight: .semibold) : .body)
                    .foregroundColor(isHeader ? .primary : .secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(width: columnWidth, alignment: .topLeading)
                    .background(isHeader ? Color.secondary.opacity(0.08) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: column == table.columnCount - 1 ? 0 : 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(isHeader ? 0.24 : 0.14))
                .frame(height: 1)
        }
    }

    private func cellText(in row: [String], at index: Int) -> String {
        guard row.indices.contains(index) else { return "" }
        return row[index]
    }
}

private enum MarkdownBlock {
    case blank
    case line(String)
    case table(MarkdownTable)

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if let table = parseTable(startingAt: index, in: lines) {
                blocks.append(.table(table.value))
                index = table.nextIndex
                continue
            }

            let line = lines[index]
            blocks.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? .blank : .line(line))
            index += 1
        }

        return blocks
    }

    private static func parseTable(startingAt index: Int, in lines: [String]) -> (value: MarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count,
              isTableRow(lines[index]),
              isSeparatorRow(lines[index + 1]) else {
            return nil
        }

        var rows = [parseCells(lines[index])]
        var nextIndex = index + 2

        while nextIndex < lines.count, isTableRow(lines[nextIndex]), !isSeparatorRow(lines[nextIndex]) {
            rows.append(parseCells(lines[nextIndex]))
            nextIndex += 1
        }

        guard let headers = rows.first, !headers.isEmpty else { return nil }
        let columnCount = rows.map(\.count).max() ?? headers.count
        return (
            MarkdownTable(headers: headers, rows: Array(rows.dropFirst()), columnCount: columnCount),
            nextIndex
        )
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && parseCells(line).count >= 2
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let cells = parseCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseCells(_ line: String) -> [String] {
        var normalized = line.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("|") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("|") {
            normalized.removeLast()
        }

        return normalized
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

private struct MarkdownTable {
    let headers: [String]
    let rows: [[String]]
    let columnCount: Int
}

private func inlineMarkdown(_ source: String) -> AttributedString {
    if let attributed = try? AttributedString(
        markdown: source,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
        return attributed
    }

    return AttributedString(source)
}

#Preview {
    RenderedNotesView(text: """
    # Heading 1
    ## Heading 2
    - List item with **bold** text
        - Nested item
            - Deeper item
    1. Ordered
        1. Nested ordered

    | 问题描述 | 讨论结果 | 决策人 |
    | --- | --- | --- |
    | AI 知识库中保险条款回复失真，需要全面审查所有条目（约 140 条） | 客服人力不足，建议由业务负责判断逻辑合理性 | 发言人 A |
    | AI 咨询已紧急下线，导致客服压力增大 | 会议未明确恢复时间，决定明天给出责任归属结论后再推动后续动作 | 待确认 |

    Normal text with **strong emphasis**.
    """)
}
