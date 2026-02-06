import SwiftUI

struct ShowEntryRow: View {
    let savedShow: SavedShow
    var showDataManager: ShowDataManager?
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(savedShow.showDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(savedShow.venue)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()

                if let manager = showDataManager {
                    Button(action: {
                        manager.toggleFavorite(savedShow: savedShow)
                    }) {
                        Image(systemName: savedShow.isFavorite ? "star.fill" : "star")
                            .foregroundColor(savedShow.isFavorite ? .yellow : .gray)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !savedShow.showInfo.isEmpty {
                Text(savedShow.showInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if isExpanded {
                Divider()

                if let note = savedShow.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                let songs = savedShow.setlist
                let acronyms = savedShow.acronymTuples
                if !songs.isEmpty {
                    Text("Setlist:")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.top, 2)

                    ForEach(Array(songs.enumerated()), id: \.offset) { idx, song in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\(idx + 1).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            formatSong(song, acronyms: acronyms)
                                .font(.caption2)
                        }
                    }
                }

                if !savedShow.url.isEmpty {
                    Button("View on FZShows website") {
                        if let url = URL(string: savedShow.url) {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                    .font(.caption2)
                    .padding(.top, 4)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { isExpanded.toggle() } }
    }

    // MARK: - Song Formatting

    @ViewBuilder
    private func formatSong(_ song: String, acronyms: [(short: String, full: String)]) -> some View {
        var result = Text("")
        var remainingText = song

        // 1. Process brackets [like this] with acronym highlighting
        while let bracketRange = remainingText.range(of: #"\[[^\]]+\]"#, options: .regularExpression) {
            let before = String(remainingText[..<bracketRange.lowerBound])
            if !before.isEmpty {
                result = result + Text(before)
            }

            let bracketContent = String(remainingText[bracketRange])
            result = result + formatBracketWithAcronyms(bracketContent, acronyms: acronyms)

            remainingText = String(remainingText[bracketRange.upperBound...])
        }

        // 2. Process parentheses (q: something) or (incl. something) ONLY
        while let parenRange = remainingText.range(of: #"\((q:|incl\.)[^)]+\)"#, options: .regularExpression) {
            let before = String(remainingText[..<parenRange.lowerBound])
            if !before.isEmpty {
                result = result + Text(before)
            }

            let parenContent = String(remainingText[parenRange])
            result = result + Text(parenContent)
                .italic()

            remainingText = String(remainingText[parenRange.upperBound...])
        }

        // 3. Remaining regular text
        if !remainingText.isEmpty {
            result = result + Text(remainingText)
        }

        return result
    }

    /// Formats bracketed content, highlighting any acronyms found within
    private func formatBracketWithAcronyms(_ bracket: String, acronyms: [(short: String, full: String)]) -> Text {
        var result = Text("")
        var remaining = bracket

        // Sort acronyms by position in the bracket text
        let sortedAcronyms = acronyms.sorted { first, second in
            let range1 = remaining.range(of: first.short)
            let range2 = remaining.range(of: second.short)
            if let r1 = range1, let r2 = range2 {
                return r1.lowerBound < r2.lowerBound
            }
            return range1 != nil
        }

        for acronym in sortedAcronyms {
            if let range = remaining.range(of: acronym.short) {
                // Text before the acronym
                let before = String(remaining[..<range.lowerBound])
                if !before.isEmpty {
                    result = result + Text(before)
                        .foregroundColor(.secondary)
                        .italic()
                }

                // The acronym itself - highlighted distinctly
                result = result + Text(acronym.short)
                    .foregroundColor(.blue)
                    .bold()

                remaining = String(remaining[range.upperBound...])
            }
        }

        // Any remaining bracket text after all acronyms
        if !remaining.isEmpty {
            result = result + Text(remaining)
                .foregroundColor(.secondary)
                .italic()
        }

        return result
    }
}
