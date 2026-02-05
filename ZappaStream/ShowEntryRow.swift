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
                if !songs.isEmpty {
                    Text("Setlist:")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.top, 2)

                    ForEach(Array(songs.enumerated()), id: \.offset) { idx, song in
                        Text("\(idx + 1). \(song)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
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
}
