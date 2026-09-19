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
    private let migrationQuarantineDirectory: URL
    private let storageLock = NSRecursiveLock()
    private var deletedMeetingIDs = Set<UUID>()
    private var hasCreatedMigrationBackup = false
    
    private init() {
        // The Documents directory should always exist for the app container, but keep
        // storage initialization fallible-safe so a system lookup failure cannot crash launch.
        if let directory = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            documentsDirectory = directory
        } else {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetMemo", isDirectory: true)
            AppLog.storage.debug("⚠️ Failed to resolve Documents directory. Using temporary fallback: \(fallbackDirectory)")
            documentsDirectory = fallbackDirectory
        }
        
        // Create meetings subdirectory
        meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        meetingSummariesDirectory = documentsDirectory.appendingPathComponent("MeetingSummaries")
        
        // Create templates subdirectory
        templatesDirectory = documentsDirectory.appendingPathComponent("Templates")
        migrationQuarantineDirectory = documentsDirectory.appendingPathComponent("Meetings_Migration_Quarantine")
        
        // Ensure directories exist
        try? FileManager.default.createDirectory(at: meetingsDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: meetingSummariesDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: templatesDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: migrationQuarantineDirectory,
                                               withIntermediateDirectories: true)
    }
    
    // MARK: - Meeting Management

    func prepareMigrationsForLaunch() {
        withStorageLock {
            guard !hasCreatedMigrationBackup else { return }
            guard meetingFilesContainOlderDataVersionLocked() else { return }
            _ = createMigrationBackupIfNeededLocked()
        }
    }
    
    /// Saves a meeting to local storage
    /// - Parameter meeting: The meeting to save
    /// - Returns: True if successful, false otherwise
    func saveMeeting(_ meeting: Meeting) -> Bool {
        withStorageLock {
            saveMeetingLocked(meeting)
        }
    }

    private func saveMeetingLocked(_ meeting: Meeting) -> Bool {
        guard !deletedMeetingIDs.contains(meeting.id) else {
            AppLog.storage.debug("🚫 Skipping save for deleted meeting: \(meeting.id)")
            return false
        }

        let fileURL = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        var meetingToSave = mergedMeetingForSave(meeting, fileURL: fileURL)
        meetingToSave.syncLegacyUserNotesFromContext()
        meetingToSave.dataVersion = Meeting.currentDataVersion

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(meetingToSave)

            try replaceFileAtomically(at: fileURL, with: data)

            AppLog.storage.debug("✅ Saved meeting: \(meeting.id)")
            saveMeetingSummary(MeetingSummary(meeting: meetingToSave))
            return true
        } catch {
            AppLog.storage.debug("❌ Failed to save meeting: \(error)")
            return false
        }
    }

    private func mergedMeetingForSave(_ incoming: Meeting, fileURL: URL) -> Meeting {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return incoming
        }

        guard let existing = loadMeetingFromFileLocked(fileURL) else {
            return incoming
        }

        var merged = incoming
        merged.transcriptChunks = incoming.transcriptChunks
            .mergingTranscriptCorrections(preservingMissingFinalChunksFrom: existing.transcriptChunks)
        return merged
    }
    
    /// Loads all meetings from local storage
    /// - Returns: Array of meetings, sorted by date (newest first)
    func loadMeetings() -> [Meeting] {
        withStorageLock {
            loadMeetingsLocked()
        }
    }

    private func loadMeetingsLocked() -> [Meeting] {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: meetingsDirectory,
                                                                      includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let meetings = fileURLs.compactMap { url -> Meeting? in
                guard let data = try? Data(contentsOf: url),
                      let meeting = try? decoder.decode(Meeting.self, from: data) else {
                    AppLog.storage.debug("⚠️ Failed to decode meeting at: \(url)")
                    return nil
                }
                // Forward-compatibility guard – skip if file was written by a newer build
                if meeting.dataVersion > Meeting.currentDataVersion {
                    AppLog.storage.debug("🚫 Meeting \(meeting.id) written by newer app version (\(meeting.dataVersion)). Skipping load.")
                    return nil
                }

                // Check if migration is needed
                if meeting.dataVersion < Meeting.currentDataVersion {
                    _ = createMigrationBackupIfNeededLocked()

                    if let migratedMeeting = DataMigrationManager.shared.migrateMeeting(meeting) {
                        if saveMeeting(migratedMeeting) {
                            AppLog.storage.debug("✅ Migrated and saved meeting: \(migratedMeeting.id)")
                            return migratedMeeting
                        }
                        AppLog.storage.debug("❌ Failed to save migrated meeting: \(migratedMeeting.id)")
                        return migratedMeeting
                    } else {
                        AppLog.storage.debug("❌ Failed to migrate meeting: \(meeting.id)")
                        quarantineMeetingFileLocked(url, meetingId: meeting.id, reason: "migration failed")
                    }
                    return nil
                }

                saveMeetingSummary(MeetingSummary(meeting: meeting))
                return meeting
            }
            
            return meetings.sorted { $0.date > $1.date }
        } catch {
            AppLog.storage.debug("❌ Failed to load meetings: \(error)")
            return []
        }
    }

    /// Loads lightweight meeting summaries for the sidebar.
    /// Falls back to full meeting files for older data and writes summary files
    /// so the expensive path is paid only once.
    func loadMeetingSummaries() -> [MeetingSummary] {
        withStorageLock {
            loadMeetingSummariesLocked()
        }
    }

    private func loadMeetingSummariesLocked() -> [MeetingSummary] {
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
                        AppLog.storage.debug("⚠️ Failed to decode meeting summary at: \(url)")
                        return nil
                    }
                    return summary
                }

                let summariesById = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
                let meetingFilesById = meetingFileURLsById()
                let summaryFilesById = Dictionary(uniqueKeysWithValues: summaryURLs.compactMap { url in
                    UUID(uuidString: url.deletingPathExtension().lastPathComponent).map { ($0, url) }
                })
                let hasInvalidSummaries = summaries.count != summaryURLs.count
                let cacheNeedsRefresh = Self.summaryCacheNeedsRefresh(
                    meetingFilesById: meetingFilesById,
                    summaryFilesById: summaryFilesById,
                    decodedSummaryIds: Set(summariesById.keys),
                    hasInvalidSummaries: hasInvalidSummaries
                )

                guard cacheNeedsRefresh else {
                    return summaries.sorted { $0.date > $1.date }
                }

                AppLog.storage.debug("⚠️ Meeting summaries are stale or incomplete. Rebuilding sidebar data.")
                // Full meeting files are authoritative. Starting from cached summaries here
                // would retain orphan entries if deletion stopped between the two file writes.
                let rebuilt = loadMeetings().map(MeetingSummary.init(meeting:))
                let validIds = Set(rebuilt.map(\.id))
                for (id, url) in summaryFilesById where !validIds.contains(id) {
                    try? FileManager.default.removeItem(at: url)
                }
                return rebuilt
            }
        } catch {
            AppLog.storage.debug("⚠️ Failed to read meeting summaries: \(error)")
        }

        return loadMeetings().map(MeetingSummary.init(meeting:))
    }

    private func meetingFileURLsById() -> [UUID: URL] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: fileURLs.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent).map { ($0, url) }
        })
    }

    /// Rebuild whenever the two cache directories disagree, decoding failed, or a meeting
    /// file is newer than its summary. The modification-date check closes the crash window
    /// between the authoritative meeting write and the subsequent summary write.
    static func summaryCacheNeedsRefresh(
        meetingFilesById: [UUID: URL],
        summaryFilesById: [UUID: URL],
        decodedSummaryIds: Set<UUID>,
        hasInvalidSummaries: Bool,
        fileModificationDate: (URL) -> Date? = { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    ) -> Bool {
        let meetingIds = Set(meetingFilesById.keys)
        let summaryIds = Set(summaryFilesById.keys)
        guard !hasInvalidSummaries,
              meetingIds == summaryIds,
              decodedSummaryIds == summaryIds else {
            return true
        }

        return meetingFilesById.contains { id, meetingURL in
            guard let summaryURL = summaryFilesById[id],
                  let meetingDate = fileModificationDate(meetingURL),
                  let summaryDate = fileModificationDate(summaryURL) else {
                return true
            }
            return meetingDate > summaryDate
        }
    }

    private func meetingFilesContainOlderDataVersionLocked() -> Bool {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return fileURLs.contains { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let meeting = try? decoder.decode(Meeting.self, from: data) else {
                return false
            }

            return meeting.dataVersion < Meeting.currentDataVersion
        }
    }

    private func createMigrationBackupIfNeededLocked() -> URL? {
        guard !hasCreatedMigrationBackup else { return nil }
        hasCreatedMigrationBackup = true
        return DataMigrationManager.shared.backupMeetingsDirectory()
    }

    /// Loads a single meeting from local storage.
    /// Use this when opening a detail view so large transcripts in unrelated
    /// meetings do not block navigation.
    /// - Parameter id: The meeting ID to load.
    /// - Returns: The decoded meeting, or nil if it cannot be loaded.
    func loadMeeting(id: UUID) -> Meeting? {
        withStorageLock {
            loadMeetingLocked(id: id)
        }
    }

    private func loadMeetingLocked(id: UUID) -> Meeting? {
        let fileURL = meetingsDirectory.appendingPathComponent("\(id.uuidString).json")

        guard let meeting = loadMeetingFromFileLocked(fileURL) else {
            return nil
        }

        guard meeting.dataVersion <= Meeting.currentDataVersion else {
            AppLog.storage.debug("🚫 Meeting \(meeting.id) written by newer app version (\(meeting.dataVersion)). Skipping load.")
            return nil
        }

        if meeting.dataVersion < Meeting.currentDataVersion {
            _ = createMigrationBackupIfNeededLocked()
            guard let migratedMeeting = DataMigrationManager.shared.migrateMeeting(meeting) else {
                AppLog.storage.debug("❌ Failed to migrate meeting: \(meeting.id)")
                quarantineMeetingFileLocked(fileURL, meetingId: meeting.id, reason: "migration failed")
                return nil
            }

            if !saveMeetingLocked(migratedMeeting) {
                AppLog.storage.debug("❌ Failed to save migrated meeting: \(migratedMeeting.id). Using migrated in-memory copy.")
            }
            return migratedMeeting
        }

        return meeting
    }

    private func loadMeetingFromFileLocked(_ fileURL: URL) -> Meeting? {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            return try decoder.decode(Meeting.self, from: data)
        } catch {
            AppLog.storage.debug("⚠️ Failed to load meeting at \(fileURL.lastPathComponent): \(error)")
            return nil
        }
    }
    
    /// Deletes a meeting from local storage
    /// - Parameter meeting: The meeting to delete
    /// - Returns: True if successful, false otherwise
    func deleteMeeting(_ meeting: Meeting) -> Bool {
        withStorageLock {
            deleteMeetingLocked(meeting.id)
        }
    }

    private func deleteMeetingLocked(_ meetingId: UUID) -> Bool {
        let fileURL = meetingsDirectory.appendingPathComponent("\(meetingId.uuidString).json")
        let summaryURL = meetingSummaryFileURL(for: meetingId)

        do {
            deletedMeetingIDs.insert(meetingId)
            try removeFileIfPresent(at: fileURL)
            try removeFileIfPresent(at: summaryURL)
            AppLog.storage.debug("✅ Deleted meeting: \(meetingId)")
            return true
        } catch {
            AppLog.storage.debug("❌ Failed to delete meeting: \(error)")
            return false
        }
    }

    func deleteMeetingSummary(_ summary: MeetingSummary) -> Bool {
        withStorageLock {
            deleteMeetingLocked(summary.id)
        }
    }

    private func removeFileIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func quarantineMeetingFileLocked(_ fileURL: URL, meetingId: UUID, reason: String) {
        do {
            try FileManager.default.createDirectory(at: migrationQuarantineDirectory,
                                                   withIntermediateDirectories: true)

            let destination = uniqueQuarantineURL(for: fileURL)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            try removeFileIfPresent(at: meetingSummaryFileURL(for: meetingId))
            AppLog.storage.debug("🚧 Quarantined meeting \(meetingId) after \(reason): \(destination.lastPathComponent)")
        } catch {
            AppLog.storage.debug("❌ Failed to quarantine meeting \(meetingId): \(error)")
        }
    }

    private func uniqueQuarantineURL(for fileURL: URL) -> URL {
        let baseURL = migrationQuarantineDirectory.appendingPathComponent(fileURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantinedName = "\(fileURL.deletingPathExtension().lastPathComponent)-\(timestamp).\(fileURL.pathExtension)"
        return migrationQuarantineDirectory.appendingPathComponent(quarantinedName)
    }

    private func saveMeetingSummary(_ summary: MeetingSummary) {
        let fileURL = meetingSummaryFileURL(for: summary.id)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(summary)
            try replaceFileAtomically(at: fileURL, with: data)
        } catch {
            AppLog.storage.debug("⚠️ Failed to save meeting summary \(summary.id): \(error)")
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
        withStorageLock {
            saveTemplateLocked(template)
        }
    }

    private func saveTemplateLocked(_ template: NoteTemplate) -> Bool {
        let fileURL = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            
            let data = try encoder.encode(template)
            try replaceFileAtomically(at: fileURL, with: data)

            AppLog.storage.debug("✅ Saved template: \(template.id)")
            return true
        } catch {
            AppLog.storage.debug("❌ Failed to save template: \(error)")
            return false
        }
    }
    
    /// Loads all templates from local storage
    /// - Returns: Array of templates, empty if none found
    func loadTemplates() -> [NoteTemplate] {
        withStorageLock {
            loadTemplatesLocked()
        }
    }

    private func loadTemplatesLocked() -> [NoteTemplate] {
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
                        _ = saveTemplateLocked(migratedTemplate)
                    }
                    templates.append(migratedTemplate)
                    AppLog.storage.debug("✅ Loaded template: \(migratedTemplate.id)")
                } catch {
                    AppLog.storage.debug("❌ Failed to load template from \(fileURL): \(error)")
                }
            }
        } catch {
            AppLog.storage.debug("❌ Failed to read templates directory: \(error)")
        }
        
        migrateDefaultTemplatesIfNeeded(&templates)

        // Always ensure all default templates are available
        let defaultTemplates = NoteTemplate.defaultTemplates()
        let existingTitles = Set(templates.map { $0.title })
        
        // Add any missing default templates
        for defaultTemplate in defaultTemplates {
            if !existingTitles.contains(defaultTemplate.title) {
                _ = saveTemplateLocked(defaultTemplate)
                templates.append(defaultTemplate)
                AppLog.storage.debug("✅ Added missing default template: \(defaultTemplate.title)")
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
                _ = saveTemplateLocked(templateToKeep)
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

            _ = saveTemplateLocked(defaultTemplate)
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
        withStorageLock {
            deleteTemplateLocked(template)
        }
    }

    private func deleteTemplateLocked(_ template: NoteTemplate) -> Bool {
        // Don't allow deletion of default templates
        if template.isDefault {
            AppLog.storage.debug("⚠️ Cannot delete default template")
            return false
        }
        
        let fileURL = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            AppLog.storage.debug("✅ Deleted template: \(template.id)")
            return true
        } catch {
            AppLog.storage.debug("❌ Failed to delete template: \(error)")
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

    private func replaceFileAtomically(at fileURL: URL, with data: Data) throws {
        let tmpURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

        try data.write(to: tmpURL, options: .atomic)

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItem(
                    at: fileURL,
                    withItemAt: tmpURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    private func withStorageLock<T>(_ operation: () -> T) -> T {
        storageLock.lock()
        defer { storageLock.unlock() }
        return operation()
    }
} 
