import SwiftUI

enum VoiceInputFloatingState: Equatable {
    case hidden
    case listening
    case transcribing
    case failed
}

struct VoiceInputFloatingWindowView: View {
    @ObservedObject var manager: VoiceInputFloatingWindowManager

    var body: some View {
        VoiceInputCapsule(
            state: manager.state,
            level: manager.audioLevel,
            message: manager.message
        )
        .background(.regularMaterial.opacity(0.94), in: Capsule(style: .continuous))
        .clipShape(Capsule(style: .continuous))
    }
}

private struct VoiceInputCapsule: View {
    let state: VoiceInputFloatingState
    let level: Float
    let message: String?

    private var showsMessage: Bool {
        state == .failed && !(message ?? "").isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 17, height: 17)

            if showsMessage {
                Text(message ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .leading)
            } else if state == .listening {
                VoiceWaveMeter(level: level, tint: tint)
            } else if state == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 16)
            } else {
                VoiceWaveMeter(level: 0, tint: tint)
                    .opacity(0.45)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var iconName: String {
        switch state {
        case .hidden, .listening:
            return "mic.fill"
        case .transcribing:
            return "waveform"
        case .failed:
            return "exclamationmark"
        }
    }

    private var tint: Color {
        switch state {
        case .failed:
            return .red
        default:
            return .accentColor
        }
    }
}

private struct VoiceWaveMeter: View {
    let level: Float
    let tint: Color

    private let barCount = 6

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.opacity(level > 0.012 ? 0.88 : 0.30))
                    .frame(width: 3.5, height: barHeight(at: index))
                    .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.76), value: level)
            }
        }
        .frame(width: 40, height: 16)
    }

    private func barHeight(at index: Int) -> CGFloat {
        let normalizedLevel = min(max(CGFloat(level) * 18, 0), 1)
        let baseHeight: CGFloat = 3
        let maxHeight: CGFloat = 16
        let shape = CGFloat(((index + 2) * 31) % 13) / 12
        let emphasis = 0.35 + shape * 0.65
        return baseHeight + (maxHeight - baseHeight) * normalizedLevel * emphasis
    }
}

@MainActor
final class VoiceInputFloatingWindowManager: ObservableObject {
    static let shared = VoiceInputFloatingWindowManager()

    @Published var state: VoiceInputFloatingState = .hidden
    @Published var audioLevel: Float = 0
    @Published var message: String?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {
        setupPanel()
    }

    func showListening() {
        hideTask?.cancel()
        message = nil
        state = .listening
        showWindow()
    }

    func showTranscribing() {
        hideTask?.cancel()
        audioLevel = 0
        message = nil
        state = .transcribing
        showWindow()
    }

    func showFailedAndHide(message: String? = nil) {
        // 有具体错误时停留更久，便于用户阅读。
        showTerminalState(.failed, duration: message == nil ? 1.8 : 4.0, message: message)
    }

    func updateAudioLevel(_ level: Float) {
        audioLevel = level
    }

    func hideWindow() {
        state = .hidden
        message = nil
        panel?.orderOut(nil)
    }

    private func showTerminalState(_ terminalState: VoiceInputFloatingState, duration: TimeInterval, message: String? = nil) {
        hideTask?.cancel()
        audioLevel = 0
        self.message = message
        state = terminalState
        showWindow()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.hideWindow()
        }
    }

    private func setupPanel() {
        let panelRect = NSRect(x: 0, y: 0, width: 96, height: 36)

        panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )

        guard let panel else { return }
        panel.level = .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.identifier = NSUserInterfaceItemIdentifier("voice-input")

        let hostingView = NSHostingView(rootView: VoiceInputFloatingWindowView(manager: self))
        hostingView.frame = panelRect
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor

        positionPanel(panel, size: panelRect.size)
    }

    private func showWindow() {
        guard let panel else {
            setupPanel()
            showWindow()
            return
        }
        // 根据内容自适应尺寸：失败态展示错误文案时需要更宽/更高，固定尺寸会裁切。
        var size = NSSize(width: 96, height: 36)
        if let hostingView = panel.contentView {
            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                size = NSSize(width: max(96, ceil(fitting.width)), height: max(36, ceil(fitting.height)))
            }
        }
        positionPanel(panel, size: size)
        panel.orderFrontRegardless()
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = NSRect(
            x: screenFrame.maxX - size.width - 20,
            y: screenFrame.maxY - size.height - 20,
            width: size.width,
            height: size.height
        )
        panel.setFrame(panelFrame, display: false)
    }
}
