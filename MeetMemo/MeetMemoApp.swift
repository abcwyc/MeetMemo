//
//  MeetMemoApp.swift
//  MeetMemo
//
//  Created for MeetMemo on 2025-07-10.
//

import SwiftUI
import PostHog

@main
struct MeetMemoApp: App {
    @StateObject private var appearanceMgr = AppearanceManager.shared

    init() {
        // Setup PostHog analytics for anonymous tracking
        let posthogAPIKey = "phc_Wt8sWUzUF7YPF50aQ0B1qbfA5SJWWR341zmXCaIaIRJ"
        let posthogHost = "https://us.i.posthog.com"
        let config = PostHogConfig(apiKey: posthogAPIKey, host: posthogHost)
        // Only capture anonymous events
        config.personProfiles = .never
        // Enable lifecycle and screen view autocapture
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = true
        PostHogSDK.shared.setup(config)
        // Register environment as a super property
        #if DEBUG
        PostHogSDK.shared.register(["environment": "dev"] )
        #else
        PostHogSDK.shared.register(["environment": "prod"] )
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(LanguageManager.shared)
                .preferredColorScheme(appearanceMgr.appearance == .light ? .light : .dark)
                .frame(minWidth: 700, minHeight: 400)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 600)
    }
}
