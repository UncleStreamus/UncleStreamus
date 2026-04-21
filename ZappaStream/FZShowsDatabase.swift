import Foundation
import SwiftData

extension Notification.Name {
    static let refreshShowDatabase = Notification.Name("refreshShowDatabase")
}

// MARK: - Shared log (observable singleton — accessible from any view without injection)

@Observable
class FZShowsLog {
    static let shared = FZShowsLog()
    var entries: [String] = []

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func append(_ message: String) {
        let ts = FZShowsLog.formatter.string(from: Date())
        entries.append("[\(ts)] \(message)")
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }
}

@Observable
class FZShowsDatabase {

    // MARK: - All known page filenames (derived from getTourPageFilename switch cases)
    static let allPageFilenames: [String] = [
        "6669.html", "6970.html", "7071.html",
        "72.html", "73.html", "7374.html",
        "75.html", "7576.html", "7677.html", "7778.html", "78.html",
        "rehearsals.html",
        "79.html", "80.html", "80fall.html",
        "8182.html",
        "84.html", "88.html",
        "orchestral.html", "unreleased.html"
    ]

    // MARK: - State

    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0   // 0.0 → 1.0
    var totalCachedShows: Int = 0
    var oldestPageDate: Date? = nil
    private var modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        updateStats()
        log("Initialized — \(totalCachedShows) shows in database")
    }

    private func log(_ message: String) {
        FZShowsLog.shared.append(message)
        print("📚 FZShowsDB: \(message)")
    }

    // MARK: - Lookup

    /// Returns a cached show for the given date/showTime, or nil if not in DB.
    func lookup(date: String, showTime: ShowTime) -> FZShow? {
        let key: String
        switch showTime {
        case .early: key = "\(date) E"
        case .late:  key = "\(date) L"
        case .none:  key = date
        }
        let descriptor = FetchDescriptor<CachedFZShow>(
            predicate: #Predicate { $0.showDate == key }
        )
        return (try? modelContext.fetch(descriptor))?.first?.toFZShow()
    }

    /// Cache-first fetch: returns local DB result immediately if found, otherwise
    /// falls back to live scraping and caches the result.
    func fetchShow(date: String, showTime: ShowTime, completion: @escaping (FZShow?) -> Void) {
        if let cached = lookup(date: date, showTime: showTime) {
            #if DEBUG
            print("📦 DB cache hit: \(date)")
            #endif
            completion(cached)
            return
        }
        #if DEBUG
        print("🌐 DB cache miss for \(date) — falling back to live fetch")
        #endif
        FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime) { [weak self] show in
            DispatchQueue.main.async {
                if let show = show {
                    self?.upsert(show: show, pageFilename: "live")
                    self?.log("Live fetch: \(date) — cached for next time")
                } else {
                    self?.log("Live fetch: \(date) — not found on zappateers.com")
                }
            }
            completion(show)
        }
    }

    // MARK: - Bulk Download

    /// Downloads and imports all pages. Replaces existing data.
    /// Safe to call if already downloading — subsequent calls are no-ops until done.
    func downloadAllPages(completion: @escaping () -> Void = {}) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.0

        let pages = FZShowsDatabase.allPageFilenames
        var completed = 0
        log("Starting full download (\(pages.count) pages)")

        func processNext(_ index: Int) {
            if index >= pages.count {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.updateStats()
                    self.log("Download complete — \(self.totalCachedShows) shows total")
                    completion()
                }
                return
            }
            let filename = pages[index]
            fetchAndImportPage(filename: filename) {
                DispatchQueue.main.async {
                    completed += 1
                    self.downloadProgress = Double(completed) / Double(pages.count)
                }
                processNext(index + 1)
            }
        }

        DispatchQueue.global(qos: .utility).async {
            processNext(0)
        }
    }

    /// Re-fetches pages that haven't been refreshed within `staleAfterDays`.
    func refreshStalePages(staleAfterDays: Int = 30) {
        guard !isDownloading else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -staleAfterDays, to: Date()) ?? Date()

        let descriptor = FetchDescriptor<FZShowsPageRecord>()
        let records = (try? modelContext.fetch(descriptor)) ?? []
        let fetchedFilenames = Set(records.map(\.filename))

        var stale: [String] = []
        for filename in FZShowsDatabase.allPageFilenames {
            if let record = records.first(where: { $0.filename == filename }) {
                if record.lastFetchedAt < cutoff { stale.append(filename) }
            } else {
                // Never fetched — treat as stale
                if !fetchedFilenames.contains(filename) { stale.append(filename) }
            }
        }

        guard !stale.isEmpty else {
            log("All pages up to date (checked on launch)")
            return
        }
        log("Refreshing \(stale.count) stale page(s) on launch")

        isDownloading = true
        downloadProgress = 0.0
        var completed = 0

        func processNext(_ index: Int) {
            if index >= stale.count {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.updateStats()
                    self.log("Stale refresh complete — \(self.totalCachedShows) shows total")
                }
                return
            }
            fetchAndImportPage(filename: stale[index]) {
                DispatchQueue.main.async {
                    completed += 1
                    self.downloadProgress = Double(completed) / Double(stale.count)
                }
                processNext(index + 1)
            }
        }

        DispatchQueue.global(qos: .utility).async {
            processNext(0)
        }
    }

    /// Re-fetches a single named page (e.g., triggered from Settings "Refresh Now").
    func refreshPage(_ filename: String, completion: @escaping () -> Void = {}) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.0

        DispatchQueue.global(qos: .utility).async {
            self.fetchAndImportPage(filename: filename) {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.updateStats()
                    completion()
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func fetchAndImportPage(filename: String, completion: @escaping () -> Void) {
        DispatchQueue.main.async { self.log("Fetching \(filename)…") }
        let urlString = "https://www.zappateers.com/fzshows/\(filename)"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { self.log("  ✗ Invalid URL for \(filename)") }
            completion()
            return
        }

        var request = URLRequest(url: url)
        request.setValue(FZShowsFetcher.userAgentString, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self?.log("  ✗ Failed to download \(filename)") }
                completion()
                return
            }

            let shows = autoreleasepool { FZShowsFetcher.importAllShows(fromHTML: html, filename: filename, url: urlString) }

            DispatchQueue.main.async {
                self.upsertPage(shows: shows, filename: filename)
                self.log("  ✓ \(filename) — \(shows.count) show\(shows.count == 1 ? "" : "s")")
                completion()
            }
        }.resume()
    }

    private func upsertPage(shows: [FZShow], filename: String) {
        for show in shows {
            upsert(show: show, pageFilename: filename)
        }

        // Update page record
        let descriptor = FetchDescriptor<FZShowsPageRecord>(
            predicate: #Predicate { $0.filename == filename }
        )
        if let record = (try? modelContext.fetch(descriptor))?.first {
            record.lastFetchedAt = Date()
            record.showCount = shows.count
        } else {
            modelContext.insert(FZShowsPageRecord(filename: filename, lastFetchedAt: Date(), showCount: shows.count))
        }

        try? modelContext.save()
    }

    func upsert(show: FZShow, pageFilename: String) {
        let showDate = show.date
        let descriptor = FetchDescriptor<CachedFZShow>(
            predicate: #Predicate { $0.showDate == showDate }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.venue = show.venue
            existing.note = show.note
            existing.showInfo = show.showInfo
            existing.setlistData = (try? JSONEncoder().encode(show.setlist)) ?? Data()
            existing.acronymsData = (try? JSONEncoder().encode(show.acronyms.map { Acronym(short: $0.short, full: $0.full) })) ?? Data()
            existing.url = show.url
            existing.city = show.city
            existing.state = show.state
            existing.country = show.country
            existing.period = show.period
            existing.tour = show.tour
            existing.bandInfo = show.bandInfo
            existing.pageFilename = pageFilename
            existing.cachedAt = Date()
        } else {
            modelContext.insert(CachedFZShow.from(show, pageFilename: pageFilename))
        }
    }

    // MARK: - Stats

    func updateStats() {
        let countDescriptor = FetchDescriptor<CachedFZShow>()
        totalCachedShows = (try? modelContext.fetchCount(countDescriptor)) ?? 0

        let pageDescriptor = FetchDescriptor<FZShowsPageRecord>(
            sortBy: [SortDescriptor(\.lastFetchedAt, order: .forward)]
        )
        oldestPageDate = (try? modelContext.fetch(pageDescriptor))?.first?.lastFetchedAt
    }
}
