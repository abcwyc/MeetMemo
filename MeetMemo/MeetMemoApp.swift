//
//  MeetMemoApp.swift
//  MeetMemo
//
//  Created for MeetMemo on 2025-07-10.
//

import AppKit
import SwiftUI

@main
struct MeetMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appearanceMgr = AppearanceManager.shared

    init() {
        LocalStorageManager.shared.prepareMigrationsForLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(LanguageManager.shared)
                .preferredColorScheme(appearanceMgr.appearance == .light ? .light : .dark)
                .frame(minWidth: 500, minHeight: 400)
                .background(MainWindowAppearanceSync(appearance: appearanceMgr.appearance))
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 600)
    }
}

private struct MainWindowAppearanceSync: NSViewRepresentable {
    let appearance: AppAppearance

    func makeNSView(context: Context) -> MainWindowAttachmentView {
        let view = MainWindowAttachmentView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: MainWindowAttachmentView, context: Context) {
        let nsAppearance = NSAppearance(named: appearance.nsAppearanceName)
        NSApplication.shared.appearance = nsAppearance
        context.coordinator.update(appearance: nsAppearance, window: nsView.window)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var appearance: NSAppearance?
        private var resizeObserver: NSObjectProtocol?

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        func update(appearance: NSAppearance?, window: NSWindow?) {
            self.appearance = appearance
            attach(to: window)
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }

            if configuredWindow !== window {
                if let resizeObserver {
                    NotificationCenter.default.removeObserver(resizeObserver)
                    self.resizeObserver = nil
                }
                configuredWindow = window

                // SwiftUI applies `.defaultSize` after AppKit's native frame
                // restoration, so `setFrameAutosaveName` is overwritten on a
                // cold launch. Restore once SwiftUI's initial window layout
                // has settled, then observe subsequent user resizes.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.configuredWindow === window else { return }
                    MainWindowSizePersistence.restore(window)
                    self.observeResizes(of: window)
                }
            }

            window.appearance = appearance
        }

        private func observeResizes(of window: NSWindow) {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainWindowSizePersistence.save(window)
            }
        }
    }
}

/// SwiftUI can call `updateNSView` before the representable has joined an
/// `NSWindow`. This attachment callback makes window restoration reliable on
/// a cold launch instead of depending on an arbitrary dispatch delay.
private final class MainWindowAttachmentView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private enum MainWindowSizePersistence {
    private static let widthKey = "mainWindowSize.width"
    private static let heightKey = "mainWindowSize.height"
    private static let minimumSize = NSSize(width: 500, height: 400)

    static func save(_ window: NSWindow) {
        // Full-screen is a presentation mode, not the user's normal window
        // size. Zoomed windows are intentionally saved because they are still
        // ordinary resizable windows.
        guard !window.styleMask.contains(.fullScreen) else { return }

        let size = window.frame.size
        guard size.width >= minimumSize.width, size.height >= minimumSize.height else { return }
        UserDefaults.standard.set(size.width, forKey: widthKey)
        UserDefaults.standard.set(size.height, forKey: heightKey)
    }

    static func restore(_ window: NSWindow) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: widthKey) != nil,
              defaults.object(forKey: heightKey) != nil else { return }

        let screen = window.screen ?? NSScreen.main
        let availableSize = screen?.visibleFrame.size ?? window.frame.size
        let savedSize = NSSize(
            width: defaults.double(forKey: widthKey),
            height: defaults.double(forKey: heightKey)
        )
        let restoredSize = NSSize(
            width: min(max(savedSize.width, minimumSize.width), availableSize.width),
            height: min(max(savedSize.height, minimumSize.height), availableSize.height)
        )

        var restoredFrame = window.frame
        let center = NSPoint(x: restoredFrame.midX, y: restoredFrame.midY)
        restoredFrame.size = restoredSize
        restoredFrame.origin = NSPoint(
            x: center.x - restoredSize.width / 2,
            y: center.y - restoredSize.height / 2
        )
        if let screen {
            restoredFrame = window.constrainFrameRect(restoredFrame, to: screen)
        }
        window.setFrame(restoredFrame, display: false)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(
            named: UserDefaultsManager.shared.appAppearance.nsAppearanceName
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaultsManager.shared.voiceInputEnabled {
            VoiceInputHotkeyManager.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VoiceInputHotkeyManager.shared.stop()
    }
}
