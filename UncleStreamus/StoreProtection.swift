import Foundation
import SQLite3

// Utilities for protecting the SwiftData history store against CloudKit zone-reset data loss.
// All methods are safe to call before the ModelContainer is opened (no SwiftData dependency).
enum StoreProtection {

    static var backupURL: URL? {
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.unclestreamus.shared"
        ) else { return nil }
        return groupContainer
            .appendingPathComponent("UncleStreamus", isDirectory: true)
            .appendingPathComponent("UncleStreamus-history.autobak")
    }

    // One-time rebrand migration (ZappaStream → UncleStreamus): copy the personal
    // history store from the legacy `group.com.zappastream.shared` container into the
    // new `group.com.unclestreamus.shared` container, then clear CloudKit metadata so
    // the records re-upload to the new (empty) CloudKit container. Safe to call before
    // the ModelContainer opens. Runs at most once (guarded by a UserDefaults flag).
    static func migrateFromLegacyGroup() {
        let flagKey = "didMigrateFromZappaStreamGroup"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let fm = FileManager.default
        // If the new group container isn't available yet, bail WITHOUT setting the flag
        // so the migration is retried on a later launch.
        guard let newGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unclestreamus.shared") else { return }

        if let oldGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.zappastream.shared") {
            let oldStore = oldGroup
                .appendingPathComponent("ZappaStream", isDirectory: true)
                .appendingPathComponent("ZappaStream-history.store")
            let newDir = newGroup.appendingPathComponent("UncleStreamus", isDirectory: true)
            let newStore = newDir.appendingPathComponent("UncleStreamus-history.store")

            // Only migrate when legacy data exists and the new store hasn't been created yet.
            if fm.fileExists(atPath: oldStore.path) && !fm.fileExists(atPath: newStore.path) {
                try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] {
                    let src = URL(fileURLWithPath: oldStore.path + suffix)
                    let dst = URL(fileURLWithPath: newStore.path + suffix)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: src, to: dst)
                }
                // The new CloudKit container is empty; clearing sync metadata makes the
                // migrated records upload as new rather than awaiting a matching sync state.
                clearCloudKitMetadata(at: newStore)
            }
        }

        UserDefaults.standard.set(true, forKey: flagKey)
    }

    // Returns the number of ZSAVEDSHOW rows in a SQLite store, or -1 if the file doesn't
    // exist or can't be read. Safe to call while no other process has the file open.
    static func countRecords(at url: URL) -> Int {
        return countRows(at: url, sql: "SELECT COUNT(*) FROM ZSAVEDSHOW")
    }

    static func countFavorites(at url: URL) -> Int {
        return countRows(at: url, sql: "SELECT COUNT(*) FROM ZSAVEDSHOW WHERE ZISFAVORITE = 1")
    }

    private static func countRows(at url: URL, sql: String) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return -1 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }

    // Copies the store to the backup URL. Attempts a passive WAL checkpoint first so the
    // backup captures any data sitting in the WAL that hasn't been merged yet.
    static func backup(from src: URL, to dst: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(src.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            sqlite3_close(db)
        }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        // Copy WAL in case checkpoint was partial
        let srcWAL = URL(fileURLWithPath: src.path + "-wal")
        let dstWAL = URL(fileURLWithPath: dst.path + "-wal")
        try? FileManager.default.removeItem(at: dstWAL)
        if FileManager.default.fileExists(atPath: srcWAL.path) {
            try? FileManager.default.copyItem(at: srcWAL, to: dstWAL)
        }
    }

    // Overwrites the live store with the backup and clears all CloudKit sync metadata.
    // Clearing the metadata makes NSPersistentCloudKitContainer treat the restored records
    // as new on the next launch, triggering a re-upload rather than a zone-reset wipe.
    static func restoreAndClearMetadata(from backup: URL, to store: URL) {
        let storeWAL = URL(fileURLWithPath: store.path + "-wal")
        let storeSHM = URL(fileURLWithPath: store.path + "-shm")
        let backupWAL = URL(fileURLWithPath: backup.path + "-wal")

        try? FileManager.default.removeItem(at: store)
        try? FileManager.default.removeItem(at: storeWAL)
        try? FileManager.default.removeItem(at: storeSHM)
        try? FileManager.default.copyItem(at: backup, to: store)
        if FileManager.default.fileExists(atPath: backupWAL.path) {
            try? FileManager.default.copyItem(at: backupWAL, to: storeWAL)
        }

        clearCloudKitMetadata(at: store)
    }

    // Deletes all NSPersistentCloudKitContainer sync state rows from the store, leaving
    // ZSAVEDSHOW (user data) and SwiftData schema tables (Z_*) untouched.
    static func clearCloudKitMetadata(at url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        for table in ckMetadataTables {
            sqlite3_exec(db, "DELETE FROM \(table)", nil, nil, nil)
        }
    }

    private static let ckMetadataTables = [
        "ANSCKRECORDZONEMETADATA", "ANSCKDATABASEMETADATA", "ANSCKRECORDMETADATA",
        "ANSCKEXPORTEDOBJECT", "ANSCKEXPORTMETADATA", "ANSCKEXPORTOPERATION",
        "ANSCKIMPORTOPERATION", "ANSCKIMPORTPENDINGRELATIONSHIP", "ANSCKMIRROREDRELATIONSHIP",
        "ANSCKMETADATAENTRY", "ANSCKEVENT", "ANSCKRECORDZONEQUERY",
        "ANSCKRECORDZONEMOVERECEIPT", "ANSCKHISTORYANALYZERSTATE",
        "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"
    ]

}
