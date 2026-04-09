import SwiftUI

struct ShowEntryRow: View {
    let savedShow: SavedShow
    var showDataManager: ShowDataManager?
    @State private var isExpanded: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var acronymsExpanded: Bool = false
    @State private var setlistInfoItem: SetlistInfoItem?
    #if os(iOS)
    @State private var bugReportData: BugReportData?
    #endif
    @Environment(\.openURL) private var openURL

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
                        .foregroundColor(Color.red.opacity(0.8))
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

                    // Collapsible official releases section
                    if !acronyms.isEmpty {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                acronymsExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 1) {
                                Text("[")
                                    .scaledFont(.caption2, weight: .medium)
                                    .foregroundColor(.secondary)
                                Text("Official Releases")
                                    .scaledFont(.caption2, weight: .medium)
                                    .foregroundColor(Color.orange.opacity(0.8))
                                Text("]")
                                    .scaledFont(.caption2, weight: .medium)
                                    .foregroundColor(.secondary)
                                Image(systemName: acronymsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 16)

                        if acronymsExpanded {
                            // Deduplicate acronyms (same short form only listed once)
                            let uniqueAcronyms = acronyms.reduce(into: [(short: String, full: String)]()) { result, acronym in
                                if !result.contains(where: { $0.short == acronym.short }) {
                                    result.append(acronym)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(uniqueAcronyms, id: \.short) { acronym in
                                    (Text(acronym.short)
                                        .foregroundColor(.blue)
                                        .bold()
                                     + Text(" = \(acronym.full)")
                                        .foregroundColor(.secondary))
                                        .scaledFont(.caption2)
                                        .italic()
                                }
                            }
                            .padding(.leading, 8)
                        }
                    }
                }

                if !savedShow.url.isEmpty {
                    Button("Setlist Info (FZShows)...") {
                        if let url = URL(string: savedShow.url) {
                            setlistInfoItem = SetlistInfoItem(url: url, showDate: savedShow.showDate)
                        }
                    }
                    .scaledFont(.caption2)
                    .padding(.top, 8)
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
                        setlistInfoItem = SetlistInfoItem(url: url, showDate: savedShow.showDate)
                    }
                }) {
                    Label("Setlist Info (FZShows)...", systemImage: "list.bullet.rectangle")
                }
            }

            Button(action: {
                let reportData = BugReportData(
                    showDate: savedShow.showDate,
                    venue: savedShow.venue,
                    url: savedShow.url,
                    rawMetadata: nil,
                    trackName: nil,
                    source: nil,
                    streamFormat: nil
                )
                #if os(iOS)
                bugReportData = reportData
                #else
                reportData.openMailClient()
                #endif
            }) {
                Label("Report Issue...", systemImage: "envelope")
            }
        }
        .sheet(item: $setlistInfoItem) { item in
            SetlistInfoPaneView(item: item)
        }
        #if os(iOS)
        .sheet(item: $bugReportData) { data in
            if MailComposerView.canSendMail {
                MailComposerView(data: data)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Mail Not Available")
                        .font(.headline)
                    Text("Please configure a mail account in Settings to send bug reports.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("OK") {
                        bugReportData = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        #endif
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
            #if DEBUG
            if success {
                print("✅ Show info refreshed successfully")
            } else {
                print("❌ Failed to refresh show info")
            }
            #endif
        }
    }

    // MARK: - Song Formatting

    /// Formats a song name using the shared SongFormatter
    private func formatSong(_ song: String, acronyms: [(short: String, full: String)]) -> Text {
        SongFormatter.format(song, acronyms: acronyms)
    }
}
