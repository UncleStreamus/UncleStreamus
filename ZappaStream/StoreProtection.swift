import Foundation
import SQLite3
import CloudKit

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
        guard FileManager.default.fileExists(atPath: url.path) else { return -1 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZSAVEDSHOW", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
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

    // Deletes the entire private CloudKit zone so NSPersistentCloudKitContainer starts with a
    // completely blank slate on the next launch — fresh zone, fresh subscription, full re-upload.
    // Safe because local ZSAVEDSHOW records are untouched; they'll be re-exported automatically.
    // Also clears all local ANSCK metadata so the container treats every local record as new.
    // Blocks up to 10 s (one-time hit at launch).
    static func resetCloudKitZoneIfNeeded(storeURL: URL) {
        let key = "ckZoneResetDone_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard FileManager.default.ubiquityIdentityToken != nil else { return }

        let privateDB = CKContainer(identifier: "iCloud.com.zappastream.ZappaStream").privateCloudDatabase
        let zoneID = CKRecordZone.ID(
            zoneName: "com.apple.coredata.cloudkit.zone",
            ownerName: CKCurrentUserDefaultName
        )

        let sem = DispatchSemaphore(value: 0)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zoneID])
        op.modifyRecordZonesResultBlock = { result in
            switch result {
            case .success:
                print("☁️ CloudKit zone deleted — fresh start")
                UserDefaults.standard.set(true, forKey: key)
            case .failure(let error):
                let ckErr = error as? CKError
                if ckErr?.code == .zoneNotFound {
                    print("☁️ CloudKit zone not found — already clean")
                    UserDefaults.standard.set(true, forKey: key)
                } else {
                    print("⚠️ CloudKit zone delete error: \(error)")
                }
            }
            sem.signal()
        }
        privateDB.add(op)

        guard sem.wait(timeout: .now() + 10) == .success else {
            print("⚠️ CloudKit zone delete timed out — will retry next launch")
            return
        }

        // Zone is gone — wipe all local ANSCK metadata so the container re-uploads everything.
        guard UserDefaults.standard.bool(forKey: key) else { return }
        clearCloudKitMetadata(at: storeURL)
        print("☁️ Local CloudKit metadata cleared — ready for fresh export")
    }

    // Deletes all existing CloudKit subscriptions from the private database — one-time fix for
    // the stale subscription left behind by the old bundle ID (com.zappastream.ZappaStream-iOS).
    // That subscription pointed to a dead APNS token and was blocking NSPersistentCloudKitContainer
    // setup with CKError.partialFailure (code 2), preventing all devices from receiving sync pushes.
    // Must be called before ModelContainer is created so the next setup attempt has a clean slate.
    // Blocks the calling thread for up to 5 s per phase (fetch + delete); this is a one-time hit.
    static func cleanupStaleSubscriptionsIfNeeded() {
        let cleanupKey = "ckSubscriptionCleanupDone_v1"
        guard !UserDefaults.standard.bool(forKey: cleanupKey) else { return }
        guard FileManager.default.ubiquityIdentityToken != nil else { return }

        let db = CKContainer(identifier: "iCloud.com.zappastream.ZappaStream").privateCloudDatabase

        // Phase 1: fetch subscription IDs
        let fetchSem = DispatchSemaphore(value: 0)
        var subscriptionIDs: [CKSubscription.ID] = []

        let fetchOp = CKFetchSubscriptionsOperation.fetchAllSubscriptionsOperation()
        fetchOp.perSubscriptionResultBlock = { id, result in
            if case .success = result { subscriptionIDs.append(id) }
        }
        fetchOp.fetchSubscriptionsResultBlock = { result in
            if case .failure(let error) = result {
                print("⚠️ CK subscription fetch error: \(error)")
            }
            fetchSem.signal()
        }
        db.add(fetchOp)

        guard fetchSem.wait(timeout: .now() + 5) == .success else {
            print("⚠️ CK subscription fetch timed out — will retry next launch")
            return
        }

        guard !subscriptionIDs.isEmpty else {
            print("☁️ No stale CK subscriptions — marking clean")
            UserDefaults.standard.set(true, forKey: cleanupKey)
            return
        }

        // Phase 2: delete them all
        print("☁️ Deleting \(subscriptionIDs.count) stale CK subscription(s)…")
        let deleteSem = DispatchSemaphore(value: 0)
        let deleteOp = CKModifySubscriptionsOperation(
            subscriptionsToSave: nil,
            subscriptionIDsToDelete: subscriptionIDs
        )
        deleteOp.modifySubscriptionsResultBlock = { result in
            switch result {
            case .success:
                print("☁️ Stale CK subscriptions deleted successfully")
                UserDefaults.standard.set(true, forKey: cleanupKey)
            case .failure(let error):
                print("⚠️ CK subscription delete error: \(error)")
            }
            deleteSem.signal()
        }
        db.add(deleteOp)

        if deleteSem.wait(timeout: .now() + 5) == .timedOut {
            print("⚠️ CK subscription delete timed out — will retry next launch")
        }
    }
}
