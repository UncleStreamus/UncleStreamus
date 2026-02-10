import SwiftData
import Foundation

@Observable
class ShowDataManager {
    private var modelContext: ModelContext
    var favoriteVersion: Int = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - History

    func recordListen(show: FZShow) {
        let showDate = show.date
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.showDate == showDate }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.listenedAt = Date()
        } else {
            let saved = SavedShow.from(show, listenedAt: Date())
            modelContext.insert(saved)
        }

        try? modelContext.save()
    }

    // MARK: - Favorites

    func toggleFavorite(show: FZShow) {
        let showDate = show.date
        let descriptor = FetchDescriptor<SavedShow>(
            predicate: #Predicate { $0.showDate == showDate }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.isFavorite.toggle()
            try? modelContext.save()
            favoriteVersion += 1
        }
    }

    func toggleFavorite(savedShow: SavedShow) {
        savedShow.isFavorite.toggle()
        try? modelContext.save()
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

        try? modelContext.save()
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

        try? modelContext.save()
        favoriteVersion += 1
    }

    // MARK: - Refresh Show Info

    func refreshShowInfo(savedShow: SavedShow, completion: @escaping (Bool) -> Void) {
        let showDate = savedShow.showDate

        // Parse showTime from showInfo if present
        let showTime: ShowTime
        if savedShow.showInfo.lowercased().contains("early") {
            showTime = .early
        } else if savedShow.showInfo.lowercased().contains("late") {
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

                try? self.modelContext.save()
                print("✅ Refreshed show info for \(showDate)")
                completion(true)
            }
        }
    }
}
