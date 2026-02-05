//
//  ParsedTrackInfo.swift
//  ZappaStream
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
        
        // Check if it's the full bracketed format or simple format
        let isFullFormat = title.hasPrefix("[")
        
        if isFullFormat {
            // Original parsing code for full format
            if let bracketRange = title.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) {
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
                
                let sources = ["AUD", "SBD", "FM", "STAGE"]
                for src in sources where bracketContent.contains(src) {
                    source = src
                    break
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
                
                if let trackNumEnd = afterColon.range(of: #"\(\d+\)"#, options: .regularExpression)?.upperBound,
                   let yearStart = afterColon.range(of: #"\(\d{4}\)"#, options: .regularExpression)?.lowerBound {
                    trackName = String(afterColon[trackNumEnd..<yearStart]).trimmingCharacters(in: .whitespaces)
                }
                
                if let yearRange = afterColon.range(of: #"\((\d{4})\)"#, options: .regularExpression) {
                    let yearText = String(afterColon[yearRange])
                    year = String(String(yearText).dropFirst().dropLast())
                }
            }
        } else {
            // Simple format: "1973 11 07 Boston MA - 01 Intro [0:03:30]"
            let parts = title.components(separatedBy: " ")
            
            // Date (first 3 parts)
            if parts.count >= 3 {
                date = "\(parts[0]) \(parts[1]) \(parts[2])"
            }
            
            // Find the dash separator
            if let dashIndex = parts.firstIndex(of: "-") {
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
            
            let sources = ["AUD", "SBD", "FM", "STAGE"]
            let fullTitleUpper = title.uppercased()
            for src in sources where fullTitleUpper.contains(src) {
                source = src
                break
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
            trackName: trackName,
            year: year,
            trackDuration: trackDuration,
            rawTitle: title
        )
    }
}
