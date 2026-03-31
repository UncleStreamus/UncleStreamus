import SwiftUI
import SwiftData

/// Filter state for history and favorites
class FilterState: ObservableObject {
    @Published var selectedPeriod: String? = nil
    @Published var selectedTour: String? = nil
    @Published var selectedCity: String? = nil
    @Published var selectedState: String? = nil
    @Published var selectedCountry: String? = nil
    @Published var searchText: String = ""
    /// Debounced version of searchText used for actual filtering (updated 250ms after typing stops)
    @Published private(set) var debouncedSearchText: String = ""
    private var debounceTask: Task<Void, Never>?

    var isActive: Bool {
        selectedPeriod != nil || selectedTour != nil ||
        selectedCity != nil || selectedState != nil || selectedCountry != nil
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Call when searchText changes to schedule a debounced update to debouncedSearchText.
    func scheduleDebounce() {
        let text = searchText
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            guard !Task.isCancelled else { return }
            self.debouncedSearchText = text
        }
    }

    func clear() {
        selectedPeriod = nil
        selectedTour = nil
        selectedCity = nil
        selectedState = nil
        selectedCountry = nil
    }

    func clearSearch() {
        debounceTask?.cancel()
        searchText = ""
        debouncedSearchText = ""
    }

    func clearAll() {
        clear()
        clearSearch()
    }
}

/// Dropdown filter button with popover
struct FilterDropdown: View {
    let title: String
    let options: [String]
    @Binding var selection: String?

    var body: some View {
        Menu {
            Button("All") {
                selection = nil
            }
            Divider()
            ForEach(options, id: \.self) { option in
                Button(action: {
                    selection = option
                }) {
                    HStack {
                        Text(option)
                        if selection == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection ?? title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .scaledFont(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selection != nil ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

/// Grouped dropdown organized by a category (tours by period, states/cities by country)
struct GroupedDropdown: View {
    let title: String
    let groups: [(header: String, items: [String])]
    @Binding var selection: String?

    var body: some View {
        Menu {
            Button("All") {
                selection = nil
            }
            Divider()
            ForEach(groups, id: \.header) { group in
                Section(header: Text("— \(group.header) —").font(.headline)) {
                    ForEach(group.items, id: \.self) { item in
                        Button(action: {
                            selection = item
                        }) {
                            HStack {
                                Text(item)
                                if selection == item {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection ?? title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .scaledFont(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selection != nil ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

/// Filter bar for the sidebar
struct FilterBar: View {
    @ObservedObject var filterState: FilterState
    let shows: [SavedShow]

    // Extract unique values from shows
    private var periods: [String] {
        let uniquePeriods = Set(shows.compactMap { $0.period })
        // Use the order from tourPeriods array for correct chronological order
        let periodOrder = GeoData.tourPeriods.map { $0.name }
        return periodOrder.filter { uniquePeriods.contains($0) }
    }

    private var tours: [String] {
        let filtered = filterState.selectedPeriod != nil
            ? shows.filter { $0.period == filterState.selectedPeriod }
            : shows
        return Array(Set(filtered.compactMap { $0.tour })).sorted()
    }

    /// Tours grouped by period for the grouped dropdown
    private var toursByPeriod: [(period: String, tours: [String])] {
        // Get all unique period-tour combinations
        var periodTourMap: [String: Set<String>] = [:]

        for show in shows {
            if let period = show.period, let tour = show.tour {
                if periodTourMap[period] == nil {
                    periodTourMap[period] = []
                }
                periodTourMap[period]?.insert(tour)
            }
        }

        // Use the order from tourPeriods array (defined in TourPeriods.swift)
        // This ensures correct chronological order (e.g., 1973 Ponty before 1973-74 Roxy)
        let periodOrder = GeoData.tourPeriods.map { $0.name }

        var result: [(period: String, tours: [String])] = []

        for period in periodOrder {
            if let tours = periodTourMap[period], !tours.isEmpty {
                result.append((period: period, tours: tours.sorted()))
                periodTourMap.removeValue(forKey: period)
            }
        }

        // Add any remaining periods not in GeoData.tourPeriods (shouldn't happen, but just in case)
        for period in periodTourMap.keys.sorted() {
            if let tours = periodTourMap[period], !tours.isEmpty {
                result.append((period: period, tours: tours.sorted()))
            }
        }

        return result
    }

    private var countries: [String] {
        Array(Set(shows.compactMap { $0.country })).sorted()
    }

    private var states: [String] {
        let filtered = filterState.selectedCountry != nil
            ? shows.filter { $0.country == filterState.selectedCountry }
            : shows
        return Array(Set(filtered.compactMap { $0.state })).sorted()
    }

    /// States grouped by country for the grouped dropdown
    private var statesByCountry: [(country: String, states: [String])] {
        // Get all unique country-state combinations
        var countryStateMap: [String: Set<String>] = [:]

        for show in shows {
            if let country = show.country, let state = show.state {
                if countryStateMap[country] == nil {
                    countryStateMap[country] = []
                }
                countryStateMap[country]?.insert(state)
            }
        }

        // Order: USA first, then Canada, then others alphabetically
        let countryOrder = ["USA", "Canada"]
        var result: [(country: String, states: [String])] = []

        for country in countryOrder {
            if let states = countryStateMap[country], !states.isEmpty {
                result.append((country: country, states: states.sorted()))
                countryStateMap.removeValue(forKey: country)
            }
        }

        // Add remaining countries alphabetically
        for country in countryStateMap.keys.sorted() {
            if let states = countryStateMap[country], !states.isEmpty {
                result.append((country: country, states: states.sorted()))
            }
        }

        return result
    }

    private var cities: [String] {
        var filtered = shows
        if let country = filterState.selectedCountry {
            filtered = filtered.filter { $0.country == country }
        }
        if let state = filterState.selectedState {
            filtered = filtered.filter { $0.state == state }
        }
        return Array(Set(filtered.compactMap { $0.city })).sorted()
    }

    /// Cities grouped by country for the grouped dropdown
    private var citiesByCountry: [(country: String, cities: [String])] {
        // Get all unique country-city combinations (respecting state filter if set)
        var countryCityMap: [String: Set<String>] = [:]

        var filtered = shows
        if let state = filterState.selectedState {
            filtered = filtered.filter { $0.state == state }
        }

        for show in filtered {
            if let country = show.country, let city = show.city {
                if countryCityMap[country] == nil {
                    countryCityMap[country] = []
                }
                countryCityMap[country]?.insert(city)
            }
        }

        // Order: USA first, then Canada, then others alphabetically
        let countryOrder = ["USA", "Canada"]
        var result: [(country: String, cities: [String])] = []

        for country in countryOrder {
            if let cities = countryCityMap[country], !cities.isEmpty {
                result.append((country: country, cities: cities.sorted()))
                countryCityMap.removeValue(forKey: country)
            }
        }

        // Add remaining countries alphabetically
        for country in countryCityMap.keys.sorted() {
            if let cities = countryCityMap[country], !cities.isEmpty {
                result.append((country: country, cities: cities.sorted()))
            }
        }

        return result
    }

    @State private var isExpanded: Bool = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Search and Filter row
            HStack(spacing: 8) {
                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Search shows...", text: $filterState.searchText)
                        .textFieldStyle(.plain)
                        .scaledFont(.caption)
                        .focused($isSearchFocused)
                        .onChange(of: filterState.searchText) { _, _ in
                            filterState.scheduleDebounce()
                        }
                    if filterState.isSearching {
                        Button(action: { filterState.clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)

                // Filter toggle button
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    HStack(spacing: 4) {
                        Text("Filter")
                        if filterState.isActive {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .scaledFont(.caption)
                    .foregroundColor(filterState.isActive ? .accentColor : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                // Period & Tour row
                HStack(spacing: 6) {
                    FilterDropdown(title: "Period", options: periods, selection: $filterState.selectedPeriod)
                        .onChange(of: filterState.selectedPeriod) { _, _ in
                            // Clear tour when period changes
                            filterState.selectedTour = nil
                        }

                    if filterState.selectedPeriod != nil {
                        // When a period is selected, show simple tour dropdown
                        if !tours.isEmpty {
                            FilterDropdown(title: "Tour", options: tours, selection: $filterState.selectedTour)
                        }
                    } else {
                        // When no period is selected, show grouped tour dropdown
                        if !toursByPeriod.isEmpty {
                            GroupedDropdown(title: "Tour", groups: toursByPeriod.map { (header: $0.period, items: $0.tours) }, selection: $filterState.selectedTour)
                        }
                    }
                }

                // Location row
                HStack(spacing: 6) {
                    FilterDropdown(title: "Country", options: countries, selection: $filterState.selectedCountry)
                        .onChange(of: filterState.selectedCountry) { _, _ in
                            filterState.selectedState = nil
                            filterState.selectedCity = nil
                        }

                    if filterState.selectedCountry != nil {
                        // When a country is selected, show simple state dropdown
                        if !states.isEmpty {
                            FilterDropdown(title: "State", options: states, selection: $filterState.selectedState)
                                .onChange(of: filterState.selectedState) { _, _ in
                                    filterState.selectedCity = nil
                                }
                        }
                    } else {
                        // When no country is selected, show grouped state dropdown
                        if !statesByCountry.isEmpty {
                            GroupedDropdown(title: "State", groups: statesByCountry.map { (header: $0.country, items: $0.states) }, selection: $filterState.selectedState)
                                .onChange(of: filterState.selectedState) { _, _ in
                                    filterState.selectedCity = nil
                                }
                        }
                    }

                    if filterState.selectedCountry != nil {
                        // When a country is selected, show simple city dropdown
                        if !cities.isEmpty {
                            FilterDropdown(title: "City", options: cities, selection: $filterState.selectedCity)
                        }
                    } else {
                        // When no country is selected, show grouped city dropdown
                        if !citiesByCountry.isEmpty {
                            GroupedDropdown(title: "City", groups: citiesByCountry.map { (header: $0.country, items: $0.cities) }, selection: $filterState.selectedCity)
                        }
                    }
                }

                // Clear filters button
                if filterState.isActive {
                    Button(action: { filterState.clear() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Clear filters")
                        }
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        #if os(macOS)
        .onAppear {
            // Prevent automatic focus on the search field - delay needed for SwiftUI focus system
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = false
            }
        }
        #endif
    }
}

// MARK: - Search Helper

extension SavedShow {
    /// Check if any searchable field contains the search text
    func matches(searchText: String) -> Bool {
        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }

        // Search across all relevant fields
        let searchableFields: [String?] = [
            showDate,
            venue,
            soundcheck,
            note,
            showInfo,
            city,
            state,
            country,
            period,
            tour
        ]

        // Check basic fields
        for field in searchableFields {
            if let field = field, field.lowercased().contains(query) {
                return true
            }
        }

        // Check setlist items
        for song in setlist {
            if song.lowercased().contains(query) {
                return true
            }
        }

        // Check acronyms (both short and full forms)
        for acronym in acronyms {
            if acronym.short.lowercased().contains(query) ||
               acronym.full.lowercased().contains(query) {
                return true
            }
        }

        return false
    }
}

/// Extension to filter SavedShow arrays
extension Array where Element == SavedShow {
    func filtered(by filterState: FilterState) -> [SavedShow] {
        var result = self

        // Apply search filter using debounced text (avoids per-keystroke JSON decoding of all shows)
        if !filterState.debouncedSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
            result = result.filter { $0.matches(searchText: filterState.debouncedSearchText) }
        }

        // Apply dropdown filters
        if let period = filterState.selectedPeriod {
            result = result.filter { $0.period == period }
        }
        if let tour = filterState.selectedTour {
            result = result.filter { $0.tour == tour }
        }
        if let country = filterState.selectedCountry {
            result = result.filter { $0.country == country }
        }
        if let state = filterState.selectedState {
            result = result.filter { $0.state == state }
        }
        if let city = filterState.selectedCity {
            result = result.filter { $0.city == city }
        }

        return result
    }
}
