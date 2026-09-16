import AppKit
import SwiftUI

/// TextKit 1 layout manager that hides markdown syntax markers (tagged via
/// `MarkdownEditorAttribute`) by substituting a real zero-width glyph for
/// their characters, unless the caret is on their line (`.lineCommand`) or
/// inside their inline span (`.commandSpan`). The backing text storage is
/// never touched here — this only changes what gets drawn, so undo, IME
/// composition, and text-selection-by-character all keep working against the
/// verbatim markdown source.
///
/// A *real* zero-width glyph (U+200B zero-width space, or one of its
/// siblings) is used instead of `NSGlyphProperty.null` on a notdef glyph:
/// a run of null-property glyphs at the start of a line gets split into its
/// own line fragment by AppKit's layout manager, which visibly changes line
/// height. A real, zero-advance glyph keeps the run intact.
final class MarkdownLiveLayoutManager: NSLayoutManager {
    /// The current caret/selection. The owning text view keeps this in sync
    /// with `NSTextView.selectedRange()` and invalidates the affected glyph
    /// ranges whenever it changes.
    var activeCharacterRange = NSRange(location: 0, length: 0)

    private static nonisolated(unsafe) var zeroGlyphCache: [String: CGGlyph] = [:]

    private static func zeroGlyph(for font: NSFont) -> CGGlyph {
        let key = font.fontName
        if let cached = zeroGlyphCache[key] { return cached }
        var glyph: CGGlyph = 0
        for scalar: UniChar in [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF] {
            var ch: [UniChar] = [scalar]
            var g = [CGGlyph](repeating: 0, count: 1)
            CTFontGetGlyphsForCharacters(font as CTFont, &ch, &g, 1)
            if g[0] != 0 {
                var adv = [CGSize](repeating: .zero, count: 1)
                CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, g, &adv, 1)
                if adv[0].width == 0 {
                    glyph = g[0]
                    break
                }
            }
        }
        if glyph == 0 {
            var sp: [UniChar] = [0x20]
            var spg = [CGGlyph](repeating: 0, count: 1)
            CTFontGetGlyphsForCharacters(font as CTFont, &sp, &spg, 1)
            glyph = spg[0]
        }
        zeroGlyphCache[key] = glyph
        return glyph
    }

    private func caretLineRange() -> NSRange {
        guard let storage = textStorage else { return NSRange(location: 0, length: 0) }
        let ns = storage.string as NSString
        let loc = min(max(activeCharacterRange.location, 0), ns.length)
        return ns.lineRange(for: NSRange(location: loc, length: 0))
    }

    private func isHidden(charIndex: Int, storage: NSTextStorage) -> Bool {
        guard charIndex >= 0, charIndex < storage.length else { return false }
        var effective = NSRange(location: 0, length: 0)
        let attrs = storage.attributes(at: charIndex, effectiveRange: &effective)
        guard attrs[MarkdownEditorAttribute.syntax] != nil else { return false }

        if attrs[MarkdownEditorAttribute.lineCommand] != nil {
            return !MarkdownLiveVisibility.isLineCommandVisible(charIndex: charIndex, caretLineRange: caretLineRange())
        }
        if let spanValue = attrs[MarkdownEditorAttribute.commandSpan] as? NSValue {
            return !MarkdownLiveVisibility.spanIsActive(spanValue.rangeValue, caret: activeCharacterRange)
        }
        return false
    }

    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        guard glyphRange.length > 0, let storage = textStorage else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            return
        }

        var hidden = [Bool](repeating: false, count: glyphRange.length)
        var anyHidden = false
        for i in 0..<glyphRange.length {
            if isHidden(charIndex: charIndexes[i], storage: storage) {
                hidden[i] = true
                anyHidden = true
            }
        }

        guard anyHidden else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            return
        }

        let zeroGlyph = Self.zeroGlyph(for: font)
        var newGlyphs = [CGGlyph](repeating: 0, count: glyphRange.length)
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for i in 0..<glyphRange.length {
            if hidden[i] {
                newGlyphs[i] = zeroGlyph
                newProps[i] = [] // real glyph, normal property — keeps the line fragment intact
            } else {
                newGlyphs[i] = glyphs[i]
                newProps[i] = props[i]
            }
        }
        newGlyphs.withUnsafeBufferPointer { gp in
            newProps.withUnsafeBufferPointer { pp in
                super.setGlyphs(gp.baseAddress!, properties: pp.baseAddress!, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            }
        }
    }

    /// Character ranges whose visibility can change when the caret moves to
    /// `selection`: the line(s) it touches, plus any inline command span
    /// adjacent to it. The caller invalidates glyphs/layout/display over the
    /// union of the old and new caret's affected ranges so hidden markers
    /// collapse/reappear immediately.
    func affectedRange(for selection: NSRange) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: 0, length: 0) }
        let ns = storage.string as NSString
        let loc = min(max(selection.location, 0), ns.length)
        let clamped = NSRange(location: loc, length: min(selection.length, ns.length - loc))
        var union = ns.lineRange(for: clamped)
        for idx in [clamped.location, clamped.location - 1, clamped.location + 1, NSMaxRange(clamped) - 1] {
            if let span = commandSpan(at: idx) { union = NSUnionRange(union, span) }
        }
        return union
    }

    private func commandSpan(at index: Int) -> NSRange? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        guard let value = storage.attribute(MarkdownEditorAttribute.commandSpan, at: index, effectiveRange: nil) as? NSValue else {
            return nil
        }
        return value.rangeValue
    }
}

/// A markdown editor that renders styled *and* stays directly editable in
/// place — there is no separate "preview mode": headings/emphasis/links are
/// shown styled, and their `#`/`**`/`` ` ``/`[]()` markers only appear while
/// the caret is on/inside them. Manually assembles the TextKit 1 stack
/// (NSTextStorage → MarkdownLiveLayoutManager → NSTextContainer → NSTextView)
/// so the custom layout manager is guaranteed to be used regardless of the
/// platform's TextKit-2-by-default `NSTextView()` initializer.
struct MarkdownLiveEditorView: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 110
    var fontSize: CGFloat = NSFont.systemFontSize

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textStorage = NSTextStorage()
        let layoutManager = MarkdownLiveLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        context.coordinator.textView = textView
        context.coordinator.layoutManager = layoutManager
        context.coordinator.applyStyledText(text, selection: nil)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.update(text: $text)
        textView.minSize = NSSize(width: 0, height: minHeight)

        // During IME composition, replacing the string from SwiftUI would
        // clear the marked (in-progress) text and lose the input — same
        // guard as the plain-text editor uses.
        guard !textView.hasMarkedText(), context.coordinator.lastAppliedText != text else { return }

        let selectedRanges = context.coordinator.clampedSelectedRanges(textView.selectedRanges, textLength: text.utf16.count)
        context.coordinator.applyStyledText(text, selection: selectedRanges)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, fontSize: fontSize)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private let fontSize: CGFloat
        weak var textView: NSTextView?
        weak var layoutManager: MarkdownLiveLayoutManager?
        private(set) var lastAppliedText: String?

        init(text: Binding<String>, fontSize: CGFloat) {
            self.text = text
            self.fontSize = fontSize
        }

        func update(text: Binding<String>) {
            self.text = text
        }

        /// Reparses+restyles `newText` and installs it into the text storage,
        /// preserving (clamped) selection. Called on load and whenever the
        /// binding changes from outside (not from this view's own typing —
        /// `textDidChange` below applies styling in place instead, to avoid
        /// fighting IME marked text on every keystroke).
        func applyStyledText(_ newText: String, selection: [NSValue]?) {
            guard let textView else { return }
            let attributed = MarkdownLiveStyler.attributedString(for: newText, configuration: .standard(baseFontSize: fontSize))
            textView.textStorage?.setAttributedString(attributed)
            lastAppliedText = newText
            if let selection {
                textView.selectedRanges = selection
            }
            syncActiveRange()
        }

        /// Reapplies styling attributes only (characters are identical) after
        /// a user edit — the storage reports `.editedAttributes`, so this does
        /// not recurse into `textDidChange`.
        private func restyleInPlace(_ currentText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let attributed = MarkdownLiveStyler.attributedString(for: currentText, configuration: .standard(baseFontSize: fontSize))
            storage.beginEditing()
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, range, _ in
                storage.setAttributes(attrs, range: range)
            }
            storage.endEditing()
            lastAppliedText = currentText
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !textView.hasMarkedText() else { return }
            let value = textView.string
            restyleInPlace(value)
            syncActiveRange()
            commit(value)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            commit(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let layoutManager else { return }
            let newSelection = textView.selectedRange()
            guard newSelection != layoutManager.activeCharacterRange else { return }
            let affected = NSUnionRange(
                layoutManager.affectedRange(for: layoutManager.activeCharacterRange),
                layoutManager.affectedRange(for: newSelection)
            )
            layoutManager.activeCharacterRange = newSelection
            layoutManager.invalidateGlyphs(forCharacterRange: affected, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: affected)
        }

        private func syncActiveRange() {
            guard let textView, let layoutManager else { return }
            layoutManager.activeCharacterRange = textView.selectedRange()
        }

        private func commit(_ value: String) {
            guard value != text.wrappedValue else { return }
            DispatchQueue.main.async {
                self.text.wrappedValue = value
            }
        }

        func clampedSelectedRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
            ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, textLength)
                let available = max(0, textLength - location)
                let length = min(range.length, available)
                return NSValue(range: NSRange(location: location, length: length))
            }
        }
    }
}
