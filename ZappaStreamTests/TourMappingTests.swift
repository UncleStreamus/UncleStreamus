import XCTest
@testable import ZappaStream

final class TourMappingTests: XCTestCase {

    // MARK: - getTourPageFilename

    func testTour_1966() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1966, month: 1), "6669.html")
    }

    func testTour_1968() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1968, month: 12), "6669.html")
    }

    func testTour_1969_jan() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1969, month: 1), "6669.html")
    }

    func testTour_1969_aug() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1969, month: 8), "6669.html")
    }

    func testTour_1969_sep_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1969, month: 9))
    }

    func testTour_1969_dec_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1969, month: 12))
    }

    func testTour_1970_jan_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1970, month: 1))
    }

    func testTour_1970_feb() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1970, month: 2), "6970.html")
    }

    func testTour_1970_may() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1970, month: 5), "6970.html")
    }

    func testTour_1970_jun() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1970, month: 6), "7071.html")
    }

    func testTour_1970_dec() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1970, month: 12), "7071.html")
    }

    func testTour_1971() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1971, month: 6), "7071.html")
    }

    func testTour_1972() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1972, month: 9), "72.html")
    }

    func testTour_1973_feb() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1973, month: 2), "73.html")
    }

    func testTour_1973_sep() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1973, month: 9), "73.html")
    }

    func testTour_1973_oct() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1973, month: 10), "7374.html")
    }

    func testTour_1974() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1974, month: 6), "7374.html")
    }

    func testTour_1975_apr() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1975, month: 4), "75.html")
    }

    func testTour_1975_may() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1975, month: 5), "75.html")
    }

    func testTour_1975_jun_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1975, month: 6))
    }

    func testTour_1975_aug_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1975, month: 8))
    }

    func testTour_1975_sep() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1975, month: 9), "7576.html")
    }

    func testTour_1976_mar() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1976, month: 3), "7576.html")
    }

    func testTour_1976_oct() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1976, month: 10), "7677.html")
    }

    func testTour_1977_feb() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1977, month: 2), "7677.html")
    }

    func testTour_1977_mar_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1977, month: 3))
    }

    func testTour_1977_sep() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1977, month: 9), "7778.html")
    }

    func testTour_1978_feb() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1978, month: 2), "7778.html")
    }

    func testTour_1978_aug() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1978, month: 8), "78.html")
    }

    func testTour_1978_dec() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1978, month: 12), "rehearsals.html")
    }

    func testTour_1979() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1979, month: 6), "79.html")
    }

    func testTour_1980_mar() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1980, month: 3), "80.html")
    }

    func testTour_1980_jul() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1980, month: 7), "80.html")
    }

    func testTour_1980_aug() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1980, month: 8), "80fall.html")
    }

    func testTour_1981_sep() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1981, month: 9), "8182.html")
    }

    func testTour_1982_jun() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1982, month: 6), "8182.html")
    }

    func testTour_1983_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1983, month: 6))
    }

    func testTour_1984_jul() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1984, month: 7), "84.html")
    }

    func testTour_1984_dec() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1984, month: 12), "84.html")
    }

    func testTour_1985_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1985, month: 1))
    }

    func testTour_1988_feb() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1988, month: 2), "88.html")
    }

    func testTour_1988_jun() {
        XCTAssertEqual(FZShowsFetcher.getTourPageFilename(year: 1988, month: 6), "88.html")
    }

    func testTour_1988_jul_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1988, month: 7))
    }

    func testTour_1990_nil() {
        XCTAssertNil(FZShowsFetcher.getTourPageFilename(year: 1990, month: 1))
    }

    // MARK: - GeoData.parseLocation

    func testParseLocation_usCityState() {
        let result = GeoData.parseLocation(from: "The Roxy, Los Angeles, CA")
        XCTAssertEqual(result.city, "Los Angeles")
        XCTAssertEqual(result.state, "CA")
        XCTAssertEqual(result.country, "USA")
    }

    func testParseLocation_canadianProvince() {
        let result = GeoData.parseLocation(from: "Maple Leaf Gardens, Toronto, ON")
        XCTAssertEqual(result.city, "Toronto")
        XCTAssertEqual(result.state, "ON")
        XCTAssertEqual(result.country, "Canada")
    }

    func testParseLocation_knownCountry() {
        let result = GeoData.parseLocation(from: "Hammersmith Odeon, London, England")
        XCTAssertEqual(result.city, "London")
        XCTAssertNil(result.state)
        XCTAssertEqual(result.country, "England")
    }

    func testParseLocation_twoComponents_noCity() {
        // Only 2 components: venue+state — city is nil (count < 3)
        let result = GeoData.parseLocation(from: "Los Angeles, CA")
        XCTAssertNil(result.city)
        XCTAssertEqual(result.state, "CA")
        XCTAssertEqual(result.country, "USA")
    }

    func testParseLocation_singleComponent_returnsCityFallback() {
        let result = GeoData.parseLocation(from: "SomeVenue")
        XCTAssertEqual(result.city, "SomeVenue")
        XCTAssertNil(result.state)
        XCTAssertNil(result.country)
    }

    func testParseLocation_singleComponent_knownCountry() {
        let result = GeoData.parseLocation(from: "England")
        XCTAssertNil(result.city)
        XCTAssertNil(result.state)
        XCTAssertEqual(result.country, "England")
    }

    func testParseLocation_dc() {
        let result = GeoData.parseLocation(from: "Constitution Hall, Washington, DC")
        XCTAssertEqual(result.state, "DC")
        XCTAssertEqual(result.country, "USA")
    }

    func testParseLocation_germany() {
        let result = GeoData.parseLocation(from: "Alte Oper, Frankfurt, West Germany")
        XCTAssertEqual(result.city, "Frankfurt")
        XCTAssertNil(result.state)
        XCTAssertEqual(result.country, "West Germany")
    }

    // MARK: - GeoData.periodName

    func testPeriodName_6669() {
        XCTAssertEqual(GeoData.periodName(forFilename: "6669.html"), "1966-1969: The Sixties")
    }

    func testPeriodName_88() {
        XCTAssertEqual(GeoData.periodName(forFilename: "88.html"), "1988: The last tour")
    }

    func testPeriodName_unknown_nil() {
        XCTAssertNil(GeoData.periodName(forFilename: "unknown.html"))
    }

    func testPeriodName_rehearsals() {
        XCTAssertEqual(GeoData.periodName(forFilename: "rehearsals.html"), "Pre-tour Rehearsals")
    }

    func testPeriodName_7374() {
        XCTAssertEqual(GeoData.periodName(forFilename: "7374.html"), "1973-1974: Roxy & Elsewhere")
    }

    // MARK: - GeoData static sets

    func testUSStateAbbreviations_containsDC() {
        XCTAssertTrue(GeoData.usStateAbbreviations.contains("DC"))
    }

    func testUSStateAbbreviations_count() {
        // 50 states + DC = 51
        XCTAssertEqual(GeoData.usStateAbbreviations.count, 51)
    }

    func testUSStateAbbreviations_containsCA() {
        XCTAssertTrue(GeoData.usStateAbbreviations.contains("CA"))
    }

    func testUSStateAbbreviations_containsNY() {
        XCTAssertTrue(GeoData.usStateAbbreviations.contains("NY"))
    }

    func testCanadianProvinces_containsBC() {
        XCTAssertTrue(GeoData.canadianProvinceAbbreviations.contains("BC"))
    }

    func testCanadianProvinces_containsON() {
        XCTAssertTrue(GeoData.canadianProvinceAbbreviations.contains("ON"))
    }

    func testCanadianProvinces_containsQC() {
        XCTAssertTrue(GeoData.canadianProvinceAbbreviations.contains("QC"))
    }
}
