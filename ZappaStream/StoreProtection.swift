import Foundation
import SQLite3

// Utilities for protecting the SwiftData history store against CloudKit zone-reset data loss.
// All methods are safe to call before the ModelContainer is opened (no SwiftData dependency).
enum StoreProtection {

    static var backupURL: URL? {
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.zappastream.shared"
        ) else { return nil }
        return groupContainer
            .appendingPathComponent("ZappaStream", isDirectory: true)
            .appendingPathComponent("ZappaStream-history.autobak")
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
