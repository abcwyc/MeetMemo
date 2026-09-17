import AppKit
import Foundation
import SwiftUI

/// Read-only markdown renderer backed by a single `NSTextView`.
///
/// Everything (headings, lists, paragraphs and tables) lives in one text storage,
/// so the whole document can be drag-selected and copied in one go — which a stack
/// of SwiftUI `Text` views cannot do.
struct RenderedNotesView: View {
    let text: String
    /// `true` hosts the text view in its own scroll view and fills the available space.
    /// `false` sizes the view to its content, for embedding inside an outer `ScrollView`.
    var isScrollable: Bool = true
    @ObservedObject private var markdownThemeManager = MarkdownThemeManager.shared

    var body: some View {
        MarkdownTextView(
            text: text,
            isScrollable: isScrollable,
            theme: markdownThemeManager.theme
        )
            .frame(maxWidth: .infinity, maxHeight: isScrollable ? .infinity : nil)
    }
}

// MARK: - NSTextView host

private struct MarkdownTextView: NSViewRepresentable {
    let text: String
    let isScrollable: Bool
    let theme: MarkdownTheme

    private static let contentInset = NSSize(
        width: MeetingNotesTypography.contentInset,
        height: MeetingNotesTypography.contentInset
    )

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        // Built by hand so the view uses TextKit 1, which is what NSTextTable needs.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = Self.contentInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        context.coordinator.textStorage = textStorage
        context.coordinator.layoutManager = layoutManager
        context.coordinator.textContainer = textContainer
        context.coordinator.textView = textView
        context.coordinator.apply(text: text, theme: theme)

        guard isScrollable else { return textView }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.apply(text: text, theme: theme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // Only the embedded (non-scrolling) variant needs to report its content height.
        guard !isScrollable else { return nil }
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.contentHeight(forWidth: width))
    }

    final class Coordinator {
        var textStorage: NSTextStorage?
        var layoutManager: NSLayoutManager?
        var textContainer: NSTextContainer?
        weak var textView: NSTextView?
        private var renderedText: String?
        private var renderedTheme: MarkdownTheme?

        /// Rebuilds the attributed content only when the markdown actually changed,
        /// so an unrelated SwiftUI update never clears the user's selection.
        func apply(text: String, theme: MarkdownTheme) {
            guard renderedText != text || renderedTheme != theme else { return }
            renderedText = text
            renderedTheme = theme
            textStorage?.setAttributedString(MarkdownAttributedStringBuilder.make(from: text, theme: theme))
        }

        func contentHeight(forWidth width: CGFloat) -> CGFloat {
            guard let layoutManager, let textContainer, let textView else { return 0 }

            let inset = textView.textContainerInset
            let contentWidth = max(1, width - inset.width * 2)
            if textContainer.size.width != contentWidth {
                textContainer.size = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: textContainer)
            return layoutManager.usedRect(for: textContainer).height + inset.height * 2
        }
    }
}

// MARK: - Markdown → NSAttributedString

private enum MarkdownAttributedStringBuilder {
    static let bodyFontSize = MeetingNotesTypography.bodyFontSize

    static func make(from text: String, theme: MarkdownTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for block in MarkdownBlock.parse(text) {
            switch block {
            case .blank:
                result.append(blankLine())
            case .line(let line):
                result.append(attributedLine(line, theme: theme))
            case .table(let table):
                result.append(attributedTable(table, theme: theme))
            }
        }

        return result
    }

    private static func blankLine() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)])
    }

    private static func attributedLine(_ line: String, theme: MarkdownTheme) -> NSAttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let level = headingLevel(for: trimmed) {
            let content = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = level == 1 ? 18 : (level == 2 ? 16 : 10)
            paragraph.paragraphSpacing = level <= 2 ? 7 : 5
            paragraph.lineHeightMultiple = 1.0
            paragraph.alignment = headingAlignment(for: theme)

            return paragraphString(
                inline: content,
                font: noteFont(ofSize: headingSize(for: level, theme: theme), weight: headingWeight(for: level, theme: theme), theme: theme),
                color: headingColor(for: theme),
                paragraph: paragraph,
                theme: theme
            )
        }

        // Compatibility with notes generated before heading syntax was
        // enforced: those templates emitted `**Section title**` on a line by
        // itself. Render them as headings without mutating persisted Markdown.
        if let content = standaloneBoldContent(in: trimmed) {
            let level = content == "会议纪要" || content == "Meeting Notes" ? 1 : 2
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = level == 1 ? 18 : 16
            paragraph.paragraphSpacing = 7
            paragraph.lineHeightMultiple = 1.0
            paragraph.alignment = headingAlignment(for: theme)
            return paragraphString(
                inline: content,
                font: noteFont(ofSize: headingSize(for: level, theme: theme), weight: headingWeight(for: level, theme: theme), theme: theme),
                color: headingColor(for: theme),
                paragraph: paragraph,
                theme: theme
            )
        }

        if let (indentLevel, bullet, content) = listItemInfo(for: line) {
            let firstLineIndent = CGFloat(indentLevel) * 18
            let hangingIndent = firstLineIndent + 20

            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = firstLineIndent
            paragraph.headIndent = hangingIndent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: hangingIndent)]
            paragraph.paragraphSpacing = 5
            paragraph.lineHeightMultiple = bodyLineHeight(for: theme)

            let font = noteFont(ofSize: bodyFontSize, theme: theme)
            let result = NSMutableAttributedString(
                string: "\(bullet)\t",
                attributes: [.font: font, .foregroundColor: bulletColor(for: theme)]
            )
            result.append(inlineAttributed(content, font: font, color: .labelColor, theme: theme))
            result.append(NSAttributedString(string: "\n"))
            result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
            return result
        }

        guard !trimmed.isEmpty else { return blankLine() }

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        paragraph.lineHeightMultiple = bodyLineHeight(for: theme)
        if theme == .typora {
            paragraph.alignment = .justified
        }

        return paragraphString(
            inline: trimmed,
            font: noteFont(ofSize: bodyFontSize, theme: theme),
            color: .labelColor,
            paragraph: paragraph,
            theme: theme
        )
    }

    private static func paragraphString(
        inline: String,
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle,
        theme: MarkdownTheme
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: inlineAttributed(inline, font: font, color: color, theme: theme))
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Tables

    private static func attributedTable(_ table: MarkdownTable, theme: MarkdownTheme) -> NSAttributedString {
        let textTable = NSTextTable()
        textTable.numberOfColumns = table.columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        // Columns share the width evenly so a wide table wraps instead of overflowing.
        let columnWidth = 100.0 / CGFloat(max(1, table.columnCount))

        let result = NSMutableAttributedString()
        result.append(
            tableRow(
                table.headers,
                rowIndex: 0,
                isHeader: true,
                table: textTable,
                columnCount: table.columnCount,
                columnWidth: columnWidth,
                theme: theme
            )
        )
        for (index, row) in table.rows.enumerated() {
            result.append(
                tableRow(
                    row,
                    rowIndex: index + 1,
                    isHeader: false,
                    table: textTable,
                    columnCount: table.columnCount,
                    columnWidth: columnWidth,
                    theme: theme
                )
            )
        }
        result.append(blankLine())
        return result
    }

    private static func tableRow(
        _ row: [String],
        rowIndex: Int,
        isHeader: Bool,
        table: NSTextTable,
        columnCount: Int,
        columnWidth: CGFloat,
        theme: MarkdownTheme
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for column in 0..<columnCount {
            let block = NSTextTableBlock(
                table: table,
                startingRow: rowIndex,
                rowSpan: 1,
                startingColumn: column,
                columnSpan: 1
            )
            block.setValue(columnWidth, type: .percentageValueType, for: .width)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setWidth(7, type: .absoluteValueType, for: .padding)
            block.setBorderColor(NSColor.separatorColor)
            if isHeader {
                block.backgroundColor = tableHeaderColor(for: theme)
            } else if !rowIndex.isMultiple(of: 2) {
                block.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.035)
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]

            let font: NSFont = isHeader
                ? noteFont(ofSize: bodyFontSize, weight: .semibold, theme: theme)
                : noteFont(ofSize: bodyFontSize, theme: theme)
            let cell = NSMutableAttributedString(
                attributedString: inlineAttributed(
                    cellText(in: row, at: column),
                    font: font,
                    color: .labelColor,
                    theme: theme
                )
            )
            cell.append(NSAttributedString(string: "\n"))
            cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
            result.append(cell)
        }

        return result
    }

    private static func cellText(in row: [String], at index: Int) -> String {
        guard row.indices.contains(index) else { return "" }
        return row[index]
    }

    // MARK: Inline markdown

    private static func inlineAttributed(
        _ source: String,
        font: NSFont,
        color: NSColor,
        theme: MarkdownTheme
    ) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: color])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    runFont = runFont.withTraits(.bold)
                }
                if intent.contains(.emphasized) {
                    runFont = runFont.withTraits(.italic)
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if intent.contains(.code) {
                    runFont = codeFont(ofSize: runFont.pointSize - 0.5, theme: theme)
                    attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
                }
            }

            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = accentColor(for: theme)
            }

            attributes[.font] = runFont
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }

        return result
    }

    // MARK: Line classification (same markdown rules as before)

    private static func headingLevel(for line: String) -> Int? {
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

    private static func standaloneBoldContent(in line: String) -> String? {
        guard line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") else { return nil }
        let content = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, !content.contains("**") else { return nil }
        return content
    }

    private static func headingSize(for level: Int, theme: MarkdownTheme) -> CGFloat {
        MeetingNotesTypography.headingSize(for: level, theme: theme)
    }

    private static func headingWeight(for level: Int, theme: MarkdownTheme) -> NSFont.Weight {
        MeetingNotesTypography.headingWeight(for: level, theme: theme)
    }

    private static func noteFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight = .regular,
        theme: MarkdownTheme
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign?
        switch theme {
        case .bear: design = .rounded
        case .typora: design = .serif
        case .meetMemo, .github, .sspai: design = nil
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func headingColor(for theme: MarkdownTheme) -> NSColor {
        .labelColor
    }

    private static func headingAlignment(for theme: MarkdownTheme) -> NSTextAlignment {
        theme == .typora ? .center : .left
    }

    private static func bodyLineHeight(for theme: MarkdownTheme) -> CGFloat {
        switch theme {
        case .meetMemo: return 1.55
        case .github, .bear: return 1.5
        case .typora: return 1.53
        case .sspai: return 1.8
        }
    }

    private static func codeFont(ofSize size: CGFloat, theme: MarkdownTheme) -> NSFont {
        switch theme {
        case .bear:
            return NSFont(name: "RobotoMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sspai:
            return NSFont(name: "Courier", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .meetMemo, .github, .typora:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private static func bulletColor(for theme: MarkdownTheme) -> NSColor {
        switch theme {
        case .meetMemo, .bear, .sspai: return accentColor(for: theme)
        case .github, .typora: return .secondaryLabelColor
        }
    }

    private static func tableHeaderColor(for theme: MarkdownTheme) -> NSColor {
        switch theme {
        case .bear, .sspai:
            return accentColor(for: theme).withAlphaComponent(0.09)
        case .meetMemo, .typora:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        case .github:
            return .clear
        }
    }

    private static func accentColor(for theme: MarkdownTheme) -> NSColor {
        switch theme {
        case .meetMemo: return .controlAccentColor
        case .github: return .linkColor
        case .bear: return NSColor(srgbRed: 0.85, green: 0.27, blue: 0.29, alpha: 1)
        case .typora: return NSColor(srgbRed: 0.25, green: 0.51, blue: 0.77, alpha: 1)
        case .sspai: return NSColor(srgbRed: 0.95, green: 0.18, blue: 0.15, alpha: 1)
        }
    }

    private static func listItemInfo(for line: String) -> (indentLevel: Int, bullet: String, content: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indentLevel = leadingSpaces / 4
        let remaining = String(line.dropFirst(leadingSpaces))

        if remaining.hasPrefix("- ") || remaining.hasPrefix("* ") {
            return (
                indentLevel,
                bullet(for: indentLevel),
                String(remaining.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            )
        }

        if let dotIndex = remaining.firstIndex(of: "."),
           let num = Int(remaining[remaining.startIndex..<dotIndex]),
           remaining[dotIndex..<remaining.endIndex].hasPrefix(". ") {
            let contentStart = remaining.index(dotIndex, offsetBy: 2)
            return (indentLevel, "\(num).", String(remaining[contentStart...]).trimmingCharacters(in: .whitespaces))
        }

        return nil
    }

    private static func bullet(for level: Int) -> String {
        switch level % 3 {
        case 0: return "•"
        case 1: return "◦"
        case 2: return "▪︎"
        default: return "-"
        }
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Markdown parsing

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
