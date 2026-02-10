import Foundation

// MARK: - HTML Entity Decoding

extension String {
    /// Decodes common HTML entities like &amp; &lt; &gt; &quot; etc.
    func decodeHTMLEntities() -> String {
        var result = self
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}

struct FZShow {
    let date: String
    let venue: String
    let soundcheck: String?
    let note: String?
    let showInfo: String
    let setlist: [String]
    let acronyms: [(short: String, full: String)]
    let url: String

    // Location fields
    let city: String?
    let state: String?
    let country: String?

    // Period and tour fields
    let period: String?
    let tour: String?
}

/// Represents Early/Late show designation
enum ShowTime {
    case early
    case late
    case none

    init(from string: String?) {
        guard let s = string?.uppercased() else {
            self = .none
            return
        }
        if s.contains("(E)") || s.contains("(E") || s.contains("EARLY") {
            self = .early
        } else if s.contains("(L)") || s.contains("(L") || s.contains("LATE") {
            self = .late
        } else {
            self = .none
        }
    }

    var displayName: String {
        switch self {
        case .early: return "Early show"
        case .late: return "Late show"
        case .none: return ""
        }
    }
}

class FZShowsFetcher {

    // MARK: - Exceptions Dictionary
    // Maps (metadata_date, showTime) -> (search_date, section_keywords)
    // For shows where the HTML structure doesn't match standard patterns

    struct ShowException {
        let searchDate: String          // Date to search for in HTML (may differ from metadata)
        let sectionKeywords: [String]?  // Keywords to find the right section (e.g., "Tape 2", "Late")
        let altFilename: String?        // Alternative filename if not on standard tour page
    }

    static let exceptions: [String: ShowException] = [
        // === 1970 11 13/14 Fillmore East ===
        // Uncertain dates, listed as "1970 11 13 and/or 14" with "Tape 1" / "Tape 2" sections
        "1970 11 13 E": ShowException(searchDate: "1970 11 13 and/or 14", sectionKeywords: ["Tape 1"], altFilename: nil),
        "1970 11 13 L": ShowException(searchDate: "1970 11 13 and/or 14", sectionKeywords: ["Tape 2"], altFilename: nil),
        "1970 11 14 E": ShowException(searchDate: "1970 11 13 and/or 14", sectionKeywords: ["Tape 1"], altFilename: nil),
        "1970 11 14 L": ShowException(searchDate: "1970 11 13 and/or 14", sectionKeywords: ["Tape 2"], altFilename: nil),
        // Without E/L designation, default to Tape 1
        "1970 11 13": ShowException(searchDate: "1970 11 13 and/or 14", sectionKeywords: ["Tape 1"], altFilename: nil),
        "1970 11 14": ShowException(searchDate: "1970 11 13 and/or 14", sectionKeywords: ["Tape 1"], altFilename: nil),

        // === 1970 05 08/09 Fillmore East ===
        // Listed as "1970 05 08 or 09"
        "1970 05 08": ShowException(searchDate: "1970 05 08 or 09", sectionKeywords: nil, altFilename: nil),
        "1970 05 09": ShowException(searchDate: "1970 05 08 or 09", sectionKeywords: nil, altFilename: nil),

        // === 1972 date confusions ===
        // Some recordings circulate with wrong dates
        "1972 12 31": ShowException(searchDate: "1972 11 11", sectionKeywords: nil, altFilename: nil),  // Wrong date, actually 11 11
        "1972 12 31 E": ShowException(searchDate: "1972 11 11", sectionKeywords: ["Early"], altFilename: nil),
        "1972 12 31 L": ShowException(searchDate: "1972 11 11", sectionKeywords: ["Late"], altFilename: nil),
        "1972 12 12": ShowException(searchDate: "1972 12 09", sectionKeywords: nil, altFilename: nil),  // Wrong date, actually 12 09
        "1972 12 12 E": ShowException(searchDate: "1972 12 09", sectionKeywords: ["Early"], altFilename: nil),
        "1972 12 12 L": ShowException(searchDate: "1972 12 09", sectionKeywords: ["Late"], altFilename: nil),
    ]

    // MARK: - Tour Page Mapping

    static func getTourPageFilename(year: Int, month: Int) -> String? {
        switch (year, month) {
        case (1966...1968, _): return "6669.html"
        case (1969, 1...8): return "6669.html"
        case (1970, 2...5): return "6970.html"
        case (1970, 6...12): return "7071.html"
        case (1971, _): return "7071.html"
        case (1972, _): return "72.html"
        case (1973, 2...9): return "73.html"
        case (1973, 10...12): return "7374.html"
        case (1974, 1...12): return "7374.html"
        case (1975, 4...5): return "75.html"
        case (1975, 9...12): return "7576.html"
        case (1976, 1...3): return "7576.html"
        case (1976, 10...12): return "7677.html"
        case (1977, 1...2): return "7677.html"
        case (1977, 9...12): return "7778.html"
        case (1978, 1...2): return "7778.html"
        case (1978, 8...10): return "78.html"
        case (1978, 12): return "rehearsals.html"
        case (1979, _): return "79.html"
        case (1980, 3...7): return "80.html"
        case (1980, 8...12): return "80fall.html"
        case (1981, 9...12): return "8182.html"
        case (1982, 5...7): return "8182.html"
        case (1984, 7...12): return "84.html"
        case (1988, 2...6): return "88.html"
        default: return nil
        }
    }

    // MARK: - Public API

    static func fetchShowInfo(date: String, showTime: ShowTime = .none, completion: @escaping (FZShow?) -> Void) {
        // Parse date format "1982 07 09"
        let parts = date.components(separatedBy: " ")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            completion(nil)
            return
        }

        // Check for exceptions
        let exceptionKey = showTime == .none ? date : "\(date) \(showTime == .early ? "E" : "L")"
        let exception = exceptions[exceptionKey] ?? exceptions[date]

        let searchDate: String
        let sectionKeywords: [String]?

        if let exc = exception {
            searchDate = exc.searchDate
            sectionKeywords = exc.sectionKeywords
            print("📋 Using exception mapping: \(date) -> \(searchDate)")
        } else {
            searchDate = date
            sectionKeywords = nil
        }

        // Determine filename
        let filename: String?
        if let exc = exception, let altFile = exc.altFilename {
            filename = altFile
        } else {
            filename = getTourPageFilename(year: year, month: month)
        }

        guard let primaryFilename = filename else {
            completion(nil)
            return
        }

        let primaryURLString = "https://www.zappateers.com/fzshows/\(primaryFilename)"
        fetchFromURL(urlString: primaryURLString, filename: primaryFilename, searchDate: searchDate, originalDate: date,
                     showTime: showTime, sectionKeywords: sectionKeywords) { show in
            if let show = show {
                completion(show)
            } else {
                // Fallback to rehearsals.html
                print("🔄 Primary page had no match, trying rehearsals.html")
                let rehearsalsURLString = "https://www.zappateers.com/fzshows/rehearsals.html"
                self.fetchFromURL(urlString: rehearsalsURLString, filename: "rehearsals.html", searchDate: searchDate, originalDate: date,
                                  showTime: showTime, sectionKeywords: sectionKeywords, completion: completion)
            }
        }
    }

    // MARK: - Private Helpers

    private static func fetchFromURL(urlString: String, filename: String, searchDate: String, originalDate: String,
                                     showTime: ShowTime, sectionKeywords: [String]?,
                                     completion: @escaping (FZShow?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        print("📖 Fetching show info from: \(urlString)")

        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                print("❌ Failed to fetch or decode HTML")
                completion(nil)
                return
            }

            let show = parseShowFromHTML(html: html, filename: filename, searchDate: searchDate, originalDate: originalDate,
                                         showTime: showTime, sectionKeywords: sectionKeywords, url: urlString)
            completion(show)
        }.resume()
    }

    private static func parseShowFromHTML(html: String, filename: String, searchDate: String, originalDate: String,
                                          showTime: ShowTime, sectionKeywords: [String]?,
                                          url: String) -> FZShow? {
        // Find the date inside an <h4> tag (not in notes or other places)
        // Search for "<h4>DATE" or "<h4 class=...>DATE" patterns
        let h4Pattern = "<h4[^>]*>\(NSRegularExpression.escapedPattern(for: searchDate))"
        guard let h4Match = html.range(of: h4Pattern, options: .regularExpression) else {
            print("❌ Date \(searchDate) not found in any <h4> tag")
            return nil
        }

        var venue = "Unknown Venue"
        var showInfo = "No show info"
        var note: String? = nil
        var soundcheck: String? = nil
        var setlist: [String] = ["No setlist available"]
        var acronyms: [(short: String, full: String)] = []
        var detectedShowType: ShowTime = .none

        // Find the start of this <h4> tag
        let fullH4Start = h4Match.lowerBound

        // Find </h4> AFTER the <h4> we found
        guard let h4End = html.range(of: "</h4>", range: fullH4Start..<html.endIndex) else {
            print("❌ Could not find </h4> tag after <h4>")
            return nil
        }

        let fullH4 = String(html[fullH4Start..<h4End.upperBound])
        print("🏟️ FULL h4: '\(fullH4)'")

        // Extract venue after dash
        if let dashIndex = fullH4.firstIndex(of: "-") {
            let afterDash = fullH4[fullH4.index(after: dashIndex)..<fullH4.endIndex]
            venue = String(afterDash).replacingOccurrences(of: "</h4>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("🏟️ Venue: '\(venue)'")
        }

        // Find end of THIS show's entire section (next h4 date OR end of file)
        let nextDatePattern = "<h4>\\d{4} \\d{2} \\d{2}"
        let showSectionEnd: String.Index
        if let nextH4Range = html.range(of: nextDatePattern, options: .regularExpression,
                                        range: h4End.upperBound..<html.endIndex) {
            showSectionEnd = nextH4Range.lowerBound
        } else {
            showSectionEnd = html.endIndex
        }

        let showSection = String(html[h4End.upperBound..<showSectionEnd])
        print("📄 Show section length: \(showSection.count) chars")

        // Determine which subsection to use based on showTime or sectionKeywords
        let targetSection: String
        let targetSectionStart: String.Index

        if let keywords = sectionKeywords {
            // Use exception keywords to find the right section
            var foundRange: Range<String.Index>? = nil
            for keyword in keywords {
                if let range = showSection.range(of: keyword, options: .caseInsensitive) {
                    foundRange = range
                    break
                }
            }
            if let range = foundRange {
                targetSectionStart = html.index(h4End.upperBound, offsetBy: showSection.distance(from: showSection.startIndex, to: range.lowerBound))
                targetSection = String(html[targetSectionStart..<showSectionEnd])
            } else {
                targetSectionStart = h4End.upperBound
                targetSection = showSection
            }
        } else if showTime != .none {
            // Find Early/Late section
            let targetKeyword = showTime == .early ? "Early" : "Late"
            if let h5Range = showSection.range(of: "<h5>\(targetKeyword)", options: .caseInsensitive) {
                targetSectionStart = html.index(h4End.upperBound, offsetBy: showSection.distance(from: showSection.startIndex, to: h5Range.lowerBound))
                targetSection = String(html[targetSectionStart..<showSectionEnd])
                detectedShowType = showTime
                print("🎭 Found \(targetKeyword) show section")
            } else {
                // No Early/Late found, maybe single show - use whole section
                targetSectionStart = h4End.upperBound
                targetSection = showSection
                print("🎭 No \(targetKeyword) section found, using full show section")
            }
        } else {
            // No showTime specified - check if there are Early/Late sections
            if showSection.range(of: "<h5>Early", options: .caseInsensitive) != nil {
                detectedShowType = .early
                print("🎭 Detected Early show (defaulting to first)")
            }
            targetSectionStart = h4End.upperBound
            targetSection = showSection
        }

        // Now parse from targetSection
        // Find ALL h6 tags (show info) in this section - shows can have multiple sources
        // Sources can be in separate <h6> tags OR within a single <h6> with <br> separators:
        // <h6>110 min, Aud, A/A-</h6>  OR  <h6>135 min, Aud, B-<br>90 min, Aud, B+</h6>
        var allShowInfos: [String] = []
        // Updated pattern to capture content including <br> tags inside h6
        let h6Pattern = "<h6>([\\s\\S]*?)</h6>"
        if let h6Regex = try? NSRegularExpression(pattern: h6Pattern, options: []) {
            // Only search up to the setlist or note to avoid picking up h6 from other shows
            let searchEnd = targetSection.range(of: "<p class=\"setlist\">")?.lowerBound
                ?? targetSection.range(of: "<p class=\"note\">")?.lowerBound
                ?? targetSection.endIndex
            let searchSection = String(targetSection[..<searchEnd])
            let nsRange = NSRange(searchSection.startIndex..<searchSection.endIndex, in: searchSection)

            h6Regex.enumerateMatches(in: searchSection, range: nsRange) { match, _, _ in
                if let match = match, let range = Range(match.range(at: 1), in: searchSection) {
                    let h6Content = String(searchSection[range])
                        .replacingOccurrences(of: "<br>", with: " • ")
                        .replacingOccurrences(of: "<br/>", with: " • ")
                        .replacingOccurrences(of: "<br />", with: " • ")
                        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !h6Content.isEmpty {
                        allShowInfos.append(h6Content)
                    }
                }
            }
        }

        if !allShowInfos.isEmpty {
            // Join multiple sources with bullet separator
            showInfo = allShowInfos.joined(separator: " • ")
            print("📊 Show info (\(allShowInfos.count) source(s)): '\(showInfo)'")
        }

        // Find notes in this section (before the setlist)
        if let noteStart = targetSection.range(of: "<p class=\"note\">"),
           let noteEnd = targetSection.range(of: "</p>", range: noteStart.upperBound..<targetSection.endIndex) {
            let fullNote = String(targetSection[noteStart.lowerBound..<noteEnd.upperBound])
            note = fullNote.replacingOccurrences(of: "<p class=\"note\">", with: "")
                .replacingOccurrences(of: "</p>", with: "")
                .replacingOccurrences(of: #"<a href="([^"]+)">([^<]+)</a>"#, with: "[$2]($1)", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("📝 Note: '\(note ?? "")'")
        }

        // Find setlist in this section
        // Need to find the setlist that belongs to the target show (Early or Late)
        // If showTime is specified, find the setlist AFTER the corresponding h5
        if let setlistStart = targetSection.range(of: "<p class=\"setlist\">"),
           let setlistEnd = targetSection.range(of: "</p>", range: setlistStart.upperBound..<targetSection.endIndex) {

            let rawSetlistText = String(targetSection[setlistStart.upperBound..<setlistEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract acronym mappings from raw HTML before stripping tags
            let acronymRegex = try! NSRegularExpression(pattern: #"<acronym title="([^"]+)">([^<]+)</acronym>"#)
            let nsRange = NSRange(rawSetlistText.startIndex..<rawSetlistText.endIndex, in: rawSetlistText)
            let matches = acronymRegex.matches(in: rawSetlistText, range: nsRange)

            for match in matches {
                if let fullRange = Range(match.range(at: 1), in: rawSetlistText),
                   let shortRange = Range(match.range(at: 2), in: rawSetlistText) {
                    let full = String(rawSetlistText[fullRange])
                    let short = String(rawSetlistText[shortRange])
                    acronyms.append((short: short, full: full))
                }
            }

            // Now strip HTML, decode entities, and parse songs
            let setlistText = rawSetlistText
                .replacingOccurrences(of: #"<acronym title="([^"]+)">([^<]+)</acronym>"#, with: "$2", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .decodeHTMLEntities()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Split on commas, but not commas inside parentheses or brackets
            var songs: [String] = []
            var currentSong = ""
            var parenDepth = 0
            var bracketDepth = 0

            for char in setlistText {
                if char == "(" {
                    parenDepth += 1
                    currentSong.append(char)
                } else if char == ")" {
                    parenDepth -= 1
                    currentSong.append(char)
                } else if char == "[" {
                    bracketDepth += 1
                    currentSong.append(char)
                } else if char == "]" {
                    bracketDepth -= 1
                    currentSong.append(char)
                } else if char == "," && parenDepth == 0 && bracketDepth == 0 {
                    let trimmed = currentSong.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed.count > 2 {
                        songs.append(trimmed)
                    }
                    currentSong = ""
                } else {
                    currentSong.append(char)
                }
            }

            // Don't forget the last song
            let trimmed = currentSong.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 2 {
                songs.append(trimmed)
            }

            setlist = songs
        }

        // Build final show info with show type
        let finalShowType = showTime != .none ? showTime : detectedShowType
        let finalShowInfo: String
        if finalShowType != .none {
            finalShowInfo = "\(finalShowType.displayName) - \(showInfo)"
        } else {
            finalShowInfo = showInfo
        }

        // Extract period name from filename
        let period = periodName(forFilename: filename)

        // Extract tour name from HTML (h3 tag preceding this show)
        let tour = extractTourName(html: html, beforeIndex: h4Match.lowerBound)

        // Parse location from venue
        let location = parseLocation(from: venue)

        print("✅ SUCCESS: \(venue) | \(setlist.count) songs | \(finalShowInfo)")
        print("   📍 Location: \(location.city ?? "?"), \(location.state ?? "?"), \(location.country ?? "?")")
        print("   🗓️ Period: \(period ?? "?") | Tour: \(tour ?? "?")")

        return FZShow(
            date: originalDate,
            venue: venue,
            soundcheck: soundcheck,
            note: note,
            showInfo: finalShowInfo,
            setlist: setlist,
            acronyms: acronyms,
            url: url,
            city: location.city,
            state: location.state,
            country: location.country,
            period: period,
            tour: tour
        )
    }

    /// Extracts the tour name from the HTML structure before the show date
    /// Structure 1 (most tours):
    /// <h2>September - December 1977<br>
    /// <span class="redbig">USA and Canada tour</span></h2>
    /// Result: "USA and Canada tour (September - December 1977)"
    ///
    /// Structure 2 (1970-1971 tours):
    /// <h2><span class="redbig">1970</span></h2>
    /// <h3>The Mothers Of Invention, June - December 1970</h3>
    /// Result: "The Mothers Of Invention (June - December 1970)"
    private static func extractTourName(html: String, beforeIndex: String.Index) -> String? {
        // Get the HTML before this show
        let precedingHTML = String(html[html.startIndex..<beforeIndex])

        var lastH2TourName: String? = nil
        var lastH2Year: String? = nil  // For year-only entries like "1970"
        var lastH2DateRange: String? = nil
        var lastH3DateRange: String? = nil

        // First, try to find h2 tags with span.redbig (most common structure)
        let h2Pattern = "<h2[^>]*>([\\s\\S]*?)</h2>"
        if let regex = try? NSRegularExpression(pattern: h2Pattern, options: []) {
            let nsRange = NSRange(precedingHTML.startIndex..<precedingHTML.endIndex, in: precedingHTML)

            regex.enumerateMatches(in: precedingHTML, range: nsRange) { match, _, _ in
                guard let match = match,
                      let range = Range(match.range(at: 1), in: precedingHTML) else { return }

                let h2Content = String(precedingHTML[range])

                // Extract tour name from <span class="redbig">...</span>
                let spanPattern = "<span class=\"redbig\">([^<]+)</span>"
                if let spanRegex = try? NSRegularExpression(pattern: spanPattern),
                   let spanMatch = spanRegex.firstMatch(in: h2Content, range: NSRange(h2Content.startIndex..<h2Content.endIndex, in: h2Content)),
                   let spanRange = Range(spanMatch.range(at: 1), in: h2Content) {
                    let extracted = String(h2Content[spanRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Check if it's a year-only entry like "1970", "1971"
                    if !extracted.isEmpty {
                        if extracted.rangeOfCharacter(from: .letters) != nil && extracted.count > 4 {
                            // It's a real tour name (contains letters and more than 4 chars)
                            lastH2TourName = extracted
                            lastH2Year = nil  // Clear year since we have a real tour name
                        } else if extracted.count == 4, Int(extracted) != nil {
                            // It's a year like "1970"
                            lastH2Year = extracted
                            lastH2TourName = nil  // Clear tour name since it's just a year
                        }
                    }
                }

                // Extract date range (text before <br> or <span>, after any <a> tag)
                let cleanedContent = h2Content
                    .replacingOccurrences(of: "<a[^>]*></a>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "<a[^>]*>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "</a>", with: "")

                if let brRange = cleanedContent.range(of: "<br") {
                    let dateCandidate = String(cleanedContent[..<brRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dateCandidate.isEmpty {
                        lastH2DateRange = dateCandidate
                    }
                } else if let spanRange = cleanedContent.range(of: "<span") {
                    let dateCandidate = String(cleanedContent[..<spanRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dateCandidate.isEmpty {
                        lastH2DateRange = dateCandidate
                    }
                }
            }
        }

        // Also look for h3 tags for 1970-1971 style pages
        // Format: <h3>The Mothers Of Invention, June - December 1970</h3>
        // We extract the date range
        let h3Pattern = "<h3[^>]*>([^<]+)</h3>"
        if let regex = try? NSRegularExpression(pattern: h3Pattern, options: []) {
            let nsRange = NSRange(precedingHTML.startIndex..<precedingHTML.endIndex, in: precedingHTML)

            regex.enumerateMatches(in: precedingHTML, range: nsRange) { match, _, _ in
                guard let match = match,
                      let range = Range(match.range(at: 1), in: precedingHTML) else { return }

                let h3Content = String(precedingHTML[range]).trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse "Band Name, Date Range" format to extract date range
                if let commaRange = h3Content.range(of: ", ", options: .backwards) {
                    let dateRange = String(h3Content[commaRange.upperBound...])
                    lastH3DateRange = dateRange
                }
            }
        }

        // Combine tour name and date range
        // Priority:
        // 1. h2 tour name with h2 date range (e.g., "USA and Canada tour (September - December 1977)")
        // 2. h2 tour name with h3 date range
        // 3. h2 year with h3 date range (for 1970-1971 pages: "1970 (June - December 1970)")
        if let tour = lastH2TourName {
            if let date = lastH2DateRange, !date.isEmpty {
                return "\(tour) (\(date))"
            } else if let date = lastH3DateRange, !date.isEmpty {
                return "\(tour) (\(date))"
            } else {
                return tour
            }
        }

        // Fall back to year + h3 date range for pages like 1970-1971
        if let year = lastH2Year, let dateRange = lastH3DateRange {
            return "\(year) (\(dateRange))"
        }

        return nil
    }
}
