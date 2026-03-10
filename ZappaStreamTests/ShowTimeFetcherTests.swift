import XCTest
@testable import ZappaStream

final class ShowTimeFetcherTests: XCTestCase {

    // MARK: - ShowTime.init

    func testShowTime_earlyParenE() {
        XCTAssertEqual(ShowTime(from: "(E)"), .early)
    }

    func testShowTime_lateParenL() {
        XCTAssertEqual(ShowTime(from: "(L)"), .late)
    }

    func testShowTime_earlyString() {
        XCTAssertEqual(ShowTime(from: "Early show"), .early)
    }

    func testShowTime_lateUppercase() {
        XCTAssertEqual(ShowTime(from: "LATE"), .late)
    }

    func testShowTime_nil() {
        XCTAssertEqual(ShowTime(from: nil), .none)
    }

    func testShowTime_empty() {
        XCTAssertEqual(ShowTime(from: ""), .none)
    }

    func testShowTime_caseInsensitive() {
        XCTAssertEqual(ShowTime(from: "early"), .early)
    }

    func testShowTime_lateParenLShort() {
        XCTAssertEqual(ShowTime(from: "(L"), .late)
    }

    // MARK: - ShowTime.displayName

    func testShowTimeDisplayName_early() {
        XCTAssertEqual(ShowTime.early.displayName, "Early show")
    }

    func testShowTimeDisplayName_late() {
        XCTAssertEqual(ShowTime.late.displayName, "Late show")
    }

    func testShowTimeDisplayName_none() {
        XCTAssertEqual(ShowTime.none.displayName, "")
    }

    // MARK: - FZShowsFetcher.exceptions

    func testException_1972_12_31_searchDate() {
        let exc = FZShowsFetcher.exceptions["1972 12 31"]
        XCTAssertNotNil(exc)
        XCTAssertEqual(exc?.searchDate, "1972 11 11")
    }

    func testException_1972_12_31_noSectionKeywords() {
        let exc = FZShowsFetcher.exceptions["1972 12 31"]
        XCTAssertNil(exc?.sectionKeywords)
    }

    func testException_1970_11_13_E_sectionKeywords() {
        let exc = FZShowsFetcher.exceptions["1970 11 13 E"]
        XCTAssertEqual(exc?.sectionKeywords, ["Tape 1"])
    }

    func testException_1970_11_14_L_sectionKeywords() {
        let exc = FZShowsFetcher.exceptions["1970 11 14 L"]
        XCTAssertEqual(exc?.sectionKeywords, ["Tape 2"])
    }

    func testException_1970_11_13_L_sectionKeywords() {
        let exc = FZShowsFetcher.exceptions["1970 11 13 L"]
        XCTAssertEqual(exc?.sectionKeywords, ["Tape 2"])
    }

    func testException_1970_05_08_searchDate() {
        let exc = FZShowsFetcher.exceptions["1970 05 08"]
        XCTAssertEqual(exc?.searchDate, "1970 05 08 or 09")
        XCTAssertNil(exc?.sectionKeywords)
    }

    func testException_1970_05_09_searchDate() {
        let exc = FZShowsFetcher.exceptions["1970 05 09"]
        XCTAssertEqual(exc?.searchDate, "1970 05 08 or 09")
    }

    func testException_nonExistent_nil() {
        XCTAssertNil(FZShowsFetcher.exceptions["2000 01 01"])
    }

    func testException_1972_12_12_wrongDate() {
        let exc = FZShowsFetcher.exceptions["1972 12 12"]
        XCTAssertEqual(exc?.searchDate, "1972 12 09")
    }

    // MARK: - String.decodeHTMLEntities

    func testDecodeHTMLEntities_amp() {
        XCTAssertEqual("Bread &amp; Butter".decodeHTMLEntities(), "Bread & Butter")
    }

    func testDecodeHTMLEntities_lt() {
        XCTAssertEqual("5 &lt; 10".decodeHTMLEntities(), "5 < 10")
    }

    func testDecodeHTMLEntities_gt() {
        XCTAssertEqual("10 &gt; 5".decodeHTMLEntities(), "10 > 5")
    }

    func testDecodeHTMLEntities_quot() {
        XCTAssertEqual("Say &quot;hello&quot;".decodeHTMLEntities(), "Say \"hello\"")
    }

    func testDecodeHTMLEntities_apos() {
        XCTAssertEqual("Rock &apos;n Roll".decodeHTMLEntities(), "Rock 'n Roll")
    }

    func testDecodeHTMLEntities_numeric39() {
        XCTAssertEqual("It&#39;s alive".decodeHTMLEntities(), "It's alive")
    }

    func testDecodeHTMLEntities_nbsp() {
        XCTAssertEqual("Hello&nbsp;World".decodeHTMLEntities(), "Hello World")
    }

    func testDecodeHTMLEntities_ndash() {
        XCTAssertEqual("2000&ndash;2001".decodeHTMLEntities(), "2000–2001")
    }

    func testDecodeHTMLEntities_mdash() {
        XCTAssertEqual("This&mdash;That".decodeHTMLEntities(), "This—That")
    }

    func testDecodeHTMLEntities_combined() {
        XCTAssertEqual("&lt;b&gt;Hello &amp; World&lt;/b&gt;".decodeHTMLEntities(), "<b>Hello & World</b>")
    }

    func testDecodeHTMLEntities_noEntities() {
        XCTAssertEqual("Plain text".decodeHTMLEntities(), "Plain text")
    }

    // MARK: - FZShowsFetcher.parseSetlist

    func testParseSetlist_simpleCommas() {
        let result = FZShowsFetcher.parseSetlist("Montana, Cosmik Debris, Camarillo Brillo")
        XCTAssertEqual(result, ["Montana", "Cosmik Debris", "Camarillo Brillo"])
    }

    func testParseSetlist_commaInsideParens_notSplit() {
        let result = FZShowsFetcher.parseSetlist("Inca Roads (incl. Dupree's Paradise), King Kong")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Inca Roads (incl. Dupree's Paradise)")
        XCTAssertEqual(result[1], "King Kong")
    }

    func testParseSetlist_commaInsideBrackets_notSplit() {
        let result = FZShowsFetcher.parseSetlist("Medley [parts 1, 2, 3], Broken Hearts Are For Assholes")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Medley [parts 1, 2, 3]")
        XCTAssertEqual(result[1], "Broken Hearts Are For Assholes")
    }

    func testParseSetlist_nestedBrackets_resetDepth() {
        let result = FZShowsFetcher.parseSetlist("Song [parts in ZA, [FZPTMOFZ]], Next Song Rocks")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Song [parts in ZA, [FZPTMOFZ]]")
        XCTAssertEqual(result[1], "Next Song Rocks")
    }

    func testParseSetlist_shortEntriesFiltered() {
        let result = FZShowsFetcher.parseSetlist("Montana, ok, Cosmik Debris")
        XCTAssertFalse(result.contains("ok"))
        XCTAssertTrue(result.contains("Montana"))
        XCTAssertTrue(result.contains("Cosmik Debris"))
    }

    func testParseSetlist_emptyString() {
        let result = FZShowsFetcher.parseSetlist("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseSetlist_singleSong() {
        let result = FZShowsFetcher.parseSetlist("Montana")
        XCTAssertEqual(result, ["Montana"])
    }

    func testParseSetlist_whitespaceTrimmingAroundEntries() {
        let result = FZShowsFetcher.parseSetlist("  Montana  ,  Cosmik Debris  ")
        XCTAssertEqual(result[0], "Montana")
        XCTAssertEqual(result[1], "Cosmik Debris")
    }

    // MARK: - parseShowFromHTML

    func testParseShowFromHTML_minimalHTML_returnsShow() {
        let html = """
        <h4>1973 11 07 - Auditorium Theater, Chicago, IL</h4>
        <h6>90 min, SBD, A</h6>
        <p class="setlist">Montana, Cosmik Debris, Camarillo Brillo</p>
        <h4>1973 11 08 - Another Venue</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertEqual(show?.venue, "Auditorium Theater, Chicago, IL")
        XCTAssertEqual(show?.showInfo, "90 min, SBD, A")
        XCTAssertEqual(show?.setlist.count, 3)
        XCTAssertEqual(show?.setlist[0], "Montana")
    }

    func testParseShowFromHTML_dateNotFound_returnsNil() {
        let html = "<h4>1999 01 01 - Some Venue</h4><h6>info</h6>"
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNil(show)
    }

    func testParseShowFromHTML_earlyShowSection() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h5>Early</h5>
        <h6>60 min, SBD, A</h6>
        <p class="setlist">Montana, Cosmik Debris, Long Song Title</p>
        <h5>Late</h5>
        <h6>70 min, AUD, B</h6>
        <p class="setlist">King Kong, Camarillo Brillo, Another Long Song</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .early, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertTrue(show?.setlist.contains("Montana") ?? false)
        XCTAssertFalse(show?.setlist.contains("King Kong") ?? true)
    }

    func testParseShowFromHTML_acronymExtraction() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist"><acronym title="Black Napkins">BN</acronym>, Montana</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertNotNil(show)
        XCTAssertEqual(show?.acronyms.count, 1)
        XCTAssertEqual(show?.acronyms.first?.short, "BN")
        XCTAssertEqual(show?.acronyms.first?.full, "Black Napkins")
    }

    func testParseShowFromHTML_htmlEntitiesDecoded() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist">Bread &amp; Butter Song, Montana</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertTrue(show?.setlist.first?.contains("&") ?? false)
    }

    func testParseShowFromHTML_noteExtracted() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="note">This is a note about the show.</p>
        <p class="setlist">Montana, Cosmik Debris, Long Name Song</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertEqual(show?.note, "This is a note about the show.")
    }

    func testParseShowFromHTML_periodFromFilename() {
        let html = """
        <h4>1973 11 07 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist">Montana, Cosmik Debris, Long Name Song</p>
        <h4>1973 11 08 - Next</h4>
        """
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "73.html",
            searchDate: "1973 11 07", originalDate: "1973 11 07",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        XCTAssertEqual(show?.period, "1973: MOI with J.L. Ponty")
    }

    func testParseShowFromHTML_originalDatePreserved() {
        let html = """
        <h4>1972 11 11 - Theater, Chicago, IL</h4>
        <h6>info</h6>
        <p class="setlist">Montana, Cosmik Debris, Long Name Song</p>
        <h4>1972 11 12 - Next</h4>
        """
        // Exception: metadata says 1972 12 31 but search uses 1972 11 11
        let show = FZShowsFetcher.parseShowFromHTML(
            html: html, filename: "72.html",
            searchDate: "1972 11 11", originalDate: "1972 12 31",
            showTime: .none, sectionKeywords: nil, url: "https://example.com"
        )
        // date should be originalDate, not searchDate
        XCTAssertEqual(show?.date, "1972 12 31")
    }
}
