//
//  ParsedTrackInfo.swift
//  UncleStreamus
//
//  Created by Darcy Taranto on 04/02/2026.
//

import Foundation

struct ParsedTrackInfo {
    let date: String?
    let showTime: String?
    let city: String?
    let state: String?
    let showDuration: String?
    let source: String?
    let generation: String?
    let creator: String?
    let artist: String?
    let trackNumber: String?
    let trackName: String?
    let year: String?
    let trackDuration: String?
    let rawTitle: String

    /// True when the metadata is a non-Zappa broadcast (cover band / guest set)
    /// that isn't in the zappateers catalogue. Set by the best-effort fallback in
    /// `parse()`; tells the pipeline to skip the (futile) show fetch and the UI to
    /// show a "not a Zappa show" note instead of a stuck "Waiting for show info…".
    /// A `var` with a default so the synthesized memberwise init keeps it optional
    /// (existing call sites and tests compile unchanged).
    var isNonZappaShow: Bool = false

    // MARK: - Track Name Normalization

    /// Maps stream metadata track names to display-normalized forms (fixes capitalization/alternate titles)
    static let trackNameExceptions: [String: String] = [
        "Pound For A Brown": "A Pound For a Brown",
        "More Trouble Every Day": "Trouble Every Day",
        "Eric Dolphy Memorial Barbecue": "The Eric Dolphy Memorial Barbecue",
        "The Eric Dolphy Memorial Barbecue": "The Eric Dolphy Memorial Barbecue",
    ]

    /// Groups of track names that are considered synonymous with each other.
    /// A name can appear in multiple groups — two names match if they share any group.
    /// This allows partial overlaps: String Quartet bridges the Pound and Sleeping groups
    /// without making Sleeping In a Jar match the Pound names directly.
    static let synonymGroups: [Set<String>] = [
        ["A Pound For a Brown", "Pound For A Brown", "The String Quartet", "String Quartet"],
        ["The String Quartet", "String Quartet", "Sleeping In a Jar"],
        ["Trouble Every Day", "More Trouble Every Day"],
        ["Eric Dolphy Memorial Barbecue", "The Eric Dolphy Memorial Barbecue"],
    ]

    /// Combined source-type tokens (e.g. "SBD-AUD"), checked before single sources.
    /// Used as a `.regularExpression` search pattern in `parse()`.
    static let combinedSourcePattern = #"(SBD-AUD|AUD-SBD|SBD-FM|FM-SBD|AUD-FM|FM-AUD)"#

    /// Normalizes a track name for display purposes
    static func normalizeTrackName(_ name: String?) -> String? {
        guard let name = name else { return nil }
        return trackNameExceptions[name] ?? name
    }

    /// Normalizes a single word from plural to singular form
    private static func singularizeWord(_ word: String) -> String {
        // Handle common plural patterns
        if word.hasSuffix("ations") && word.count > 6 {
            return String(word.dropLast(1)) // "Improvisations" → "Improvisation"
        }
        if word.hasSuffix("ies") && word.count > 3 {
            return String(word.dropLast(3)) + "y" // "Discoveries" → "Discovery"
        }
        if word.hasSuffix("es") && word.count > 2 {
            return String(word.dropLast(2)) // "Boxes" → "Box"
        }
        if word.hasSuffix("s") && word.count > 1 && !word.hasSuffix("ss") {
            return String(word.dropLast(1)) // "Songs" → "Song"
        }
        return word
    }

    /// Normalizes plural forms to singular for matching by processing each word
    /// (e.g., "Improvisations in Q" → "Improvisation in Q")
    static func normalizePluralForm(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)

        // Remove trailing asterisks and punctuation that don't affect track identity
        var cleanedName = name
        while cleanedName.hasSuffix("*") || cleanedName.hasSuffix(".") {
            cleanedName = String(cleanedName.dropLast())
        }

        // Split into words and normalize plural forms in each word
        let words = cleanedName.split(separator: " ", omittingEmptySubsequences: true)
        let normalizedWords = words.map { word -> String in
            let wordStr = String(word)
            return singularizeWord(wordStr)
        }

        return normalizedWords.joined(separator: " ")
    }

    /// Returns true if two track names should be treated as matching,
    /// accounting for synonym groups with possible overlaps and singular/plural forms.
    static func tracksMatch(_ a: String, _ b: String) -> Bool {
        if a.lowercased() == b.lowercased() { return true }
        let normA = normalizeTrackName(a) ?? a
        let normB = normalizeTrackName(b) ?? b
        if normA.lowercased() == normB.lowercased() { return true }

        // Check singular/plural normalization (case-insensitive)
        let pluralNormA = normalizePluralForm(normA).lowercased()
        let pluralNormB = normalizePluralForm(normB).lowercased()
        if pluralNormA == pluralNormB { return true }

        for group in synonymGroups {
            if (group.contains(a) || group.contains(normA)) &&
               (group.contains(b) || group.contains(normB)) { return true }
        }
        return false
    }

    static func parse(_ title: String) -> ParsedTrackInfo {
        var date: String?
        var showTime: String?
        var city: String?
        var state: String?
        var showDuration: String?
        var source: String?
        var generation: String?
        var creator: String?
        var artist: String?
        var trackNumber: String?
        var trackName: String?
        var year: String?
        var trackDuration: String?
        var isNonZappaShow = false

        // Check if it's the full bracketed format or simple format
        let isFullFormat = title.hasPrefix("[")

        // Try simple two-part format first: "01 Intro" or "01 - Intro" (from FLAC Vorbis comments)
        if !isFullFormat && !title.contains(":") && !title.contains("[") {
            let parts = title.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count >= 1, let firstPart = parts.first, firstPart.allSatisfy({ $0.isNumber }) {
                trackNumber = String(firstPart)
                if parts.count >= 2 {
                    let rest = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                    if !rest.isEmpty {
                        trackName = rest
                        return ParsedTrackInfo(
                            date: date, showTime: showTime, city: city, state: state,
                            showDuration: showDuration, source: source, generation: generation,
                            creator: creator, artist: artist, trackNumber: trackNumber,
                            trackName: trackName, year: year, trackDuration: trackDuration,
                            rawTitle: title
                        )
                    }
                }
            } else if let firstPart = parts.first, Int(firstPart) == nil {
                // Bare track name with no number prefix and no structured formatting
                // (e.g. FLAC Vorbis comment "When The Lie's So Big").
                // Use the whole title as the track name so the UI shows it immediately
                // without waiting for the Icecast full-metadata callback.
                trackName = title
                return ParsedTrackInfo(
                    date: nil, showTime: nil, city: nil, state: nil,
                    showDuration: nil, source: nil, generation: nil,
                    creator: nil, artist: nil, trackNumber: nil,
                    trackName: normalizeTrackName(trackName), year: nil, trackDuration: nil,
                    rawTitle: title
                )
            }
        }
        
        if isFullFormat {
            // Original parsing code for full format
            if let bracketRange = title.range(of: #"\[(\d{4}[^\]]+)\]"#, options: .regularExpression) {
                let bracketContent = String(title[bracketRange]).dropFirst().dropLast()
                let parts = bracketContent.components(separatedBy: " ")
                
                if parts.count >= 3 {
                    date = "\(parts[0]) \(parts[1]) \(parts[2])"
                }
                
                if parts.count >= 4 && parts[3].hasPrefix("(") {
                    showTime = parts[3]
                }
                
                for (index, part) in parts.enumerated() {
                    // Special case for NYC
                    if part == "NYC" {
                        state = "NY"
                        city = "New York City"
                        break
                    }
                    
                    if index > 2 && part.count == 2 && part.uppercased() == part {
                        state = part
                        let cityStartIndex = parts[3].hasPrefix("(") ? 4 : 3
                        if index > cityStartIndex {
                            city = parts[cityStartIndex..<index].joined(separator: " ")
                        }
                        break
                    }
                }
                
                if let durationMatch = bracketContent.range(of: #"\d+\.\d+"#, options: .regularExpression) {
                    showDuration = String(bracketContent[durationMatch])
                }
                
                // Check for combined sources first (e.g., "SBD-AUD", "AUD-SBD")
                // Then fall back to single sources
                if let combinedMatch = bracketContent.range(of: Self.combinedSourcePattern, options: .regularExpression) {
                    source = String(bracketContent[combinedMatch])
                } else {
                    let sources = ["AUD", "SBD", "FM", "STAGE"]
                    for src in sources where bracketContent.contains(src) {
                        source = src
                        break
                    }
                }
                
                if let genMatch = bracketContent.range(of: #"\b(GEN|MC)\b"#, options: .regularExpression) {
                    generation = String(bracketContent[genMatch])
                }
                
                if let creatorRange = bracketContent.range(of: #"\(([^)]+)\)$"#, options: .regularExpression) {
                    creator = String(String(bracketContent[creatorRange]).dropFirst().dropLast())
                }
            }
            
            if let colonRange = title.range(of: ": ") {
                let beforeColon = String(title[..<colonRange.lowerBound])
                if let bracketEnd = beforeColon.lastIndex(of: "]") {
                    artist = String(beforeColon[beforeColon.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
                }
                
                let afterColon = String(title[colonRange.upperBound...])
                if let trackRange = afterColon.range(of: #"\((\d+)\)"#, options: .regularExpression) {
                    let trackText = String(afterColon[trackRange])
                    trackNumber = String(trackText.dropFirst().dropLast())
                }
                
                if let trackNumEnd = afterColon.range(of: #"\(\d+\)"#, options: .regularExpression)?.upperBound {
                    if let yearStart = afterColon.range(of: #"\(\d{4}\)"#, options: .regularExpression)?.lowerBound {
                        trackName = String(afterColon[trackNumEnd..<yearStart]).trimmingCharacters(in: .whitespaces)
                    } else {
                        // No year annotation — take everything from after track number to the duration bracket
                        let afterTrackNum = String(afterColon[trackNumEnd...]).trimmingCharacters(in: .whitespaces)
                        if let durationStart = afterTrackNum.range(of: #"\[\d"#, options: .regularExpression)?.lowerBound {
                            trackName = String(afterTrackNum[..<durationStart]).trimmingCharacters(in: .whitespaces)
                        } else if !afterTrackNum.isEmpty {
                            trackName = afterTrackNum
                        }
                    }
                }
                
                if let yearRange = afterColon.range(of: #"\((\d{4})\)"#, options: .regularExpression) {
                    let yearText = String(afterColon[yearRange])
                    year = String(String(yearText).dropFirst().dropLast())
                }
            }
        } else {
            // Simple format: "1973 11 07 Boston MA - 01 Intro [0:03:30]"
            let parts = title.components(separatedBy: " ")

            // Date (first 3 parts) — only assign if first part looks like a 4-digit year,
            // so that bare FLAC Vorbis track names like "How Could I Be Such A Fool"
            // aren't misread as date-based metadata.
            if parts.count >= 3,
               let year = Int(parts[0]), year >= 1900 && year <= 2100 {
                date = "\(parts[0]) \(parts[1]) \(parts[2])"
            }
            
            // Find the dash separator. Gated on a 4-digit Zappa date being present:
            // this is the Zappa simple format ("1973 11 07 Boston MA - 01 Intro …"),
            // which always carries such a date. A dashed *non-Zappa* line without a
            // Zappa date (e.g. "Some Band - Song [3:20]") is left for the best-effort
            // fallback below instead of being mis-parsed into a garbage track name.
            if date != nil, let dashIndex = parts.firstIndex(of: "-") {
                // City and State are between date and dash
                if dashIndex > 3 {
                    // Filter out (E), (L), (E), (L) show time indicators from location
                    let locationParts = Array(parts[3..<dashIndex]).filter { part in
                        let upper = part.uppercased()
                        return upper != "(E)" && upper != "(L)" && !upper.hasPrefix("(E") && !upper.hasPrefix("(L")
                    }

                    // Special case for NYC
                    if locationParts.contains("NYC") {
                        state = "NY"
                        city = "New York City"
                    } else if locationParts.count >= 2 {
                        state = locationParts.last
                        city = locationParts.dropLast().joined(separator: " ")
                    } else if locationParts.count == 1 {
                        // Just a city, no state (or state is the only part)
                        city = locationParts[0]
                    }
                }
                
                // Track number and name are after dash
                if dashIndex + 1 < parts.count {
                    trackNumber = parts[dashIndex + 1]
                    
                    // Track name is everything after track number until duration bracket
                    let afterTrackNum = parts[(dashIndex + 2)...]
                    var trackParts: [String] = []
                    for part in afterTrackNum {
                        if part.hasPrefix("[") { break }
                        trackParts.append(part)
                    }
                    if !trackParts.isEmpty {
                        trackName = trackParts.joined(separator: " ")
                    }
                }
            }
            
            // Check for combined sources first (e.g., "SBD-AUD", "AUD-SBD")
            // Then fall back to single sources
            let fullTitleUpper = title.uppercased()
            if let combinedRange = fullTitleUpper.range(of: Self.combinedSourcePattern, options: .regularExpression) {
                source = String(fullTitleUpper[combinedRange])
            } else {
                let sources = ["AUD", "SBD", "FM", "STAGE"]
                for src in sources where fullTitleUpper.contains(src) {
                    source = src
                    break
                }
            }
            
            // ADD: Early/Late detection
            if fullTitleUpper.contains("(E") || fullTitleUpper.contains("EARLY") {
                showTime = "(E)"
            } else if fullTitleUpper.contains("(L") || fullTitleUpper.contains("LATE") {
                showTime = "(L)"
            }
        }
        
        // Track duration (works for both formats)
        if let durationRange = title.range(of: #"\[[\d:]+\]$"#, options: .regularExpression) {
            trackDuration = String(String(title[durationRange]).dropFirst().dropLast())
        }

        // General non-Zappa best-effort fallback. If none of the Zappa formats above
        // produced a track name but this is a "full" metadata line (a trailing
        // [duration] or a leading date), treat it as a non-Zappa broadcast (cover
        // band / guest set) and surface whatever structure we can — always leaving a
        // non-empty track name so the UI never sits on "Waiting for info…".
        if trackName == nil {
            let hasDuration = trackDuration != nil
            var remainder = title
            if let durationRange = remainder.range(of: #"\s*\[[\d:]+\]$"#, options: .regularExpression) {
                remainder.removeSubrange(durationRange)
            }
            remainder = remainder.trimmingCharacters(in: .whitespaces)
            var tokens = remainder.components(separatedBy: " ").filter { !$0.isEmpty }

            // Optional leading date: "YY MM DD" or "YYYY MM DD".
            var hasLeadingDate = false
            if tokens.count >= 3,
               (tokens[0].count == 2 || tokens[0].count == 4),
               let _ = Int(tokens[0]), let mm = Int(tokens[1]), let dd = Int(tokens[2]),
               (1...12).contains(mm), (1...31).contains(dd) {
                date = Self.expandedDate(year: tokens[0], month: tokens[1], day: tokens[2])
                tokens.removeFirst(3)
                hasLeadingDate = true
            }

            if hasDuration || hasLeadingDate {
                // Split "band NN track name" on the first standalone 1–2 digit token.
                if let tnIdx = tokens.firstIndex(where: { $0.count <= 2 && Int($0) != nil }) {
                    trackNumber = tokens[tnIdx]
                    let band = tokens[..<tnIdx].filter { $0 != "-" }.joined(separator: " ")
                    if !band.isEmpty { artist = band }
                    let name = tokens[(tnIdx + 1)...].joined(separator: " ")
                    if !name.isEmpty { trackName = name }
                }
                // Guarantee a visible title: remainder, else the raw title.
                if trackName == nil {
                    let joined = tokens.joined(separator: " ")
                    trackName = !joined.isEmpty ? joined : (remainder.isEmpty ? title : remainder)
                }
                isNonZappaShow = true
            }
        }

        return ParsedTrackInfo(
            date: date,
            showTime: showTime,
            city: city,
            state: state,
            showDuration: showDuration,
            source: source,
            generation: generation,
            creator: creator,
            artist: artist,
            trackNumber: trackNumber,
            trackName: normalizeTrackName(trackName),
            year: year,
            trackDuration: trackDuration,
            rawTitle: title,
            isNonZappaShow: isNonZappaShow
        )
    }

    /// Expands a possibly 2-digit year date ("08 11 15") to a 4-digit display date
    /// ("2008 11 15") via a sliding-century pivot on the current year. 4-digit years
    /// pass through unchanged. Display-only — it drives no show fetch.
    private static func expandedDate(year: String, month: String, day: String) -> String {
        guard year.count == 2, let yy = Int(year) else {
            return "\(year) \(month) \(day)"
        }
        let pivot = Calendar.current.component(.year, from: Date()) % 100
        let fullYear = yy <= pivot ? 2000 + yy : 1900 + yy
        return "\(fullYear) \(month) \(day)"
    }
}

// MARK: - Derived / Merge Helpers

extension ParsedTrackInfo {
    /// The artist to display: the metadata's artist if present, otherwise inferred
    /// from the show date (Mothers of Invention pre-1975, Bongo Fury Jan–May 1975,
    /// Frank Zappa from June 1975 on).
    var inferredArtist: String {
        if let artist = artist, !artist.isEmpty {
            return artist
        }

        guard let dateStr = date else { return "Frank Zappa" }

        let parts = dateStr.components(separatedBy: " ")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            return "Frank Zappa"
        }

        // The Mothers of Invention era: 1966 through 1974
        if year < 1975 {
            return "The Mothers of Invention"
        }

        // Bongo Fury era: Jan-May 1975
        if year == 1975 && month <= 5 {
            return "Zappa / Beefheart / Mothers"
        }

        // Frank Zappa era: June 1975 onwards
        return "Frank Zappa"
    }

    /// Merges a freshly-parsed update with the previous track info. For FLAC the
    /// Vorbis short title arrives first (trackName only, date == nil); preserving
    /// the previous show metadata keeps date/location/artist visible so the UI
    /// doesn't flash mid-show. When the track number changes the preserved
    /// duration is cleared so the new Icecast duration is used.
    static func merged(new newParsed: ParsedTrackInfo, previous old: ParsedTrackInfo?) -> ParsedTrackInfo {
        guard newParsed.date == nil, let old = old else { return newParsed }

        let trackNumberChanged = newParsed.trackNumber != nil && newParsed.trackNumber != old.trackNumber
        let preservedDuration = trackNumberChanged ? nil : (newParsed.trackDuration ?? old.trackDuration)

        return ParsedTrackInfo(
            date: old.date, showTime: old.showTime,
            city: old.city, state: old.state,
            showDuration: old.showDuration, source: old.source,
            generation: old.generation, creator: old.creator,
            artist: old.artist, trackNumber: newParsed.trackNumber ?? old.trackNumber,
            trackName: newParsed.trackName, year: newParsed.year,
            trackDuration: preservedDuration, rawTitle: newParsed.rawTitle,
            isNonZappaShow: newParsed.isNonZappaShow
        )
    }

    /// Returns a copy with city/state filled in from a fetched show when the
    /// metadata lacked them. Returns `self` unchanged when both are already set.
    func fillingLocation(city fallbackCity: String?, state fallbackState: String?) -> ParsedTrackInfo {
        guard city == nil || state == nil else { return self }
        return ParsedTrackInfo(
            date: date, showTime: showTime,
            city: city ?? fallbackCity, state: state ?? fallbackState,
            showDuration: showDuration, source: source,
            generation: generation, creator: creator,
            artist: artist, trackNumber: trackNumber,
            trackName: trackName, year: year,
            trackDuration: trackDuration, rawTitle: rawTitle,
            isNonZappaShow: isNonZappaShow
        )
    }
}
