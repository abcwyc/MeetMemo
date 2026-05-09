// DataMigrationManager.swift
// Handles data migration between different app versions

import Foundation

/// Manages data migration between different app versions
class DataMigrationManager {
    static let shared = DataMigrationManager()
    
    private init() {}
    
    /// Migrates a meeting from an older version to the current version
    /// - Parameter meeting: The meeting to migrate
    /// - Returns: The migrated meeting, or nil if migration failed
    func migrateMeeting(_ meeting: Meeting) -> Meeting? {
        // No releases prior to version 1 – any older file is considered unsupported.
        guard meeting.dataVersion >= 1 else {
            print("🚫 Cannot migrate meeting \(meeting.id) – unsupported data version \(meeting.dataVersion)")
            return nil
        }

        var migratedMeeting = meeting

        if migratedMeeting.dataVersion < 2 {
            migratedMeeting.contextItems = Meeting(
                id: migratedMeeting.id,
                date: migratedMeeting.date,
                title: migratedMeeting.title,
                transcriptChunks: migratedMeeting.transcriptChunks,
                userNotes: migratedMeeting.userNotes,
                generatedNotes: migratedMeeting.generatedNotes,
                templateId: migratedMeeting.templateId,
                dataVersion: 2
            ).contextItems
            migratedMeeting.dataVersion = 2
        }

        if migratedMeeting.dataVersion < 3 {
            migratedMeeting.followUpTasks = []
            migratedMeeting.dataVersion = 3
        }

        if migratedMeeting.dataVersion < Meeting.currentDataVersion {
            print("⚠️ No migration path for versions \(migratedMeeting.dataVersion + 1)...\(Meeting.currentDataVersion)")
            return nil
        }

        return migratedMeeting
    }
    
    // Future migrateXToVersionY helpers will go here as needed
    
    /// Performs a backup of the meetings directory before migration
    /// - Returns: The backup directory URL, or nil if backup failed
    func backupMeetingsDirectory() -> URL? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Failed to resolve Documents directory for migration backup")
            return nil
        }
        let meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        
        let backupDirectory = documentsDirectory.appendingPathComponent("Meetings_Backup_\(timestamp)")
        
        do {
            try FileManager.default.copyItem(at: meetingsDirectory, to: backupDirectory)
            print("✅ Created backup at: \(backupDirectory)")
            return backupDirectory
        } catch {
            print("❌ Failed to create backup: \(error)")
            return nil
        }
    }
} 
