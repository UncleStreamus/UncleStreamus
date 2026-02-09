import Foundation

/// Defines the tour periods and their associated HTML pages
struct TourPeriod {
    let name: String
    let filename: String
    let yearRange: ClosedRange<Int>
}

/// All tour periods from FZShows, matching the index page titles
let tourPeriods: [TourPeriod] = [
    TourPeriod(name: "1966-1969: The Sixties", filename: "6669.html", yearRange: 1966...1969),
    TourPeriod(name: "1969-1970: Hot Rats / MOI reunion", filename: "6970.html", yearRange: 1969...1970),
    TourPeriod(name: "1970-1971: MOI with Flo & Eddie", filename: "7071.html", yearRange: 1970...1971),
    TourPeriod(name: "1972: Grand and Petit Wazoo", filename: "72.html", yearRange: 1972...1972),
    TourPeriod(name: "1973: MOI with J.L. Ponty", filename: "73.html", yearRange: 1973...1973),
    TourPeriod(name: "1973-1974: Roxy & Elsewhere", filename: "7374.html", yearRange: 1973...1974),
    TourPeriod(name: "1975: The Bongo Fury tour", filename: "75.html", yearRange: 1975...1975),
    TourPeriod(name: "1975-1976: World tour", filename: "7576.html", yearRange: 1975...1976),
    TourPeriod(name: "1976-1977: US-Canada / Europe tours", filename: "7677.html", yearRange: 1976...1977),
    TourPeriod(name: "1977-1978: Sheik Yerbouti tours", filename: "7778.html", yearRange: 1977...1978),
    TourPeriod(name: "1978: World tour", filename: "78.html", yearRange: 1978...1978),
    TourPeriod(name: "1979: European tour", filename: "79.html", yearRange: 1979...1979),
    TourPeriod(name: "1980: Spring-Summer tours", filename: "80.html", yearRange: 1980...1980),
    TourPeriod(name: "1980: Fall tour", filename: "80fall.html", yearRange: 1980...1980),
    TourPeriod(name: "1981-1982: US-Canada / Europe tours", filename: "8182.html", yearRange: 1981...1982),
    TourPeriod(name: "1984: 20th Anniversary World tour", filename: "84.html", yearRange: 1984...1984),
    TourPeriod(name: "1988: The last tour", filename: "88.html", yearRange: 1988...1988),
    TourPeriod(name: "Pre-tour Rehearsals", filename: "rehearsals.html", yearRange: 1977...1987),
]

/// Maps HTML filename to period name
func periodName(forFilename filename: String) -> String? {
    tourPeriods.first { $0.filename == filename }?.name
}

/// US state abbreviations for parsing venues
let usStateAbbreviations: Set<String> = [
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
    "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
    "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
    "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
    "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
    "DC"
]

/// Canadian province abbreviations
let canadianProvinceAbbreviations: Set<String> = [
    "AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "QC", "SK", "YT"
]

/// Known countries that appear in FZShows venues
let knownCountries: Set<String> = [
    "Australia", "Austria", "Belgium", "Canada", "Denmark", "England",
    "Finland", "France", "Germany", "Holland", "Ireland", "Italy",
    "Japan", "Netherlands", "New Zealand", "Norway", "Scotland",
    "Spain", "Sweden", "Switzerland", "UK", "USA", "Wales", "West Germany"
]

/// Parses location from venue string
/// Format: "Venue Name, City, State" or "Venue Name, City, Country"
func parseLocation(from venue: String) -> (city: String?, state: String?, country: String?) {
    let components = venue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

    guard components.count >= 2 else {
        return (nil, nil, nil)
    }

    // Last component is usually state/country
    let lastComponent = components.last!

    // Check if it's a US state abbreviation
    if usStateAbbreviations.contains(lastComponent.uppercased()) {
        let city = components.count >= 3 ? components[components.count - 2] : nil
        return (city, lastComponent, "USA")
    }

    // Check if it's a Canadian province
    if canadianProvinceAbbreviations.contains(lastComponent.uppercased()) {
        let city = components.count >= 3 ? components[components.count - 2] : nil
        return (city, lastComponent, "Canada")
    }

    // Check if it's a known country
    if knownCountries.contains(lastComponent) {
        let city = components.count >= 3 ? components[components.count - 2] : nil
        return (city, nil, lastComponent)
    }

    // Otherwise assume last is city in an international location
    return (lastComponent, nil, nil)
}
