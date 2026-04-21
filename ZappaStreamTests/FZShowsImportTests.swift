import XCTest
@testable import ZappaStream

/// Network integration tests: downloads each zappateers.com HTML page and validates
/// every FZShow produced by importAllShows. Tests hit the live site — run on-demand,
/// not in automated CI unless network access is guaranteed.
///
/// One test method per page so failures are individually identifiable in the test navigator.
final class FZShowsImportTests: XCTestCase {

    // MARK: - Per-page tests

    func testImport_6669()      throws { try runPageTest("6669.html") }
    func testImport_6970()      throws { try runPageTest("6970.html") }
    func testImport_7071()      throws { try runPageTest("7071.html") }
    func testImport_72()        throws { try runPageTest("72.html") }
    func testImport_73()        throws { try runPageTest("73.html") }
    func testImport_7374()      throws { try runPageTest("7374.html") }
    func testImport_75()        throws { try runPageTest("75.html") }
    func testImport_7576()      throws { try runPageTest("7576.html") }
    func testImport_7677()      throws { try runPageTest("7677.html") }
    func testImport_7778()      throws { try runPageTest("7778.html") }
    func testImport_78()        throws { try runPageTest("78.html") }
    func testImport_rehearsals() throws { try runPageTest("rehearsals.html") }
    func testImport_79()        throws { try runPageTest("79.html") }
    func testImport_80()        throws { try runPageTest("80.html") }
    func testImport_80fall()    throws { try runPageTest("80fall.html") }
    func testImport_8182()      throws { try runPageTest("8182.html") }
    func testImport_84()        throws { try runPageTest("84.html") }
    func testImport_88()        throws { try runPageTest("88.html") }
    func testImport_orchestral() throws { try runPageTest("orchestral.html") }
    func testImport_unreleased() throws { try runPageTest("unreleased.html") }

    // MARK: - Helpers

    private static let dateRegex = try! NSRegularExpression(
        pattern: #"^\d{4} \d{2} \d{2}( [EL])?$"#)
    private static let htmlEntityRegex = try! NSRegularExpression(
        pattern: #"&(amp|lt|gt|quot|apos|nbsp|ndash|mdash|#\d+);"#)
    private static let htmlTagRegex = try! NSRegularExpression(
        pattern: #"<[^>]+>"#)

    private func downloadHTML(filename: String) -> String? {
        let urlString = "https://www.zappateers.com/fzshows/\(filename)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(FZShowsFetcher.userAgentString, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data.flatMap { String(data: $0, encoding: .utf8) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 35)
        return result
    }

    private func runPageTest(_ filename: String) throws {
        guard let html = downloadHTML(filename: filename) else {
            throw XCTSkip("Could not download \(filename) — network unavailable?")
        }

        let urlString = "https://www.zappateers.com/fzshows/\(filename)"
        let shows = FZShowsFetcher.importAllShows(fromHTML: html, filename: filename, url: urlString)

        XCTAssertFalse(shows.isEmpty, "\(filename): importAllShows returned no shows")

        var failures: [String] = []
        for show in shows {
            validateShow(show, page: filename, into: &failures)
        }

        if !failures.isEmpty {
            XCTFail("\(filename): \(failures.count) validation failure(s):\n"
                    + failures.joined(separator: "\n"))
        }
    }

    private func validateShow(_ show: FZShow, page: String, into failures: inout [String]) {
        let ctx = "\(page) / \(show.date)"

        // 1. Date key format: "YYYY MM DD" or "YYYY MM DD E" or "YYYY MM DD L"
        let dateNS = NSRange(show.date.startIndex..., in: show.date)
        if Self.dateRegex.firstMatch(in: show.date, range: dateNS) == nil {
            failures.append("\(ctx): invalid date key '\(show.date)'")
        }

        // 2. Venue non-empty
        if show.venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("\(ctx): empty venue")
        }

        // 3. Venue and showInfo contain no raw HTML tags (indicates stripping failed)
        for (label, text) in [("venue", show.venue), ("showInfo", show.showInfo)] {
            let range = NSRange(text.startIndex..., in: text)
            if Self.htmlTagRegex.firstMatch(in: text, range: range) != nil {
                failures.append("\(ctx): HTML tag in \(label): '\(text.prefix(80))'")
            }
        }

        // 4. Setlist non-empty — rehearsals.html may legitimately omit setlists
        if page != "rehearsals.html" && show.setlist.isEmpty {
            failures.append("\(ctx): empty setlist")
        }

        // 5. No residual HTML entities in any text field
        var fieldsToCheck: [(String, String)] = [
            ("venue",    show.venue),
            ("showInfo", show.showInfo),
        ]
        if let note = show.note { fieldsToCheck.append(("note", note)) }
        for (i, song) in show.setlist.enumerated() { fieldsToCheck.append(("setlist[\(i)]", song)) }

        for (label, text) in fieldsToCheck {
            let range = NSRange(text.startIndex..., in: text)
            if Self.htmlEntityRegex.firstMatch(in: text, range: range) != nil {
                failures.append("\(ctx): residual HTML entity in \(label): '\(text.prefix(80))'")
            }
        }

        // 6. Setlist items contain no raw HTML tags
        for (i, song) in show.setlist.enumerated() {
            let range = NSRange(song.startIndex..., in: song)
            if Self.htmlTagRegex.firstMatch(in: song, range: range) != nil {
                failures.append("\(ctx): HTML tag in setlist[\(i)]: '\(song.prefix(80))'")
            }
        }

        // 7. Location: at least one field populated for non-rehearsal pages
        if page != "rehearsals.html" && show.city == nil && show.state == nil && show.country == nil {
            failures.append("\(ctx): no location data (city/state/country all nil)")
        }
    }
}
