// LocalStorageManager.swift
// Handles local storage of meetings and app data

import Foundation

/// Manages local file storage for meetings and app data
class LocalStorageManager {
    static let shared = LocalStorageManager()
    
    private let documentsDirectory: URL
    private let meetingsDirectory: URL
    private let meetingSummariesDirectory: URL
    private let templatesDirectory: URL
    
    private init() {
        // The Documents directory should always exist for the app container, but keep
        // storage initialization fallible-safe so a system lookup failure cannot crash launch.
        if let directory = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            documentsDirectory = directory
        } else {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetMemo", isDirectory: true)
            print("⚠️ Failed to resolve Documents directory. Using temporary fallback: \(fallbackDirectory)")
            documentsDirectory = fallbackDirectory
        }
        
        // Create meetings subdirectory
        meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        meetingSummariesDirectory = documentsDirectory.appendingPathComponent("MeetingSummaries")
        
        // Create templates subdirectory
        templatesDirectory = documentsDirectory.appendingPathComponent("Templates")
        
        // Ensure directories exist
        try? FileManager.default.createDirectory(at: meetingsDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: meetingSummariesDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: templatesDirectory,
                                               withIntermediateDirectories: true)
    }
    
    // MARK: - Meeting Management
    
    /// Saves a meeting to local storage
    /// - Parameter meeting: The meeting to save
    /// - Returns: True if successful, false otherwise
    func saveMeeting(_ meeting: Meeting) -> Bool {
        let fileURL = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        var meetingToSave = meeting
        meetingToSave.syncLegacyUserNotesFromContext()
        meetingToSave.dataVersion = Meeting.currentDataVersion

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(meetingToSave)

            // Write atomically using a temp file then replace
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
                } catch {
                    // Fallback for the first save path if replacement fails because the file does not yet exist.
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                    try FileManager.default.moveItem(at: tmpURL, to: fileURL)
                }
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }

            print("✅ Saved meeting: \(meeting.id)")
            saveMeetingSummary(MeetingSummary(meeting: meetingToSave))
            return true
        } catch {
            print("❌ Failed to save meeting: \(error)")
            return false
        }
    }
    
    /// Loads all meetings from local storage
    /// - Returns: Array of meetings, sorted by date (newest first)
    func loadMeetings() -> [Meeting] {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: meetingsDirectory,
                                                                      includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            var didCreateBackup = false
            
            let meetings = fileURLs.compactMap { url -> Meeting? in
                guard let data = try? Data(contentsOf: url),
                      let meeting = try? decoder.decode(Meeting.self, from: data) else {
                    print("⚠️ Failed to decode meeting at: \(url)")
                    return nil
                }
                // Forward-compatibility guard – skip if file was written by a newer build
                if meeting.dataVersion > Meeting.currentDataVersion {
                    print("🚫 Meeting \(meeting.id) written by newer app version (\(meeting.dataVersion)). Skipping load.")
                    return nil
                }

                // Check if migration is needed
                if meeting.dataVersion < Meeting.currentDataVersion {
                    // Create backup **once** before we start mutating anything
                    if !didCreateBackup {
                        _ = DataMigrationManager.shared.backupMeetingsDirectory()
                        didCreateBackup = true
                    }

                    if let migratedMeeting = DataMigrationManager.shared.migrateMeeting(meeting) {
                        if saveMeeting(migratedMeeting) {
                            print("✅ Migrated and saved meeting: \(migratedMeeting.id)")
                            return migratedMeeting
                        }
                        print("❌ Failed to save migrated meeting: \(migratedMeeting.id)")
                    } else {
                        print("❌ Failed to migrate meeting: \(meeting.id)")
                    }
                    // Return original if anything failed
                    return meeting
                }

                saveMeetingSummary(MeetingSummary(meeting: meeting))
                return meeting
            }
            
            return meetings.sorted { $0.date > $1.date }
        } catch {
            print("❌ Failed to load meetings: \(error)")
            return []
        }
    }

    /// Loads lightweight meeting summaries for the sidebar.
    /// Falls back to full meeting files for older data and writes summary files
    /// so the expensive path is paid only once.
    func loadMeetingSummaries() -> [MeetingSummary] {
        do {
            let summaryURLs = try FileManager.default.contentsOfDirectory(
                at: meetingSummariesDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }

            if !summaryURLs.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                let summaries = summaryURLs.compactMap { url -> MeetingSummary? in
                    guard let data = try? Data(contentsOf: url),
                          let summary = try? decoder.decode(MeetingSummary.self, from: data),
                          summary.dataVersion <= Meeting.currentDataVersion else {
                        print("⚠️ Failed to decode meeting summary at: \(url)")
                        return nil
                    }
                    return summary
                }

                let summaryIds = Set(summaries.map(\.id))
                let meetingFileIds = meetingFileIds()
                let hasMissingSummaries = !meetingFileIds.isSubset(of: summaryIds)
                let hasInvalidSummaries = summaries.count != summaryURLs.count

                guard hasMissingSummaries || hasInvalidSummaries else {
                    return summaries.sorted { $0.date > $1.date }
                }

                print("⚠️ Meeting summaries are incomplete. Regenerating missing sidebar data.")
                var mergedById = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
                for fullSummary in loadMeetings().map(MeetingSummary.init(meeting:)) {
                    mergedById[fullSummary.id] = fullSummary
                }

                return Array(mergedById.values).sorted { $0.date > $1.date }
            }
        } catch {
            print("⚠️ Failed to read meeting summaries: \(error)")
        }

        return loadMeetings().map(MeetingSummary.init(meeting:))
    }

    private func meetingFileIds() -> Set<UUID> {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return Set(fileURLs.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        })
    }

    /// Loads a single meeting from local storage.
    /// Use this when opening a detail view so large transcripts in unrelated
    /// meetings do not block navigation.
    /// - Parameter id: The meeting ID to load.
    /// - Returns: The decoded meeting, or nil if it cannot be loaded.
    func loadMeeting(id: UUID) -> Meeting? {
        let fileURL = meetingsDirectory.appendingPathComponent("\(id.uuidString).json")

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let meeting = try decoder.decode(Meeting.self, from: data)
            guard meeting.dataVersion <= Meeting.currentDataVersion else {
                print("🚫 Meeting \(meeting.id) written by newer app version (\(meeting.dataVersion)). Skipping load.")
                return nil
            }

            if meeting.dataVersion < Meeting.currentDataVersion,
               let migratedMeeting = DataMigrationManager.shared.migrateMeeting(meeting) {
                _ = saveMeeting(migratedMeeting)
                return migratedMeeting
            }

            return meeting
        } catch {
            print("⚠️ Failed to load meeting \(id): \(error)")
            return nil
        }
    }
    
    /// Deletes a meeting from local storage
    /// - Parameter meeting: The meeting to delete
    /// - Returns: True if successful, false otherwise
    func deleteMeeting(_ meeting: Meeting) -> Bool {
        let fileURL = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        let summaryURL = meetingSummaryFileURL(for: meeting.id)

        do {
            try removeFileIfPresent(at: fileURL)
            try removeFileIfPresent(at: summaryURL)
            print("✅ Deleted meeting: \(meeting.id)")
            return true
        } catch {
            print("❌ Failed to delete meeting: \(error)")
            return false
        }
    }

    func deleteMeetingSummary(_ summary: MeetingSummary) -> Bool {
        let fileURL = meetingsDirectory.appendingPathComponent("\(summary.id.uuidString).json")
        let summaryURL = meetingSummaryFileURL(for: summary.id)

        do {
            try removeFileIfPresent(at: fileURL)
            try removeFileIfPresent(at: summaryURL)
            print("✅ Deleted meeting: \(summary.id)")
            return true
        } catch {
            print("❌ Failed to delete meeting: \(error)")
            return false
        }
    }

    private func removeFileIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func saveMeetingSummary(_ summary: MeetingSummary) {
        let fileURL = meetingSummaryFileURL(for: summary.id)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(summary)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            print("⚠️ Failed to save meeting summary \(summary.id): \(error)")
        }
    }

    private func meetingSummaryFileURL(for id: UUID) -> URL {
        meetingSummariesDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    
    // MARK: - Template Management
    
    /// Saves a note template to local storage
    /// - Parameter template: The template to save
    /// - Returns: True if successful, false otherwise
    func saveTemplate(_ template: NoteTemplate) -> Bool {
        let fileURL = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            
            let data = try encoder.encode(template)

            // Write atomically using a temp file then replace
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }

            print("✅ Saved template: \(template.id)")
            return true
        } catch {
            print("❌ Failed to save template: \(error)")
            return false
        }
    }
    
    /// Loads all templates from local storage
    /// - Returns: Array of templates, empty if none found
    func loadTemplates() -> [NoteTemplate] {
        var templates: [NoteTemplate] = []
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: templatesDirectory,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)
            
            let decoder = JSONDecoder()
            
            for fileURL in fileURLs {
                guard fileURL.pathExtension == "json" else { continue }
                
                do {
                    let data = try Data(contentsOf: fileURL)
                    let template = try decoder.decode(NoteTemplate.self, from: data)
                    let migratedTemplate = template.migratedToPromptOnly()
                    if migratedTemplate != template {
                        _ = saveTemplate(migratedTemplate)
                    }
                    templates.append(migratedTemplate)
                    print("✅ Loaded template: \(migratedTemplate.id)")
                } catch {
                    print("❌ Failed to load template from \(fileURL): \(error)")
                }
            }
        } catch {
            print("❌ Failed to read templates directory: \(error)")
        }
        
        migrateDefaultTemplatesIfNeeded(&templates)

        // Always ensure all default templates are available
        let defaultTemplates = NoteTemplate.defaultTemplates()
        let existingTitles = Set(templates.map { $0.title })
        
        // Add any missing default templates
        for defaultTemplate in defaultTemplates {
            if !existingTitles.contains(defaultTemplate.title) {
                _ = saveTemplate(defaultTemplate)
                templates.append(defaultTemplate)
                print("✅ Added missing default template: \(defaultTemplate.title)")
            }
        }
        
        return templates.sorted { $0.title < $1.title }
    }

    /// Keeps bundled defaults available and removes historical default templates.
    private func migrateDefaultTemplatesIfNeeded(_ templates: inout [NoteTemplate]) {
        let defaultsByTitle = Dictionary(uniqueKeysWithValues: NoteTemplate.defaultTemplates().map { ($0.title, $0) })
        var defaultsByTitleToKeep: [String: NoteTemplate] = [:]
        var duplicateDefaultTemplates: [NoteTemplate] = []

        var customTemplates: [NoteTemplate] = []

        for template in templates {
            guard template.isDefault else {
                customTemplates.append(template)
                continue
            }

            if NoteTemplate.historicalDefaultTitles.contains(template.title) {
                deleteTemplateFile(template)
                continue
            }

            guard let bundledDefault = defaultsByTitle[template.title] else {
                customTemplates.append(template)
                continue
            }

            if defaultsByTitleToKeep[template.title] == nil {
                let templateToKeep = NoteTemplate(
                    id: template.id,
                    title: bundledDefault.title,
                    context: bundledDefault.context,
                    sections: bundledDefault.sections,
                    isDefault: true
                )
                _ = saveTemplate(templateToKeep)
                defaultsByTitleToKeep[template.title] = templateToKeep
            } else {
                duplicateDefaultTemplates.append(template)
            }
        }

        for template in duplicateDefaultTemplates {
            deleteTemplateFile(template)
        }

        let defaultsToKeep = NoteTemplate.defaultTemplates().map { defaultTemplate -> NoteTemplate in
            if let existing = defaultsByTitleToKeep[defaultTemplate.title] {
                return existing
            }

            _ = saveTemplate(defaultTemplate)
            return defaultTemplate
        }

        templates = (customTemplates + defaultsToKeep).sorted { $0.title < $1.title }
    }

    private func deleteTemplateFile(_ template: NoteTemplate) {
        try? FileManager.default.removeItem(at: templateFileURL(for: template))
    }

    private func templateFileURL(for template: NoteTemplate) -> URL {
        templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
    }
    
    /// Deletes a template from local storage
    /// - Parameter template: The template to delete
    /// - Returns: True if successful, false otherwise
    func deleteTemplate(_ template: NoteTemplate) -> Bool {
        // Don't allow deletion of default templates
        if template.isDefault {
            print("⚠️ Cannot delete default template")
            return false
        }
        
        let fileURL = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            print("✅ Deleted template: \(template.id)")
            return true
        } catch {
            print("❌ Failed to delete template: \(error)")
            return false
        }
    }
    
    // MARK: - Settings Management
    
    /// Saves non-sensitive settings to local storage
    /// - Parameter settings: The settings to save (sensitive data should use Keychain)
    func saveSettings(_ settings: Settings) -> Bool {
        // For now, all settings are stored in Keychain
        // This method is here for future non-sensitive settings
        return true
    }
    
    /// Gets the app's documents directory URL
    var documentsDirectoryURL: URL {
        documentsDirectory
    }
    
    /// Gets the meetings directory URL
    var meetingsDirectoryURL: URL {
        meetingsDirectory
    }
} 
