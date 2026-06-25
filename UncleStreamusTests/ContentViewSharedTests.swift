import XCTest
@testable import UncleStreamus

final class ContentViewSharedTests: XCTestCase {

    // MARK: - Helpers

    private func makeInfo(date: String? = nil,
                          city: String? = nil,
                          state: String? = nil,
                          artist: String? = nil,
                          trackNumber: String? = nil,
                          trackName: String? = nil,
                          trackDuration: String? = nil) -> ParsedTrackInfo {
        ParsedTrackInfo(
            date: date, showTime: nil, city: city, state: state,
            showDuration: nil, source: nil, generation: nil, creator: nil,
            artist: artist, trackNumber: trackNumber, trackName: trackName,
            year: nil, trackDuration: trackDuration, rawTitle: "raw"
        )
    }

    // MARK: - variantDate

    func testVariantDate_none() {
        XCTAssertEqual(variantDate(date: "1980 12 11", showTime: .none), "1980 12 11")
    }

    func testVariantDate_earlyLate() {
        XCTAssertEqual(variantDate(date: "1980 12 11", showTime: .early), "1980 12 11 E")
        XCTAssertEqual(variantDate(date: "1980 12 11", showTime: .late), "1980 12 11 L")
    }

    // MARK: - fxRestorePlan

    func testFXRestorePlan_remember() {
        let plan = fxRestorePlan(variantDate: "X", rememberPerShow: true, persistAcrossShows: false)
        guard case .restore(let d) = plan else { return XCTFail("expected .restore") }
        XCTAssertEqual(d, "X")
    }

    func testFXRestorePlan_resetWhenNotPersisting() {
        guard case .reset = fxRestorePlan(variantDate: "X", rememberPerShow: false, persistAcrossShows: false) else {
            return XCTFail("expected .reset")
        }
    }

    func testFXRestorePlan_keepWhenPersisting() {
        guard case .keep = fxRestorePlan(variantDate: "X", rememberPerShow: false, persistAcrossShows: true) else {
            return XCTFail("expected .keep")
        }
    }

    // MARK: - decideWhatsNew

    private func notes(current: Bool, empty: Bool = false) -> ReleaseNotes {
        ReleaseNotes(build: "200", version: "1.0",
                     new: empty ? [] : ["A new thing"], improved: [], fixed: [],
                     current: current)
    }

    func testDecideWhatsNew_firstInstallShowsWelcome() {
        let r = decideWhatsNew(currentBuild: "100", lastSeenBuild: "", hasSeenWelcome: false) { nil }
        XCTAssertEqual(r.buildToRecord, "100")
        guard case .showWelcome = r.action else { return XCTFail("expected .showWelcome") }
    }

    func testDecideWhatsNew_firstInstallWelcomeSeen() {
        let r = decideWhatsNew(currentBuild: "100", lastSeenBuild: "", hasSeenWelcome: true) { nil }
        XCTAssertEqual(r.buildToRecord, "100")
        guard case .nothing = r.action else { return XCTFail("expected .nothing") }
    }

    func testDecideWhatsNew_changedBuildWithCurrentNotes() {
        let r = decideWhatsNew(currentBuild: "200", lastSeenBuild: "100", hasSeenWelcome: true) {
            self.notes(current: true)
        }
        XCTAssertEqual(r.buildToRecord, "200")
        guard case .showNotes = r.action else { return XCTFail("expected .showNotes") }
    }

    func testDecideWhatsNew_changedBuildWithNonCurrentNotes() {
        let r = decideWhatsNew(currentBuild: "200", lastSeenBuild: "100", hasSeenWelcome: true) {
            self.notes(current: false)
        }
        XCTAssertEqual(r.buildToRecord, "200", "build is recorded even when no popup")
        guard case .nothing = r.action else { return XCTFail("expected .nothing") }
    }

    func testDecideWhatsNew_sameBuildDoesNothing() {
        let r = decideWhatsNew(currentBuild: "200", lastSeenBuild: "200", hasSeenWelcome: true) {
            self.notes(current: true)
        }
        XCTAssertNil(r.buildToRecord)
        guard case .nothing = r.action else { return XCTFail("expected .nothing") }
    }

    func testDecideWhatsNew_emptyCurrentBuildDoesNothing() {
        let r = decideWhatsNew(currentBuild: "", lastSeenBuild: "", hasSeenWelcome: false) { nil }
        XCTAssertNil(r.buildToRecord)
        guard case .nothing = r.action else { return XCTFail("expected .nothing") }
    }

    // MARK: - currentTrackPosition

    func testCurrentTrackPosition_basicMatch() {
        let setlist = ["Intro", "Cosmik Debris", "Montana"]
        XCTAssertEqual(currentTrackPosition(trackName: "Montana", setlist: setlist, after: 0), 3)
    }

    func testCurrentTrackPosition_nilInputs() {
        XCTAssertNil(currentTrackPosition(trackName: nil, setlist: ["A"], after: 0))
        XCTAssertNil(currentTrackPosition(trackName: "A", setlist: nil, after: 0))
    }

    func testCurrentTrackPosition_noMatch() {
        XCTAssertNil(currentTrackPosition(trackName: "Not Present", setlist: ["A", "B"], after: 0))
    }

    func testCurrentTrackPosition_duplicateAdvancesAfterLastPosition() {
        let setlist = ["Improvisation", "Montana", "Improvisation"]
        // From position 1, the second "Improvisation" (index 3) should be chosen.
        XCTAssertEqual(currentTrackPosition(trackName: "Improvisation", setlist: setlist, after: 1), 3)
        // From position 0, the first one (index 1) is chosen.
        XCTAssertEqual(currentTrackPosition(trackName: "Improvisation", setlist: setlist, after: 0), 1)
    }

    // MARK: - ParsedTrackInfo.inferredArtist

    func testInferredArtist_explicitArtistWins() {
        XCTAssertEqual(makeInfo(date: "1968 05 01", artist: "Captain Beefheart").inferredArtist,
                       "Captain Beefheart")
    }

    func testInferredArtist_mothersEra() {
        XCTAssertEqual(makeInfo(date: "1971 06 06").inferredArtist, "The Mothers of Invention")
    }

    func testInferredArtist_bongoFuryEra() {
        XCTAssertEqual(makeInfo(date: "1975 04 01").inferredArtist, "Zappa / Beefheart / Mothers")
    }

    func testInferredArtist_frankZappaEra() {
        XCTAssertEqual(makeInfo(date: "1975 06 01").inferredArtist, "Frank Zappa")
        XCTAssertEqual(makeInfo(date: "1988 03 01").inferredArtist, "Frank Zappa")
    }

    func testInferredArtist_noDateDefaults() {
        XCTAssertEqual(makeInfo().inferredArtist, "Frank Zappa")
    }

    // MARK: - ParsedTrackInfo.merged

    func testMerged_newHasDateReturnsNew() {
        let old = makeInfo(date: "1973 11 07", city: "Boston")
        let new = makeInfo(date: "1974 10 28", trackName: "Stinkfoot")
        let merged = ParsedTrackInfo.merged(new: new, previous: old)
        XCTAssertEqual(merged.date, "1974 10 28")
    }

    func testMerged_nilPreviousReturnsNew() {
        let new = makeInfo(trackName: "Bare Title")
        let merged = ParsedTrackInfo.merged(new: new, previous: nil)
        XCTAssertEqual(merged.trackName, "Bare Title")
        XCTAssertNil(merged.date)
    }

    func testMerged_preservesShowMetadataWhenNewHasNoDate() {
        let old = makeInfo(date: "1973 11 07", city: "Boston", state: "MA",
                           artist: "Frank Zappa", trackNumber: "01", trackDuration: "3:30")
        let new = makeInfo(trackNumber: "01", trackName: "Cosmik Debris")
        let merged = ParsedTrackInfo.merged(new: new, previous: old)
        XCTAssertEqual(merged.date, "1973 11 07")
        XCTAssertEqual(merged.city, "Boston")
        XCTAssertEqual(merged.trackName, "Cosmik Debris")
        // Same track number → preserve previous duration.
        XCTAssertEqual(merged.trackDuration, "3:30")
    }

    func testMerged_clearsDurationWhenTrackNumberChanges() {
        let old = makeInfo(date: "1973 11 07", trackNumber: "01", trackDuration: "3:30")
        let new = makeInfo(trackNumber: "02", trackName: "Montana")
        let merged = ParsedTrackInfo.merged(new: new, previous: old)
        XCTAssertEqual(merged.trackNumber, "02")
        XCTAssertNil(merged.trackDuration, "duration cleared so new Icecast value is used")
    }

    // MARK: - ParsedTrackInfo.fillingLocation

    func testFillingLocation_fillsWhenMissing() {
        let filled = makeInfo(date: "1973 11 07").fillingLocation(city: "Boston", state: "MA")
        XCTAssertEqual(filled.city, "Boston")
        XCTAssertEqual(filled.state, "MA")
    }

    func testFillingLocation_keepsExisting() {
        let info = makeInfo(date: "1973 11 07", city: "Helsinki", state: "FI")
        let filled = info.fillingLocation(city: "Boston", state: "MA")
        XCTAssertEqual(filled.city, "Helsinki")
        XCTAssertEqual(filled.state, "FI")
    }
}
