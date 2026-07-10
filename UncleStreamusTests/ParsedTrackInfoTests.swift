import XCTest
@testable import UncleStreamus

final class ParsedTrackInfoTests: XCTestCase {

    // MARK: - Full Bracket Format

    func testFullBracket_basicFields() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA] Frank Zappa: (01) Cosmik Debris (1973) [3:30]")
        XCTAssertEqual(info.date, "1973 11 07")
        XCTAssertEqual(info.city, "Boston")
        XCTAssertEqual(info.state, "MA")
        XCTAssertEqual(info.artist, "Frank Zappa")
        XCTAssertEqual(info.trackNumber, "01")
        XCTAssertEqual(info.trackName, "Cosmik Debris")
        XCTAssertEqual(info.year, "1973")
        XCTAssertEqual(info.trackDuration, "3:30")
    }

    func testFullBracket_showTimeParsed() {
        let info = ParsedTrackInfo.parse("[1973 11 07 (E) Boston MA] Frank Zappa: (01) Pygmy Twylyte (1973) [3:00]")
        XCTAssertEqual(info.date, "1973 11 07")
        XCTAssertEqual(info.showTime, "(E)")
    }

    func testFullBracket_NYCSpecialCase() {
        let info = ParsedTrackInfo.parse("[1974 10 28 NYC] Frank Zappa: (01) Stinkfoot (1974) [4:00]")
        XCTAssertEqual(info.city, "New York City")
        XCTAssertEqual(info.state, "NY")
    }

    func testFullBracket_combinedSourceSBDAUD() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA SBD-AUD] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.source, "SBD-AUD")
    }

    func testFullBracket_combinedSourceAUDSBD() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA AUD-SBD] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.source, "AUD-SBD")
    }

    func testFullBracket_singleSourceAUD() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA AUD] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.source, "AUD")
    }

    func testFullBracket_singleSourceSBD() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA SBD] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.source, "SBD")
    }

    func testFullBracket_generationGEN() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA SBD GEN] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.generation, "GEN")
    }

    func testFullBracket_generationMC() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA SBD MC] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.generation, "MC")
    }

    func testFullBracket_creatorExtracted() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA SBD (JohnDoe)] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.creator, "JohnDoe")
    }

    func testFullBracket_showDuration() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA 2.5] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.showDuration, "2.5")
    }

    func testFullBracket_noYearAnnotation_trackNameExtracted() {
        let info = ParsedTrackInfo.parse("[1988 02 22 Kansas City MO SBD] Frank Zappa: (01) Stairway To Heaven [3:30]")
        XCTAssertEqual(info.trackName, "Stairway To Heaven")
        XCTAssertNil(info.year)
    }

    func testFullBracket_multiWordCity() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Los Angeles CA] Frank Zappa: (01) Montana (1973) [5:00]")
        XCTAssertEqual(info.city, "Los Angeles")
        XCTAssertEqual(info.state, "CA")
    }

    func testFullBracket_rawTitlePreserved() {
        let title = "[1973 11 07 Boston MA] Frank Zappa: (01) Montana (1973) [5:00]"
        let info = ParsedTrackInfo.parse(title)
        XCTAssertEqual(info.rawTitle, title)
    }

    func testFullBracket_icecastPrefix() {
        // [ICECAST] prefix must not swallow the date bracket
        let info = ParsedTrackInfo.parse("[ICECAST] [1988 03 25 Uniondale NY 154.04 AUD MC (PvL-walk)] Frank Zappa: (16) Pound For A Brown (1988) [0:10:43]")
        XCTAssertEqual(info.date, "1988 03 25")
        XCTAssertEqual(info.city, "Uniondale")
        XCTAssertEqual(info.state, "NY")
        XCTAssertEqual(info.artist, "Frank Zappa")
        XCTAssertEqual(info.trackNumber, "16")
        XCTAssertEqual(info.source, "AUD")
        XCTAssertEqual(info.generation, "MC")
        XCTAssertEqual(info.creator, "PvL-walk")
    }

    // MARK: - Simple Date Format

    func testSimpleDate_basicFields() {
        let info = ParsedTrackInfo.parse("1973 11 07 Boston MA - 01 Intro [0:03:30]")
        XCTAssertEqual(info.date, "1973 11 07")
        XCTAssertEqual(info.city, "Boston")
        XCTAssertEqual(info.state, "MA")
        XCTAssertEqual(info.trackNumber, "01")
        XCTAssertEqual(info.trackName, "Intro")
    }

    func testSimpleDate_trackDurationExtracted() {
        let info = ParsedTrackInfo.parse("1973 11 07 Boston MA - 01 Intro [0:03:30]")
        XCTAssertEqual(info.trackDuration, "0:03:30")
    }

    func testSimpleDate_earlyShow() {
        let info = ParsedTrackInfo.parse("1973 11 07 Boston MA (E) - 01 Intro [0:03:30]")
        XCTAssertEqual(info.showTime, "(E)")
    }

    func testSimpleDate_lateShow() {
        let info = ParsedTrackInfo.parse("1973 11 07 Boston MA (L) - 01 Intro [0:03:30]")
        XCTAssertEqual(info.showTime, "(L)")
    }

    func testSimpleDate_NYCSpecialCase() {
        let info = ParsedTrackInfo.parse("1974 10 28 NYC - 01 Stinkfoot [4:00]")
        XCTAssertEqual(info.city, "New York City")
        XCTAssertEqual(info.state, "NY")
    }

    func testSimpleDate_multiWordTrackName() {
        let info = ParsedTrackInfo.parse("1979 01 15 New York NY - 15 Sleep Dirt [4:20]")
        XCTAssertEqual(info.trackName, "Sleep Dirt")
        XCTAssertEqual(info.city, "New York")
        XCTAssertEqual(info.state, "NY")
    }

    // MARK: - Numbered Track Format (FLAC Vorbis)

    func testNumberedTrack_trackNumberAndName() {
        let info = ParsedTrackInfo.parse("01 Intro")
        XCTAssertEqual(info.trackNumber, "01")
        XCTAssertEqual(info.trackName, "Intro")
        XCTAssertNil(info.date)
        XCTAssertNil(info.city)
    }

    func testNumberedTrack_multiWordName() {
        let info = ParsedTrackInfo.parse("15 Sleep Dirt")
        XCTAssertEqual(info.trackNumber, "15")
        XCTAssertEqual(info.trackName, "Sleep Dirt")
    }

    func testNumberedTrack_noDateFields() {
        let info = ParsedTrackInfo.parse("07 Montana")
        XCTAssertNil(info.date)
        XCTAssertNil(info.artist)
        XCTAssertNil(info.year)
    }

    // MARK: - Bare Name Format (Fallback)

    func testBareName_usedAsFallback() {
        let info = ParsedTrackInfo.parse("When The Lie's So Big")
        XCTAssertEqual(info.trackName, "When The Lie's So Big")
        XCTAssertNil(info.date)
        XCTAssertNil(info.trackNumber)
    }

    func testBareName_noStructuredFields() {
        let info = ParsedTrackInfo.parse("Cosmik Debris")
        XCTAssertEqual(info.trackName, "Cosmik Debris")
        XCTAssertNil(info.artist)
        XCTAssertNil(info.state)
    }

    func testBareName_notFlaggedNonZappa() {
        let info = ParsedTrackInfo.parse("Cosmik Debris")
        XCTAssertFalse(info.isNonZappaShow)
    }

    // MARK: - Non-Zappa Broadcast Fallback

    func testNonZappa_reportedTrebuchetLine() {
        let info = ParsedTrackInfo.parse("08 11 15 Trebuchet 03 Let It Rock [0:04:13]")
        XCTAssertEqual(info.artist, "Trebuchet")
        XCTAssertEqual(info.trackNumber, "03")
        XCTAssertEqual(info.trackName, "Let It Rock")
        XCTAssertEqual(info.trackDuration, "0:04:13")
        XCTAssertEqual(info.date, "2008 11 15")
        XCTAssertTrue(info.isNonZappaShow)
    }

    func testNonZappa_fourDigitYearVariant() {
        let info = ParsedTrackInfo.parse("2008 11 15 Trebuchet 03 Let It Rock [0:04:13]")
        XCTAssertEqual(info.artist, "Trebuchet")
        XCTAssertEqual(info.trackNumber, "03")
        XCTAssertEqual(info.trackName, "Let It Rock")
        XCTAssertEqual(info.date, "2008 11 15")
        XCTAssertTrue(info.isNonZappaShow)
    }

    func testNonZappa_multiWordBandName() {
        let info = ParsedTrackInfo.parse("08 11 15 The Mighty Reeds 02 Peaches [3:00]")
        XCTAssertEqual(info.artist, "The Mighty Reeds")
        XCTAssertEqual(info.trackNumber, "02")
        XCTAssertEqual(info.trackName, "Peaches")
        XCTAssertEqual(info.date, "2008 11 15")
        XCTAssertTrue(info.isNonZappaShow)
    }

    func testNonZappa_noDateBandTrackName() {
        let info = ParsedTrackInfo.parse("Trebuchet 03 Let It Rock [4:13]")
        XCTAssertEqual(info.artist, "Trebuchet")
        XCTAssertEqual(info.trackNumber, "03")
        XCTAssertEqual(info.trackName, "Let It Rock")
        XCTAssertNil(info.date)
        XCTAssertTrue(info.isNonZappaShow)
    }

    func testNonZappa_dashedLineNotMisparsed() {
        // No Zappa date + a dash → the Zappa dash branch must be skipped and this
        // falls to the best-effort fallback (rather than mis-parsing the dash).
        let info = ParsedTrackInfo.parse("Some Band - Some Song [3:20]")
        XCTAssertTrue(info.isNonZappaShow)
        XCTAssertNotNil(info.trackName)
        XCTAssertFalse(info.trackName?.isEmpty ?? true)
    }

    func testNonZappa_unstructuredFullLineNeverBlank() {
        let info = ParsedTrackInfo.parse("Just A Jam Session [10:00]")
        XCTAssertTrue(info.isNonZappaShow)
        XCTAssertEqual(info.trackName, "Just A Jam Session")
    }

    func testNonZappa_zappaSimpleNotFlagged() {
        let info = ParsedTrackInfo.parse("1973 11 07 Boston MA - 01 Intro [0:03:30]")
        XCTAssertEqual(info.trackName, "Intro")
        XCTAssertFalse(info.isNonZappaShow)
    }

    func testNonZappa_fullBracketNotFlagged() {
        let info = ParsedTrackInfo.parse("[1973 11 07 Boston MA] Frank Zappa: (01) Cosmik Debris (1973) [3:30]")
        XCTAssertEqual(info.trackName, "Cosmik Debris")
        XCTAssertFalse(info.isNonZappaShow)
    }

    // MARK: - tracksMatch

    func testTracksMatch_exactMatch() {
        XCTAssertTrue(ParsedTrackInfo.tracksMatch("Montana", "Montana"))
    }

    func testTracksMatch_caseInsensitive() {
        XCTAssertTrue(ParsedTrackInfo.tracksMatch("montana", "Montana"))
    }

    func testTracksMatch_synonymPoundAndStringQuartet() {
        XCTAssertTrue(ParsedTrackInfo.tracksMatch("Pound For A Brown", "The String Quartet"))
    }

    func testTracksMatch_synonymStringQuartetAndSleeping() {
        XCTAssertTrue(ParsedTrackInfo.tracksMatch("String Quartet", "Sleeping In a Jar"))
    }

    func testTracksMatch_noMatchAcrossGroups() {
        // Pound and Sleeping share String Quartet as bridge but do NOT directly match each other
        XCTAssertFalse(ParsedTrackInfo.tracksMatch("A Pound For a Brown", "Sleeping In a Jar"))
    }

    func testTracksMatch_troubleEverydaySynonym() {
        XCTAssertTrue(ParsedTrackInfo.tracksMatch("More Trouble Every Day", "Trouble Every Day"))
    }

    func testTracksMatch_differentNames() {
        XCTAssertFalse(ParsedTrackInfo.tracksMatch("Montana", "Cosmik Debris"))
    }

    func testTracksMatch_normalizedPoundName() {
        // "Pound For A Brown" normalizes to "A Pound For a Brown", which is in the synonym group
        XCTAssertTrue(ParsedTrackInfo.tracksMatch("Pound For A Brown", "A Pound For a Brown"))
    }

    // MARK: - normalizeTrackName

    func testNormalizeTrackName_knownException() {
        XCTAssertEqual(ParsedTrackInfo.normalizeTrackName("Pound For A Brown"), "A Pound For a Brown")
    }

    func testNormalizeTrackName_anotherException() {
        XCTAssertEqual(ParsedTrackInfo.normalizeTrackName("More Trouble Every Day"), "Trouble Every Day")
    }

    func testNormalizeTrackName_unknownPassthrough() {
        XCTAssertEqual(ParsedTrackInfo.normalizeTrackName("Montana"), "Montana")
    }

    func testNormalizeTrackName_nil() {
        XCTAssertNil(ParsedTrackInfo.normalizeTrackName(nil))
    }

    // MARK: - normalizePluralForm

    func testNormalizePluralForm_ations() {
        XCTAssertEqual(ParsedTrackInfo.normalizePluralForm("Improvisations in Q"), "Improvisation in Q")
    }

    func testNormalizePluralForm_ies() {
        XCTAssertEqual(ParsedTrackInfo.normalizePluralForm("Discoveries"), "Discovery")
    }

    func testNormalizePluralForm_trailingAsterisk() {
        XCTAssertEqual(ParsedTrackInfo.normalizePluralForm("Montana*"), "Montana")
    }

    func testNormalizePluralForm_trailingDot() {
        XCTAssertEqual(ParsedTrackInfo.normalizePluralForm("Montana."), "Montana")
    }

    func testNormalizePluralForm_alreadySingular() {
        XCTAssertEqual(ParsedTrackInfo.normalizePluralForm("Montana"), "Montana")
    }

    func testNormalizePluralForm_multipleTrailingAsterisks() {
        XCTAssertEqual(ParsedTrackInfo.normalizePluralForm("Montana**"), "Montana")
    }
}
