import SwiftData
import Foundation
#if os(iOS)
import UIKit
#endif

@Observable
class ShowDataManager {
    private var modelContext: ModelContext
    var favoriteVersion: Int = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        DispatchQueue.main.async { [weak self] in
            self?.deduplicateSavedShows()
            self?.migrateRederivedSetlists()
        }
    }

    // MARK: - Deduplication

    /// Removes duplicate SavedShow records that represent the same show listened to on the same
    /// calendar date — a natural consequence of CloudKit syncing records created independently on
    /// multiple devices before they could see each other. Records for the same show on *different*
    /// dates are kept (they represent distinct listen events). Keeps the record with the most recent
    /// listenedAt timestamp; preserves isFavorite from any duplicate. Runs every launch (fast O(n)
    /// scan) so it handles new CloudKit-sourced duplicates too.
    private func deduplicateSavedShows() {
        guard let all = try? modelContext.fetch(FetchDescriptor<SavedShow>()) else { return }
        let calendar = Calendar.current

        // Key: showDate + calendar day of listenedAt (or a nil sentinel for unfavourited non-listens)
        var byKey: [String: [SavedShow]] = [:]
        for show in all {
            let dayKey: String
            if let date = show.listenedAt {
                let d = calendar.dateComponents([.year, .month, .day], from: date)
                dayKey = "\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)"
            } else {
                dayKey = "nil"
            }
            byKey["\(show.showDate)|\(dayKey)", default: []].append(show)
        }

        var deletedCount = 0
        for duplicates in byKey.values where duplicates.count > 1 {
            let sorted = duplicates.sorted {
                ($0.listenedAt ?? .distantPast) > ($1.listenedAt ?? .distantPast)
            }
            let keeper = sorted[0]
            if sorted.dropFirst().contains(where: { $0.isFavorite }) { keeper.isFavorite = true }
            for dupe in sorted.dropFirst() { modelContext.delete(dupe); deletedCount += 1 }
        }

        if deletedCount > 0 {
            try? modelContext.save()
            #if DEBUG
            print("✅ ShowDataManager: removed \(deletedCount) duplicate show record(s)")
            #endif
        }
    }

    // MARK: - One-time Migrations

    /// Re-derives `setlist` for every `SavedShow` by feeding its already-parsed
    /// entries back through the current `parseSetlist` logic (see
    /// `FZShowsFetcher.redrivedSetlist`). This retroactively fixes shows whose
    /// setlists were split incorrectly by an older parser — e.g. standalone
    /// "q:" quote entries, or songs glued together by a stray-paren cascade —
    /// without re-fetching from zappateers. Runs once per device, guarded by
    /// a UserDefaults flag (SavedShow syncs via CloudKit, but the migration
    /// itself is local — each device that has ever opened the app migrates
    /// its own copy once).
    private static let rederiveSetlistsMigrationKey = "didRederiveSavedShowSetlists_v1"

    private func migrateRederivedSetlists() {
        guard !UserDefaults.standard.bool(forKey: Self.rederiveSetlistsMigrationKey) else { return }
        guard let shows = try? modelContext.fetch(FetchDescriptor<SavedShow>()) else { return }

        var changedCount = 0
        for show in shows {
            let original = (try? JSONDecoder().decode([String].self, from: show.setlistData)) ?? []
            if let rederived = FZShowsFetcher.redrivedSetlist(from: original) {
                show.applyMigratedSetlist(rederived)
                changedCount += 1
            }
        }

        if changedCount > 0 {
            try? modelContext.save()
        }
        UserDefaults.standard.set(true, forKey: Self.rederiveSetlistsMigrationKey)
        #if DEBUG
        print("✅ ShowDataManager: re-derived setlists for \(changedCount) of \(shows.count) saved show(s)")
        #endif
    }

    // MARK: - History

    func recordListen(show: FZShow) {
        let showDate = show.date
        let calendar = Calendar.current
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.showDate == showDate }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []

        // Only upsert into a record from today — a record from a previous date is a distinct listen event
        let todayRecords = existing.filter {
            $0.listenedAt.map { calendar.isDateInToday($0) } == true
        }

        if let keeper = todayRecords.first {
            // Same show, same calendar day — update device tag and clean up any same-day duplicates
            keeper.deviceName = currentDeviceName()
            keeper.listenedAt = Date()
            for dupe in todayRecords.dropFirst() { modelContext.delete(dupe) }
        } else {
            // New calendar day (or first ever listen) — insert a fresh record
            modelContext.insert(SavedShow.from(show, listenedAt: Date(), deviceName: currentDeviceName()))
        }
        do { try modelContext.save() } catch { print("ShowDataManager: SwiftData save error — \(error)") }
    }

    private func currentDeviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    // MARK: - Favorites

    func toggleFavorite(show: FZShow) {
        let showDate = show.date
        setFavorite(showDate: showDate)
    }

    func toggleFavorite(savedShow: SavedShow) {
        setFavorite(showDate: savedShow.showDate)
    }

    private func setFavorite(showDate: String) {
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.showDate == showDate }
        )
        guard let records = try? modelContext.fetch(descriptor), !records.isEmpty else { return }
        // Toggle: if any record is already a favourite → unfavourite all; otherwise favourite all
        let newValue = !records.contains { $0.isFavorite }
        records.forEach { $0.isFavorite = newValue }
        do { try modelContext.save() } catch { print("ShowDataManager: SwiftData save error — \(error)") }
        favoriteVersion += 1
    }

    func isFavorite(showDate: String) -> Bool {
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.showDate == showDate && $0.isFavorite == true }
        )
        return ((try? modelContext.fetch(descriptor))?.first) != nil
    }

    // MARK: - Clear Data

    func clearHistory() {
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.listenedAt != nil }
        )

        guard let shows = try? modelContext.fetch(descriptor) else { return }

        for show in shows {
            if show.isFavorite {
                // Keep the record but clear the listen date
                show.listenedAt = nil
            } else {
                // Delete entirely if not a favorite
                modelContext.delete(show)
            }
        }

        do { try modelContext.save() } catch { print("ShowDataManager: SwiftData save error — \(error)") }
    }

    func clearFavorites() {
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.isFavorite == true }
        )

        guard let shows = try? modelContext.fetch(descriptor) else { return }

        for show in shows {
            if show.listenedAt != nil {
                // Keep the record but unfavorite
                show.isFavorite = false
            } else {
                // Delete entirely if not in history
                modelContext.delete(show)
            }
        }

        do { try modelContext.save() } catch { print("ShowDataManager: SwiftData save error — \(error)") }
        favoriteVersion += 1
    }

    // MARK: - iCloud Sync

    @MainActor
    func triggerCloudKitSync() async {
        try? modelContext.save()
        try? await Task.sleep(for: .seconds(1.5))
    }

    // MARK: - Refresh Show Info

    func refreshShowInfo(savedShow: SavedShow, completion: @escaping (Bool) -> Void) {
        let showDate = savedShow.showDate

        // Derive showTime from showDate suffix (e.g. "1980 12 11 E" → .early)
        let showTime: ShowTime
        if showDate.hasSuffix(" E") {
            showTime = .early
        } else if showDate.hasSuffix(" L") {
            showTime = .late
        } else {
            showTime = .none
        }

        FZShowsFetcher.fetchShowInfo(date: showDate, showTime: showTime) { [weak self] newShow in
            DispatchQueue.main.async {
                guard let self = self, let newShow = newShow else {
                    completion(false)
                    return
                }

                // Update the saved show with new data
                savedShow.venue = newShow.venue
                savedShow.soundcheck = newShow.soundcheck
                savedShow.note = newShow.note
                savedShow.showInfo = newShow.showInfo
                savedShow.setlistData = (try? JSONEncoder().encode(newShow.setlist)) ?? Data()
                let acronymsCodable = newShow.acronyms.map { Acronym(short: $0.short, full: $0.full) }
                savedShow.acronymsData = (try? JSONEncoder().encode(acronymsCodable)) ?? Data()
                savedShow.url = newShow.url
                savedShow.city = newShow.city
                savedShow.state = newShow.state
                savedShow.country = newShow.country
                savedShow.period = newShow.period
                savedShow.tour = newShow.tour
                savedShow.bandInfo = newShow.bandInfo

                try? self.modelContext.save()
                #if DEBUG
                print("✅ Refreshed show info for \(showDate)")
                #endif
                completion(true)
            }
        }
    }
}
