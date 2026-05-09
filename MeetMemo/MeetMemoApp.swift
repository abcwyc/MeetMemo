//
//  MeetMemoApp.swift
//  MeetMemo
//
//  Created for MeetMemo on 2025-07-10.
//

import SwiftUI

@main
struct MeetMemoApp: App {
    @StateObject private var appearanceMgr = AppearanceManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(LanguageManager.shared)
                .preferredColorScheme(colorScheme(for: appearanceMgr.appearance))
                .frame(minWidth: 700, minHeight: 400)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 600)
    }

    private func colorScheme(for appearance: AppAppearance) -> ColorScheme? {
        switch appearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
