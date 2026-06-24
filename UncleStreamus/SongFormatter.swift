import SwiftUI

/// Shared utility for formatting song names in setlists
/// Used by both ContentView (main window) and ShowEntryRow (sidebar)
struct SongFormatter {

    /// Formats a song name with proper styling for brackets, parentheses, and acronyms
    /// - Parameters:
    ///   - song: The song name to format
    ///   - acronyms: List of acronym mappings (short form to full name)
    /// - Returns: A styled Text view
    static func format(_ song: String, acronyms: [(short: String, full: String)]) -> Text {
        var result = Text("")
        var remainingText = song

        // Process brackets [like this] and parentheses (q: ...) or (incl. ...) in order of appearance
        while true {
            // Find next bracket and next parentheses
            let bracketRange = remainingText.range(of: #"\[[^\]]+\]"#, options: .regularExpression)
            let parenRange = remainingText.range(of: #"\((q:|incl\.)[^)]+\)"#, options: .regularExpression)

            // Determine which comes first (if any)
            let nextRange: Range<String.Index>?
            let isBracket: Bool

            if let br = bracketRange, let pr = parenRange {
                // Both exist - pick the one that comes first
                if br.lowerBound < pr.lowerBound {
                    nextRange = br
                    isBracket = true
                } else {
                    nextRange = pr
                    isBracket = false
                }
            } else if let br = bracketRange {
                nextRange = br
                isBracket = true
            } else if let pr = parenRange {
                nextRange = pr
                isBracket = false
            } else {
                // No more special formatting needed
                break
            }

            guard let range = nextRange else { break }

            // Add text before this match as plain text
            let before = String(remainingText[..<range.lowerBound])
            if !before.isEmpty {
                result = result + Text(before)
            }

            // Format the matched content
            let content = String(remainingText[range])
            if isBracket {
                result = result + formatBracketWithAcronyms(content, acronyms: acronyms)
            } else {
                // Parentheses (q: or incl.) content gets italic + secondary gray
                result = result + Text(content).italic().foregroundColor(.secondary)
            }

            // Continue with remaining text
            remainingText = String(remainingText[range.upperBound...])
        }

        // Add any remaining regular text
        if !remainingText.isEmpty {
            result = result + Text(remainingText)
        }

        return result
    }

    /// Formats bracketed content, highlighting any acronyms found within
    /// Brackets [ ] are gray, inner text is orange, acronyms are blue bold
    private static func formatBracketWithAcronyms(_ bracket: String, acronyms: [(short: String, full: String)]) -> Text {
        // Start with gray opening bracket
        var result = Text("[").foregroundColor(.secondary).italic()

        // Extract inner content (remove [ and ])
        var inner = bracket
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }

        // Sort acronyms by position in the inner text
        let sortedAcronyms = acronyms.sorted { first, second in
            let range1 = inner.range(of: first.short)
            let range2 = inner.range(of: second.short)
            if let r1 = range1, let r2 = range2 {
                return r1.lowerBound < r2.lowerBound
            }
            return range1 != nil
        }

        var remaining = inner
        for acronym in sortedAcronyms {
            if let range = remaining.range(of: acronym.short) {
                // Text before the acronym - orange
                let before = String(remaining[..<range.lowerBound])
                if !before.isEmpty {
                    result = result + Text(before)
                        .foregroundColor(Color.orange.opacity(0.8))
                        .italic()
                }

                // The acronym itself - highlighted distinctly in blue
                result = result + Text(acronym.short)
                    .foregroundColor(.blue)
                    .bold()
                    .italic()

                remaining = String(remaining[range.upperBound...])
            }
        }

        // Any remaining inner text after all acronyms - orange
        if !remaining.isEmpty {
            result = result + Text(remaining)
                .foregroundColor(Color.orange.opacity(0.8))
                .italic()
        }

        // End with gray closing bracket
        result = result + Text("]").foregroundColor(.secondary).italic()

        return result
    }
}
