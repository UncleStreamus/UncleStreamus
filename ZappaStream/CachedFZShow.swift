import Foundation
import SwiftData

@Model
final class CachedFZShow {
    @Attribute(.unique) var showDate: String

    var venue: String
    var note: String?
    var showInfo: String
    var setlistData: Data
    var acronymsData: Data
    var url: String

    var city: String?
    var state: String?
    var country: String?
    var period: String?
    var tour: String?
    var bandInfo: String?

    // Tracking fields
    var pageFilename: String
    var cachedAt: Date

    init(showDate: String, venue: String, note: String?, showInfo: String,
         setlistData: Data, acronymsData: Data, url: String,
         city: String?, state: String?, country: String?,
         period: String?, tour: String?, bandInfo: String?,
         pageFilename: String, cachedAt: Date = Date()) {
        self.showDate = showDate
        self.venue = venue
        self.note = note
        self.showInfo = showInfo
        self.setlistData = setlistData
        self.acronymsData = acronymsData
        self.url = url
        self.city = city
        self.state = state
        self.country = country
        self.period = period
        self.tour = tour
        self.bandInfo = bandInfo
        self.pageFilename = pageFilename
        self.cachedAt = cachedAt
    }

    var setlist: [String] {
        (try? JSONDecoder().decode([String].self, from: setlistData)) ?? []
    }

    var acronymTuples: [(short: String, full: String)] {
        ((try? JSONDecoder().decode([Acronym].self, from: acronymsData)) ?? []).map { ($0.short, $0.full) }
    }

    func toFZShow() -> FZShow {
        FZShow(
            date: showDate,
            venue: venue,
            soundcheck: nil,
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

    static func from(_ show: FZShow, pageFilename: String) -> CachedFZShow {
        let setlistData = (try? JSONEncoder().encode(show.setlist)) ?? Data()
        let acronymsCodable = show.acronyms.map { Acronym(short: $0.short, full: $0.full) }
        let acronymsData = (try? JSONEncoder().encode(acronymsCodable)) ?? Data()

        return CachedFZShow(
            showDate: show.date,
            venue: show.venue,
            note: show.note,
            showInfo: show.showInfo,
            setlistData: setlistData,
            acronymsData: acronymsData,
            url: show.url,
            city: show.city,
            state: show.state,
            country: show.country,
            period: show.period,
            tour: show.tour,
            bandInfo: show.bandInfo,
            pageFilename: pageFilename
        )
    }
}
