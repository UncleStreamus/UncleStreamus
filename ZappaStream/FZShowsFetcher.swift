import Foundation

struct FZShow {
    let date: String
    let venue: String
    let soundcheck: String?
    let note: String?
    let showInfo: String
    let setlist: [String]
    let acronyms: [(short: String, full: String)]
    let url: String
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
        fetchFromURL(urlString: primaryURLString, searchDate: searchDate, originalDate: date,
                     showTime: showTime, sectionKeywords: sectionKeywords) { show in
            if let show = show {
                completion(show)
            } else {
                // Fallback to rehearsals.html
                print("🔄 Primary page had no match, trying rehearsals.html")
                let rehearsalsURLString = "https://www.zappateers.com/fzshows/rehearsals.html"
                self.fetchFromURL(urlString: rehearsalsURLString, searchDate: searchDate, originalDate: date,
                                  showTime: showTime, sectionKeywords: sectionKeywords, completion: completion)
            }
        }
    }

    // MARK: - Private Helpers

    private static func fetchFromURL(urlString: String, searchDate: String, originalDate: String,
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

            let show = parseShowFromHTML(html: html, searchDate: searchDate, originalDate: originalDate,
                                         showTime: showTime, sectionKeywords: sectionKeywords, url: urlString)
            completion(show)
        }.resume()
    }

    private static func parseShowFromHTML(html: String, searchDate: String, originalDate: String,
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
        // Find the h6 (show info) in this section
        if let h6Start = targetSection.range(of: "<h6>"),
           let h6End = targetSection.range(of: "</h6>", range: h6Start.upperBound..<targetSection.endIndex) {
            let fullH6 = String(targetSection[h6Start.lowerBound..<h6End.upperBound])
            showInfo = fullH6.replacingOccurrences(of: "<h6>", with: "")
                .replacingOccurrences(of: "</h6>", with: "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("📊 Show info: '\(showInfo)'")
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

            // Now strip HTML and parse songs
            let setlistText = rawSetlistText
                .replacingOccurrences(of: #"<acronym title="([^"]+)">([^<]+)</acronym>"#, with: "$2", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

        print("✅ SUCCESS: \(venue) | \(setlist.count) songs | \(finalShowInfo)")

        return FZShow(
            date: originalDate,
            venue: venue,
            soundcheck: soundcheck,
            note: note,
            showInfo: finalShowInfo,
            setlist: setlist,
            acronyms: acronyms,
            url: url
        )
    }
}
