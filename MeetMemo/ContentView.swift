//
//  ContentView.swift
//  MeetMemo
//
//  Created for MeetMemo on 2025-07-10.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var settingsViewModel = SettingsViewModel()
    @State private var showingSettings = false
    
    var body: some View {
        Group {
            if !settingsViewModel.settings.hasCompletedOnboarding {
                OnboardingView(settingsViewModel: settingsViewModel)
            } else {
                MeetingListView(settingsViewModel: settingsViewModel)
            }
        }
    }
}

#Preview {
    ContentView()
}
