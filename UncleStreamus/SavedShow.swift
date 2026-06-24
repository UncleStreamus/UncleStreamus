import Foundation
import SwiftData

@Model
final class SavedShow {
    var showDate: String = ""
    var venue: String = ""
    var soundcheck: String?
    var note: String?
    var showInfo: String = ""
    var setlistData: Data = Data()
    var acronymsData: Data = Data()
    var url: String = ""

    var isFavorite: Bool = false
    var listenedAt: Date?
    var deviceName: String?

    // Location fields
    var city: String?
    var state: String?
    var country: String?

    // Period and tour fields
    var period: String?
    var tour: String?

    // Band lineup: "{h3 title}\n{members}" or nil
    var bandInfo: String?

    init(showDate: String, venue: String, soundcheck: String?, note: String?,
         showInfo: String, setlistData: Data, acronymsData: Data, url: String,
         isFavorite: Bool = false, listenedAt: Date? = nil, deviceName: String? = nil,
         city: String? = nil, state: String? = nil, country: String? = nil,
         period: String? = nil, tour: String? = nil, bandInfo: String? = nil) {
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
        self.deviceName = deviceName
        self.city = city
        self.state = state
        self.country = country
        self.period = period
        self.tour = tour
        self.bandInfo = bandInfo
    }

    // Decode once and cache; setlistData/acronymsData are write-once so the cache never stales.
    @Transient private var _setlistCache: [String]? = nil
    @Transient private var _acronymsCache: [Acronym]? = nil

    var setlist: [String] {
        if let cached = _setlistCache { return cached }
        let decoded = (try? JSONDecoder().decode([String].self, from: setlistData)) ?? []
        _setlistCache = decoded
        return decoded
    }

    /// Updates the persisted setlist and its in-memory cache together — used by
    /// one-time data migrations so a stale `_setlistCache` can't linger after
    /// `setlistData` changes underneath it.
    func applyMigratedSetlist(_ newSetlist: [String]) {
        setlistData = (try? JSONEncoder().encode(newSetlist)) ?? setlistData
        _setlistCache = newSetlist
    }

    var acronyms: [Acronym] {
        if let cached = _acronymsCache { return cached }
        let decoded = (try? JSONDecoder().decode([Acronym].self, from: acronymsData)) ?? []
        _acronymsCache = decoded
        return decoded
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
            url: url,
            city: city,
            state: state,
            country: country,
            period: period,
            tour: tour,
            bandInfo: bandInfo
        )
    }

    static func from(_ show: FZShow, isFavorite: Bool = false, listenedAt: Date? = nil, deviceName: String? = nil) -> SavedShow {
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
            listenedAt: listenedAt,
            deviceName: deviceName,
            city: show.city,
            state: show.state,
            country: show.country,
            period: show.period,
            tour: show.tour,
            bandInfo: show.bandInfo
        )
    }
}
