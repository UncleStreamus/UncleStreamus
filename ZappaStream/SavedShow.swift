import Foundation
import SwiftData

@Model
final class SavedShow {
    @Attribute(.unique) var showDate: String

    var venue: String
    var soundcheck: String?
    var note: String?
    var showInfo: String
    var setlistData: Data
    var acronymsData: Data
    var url: String

    var isFavorite: Bool
    var listenedAt: Date?

    init(showDate: String, venue: String, soundcheck: String?, note: String?,
         showInfo: String, setlistData: Data, acronymsData: Data, url: String,
         isFavorite: Bool = false, listenedAt: Date? = nil) {
        self.showDate = showDate
        self.venue = venue
        self.soundcheck = soundcheck
        self.note = note
        self.showInfo = showInfo
        self.setlistData = setlistData
        self.acronymsData = acronymsData
        self.url = url
        self.isFavorite = isFavorite
        self.listenedAt = listenedAt
    }

    var setlist: [String] {
        (try? JSONDecoder().decode([String].self, from: setlistData)) ?? []
    }

    var acronyms: [Acronym] {
        (try? JSONDecoder().decode([Acronym].self, from: acronymsData)) ?? []
    }

    var acronymTuples: [(short: String, full: String)] {
        acronyms.map { ($0.short, $0.full) }
    }

    func toFZShow() -> FZShow {
        FZShow(
            date: showDate,
            venue: venue,
            soundcheck: soundcheck,
            note: note,
            showInfo: showInfo,
            setlist: setlist,
            acronyms: acronymTuples,
            url: url
        )
    }

    static func from(_ show: FZShow, isFavorite: Bool = false, listenedAt: Date? = nil) -> SavedShow {
        let setlistData = (try? JSONEncoder().encode(show.setlist)) ?? Data()
        let acronymsCodable = show.acronyms.map { Acronym(short: $0.short, full: $0.full) }
        let acronymsData = (try? JSONEncoder().encode(acronymsCodable)) ?? Data()

        return SavedShow(
            showDate: show.date,
            venue: show.venue,
            soundcheck: show.soundcheck,
            note: show.note,
            showInfo: show.showInfo,
            setlistData: setlistData,
            acronymsData: acronymsData,
            url: show.url,
            isFavorite: isFavorite,
            listenedAt: listenedAt
        )
    }
}
