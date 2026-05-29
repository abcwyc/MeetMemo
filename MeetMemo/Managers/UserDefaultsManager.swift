// UserDefaultsManager.swift
// Manages non-sensitive app settings using UserDefaults

import Foundation

enum NotesOutputFormat: String, CaseIterable {
    case markdown = "markdown"
    case structured = "structured"
}

/// Manages non-sensitive app settings using UserDefaults
class UserDefaultsManager {
    static let shared = UserDefaultsManager()
    
    private let userDefaults = UserDefaults.standard
    
    private init() {}
    
    // MARK: - Keys
    private enum Keys {
        static let userBlurb = "userBlurb"
        static let systemPrompt = "systemPrompt"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasAcceptedTerms = "hasAcceptedTerms"
        static let selectedTemplateId = "selectedTemplateId"
        static let hasMigratedToV2Providers = "hasMigratedToV2Providers"
        static let appLanguage = "appLanguage"
        static let appAppearance = "appAppearance"
        static let speakerParticipantNames = "speakerParticipantNames"
        static let notesOutputFormat = "notesOutputFormat"
        static let sttLocaleIdentifier = "sttLocaleIdentifier"
        static let enableSystemAudioSTT = "enableSystemAudioSTT"
    }
    
    // MARK: - User Blurb
    var userBlurb: String {
        get { userDefaults.string(forKey: Keys.userBlurb) ?? "" }
        set { userDefaults.set(newValue, forKey: Keys.userBlurb) }
    }
    
    // MARK: - System Prompt
    var systemPrompt: String {
        get {
            let stored = userDefaults.string(forKey: Keys.systemPrompt)
            guard let stored, !stored.isEmpty else {
                return Settings.defaultSystemPrompt()
            }

            if Self.looksLikeHistoricalDefaultSystemPrompt(stored) {
                let updated = Settings.defaultSystemPrompt()
                userDefaults.set(updated, forKey: Keys.systemPrompt)
                return updated
            }

            return stored
        }
        set { userDefaults.set(newValue, forKey: Keys.systemPrompt) }
    }

    private static func looksLikeHistoricalDefaultSystemPrompt(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return normalized.contains("Your job is to generate enhanced meeting notes")
            && normalized.contains("<user_notes>")
            && !normalized.contains("<meeting_context>")
    }
    
    // MARK: - Onboarding Status
    var hasCompletedOnboarding: Bool {
        get { userDefaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { userDefaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }
    
    // MARK: - Terms Acceptance
    var hasAcceptedTerms: Bool {
        get { userDefaults.bool(forKey: Keys.hasAcceptedTerms) }
        set { userDefaults.set(newValue, forKey: Keys.hasAcceptedTerms) }
    }
    
    // MARK: - Selected Template ID
    var selectedTemplateId: UUID? {
        get { 
            guard let uuidString = userDefaults.string(forKey: Keys.selectedTemplateId) else { return nil }
            return UUID(uuidString: uuidString)
        }
        set { 
            if let uuid = newValue {
                userDefaults.set(uuid.uuidString, forKey: Keys.selectedTemplateId)
            } else {
                userDefaults.removeObject(forKey: Keys.selectedTemplateId)
            }
        }
    }

    // MARK: - Provider Migration Flag
    var hasMigratedToV2Providers: Bool {
        get { userDefaults.bool(forKey: Keys.hasMigratedToV2Providers) }
        set { userDefaults.set(newValue, forKey: Keys.hasMigratedToV2Providers) }
    }

    // MARK: - App Language
    var appLanguage: AppLanguage {
        get {
            let raw = userDefaults.string(forKey: Keys.appLanguage) ?? AppLanguage.chinese.rawValue
            return AppLanguage(rawValue: raw) ?? .chinese
        }
        set { userDefaults.set(newValue.rawValue, forKey: Keys.appLanguage) }
    }

    // MARK: - App Appearance
    var appAppearance: AppAppearance {
        get {
            let raw = userDefaults.string(forKey: Keys.appAppearance) ?? AppAppearance.light.rawValue
            return AppAppearance(rawValue: raw) ?? .light
        }
        set { userDefaults.set(newValue.rawValue, forKey: Keys.appAppearance) }
    }

    // MARK: - Speaker Participants
    var speakerParticipantNames: [String] {
        get {
            normalizedNames(userDefaults.stringArray(forKey: Keys.speakerParticipantNames) ?? [])
        }
        set {
            userDefaults.set(normalizedNames(newValue), forKey: Keys.speakerParticipantNames)
        }
    }

    func mergeSpeakerParticipantNames(_ names: [String]) {
        speakerParticipantNames = speakerParticipantNames + names
    }

    // MARK: - Notes Output Format
    var notesOutputFormat: NotesOutputFormat {
        get {
            let raw = userDefaults.string(forKey: Keys.notesOutputFormat) ?? NotesOutputFormat.markdown.rawValue
            return NotesOutputFormat(rawValue: raw) ?? .markdown
        }
        set { userDefaults.set(newValue.rawValue, forKey: Keys.notesOutputFormat) }
    }

    // MARK: - STT Locale
    var sttLocaleIdentifier: String {
        get { userDefaults.string(forKey: Keys.sttLocaleIdentifier) ?? "zh-CN" }
        set { userDefaults.set(newValue, forKey: Keys.sttLocaleIdentifier) }
    }

    // MARK: - Dual STT (mic + system audio)
    var enableSystemAudioSTT: Bool {
        get {
            if userDefaults.object(forKey: Keys.enableSystemAudioSTT) == nil { return true }
            return userDefaults.bool(forKey: Keys.enableSystemAudioSTT)
        }
        set { userDefaults.set(newValue, forKey: Keys.enableSystemAudioSTT) }
    }

    private func normalizedNames(_ names: [String]) -> [String] {
        var seenNames = Set<String>()
        var result: [String] = []

        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            result.append(name)
        }

        return result
    }
}
