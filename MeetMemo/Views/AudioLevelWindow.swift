import SwiftUI

// MARK: - Recording Track Meter
struct RecordingTrackMeter: View {
    let micLevel: Float
    let systemLevel: Float
    let showsSystemTrack: Bool

    private var isDualTrack: Bool {
        showsSystemTrack
    }

    var body: some View {
        HStack(spacing: 7.5) {
            ZStack(alignment: .bottomTrailing) {
                Image("Icon32")
                    .resizable()
                    .frame(width: 27, height: 27)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .red.opacity(0.5), radius: 4.5)
            }

            VStack(spacing: isDualTrack ? 1.5 : 4.5) {
                AudioTrackRow(
                    systemName: "mic.fill",
                    tint: .blue,
                    level: micLevel,
                    phase: 0,
                    isCompact: isDualTrack
                )

                if showsSystemTrack {
                    AudioTrackRow(
                        systemName: "speaker.wave.2.fill",
                        tint: .orange,
                        level: systemLevel,
                        phase: 3,
                        isCompact: isDualTrack
                    )
                }
            }
            .frame(width: 42, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7.5)
    }
}

private struct AudioTrackRow: View {
    let systemName: String
    let tint: Color
    let level: Float
    let phase: Int
    let isCompact: Bool

    private let barCount = 4

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: isCompact ? 10 : 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 12)

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(level > 0.015 ? 0.88 : 0.28))
                        .frame(width: 4.5, height: barHeight(at: index))
                        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.78), value: level)
                }
            }
            .frame(width: 27, height: isCompact ? 12.75 : 15)
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        let normalizedLevel = min(max(CGFloat(level), 0), 1)
        let baseHeight: CGFloat = isCompact ? 2.5 : 3
        let maxHeight: CGFloat = isCompact ? 12.75 : 15
        let shape = CGFloat(((index + phase) * 37) % 11) / 10
        let emphasis = 0.42 + shape * 0.58
        return baseHeight + (maxHeight - baseHeight) * normalizedLevel * emphasis
    }
}

// MARK: - Audio Level Window View
struct AudioLevelWindowView: View {
    @StateObject private var audioLevelManager = AudioLevelManager.shared
    
    var body: some View {
        let micLevel = audioLevelManager.isRecording ? audioLevelManager.micAudioLevel * 36 : 0
        let systemLevel = audioLevelManager.isRecording ? audioLevelManager.systemAudioLevel * 10 : 0
        return RecordingTrackMeter(
            micLevel: micLevel,
            systemLevel: systemLevel,
            showsSystemTrack: UserDefaultsManager.shared.enableSystemAudioSTT
        )
        .background(.regularMaterial.opacity(0.94), in: Capsule(style: .continuous))
        .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Audio Level Manager (Singleton to share data)
class AudioLevelManager: ObservableObject {
    static let shared = AudioLevelManager()
    
    @Published var micAudioLevel: Float = 0.0
    @Published var systemAudioLevel: Float = 0.0
    @Published var isRecording: Bool = false
    
    private init() {}
    
    func updateMicLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.micAudioLevel = level
        }
    }
    
    func updateSystemLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.systemAudioLevel = level
        }
    }
    
    func updateRecordingState(_ isRecording: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            if isRecording {
                // Auto-show the window when recording starts
                AudioLevelWindowManager.shared.showWindow()
            } else {
                // Auto-hide the window when recording stops
                AudioLevelWindowManager.shared.hideWindow()
            }
        }
    }
}

// MARK: - Audio Level Window Manager using NSPanel
@MainActor
class AudioLevelWindowManager: ObservableObject {
    static let shared = AudioLevelWindowManager()
    
    private var audioLevelPanel: NSPanel?
    
    private init() {
        setupPanel()
    }
    
    private func setupPanel() {
        let panelRect = NSRect(x: 0, y: 0, width: 99, height: 63)
        
        audioLevelPanel = NSPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        
        guard let panel = audioLevelPanel else { return }
        
        panel.level = .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.identifier = NSUserInterfaceItemIdentifier("audio-levels")
        
        let hostingView = NSHostingView(rootView: AudioLevelWindowView())
        hostingView.frame = panelRect
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = NSRect(
                x: screenFrame.maxX - panelRect.width - 20,
                y: screenFrame.maxY - panelRect.height - 20,
                width: panelRect.width,
                height: panelRect.height
            )
            panel.setFrame(panelFrame, display: false)
        }
    }
    
    func showWindow() {
        guard let panel = audioLevelPanel else {
            setupPanel()
            showWindow()
            return
        }
        
        panel.orderFrontRegardless()
    }
    
    func hideWindow() {
        audioLevelPanel?.orderOut(nil)
    }
}
