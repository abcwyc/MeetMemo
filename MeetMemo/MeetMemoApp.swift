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
        private static let frameAutosaveName = "MeetMemo.MainWindow"

        private weak var configuredWindow: NSWindow?
        private var appearance: NSAppearance?

        func update(appearance: NSAppearance?, window: NSWindow?) {
            self.appearance = appearance
            attach(to: window)
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }

            if configuredWindow !== window {
                configuredWindow = window
                // AppKit persists every move and resize under this stable
                // name, then restores the saved frame when the next main
                // window is attached. It also constrains stale frames to the
                // current display after a monitor arrangement changes.
                window.setFrameAutosaveName(Self.frameAutosaveName)
            }

            window.appearance = appearance
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
