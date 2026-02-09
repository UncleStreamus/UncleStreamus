import SwiftUI

struct ShowEntryRow: View {
    let savedShow: SavedShow
    var showDataManager: ShowDataManager?
    @State private var isExpanded: Bool = false
    @State private var isRefreshing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(savedShow.showDate)
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Text(savedShow.venue)
                        .scaledFont(.subheadline, weight: .medium)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()

                if let manager = showDataManager {
                    Button(action: {
                        manager.toggleFavorite(savedShow: savedShow)
                    }) {
                        Image(systemName: savedShow.isFavorite ? "star.fill" : "star")
                            .foregroundColor(savedShow.isFavorite ? .yellow : .gray)
                            .scaledFont(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !savedShow.showInfo.isEmpty {
                Text(savedShow.showInfo)
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
            }

            if isExpanded {
                Divider()

                if let note = savedShow.note {
                    Text(note)
                        .scaledFont(.caption2)
                        .foregroundColor(.orange)
                }

                let songs = savedShow.setlist
                let acronyms = savedShow.acronymTuples
                if !songs.isEmpty {
                    Text("Setlist:")
                        .scaledFont(.caption2, weight: .semibold)
                        .padding(.top, 2)

                    ForEach(Array(songs.enumerated()), id: \.offset) { idx, song in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\(idx + 1).")
                                .scaledFont(.caption2)
                                .foregroundColor(.secondary)
                            formatSong(song, acronyms: acronyms)
                                .scaledFont(.caption2)
                        }
                    }
                }

                if !savedShow.url.isEmpty {
                    Button("View on FZShows") {
                        if let url = URL(string: savedShow.url) {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                    .scaledFont(.caption2)
                    .padding(.top, 4)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { isExpanded.toggle() } }
        .contextMenu {
            Button(action: {
                refreshShowInfo()
            }) {
                Label("Refresh Info", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)

            if !savedShow.url.isEmpty {
                Button(action: {
                    if let url = URL(string: savedShow.url) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("View on FZShows", systemImage: "safari")
                }
            }
        }
        .overlay {
            if isRefreshing {
                Color.black.opacity(0.3)
                    .cornerRadius(6)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
            }
        }
    }

    private func refreshShowInfo() {
        guard let manager = showDataManager else { return }
        isRefreshing = true
        manager.refreshShowInfo(savedShow: savedShow) { success in
            isRefreshing = false
            if success {
                print("✅ Show info refreshed successfully")
            } else {
                print("❌ Failed to refresh show info")
            }
        }
    }

    // MARK: - Song Formatting

    /// Formats a song name using the shared SongFormatter
    private func formatSong(_ song: String, acronyms: [(short: String, full: String)]) -> Text {
        SongFormatter.format(song, acronyms: acronyms)
    }
}
