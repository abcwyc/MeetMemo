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

    init() {
        LocalStorageManager.shared.prepareMigrationsForLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(LanguageManager.shared)
                .preferredColorScheme(appearanceMgr.appearance == .light ? .light : .dark)
                .frame(minWidth: 500, minHeight: 400)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 600)
    }
}
