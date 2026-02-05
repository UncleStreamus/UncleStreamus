import SwiftUI
import SwiftData

struct SidebarView: View {
    var showDataManager: ShowDataManager
    @State private var selectedTab: SidebarTab = .history

    enum SidebarTab {
        case history, favorites
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("History").tag(SidebarTab.history)
                Text("Favorites").tag(SidebarTab.favorites)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .history:
                HistoryListView(showDataManager: showDataManager)
            case .favorites:
                FavoritesListView(showDataManager: showDataManager)
            }
        }
        .frame(width: 280)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - History List with sticky date headers

struct HistoryListView: View {
    var showDataManager: ShowDataManager

    @Query(filter: #Predicate<SavedShow> { $0.listenedAt != nil },
           sort: \SavedShow.listenedAt, order: .reverse)
    private var history: [SavedShow]

    private var groupedHistory: [(String, [SavedShow])] {
        let calendar = Calendar.current
        let now = Date()

        var groups: [String: [SavedShow]] = [:]
        var groupOrder: [String] = []

        for show in history {
            guard let date = show.listenedAt else { continue }

            let label: String
            if calendar.isDateInToday(date) {
                label = "Today"
            } else if calendar.isDateInYesterday(date) {
                label = "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                label = formatter.string(from: date)
            }

            if groups[label] == nil {
                groups[label] = []
                groupOrder.append(label)
            }
            groups[label]?.append(show)
        }

        return groupOrder.map { ($0, groups[$0]!) }
    }

    var body: some View {
        if history.isEmpty {
            VStack {
                Spacer()
                Text("No listening history yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Play a show to start tracking")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedHistory, id: \.0) { dateLabel, shows in
                        Section {
                            ForEach(shows) { show in
                                ShowEntryRow(savedShow: show, showDataManager: showDataManager)
                            }
                        } header: {
                            Text(dateLabel)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Favorites List

struct FavoritesListView: View {
    var showDataManager: ShowDataManager

    @Query(filter: #Predicate<SavedShow> { $0.isFavorite == true },
           sort: \SavedShow.showDate, order: .reverse)
    private var favorites: [SavedShow]

    private var groupedFavorites: [(String, [SavedShow])] {
        var groups: [String: [SavedShow]] = [:]
        var groupOrder: [String] = []

        for show in favorites {
            // Extract first 4 characters: "2024 02 05" → "2024"
            let year = String(show.showDate.prefix(4))
            
            if groups[year] == nil {
                groups[year] = []
                groupOrder.append(year)
            }
            groups[year]?.append(show)
        }

        return groupOrder.map { ($0, groups[$0]!) }
    }

    var body: some View {
        if favorites.isEmpty {
            VStack {
                Spacer()
                Text("No favorites yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Tap the star on a show to save it")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedFavorites, id: \.0) { year, shows in
                        Section {
                            ForEach(shows) { show in
                                ShowEntryRow(savedShow: show, showDataManager: showDataManager)
                            }
                        } header: {
                            Text(year)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}
