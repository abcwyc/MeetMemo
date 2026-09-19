import AppKit
import SwiftUI

struct DetailHeaderActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isConfirmed = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundColor(foregroundColor)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var foregroundColor: Color {
        if !isEnabled { return .secondary }
        if isConfirmed { return .green }
        return .primary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled { return Color.secondary.opacity(0.06) }
        if isConfirmed { return Color.green.opacity(isPressed ? 0.16 : 0.1) }
        if isSelected { return Color.secondary.opacity(isPressed ? 0.22 : 0.16) }
        return Color.secondary.opacity(isPressed ? 0.14 : 0.08)
    }
}

// MARK: - Transcript Chunk Row

struct TranscriptChunkRowView: View {
    @EnvironmentObject var langMgr: LanguageManager
    let chunk: TranscriptDisplayChunk

    var body: some View {
        transcriptRow
            .textSelection(.enabled)
    }

    private var transcriptRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: chunk.source.icon)
                    .font(.caption2)
                    .foregroundColor(chunk.source == .mic ? .blue : .orange)
            }
            .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displaySourceLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(chunk.source == .mic ? .blue : .orange)

                    if let speakerLabel = chunk.speakerLabel {
                        Text(speakerLabel)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }

                    if !chunk.isFinal {
                        transcriptStatusLabel(
                            langMgr.t("识别中", "Listening"),
                            foregroundColor: .blue,
                            backgroundColor: .blue.opacity(0.10)
                        )
                    } else if chunk.isLowConfidence {
                        transcriptStatusLabel(
                            langMgr.t("低置信", "Low confidence"),
                            foregroundColor: .orange,
                            backgroundColor: .orange.opacity(0.12)
                        )
                    }

                    Spacer(minLength: 8)

                    Text(chunk.timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Text(chunk.text)
                    .font(.body)
                    .foregroundColor(chunk.isLowConfidence ? .secondary : .primary)
                    .italic(chunk.isLowConfidence)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(chunk.isFinal ? (chunk.isLowConfidence ? 0.8 : 1.0) : 0.72)
            }
        }
        .padding(.vertical, 4)
        .opacity(chunk.isFinal ? 1.0 : 0.9)
    }

    private func transcriptStatusLabel(
        _ title: String,
        foregroundColor: Color,
        backgroundColor: Color
    ) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var displaySourceLabel: String {
        switch chunk.source {
        case .mic:
            return langMgr.t("麦克风", "mic")
        case .system:
            return langMgr.t("系统音频", "online")
        }
    }
}

struct ContextAttachmentChip: View {
    @EnvironmentObject var langMgr: LanguageManager
    let item: MeetingContextItem
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.icon)
                .foregroundStyle(.secondary)

            Text(item.displayTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(langMgr.t("移除附件", "Remove attachment"))
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
        .fixedSize()
    }
}

struct ContextAttachmentFlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        var contentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedRowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if proposedRowWidth > availableWidth, rowWidth > 0 {
                contentWidth = max(contentWidth, rowWidth)
                contentHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = proposedRowWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        contentWidth = max(contentWidth, rowWidth)
        contentHeight += rowHeight
        return CGSize(width: proposal.width ?? contentWidth, height: contentHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct BorderlessRoundedTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.drawsBackground = true
        textField.backgroundColor = .controlBackgroundColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }
    }
}

struct ClearInitialFocusView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

// MARK: - Shimmer Overlay
struct ShimmerOverlay: View {
    @State private var animate: Bool = false
    let color: Color

    init(color: Color = .green) {
        self.color = color
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, color.opacity(0.1), Color.clear]),
                        startPoint: UnitPoint(x: animate ? 2.5 : -1, y: 0.5),
                        endPoint: UnitPoint(x: animate ? 3.5 : 0, y: 0.5)
                    )
                )
                .frame(width: width, height: height)
                .onAppear {
                    animate = true
                }
                .animation(
                    Animation.linear(duration: 1.5).repeatForever(autoreverses: false),
                    value: animate
                )
        }
        .allowsHitTesting(false)
    }
}
