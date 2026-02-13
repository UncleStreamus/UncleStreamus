import SwiftUI
import SwiftData

// MARK: - Scroll Offset Tracking

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SidebarView: View {
    var showDataManager: ShowDataManager
    @Binding var selectedTab: SidebarTab
    @StateObject private var historyFilter = FilterState()
    @StateObject private var favoritesFilter = FilterState()

    enum SidebarTab {
        case history, favorites
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("History").tag(SidebarTab.history)
                Text("Favourites").tag(SidebarTab.favorites)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Wrap list content with tap gesture for keyboard dismissal
            // (not the picker, which needs its own tap handling)
            Group {
                switch selectedTab {
                case .history:
                    HistoryListView(showDataManager: showDataManager, filterState: historyFilter)
                case .favorites:
                    FavoritesListView(showDataManager: showDataManager, filterState: favoritesFilter)
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    #if os(iOS)
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    #elseif os(macOS)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    #endif
                }
            )
        }
        #if os(macOS)
        .frame(width: 280)
        #endif
        .background(Color.controlBackground)
    }
}

// MARK: - History List with sticky date headers

struct HistoryListView: View {
    var showDataManager: ShowDataManager
    @ObservedObject var filterState: FilterState
    @State private var showFilterBar: Bool = false
    @State private var initialScrollOffset: CGFloat = 0
    @State private var hasSetInitialOffset: Bool = false

    @Query(filter: #Predicate<SavedShow> { $0.listenedAt != nil },
           sort: \SavedShow.listenedAt, order: .reverse)
    private var history: [SavedShow]

    private var filteredHistory: [SavedShow] {
        history.filtered(by: filterState)
    }

    private var groupedHistory: [(String, [SavedShow])] {
        let calendar = Calendar.current

        var groups: [String: [SavedShow]] = [:]
        var groupOrder: [String] = []

        for show in filteredHistory {
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
        VStack(spacing: 0) {
            // Filter bar - shown when scrolled
            if !history.isEmpty && showFilterBar {
                FilterBar(filterState: filterState, shows: history)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }

            if history.isEmpty {
                VStack {
                    Spacer()
                    Text("No listening history yet")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Text("Play a show to start tracking")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if filteredHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No shows match filters")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Button("Clear filters") {
                        filterState.clear()
                    }
                    .scaledFont(.caption2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Invisible anchor at the very top to detect pull-down
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geo.frame(in: .global).minY
                            )
                        }
                        .frame(height: 0)

                        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                            ForEach(groupedHistory, id: \.0) { dateLabel, shows in
                                Section {
                                    ForEach(shows) { show in
                                        ShowEntryRow(savedShow: show, showDataManager: showDataManager)
                                    }
                                } header: {
                                    Text(dateLabel)
                                        .scaledFont(.subheadline, weight: .bold)
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.sectionHeaderBackground)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { minY in
                    // Capture initial offset on first reading
                    if !hasSetInitialOffset {
                        initialScrollOffset = minY
                        hasSetInitialOffset = true
                        return
                    }
                    // When pulled down, minY increases beyond its resting position
                    if !showFilterBar && minY > initialScrollOffset + 20 {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showFilterBar = true
                        }
                    }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFilterBar)
    }
}

// MARK: - Favorites List

struct FavoritesListView: View {
    var showDataManager: ShowDataManager
    @ObservedObject var filterState: FilterState
    @State private var collapsedYears: Set<String> = []
    @State private var showFilterBar: Bool = false
    @State private var initialScrollOffset: CGFloat = 0
    @State private var hasSetInitialOffset: Bool = false

    @Query(filter: #Predicate<SavedShow> { $0.isFavorite == true },
           sort: \SavedShow.showDate, order: .reverse)
    private var favorites: [SavedShow]

    private var filteredFavorites: [SavedShow] {
        favorites.filtered(by: filterState)
    }

    private var groupedFavorites: [(String, [SavedShow])] {
        var groups: [String: [SavedShow]] = [:]
        var groupOrder: [String] = []

        for show in filteredFavorites {
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

    private func toggleYear(_ year: String, shiftPressed: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if shiftPressed {
                // Shift-click: toggle all years
                let allYears = Set(groupedFavorites.map { $0.0 })
                if collapsedYears.contains(year) {
                    // Expand all
                    collapsedYears.removeAll()
                } else {
                    // Collapse all
                    collapsedYears = allYears
                }
            } else {
                // Normal click: toggle single year
                if collapsedYears.contains(year) {
                    collapsedYears.remove(year)
                } else {
                    collapsedYears.insert(year)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar - shown when scrolled
            if !favorites.isEmpty && showFilterBar {
                FilterBar(filterState: filterState, shows: favorites)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }

            if favorites.isEmpty {
                VStack {
                    Spacer()
                    Text("No favourites yet")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Text("Tap the star on a show to save it")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if filteredFavorites.isEmpty {
                VStack {
                    Spacer()
                    Text("No shows match filters")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Button("Clear filters") {
                        filterState.clear()
                    }
                    .scaledFont(.caption2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Invisible anchor at the very top to detect pull-down
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geo.frame(in: .global).minY
                            )
                        }
                        .frame(height: 0)

                        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                            ForEach(groupedFavorites, id: \.0) { year, shows in
                                Section {
                                    if !collapsedYears.contains(year) {
                                        ForEach(shows) { show in
                                            ShowEntryRow(savedShow: show, showDataManager: showDataManager)
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text(year)
                                            .scaledFont(.subheadline, weight: .bold)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: collapsedYears.contains(year) ? "chevron.right" : "chevron.down")
                                            .scaledFont(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.sectionHeaderBackground)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        #if os(macOS)
                                        let shiftPressed = NSEvent.modifierFlags.contains(.shift)
                                        #else
                                        let shiftPressed = false
                                        #endif
                                        toggleYear(year, shiftPressed: shiftPressed)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { minY in
                    // Capture initial offset on first reading
                    if !hasSetInitialOffset {
                        initialScrollOffset = minY
                        hasSetInitialOffset = true
                        return
                    }
                    // When pulled down, minY increases beyond its resting position
                    if !showFilterBar && minY > initialScrollOffset + 20 {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showFilterBar = true
                        }
                    }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFilterBar)
    }
}
