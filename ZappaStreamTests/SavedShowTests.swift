import XCTest
@testable import ZappaStream

final class SavedShowTests: XCTestCase {

    private func makeFZShow(
        date: String = "1973 11 07",
        venue: String = "Auditorium Theater, Chicago, IL",
        soundcheck: String? = nil,
        note: String? = nil,
        showInfo: String = "90 min, SBD, A",
        setlist: [String] = ["Montana", "Cosmik Debris"],
        acronyms: [(short: String, full: String)] = [],
        url: String = "https://example.com",
        city: String? = "Chicago",
        state: String? = "IL",
        country: String? = "USA",
        period: String? = "1973: MOI with J.L. Ponty",
        tour: String? = "Fall 1973 tour"
    ) -> FZShow {
        FZShow(
            date: date, venue: venue, soundcheck: soundcheck, note: note,
            showInfo: showInfo, setlist: setlist, acronyms: acronyms, url: url,
            city: city, state: state, country: country, period: period, tour: tour,
            bandInfo: nil
        )
    }

    // MARK: - SavedShow.from(_:)

    func testFrom_dateFieldMapped() {
        let saved = SavedShow.from(makeFZShow(date: "1973 11 07"))
        XCTAssertEqual(saved.showDate, "1973 11 07")
    }

    func testFrom_venueFieldMapped() {
        let saved = SavedShow.from(makeFZShow(venue: "Roxy, Los Angeles, CA"))
        XCTAssertEqual(saved.venue, "Roxy, Los Angeles, CA")
    }

    func testFrom_showInfoMapped() {
        let saved = SavedShow.from(makeFZShow(showInfo: "90 min, SBD, A"))
        XCTAssertEqual(saved.showInfo, "90 min, SBD, A")
    }

    func testFrom_optionalFieldsMapped() {
        let saved = SavedShow.from(makeFZShow(soundcheck: "Soundcheck info", note: "A note"))
        XCTAssertEqual(saved.soundcheck, "Soundcheck info")
        XCTAssertEqual(saved.note, "A note")
    }

    func testFrom_optionalFieldsNilWhenAbsent() {
        let saved = SavedShow.from(makeFZShow(soundcheck: nil, note: nil))
        XCTAssertNil(saved.soundcheck)
        XCTAssertNil(saved.note)
    }

    func testFrom_locationFieldsMapped() {
        let saved = SavedShow.from(makeFZShow(city: "Chicago", state: "IL", country: "USA"))
        XCTAssertEqual(saved.city, "Chicago")
        XCTAssertEqual(saved.state, "IL")
        XCTAssertEqual(saved.country, "USA")
    }

    func testFrom_periodAndTourMapped() {
        let saved = SavedShow.from(makeFZShow(period: "1973: MOI", tour: "Fall tour"))
        XCTAssertEqual(saved.period, "1973: MOI")
        XCTAssertEqual(saved.tour, "Fall tour")
    }

    func testFrom_urlMapped() {
        let saved = SavedShow.from(makeFZShow(url: "https://zappateers.com/fzshows/73.html"))
        XCTAssertEqual(saved.url, "https://zappateers.com/fzshows/73.html")
    }

    func testFrom_setlistEncodedAsValidJSON() throws {
        let songs = ["Montana", "Cosmik Debris", "Camarillo Brillo"]
        let saved = SavedShow.from(makeFZShow(setlist: songs))
        let decoded = try JSONDecoder().decode([String].self, from: saved.setlistData)
        XCTAssertEqual(decoded, songs)
    }

    func testFrom_acronymsEncodedAsValidJSON() throws {
        let acronyms: [(short: String, full: String)] = [
            ("BN", "Black Napkins"),
            ("AHR", "Andy's Horrible Racket")
        ]
        let saved = SavedShow.from(makeFZShow(acronyms: acronyms))
        let decoded = try JSONDecoder().decode([Acronym].self, from: saved.acronymsData)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].short, "BN")
        XCTAssertEqual(decoded[0].full, "Black Napkins")
    }

    func testFrom_defaultsNotFavorite() {
        let saved = SavedShow.from(makeFZShow())
        XCTAssertFalse(saved.isFavorite)
    }

    func testFrom_isFavoritePropagated() {
        let saved = SavedShow.from(makeFZShow(), isFavorite: true)
        XCTAssertTrue(saved.isFavorite)
    }

    // MARK: - SavedShow.setlist computed property

    func testSetlistComputedProperty_validData() {
        let saved = SavedShow.from(makeFZShow(setlist: ["Montana", "Cosmik Debris"]))
        XCTAssertEqual(saved.setlist, ["Montana", "Cosmik Debris"])
    }

    func testSetlistComputedProperty_emptySetlist() {
        let saved = SavedShow.from(makeFZShow(setlist: []))
        XCTAssertEqual(saved.setlist, [])
    }

    func testSetlistComputedProperty_corruptData_returnsEmpty() {
        let saved = SavedShow(
            showDate: "1973 11 07", venue: "Test", soundcheck: nil, note: nil,
            showInfo: "info", setlistData: Data("not json".utf8), acronymsData: Data(),
            url: "https://example.com"
        )
        XCTAssertEqual(saved.setlist, [])
    }

    // MARK: - SavedShow.acronyms computed property

    func testAcronymsComputedProperty_validData() {
        let saved = SavedShow.from(makeFZShow(acronyms: [("BN", "Black Napkins")]))
        XCTAssertEqual(saved.acronyms.count, 1)
        XCTAssertEqual(saved.acronyms[0].short, "BN")
        XCTAssertEqual(saved.acronyms[0].full, "Black Napkins")
    }

    func testAcronymsComputedProperty_empty() {
        let saved = SavedShow.from(makeFZShow(acronyms: []))
        XCTAssertEqual(saved.acronyms, [])
    }

    func testAcronymsComputedProperty_corruptData_returnsEmpty() {
        let saved = SavedShow(
            showDate: "1973 11 07", venue: "Test", soundcheck: nil, note: nil,
            showInfo: "info", setlistData: Data(), acronymsData: Data("bad".utf8),
            url: "https://example.com"
        )
        XCTAssertEqual(saved.acronyms, [])
    }

    func testAcronymTuples_correctMapping() {
        let saved = SavedShow.from(makeFZShow(acronyms: [("BN", "Black Napkins"), ("AHR", "Andy's Horrible Racket")]))
        let tuples = saved.acronymTuples
        XCTAssertEqual(tuples.count, 2)
        XCTAssertEqual(tuples[0].short, "BN")
        XCTAssertEqual(tuples[0].full, "Black Napkins")
        XCTAssertEqual(tuples[1].short, "AHR")
    }

    // MARK: - Round-trip toFZShow()

    func testRoundTrip_allFieldsPreserved() {
        let original = makeFZShow(
            date: "1973 11 07",
            venue: "Theater, Chicago, IL",
            soundcheck: "Soundcheck",
            note: "A note",
            showInfo: "90 min, SBD, A",
            setlist: ["Montana", "Cosmik Debris"],
            acronyms: [("BN", "Black Napkins")],
            url: "https://example.com",
            city: "Chicago",
            state: "IL",
            country: "USA",
            period: "1973: MOI",
            tour: "Fall tour"
        )
        let saved = SavedShow.from(original)
        let recovered = saved.toFZShow()

        XCTAssertEqual(recovered.date, original.date)
        XCTAssertEqual(recovered.venue, original.venue)
        XCTAssertEqual(recovered.soundcheck, original.soundcheck)
        XCTAssertEqual(recovered.note, original.note)
        XCTAssertEqual(recovered.showInfo, original.showInfo)
        XCTAssertEqual(recovered.setlist, original.setlist)
        XCTAssertEqual(recovered.url, original.url)
        XCTAssertEqual(recovered.city, original.city)
        XCTAssertEqual(recovered.state, original.state)
        XCTAssertEqual(recovered.country, original.country)
        XCTAssertEqual(recovered.period, original.period)
        XCTAssertEqual(recovered.tour, original.tour)
    }

    func testRoundTrip_acronymsPreserved() {
        let original = makeFZShow(acronyms: [("BN", "Black Napkins")])
        let saved = SavedShow.from(original)
        let recovered = saved.toFZShow()
        XCTAssertEqual(recovered.acronyms.count, 1)
        XCTAssertEqual(recovered.acronyms[0].short, "BN")
        XCTAssertEqual(recovered.acronyms[0].full, "Black Napkins")
    }

    func testRoundTrip_nilOptionalFieldsPreserved() {
        let original = makeFZShow(soundcheck: nil, note: nil, city: nil, state: nil, country: nil, period: nil, tour: nil)
        let saved = SavedShow.from(original)
        let recovered = saved.toFZShow()
        XCTAssertNil(recovered.soundcheck)
        XCTAssertNil(recovered.note)
        XCTAssertNil(recovered.city)
        XCTAssertNil(recovered.period)
        XCTAssertNil(recovered.tour)
    }
}
