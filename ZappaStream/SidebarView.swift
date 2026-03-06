import SwiftUI
import SwiftData

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

// MARK: - History Time Period

enum HistoryTimePeriod: String, CaseIterable {
    case thisWeek = "This Week"  // Last 7 days, not displayed as a collapsible header
    case oneWeekAgo = "One Week Ago"
    case twoWeeksAgo = "Two Weeks Ago"
    case threeWeeksAgo = "Three Weeks Ago"
    case fourWeeksAgo = "Four Weeks Ago"
    case oneMonthAgo = "One Month Ago"
    case older = "Older"

    var isCollapsible: Bool {
        self != .thisWeek
    }

    static func period(for date: Date, calendar: Calendar = .current) -> HistoryTimePeriod {
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Rolling windows relative to "today"
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: startOfToday)!
        let twentyOneDaysAgo = calendar.date(byAdding: .day, value: -21, to: startOfToday)!
        let twentyEightDaysAgo = calendar.date(byAdding: .day, value: -28, to: startOfToday)!
        let thirtyOneDaysAgo = calendar.date(byAdding: .day, value: -31, to: startOfToday)!
        let sixtyTwoDaysAgo = calendar.date(byAdding: .day, value: -62, to: startOfToday)!

        if date >= sevenDaysAgo {
            // Last 7 days (including today)
            return .thisWeek
        } else if date >= fourteenDaysAgo {
            // 7–14 days ago
            return .oneWeekAgo
        } else if date >= twentyOneDaysAgo {
            // 14–21 days ago
            return .twoWeeksAgo
        } else if date >= twentyEightDaysAgo {
            // 21–28 days ago
            return .threeWeeksAgo
        } else if date >= thirtyOneDaysAgo {
            // 28–31 days ago
            return .fourWeeksAgo
        } else if date >= sixtyTwoDaysAgo {
            // 31–62 days ago
            return .oneMonthAgo
        } else {
            // Older than 62 days
            return .older
        }
    }
}

// MARK: - History Section (for flattened list)

struct HistorySection {
    let id: String
    let title: String
    let shows: [SavedShow]
    let isPeriodHeader: Bool
    let period: HistoryTimePeriod?  // Set if this is a period header
    let showCount: Int
    let parentPeriod: HistoryTimePeriod?  // Set if this date section belongs to a collapsible period
    let dateGroups: [(String, [SavedShow])]  // For period sections: the date groupings within
}

// MARK: - History List with collapsible time periods

struct HistoryListView: View {
    var showDataManager: ShowDataManager
    @ObservedObject var filterState: FilterState
    @State private var collapsedPeriods: Set<HistoryTimePeriod> = [
        .oneWeekAgo, .twoWeeksAgo, .threeWeeksAgo, .fourWeeksAgo, .oneMonthAgo, .older
    ]

    @Query(filter: #Predicate<SavedShow> { $0.listenedAt != nil },
           sort: \SavedShow.listenedAt, order: .reverse)
    private var history: [SavedShow]

    private var filteredHistory: [SavedShow] {
        history.filtered(by: filterState)
    }

    // Group shows by time period, then by date within each period
    private var groupedByPeriod: [(HistoryTimePeriod, [(String, [SavedShow])])] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        // First, group by period
        var periodGroups: [HistoryTimePeriod: [SavedShow]] = [:]

        for show in filteredHistory {
            guard let date = show.listenedAt else { continue }
            let period = HistoryTimePeriod.period(for: date, calendar: calendar)

            if periodGroups[period] == nil {
                periodGroups[period] = []
            }
            periodGroups[period]?.append(show)
        }

        // Now, for each period, group by date
        var result: [(HistoryTimePeriod, [(String, [SavedShow])])] = []

        for period in HistoryTimePeriod.allCases {
            guard let shows = periodGroups[period], !shows.isEmpty else { continue }

            var dateGroups: [String: [SavedShow]] = [:]
            var dateOrder: [String] = []

            for show in shows {
                guard let date = show.listenedAt else { continue }

                let label: String
                if calendar.isDateInToday(date) {
                    label = "Today"
                } else if calendar.isDateInYesterday(date) {
                    label = "Yesterday"
                } else {
                    label = dateFormatter.string(from: date)
                }

                if dateGroups[label] == nil {
                    dateGroups[label] = []
                    dateOrder.append(label)
                }
                dateGroups[label]?.append(show)
            }

            let datesWithShows = dateOrder.map { ($0, dateGroups[$0]!) }
            result.append((period, datesWithShows))
        }

        return result
    }

    private func togglePeriod(_ period: HistoryTimePeriod, shiftPressed: Bool) {
        guard period.isCollapsible else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            if shiftPressed {
                // Shift-click: toggle all collapsible periods
                let allCollapsiblePeriods = Set(groupedByPeriod.map { $0.0 }.filter { $0.isCollapsible })
                if collapsedPeriods.contains(period) {
                    // Expand all
                    collapsedPeriods.removeAll()
                } else {
                    // Collapse all
                    collapsedPeriods = allCollapsiblePeriods
                }
            } else {
                // Normal click: toggle single period
                if collapsedPeriods.contains(period) {
                    collapsedPeriods.remove(period)
                } else {
                    collapsedPeriods.insert(period)
                }
            }
        }
    }

    private func showCount(for period: HistoryTimePeriod) -> Int {
        groupedByPeriod.first { $0.0 == period }?.1.reduce(0) { $0 + $1.1.count } ?? 0
    }

    // Build sections where period headers contain all their shows as content
    // This allows period headers to be pinned while scrolling through their content
    private func buildFlattenedSections(collapsedPeriods: Set<HistoryTimePeriod>) -> [HistorySection] {
        var sections: [HistorySection] = []

        for (period, dateGroups) in groupedByPeriod {
            if period.isCollapsible {
                // Collapsible period: one section with all shows as content
                let allShows = dateGroups.flatMap { $0.1 }
                let periodShowCount = allShows.count

                sections.append(HistorySection(
                    id: "period-\(period.rawValue)",
                    title: period.rawValue,
                    shows: collapsedPeriods.contains(period) ? [] : allShows,
                    isPeriodHeader: true,
                    period: period,
                    showCount: periodShowCount,
                    parentPeriod: nil,
                    dateGroups: collapsedPeriods.contains(period) ? [] : dateGroups
                ))
            } else {
                // This week: add date sections directly (these will have sticky date headers)
                for (dateLabel, shows) in dateGroups {
                    sections.append(HistorySection(
                        id: "date-thisweek-\(dateLabel)",
                        title: dateLabel,
                        shows: shows,
                        isPeriodHeader: false,
                        period: nil,
                        showCount: shows.count,
                        parentPeriod: nil,
                        dateGroups: []
                    ))
                }
            }
        }

        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            if !history.isEmpty {
                FilterBar(filterState: filterState, shows: history)
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
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(buildFlattenedSections(collapsedPeriods: collapsedPeriods), id: \.id) { section in
                            Section {
                                if section.isPeriodHeader {
                                    // Period section content: date groups with their shows
                                    ForEach(section.dateGroups, id: \.0) { dateLabel, shows in
                                        // Date header (non-sticky, within period)
                                        Text(dateLabel)
                                            .scaledFont(.subheadline, weight: .bold)
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.sectionHeaderBackground)

                                        // Shows for this date
                                        ForEach(shows) { show in
                                            ShowEntryRow(savedShow: show, showDataManager: showDataManager)
                                        }
                                    }
                                } else {
                                    // This week date section: shows directly
                                    ForEach(section.shows) { show in
                                        ShowEntryRow(savedShow: show, showDataManager: showDataManager)
                                    }
                                }
                            } header: {
                                if section.isPeriodHeader {
                                    // Period header (collapsible, sticky)
                                    HStack {
                                        Text(section.title.uppercased())
                                            .scaledFont(.caption, weight: .heavy)
                                            .foregroundColor(.secondary)
                                            .tracking(0.5)

                                        Text("(\(section.showCount))")
                                            .scaledFont(.caption)
                                            .foregroundColor(.secondary.opacity(0.7))

                                        Spacer()

                                        Image(systemName: collapsedPeriods.contains(section.period!) ? "chevron.right" : "chevron.down")
                                            .scaledFont(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.controlBackground)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        #if os(macOS)
                                        let shiftPressed = NSEvent.modifierFlags.contains(.shift)
                                        #else
                                        let shiftPressed = false
                                        #endif
                                        togglePeriod(section.period!, shiftPressed: shiftPressed)
                                    }
                                } else {
                                    // This week date header (sticky)
                                    Text(section.title)
                                        .scaledFont(.subheadline, weight: .bold)
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.sectionHeaderBackground)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
        }
    }
}

// MARK: - Favorites List

struct FavoritesListView: View {
    var showDataManager: ShowDataManager
    @ObservedObject var filterState: FilterState
    @State private var collapsedYears: Set<String> = []

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
            // Filter bar
            if !favorites.isEmpty {
                FilterBar(filterState: filterState, shows: favorites)
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
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
        }
    }
}
