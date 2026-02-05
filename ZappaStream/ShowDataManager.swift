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
}
