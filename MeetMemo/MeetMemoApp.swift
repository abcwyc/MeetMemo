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

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let nsAppearance = NSAppearance(named: appearance.nsAppearanceName)
        NSApplication.shared.appearance = nsAppearance

        DispatchQueue.main.async {
            nsView.window?.appearance = nsAppearance
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(
            named: UserDefaultsManager.shared.appAppearance.nsAppearanceName
        )
    }
}
