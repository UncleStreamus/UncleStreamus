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

class FZShowsFetcher {
    
    // Map years to FZShows page filenames
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
    
    static func fetchShowInfo(date: String, completion: @escaping (FZShow?) -> Void) {
        // Parse date format "1982 07 09"
        let parts = date.components(separatedBy: " ")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let filename = getTourPageFilename(year: year, month: month) else {
            completion(nil)
            return
        }
        
        // Try primary tour page first
        if let primaryFilename = getTourPageFilename(year: year, month: month) {
            let primaryURLString = "https://www.zappateers.com/fzshows/\(primaryFilename)"
            fetchFromURL(urlString: primaryURLString, date: date, year: year, month: month, day: day) { show in
                if let show = show {
                    completion(show)
                } else {
                    // Fallback to rehearsals.html
                    print("🔄 Primary page had no match, trying rehearsals.html")
                    let rehearsalsURLString = "https://www.zappateers.com/fzshows/rehearsals.html"
                    self.fetchFromURL(urlString: rehearsalsURLString, date: date, year: year, month: month, day: day, completion: completion)
                }
            }
        } else {
            completion(nil)
        }
    }

    // Helper to avoid code duplication
    private static func fetchFromURL(urlString: String, date: String, year: Int, month: Int, day: Int, completion: @escaping (FZShow?) -> Void) {
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
            
            // Parse the HTML to find the show
            let show = parseShowFromHTML(html: html, year: year, month: month, day: day, url: urlString)
            completion(show)
        }.resume()
    }
    
    private static func parseShowFromHTML(html: String, year: Int, month: Int, day: Int, url: String) -> FZShow? {
        let dateString = String(format: "%04d %02d %02d", year, month, day)
        
        guard let dateRange = html.range(of: dateString) else {
            print("❌ Date \(dateString) not found in HTML")
            return nil
        }
        
        var venue = "Unknown Venue"
        var showInfo = "No show info"
        var note: String? = nil
        var soundcheck: String? = nil
        var setlist: [String] = ["No setlist available"]
        var acronyms: [(short: String, full: String)] = []
        var showType: String? = nil

        // Search BACKWARD from date for <h4>
        let searchStart = max(html.startIndex, html.index(dateRange.lowerBound, offsetBy: -100))
        let backwardSearch = String(html[searchStart..<html.endIndex])

        guard let h4Start = backwardSearch.range(of: "<h4>"),
              let h4End = html.range(of: "</h4>", range: searchStart..<html.endIndex) else {
            return nil
        }
        
        let fullH4Start = html.index(searchStart, offsetBy: backwardSearch.distance(from: backwardSearch.startIndex, to: h4Start.lowerBound))
        let fullH4 = String(html[fullH4Start..<h4End.upperBound])
        print("🏟️ FULL h4: '\(fullH4)'")
        
        // Extract venue after dash
        if let dashIndex = fullH4.firstIndex(of: "-") {
            let afterDash = fullH4[fullH4.index(after: dashIndex)..<fullH4.endIndex]
            venue = String(afterDash).replacingOccurrences(of: "</h4>", with: "")
                                 .trimmingCharacters(in: .whitespacesAndNewlines)
            print("🏟️ Venue: '\(venue)'")
        }
        
        // Show info from h6 after h4End
        if let h6Start = html.range(of: "<h6>", range: h4End.upperBound..<html.endIndex),
           let h6End = html.range(of: "</h6>", range: h6Start.upperBound..<html.endIndex) {
            
            let fullH6 = String(html[h6Start.lowerBound..<h6End.upperBound])
            showInfo = fullH6.replacingOccurrences(of: "<h6>", with: "")
                             .replacingOccurrences(of: "</h6>", with: "")
                             .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)  // <- Add this
                             .trimmingCharacters(in: .whitespacesAndNewlines)
            print("📊 Show info: '\(showInfo)'")
        }
        
        // Find end of THIS show = next date OR end of file
        let nextDatePattern = "\\d{4} \\d{2} \\d{2}"
        let showSectionEnd: String.Index
        if let nextDateRange = html.range(of: nextDatePattern, options: .regularExpression,
                                         range: dateRange.upperBound..<html.endIndex) {
            showSectionEnd = nextDateRange.lowerBound
        } else {
            showSectionEnd = html.endIndex
        }
        
        // Notes within our show's section
        if let noteStart = html.range(of: "<p class=\"note\">", range: h4End.upperBound..<showSectionEnd),
           let noteEnd = html.range(of: "</p>", range: noteStart.upperBound..<showSectionEnd) {
            
            let fullNote = String(html[noteStart.lowerBound..<noteEnd.upperBound])
            note = fullNote.replacingOccurrences(of: "<p class=\"note\">", with: "")
                                .replacingOccurrences(of: "</p>", with: "")
                                .replacingOccurrences(of: #"<a href="([^"]+)">([^<]+)</a>"#, with: "[$2]($1)", options: .regularExpression)
                                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("📝 Note: '\(note ?? "")'")
        }
        
        // ShowType (Early/Late)
        let h5SearchRange = dateRange.lowerBound..<html.endIndex
        if let firstH5Range = html.range(of: "<h5>", range: h5SearchRange),
           let h5TextRange = html.range(of: ">(.+?)<", range: firstH5Range.lowerBound..<html.index(firstH5Range.upperBound, offsetBy: 50)) {
            
            let h5Text = String(html[h5TextRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if h5Text.contains("Early") {
                showType = "Early show"
            } else if h5Text.contains("Late") {
                showType = "Late show"
            }
            print("🎭 Show type: \(showType ?? "None")")
        }
        
        if let setlistRange = html.range(of: #"<p class="setlist">(.+?)</p>"#, options: .regularExpression,
                                         range: dateRange.lowerBound..<html.endIndex) {
            let rawSetlistText = String(html[setlistRange])
                .replacingOccurrences(of: "<p class=\"setlist\">", with: "")
                .replacingOccurrences(of: "</p>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Parse songs WITH their acronym info preserved temporarily
//            var songsWithAcronyms: [(song: String, acronym: String?)] = []
            
            // First, let's keep track of acronyms in the text
            // Pattern: [text on <acronym title="full">SHORT</acronym>]
            let acronymPattern = #"\[([^\[]*)<acronym title="([^"]+)">([^<]+)</acronym>([^\]]*)\]"#
            
            // For now, just extract the display text with acronym short form
            let setlistText = rawSetlistText
                .replacingOccurrences(of: #"<acronym title="([^"]+)">([^<]+)</acronym>"#, with: "$2", options: .regularExpression)
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
                    // This is a song separator (not inside parens or brackets)
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
            
            // Now extract acronym mappings from raw HTML
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
            
        }


        let finalShowInfo: String
        if let showType = showType {
            finalShowInfo = "\(showType) - \(showInfo)"
        } else {
            finalShowInfo = showInfo
        }

        print("✅ SUCCESS: \(venue) | \(setlist.count) songs | \(finalShowInfo)")
        
        return FZShow(
            date: dateString,
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
