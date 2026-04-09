//
//  DonlopeIndexCache.swift
//  ZappaStream
//

import Foundation

// MARK: - Lookup Result

enum DonlopeLookupResult {
    case found(URL)
    case noMatch(String)     // carries the normalized name that was attempted
    case fetchError(Error)
}

// MARK: - Index Cache Actor

actor DonlopeIndexCache {
    static let shared = DonlopeIndexCache()

    private let baseURL = "https://www.donlope.net/fz/songs/"
    private let indexURL = URL(string: "https://www.donlope.net/fz/songs/index.html")!

    private var index: [String: URL]? = nil
    private var isFetching = false
    private var pendingContinuations: [CheckedContinuation<[String: URL], Error>] = []

    // MARK: - Public API

    func lookupURL(for trackName: String) async -> DonlopeLookupResult {
        do {
            let idx = try await ensureIndex()
            let normalized = normalizeForLookup(trackName)

            // 1. Exact match (case-insensitive)
            if let url = caseInsensitiveLookup(normalized, in: idx) {
                return .found(url)
            }

            // 2. Try stripping common trailing qualifiers
            let suffixes = [
                " (Reprise)", " (reprise)",
                " (Part 1)", " (Part 2)", " (Part 3)",
                " (Part I)", " (Part II)", " (Part III)",
                " (Excerpt)", " (excerpt)",
                " #1", " #2", " #3",
                " (Early Version)", " (early version)",
                " (Alternate Version)"
            ]
            for suffix in suffixes where normalized.lowercased().hasSuffix(suffix.lowercased()) {
                let stripped = String(normalized.dropLast(suffix.count))
                if let url = caseInsensitiveLookup(stripped, in: idx) {
                    return .found(url)
                }
            }

            // 3. Try stripping subtitle separator (e.g. "Goblin Girl - Doreen" → "Goblin Girl")
            if let dashRange = normalized.range(of: " - ") {
                let baseName = String(normalized[..<dashRange.lowerBound])
                if let url = caseInsensitiveLookup(baseName, in: idx) {
                    return .found(url)
                }
                for suffix in suffixes where baseName.lowercased().hasSuffix(suffix.lowercased()) {
                    let stripped = String(baseName.dropLast(suffix.count))
                    if let url = caseInsensitiveLookup(stripped, in: idx) {
                        return .found(url)
                    }
                }
                if let url = fuzzyMatch(normalizedName: baseName, in: idx) {
                    return .found(url)
                }
            }

            // 4. Fuzzy fallback on full name
            if let url = fuzzyMatch(normalizedName: normalized, in: idx) {
                return .found(url)
            }

            return .noMatch(normalized)
        } catch {
            return .fetchError(error)
        }
    }

    // MARK: - Private: Index Management

    private func ensureIndex() async throws -> [String: URL] {
        if let existing = index { return existing }

        if isFetching {
            return try await withCheckedThrowingContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }

        isFetching = true
        do {
            let result = try await fetchIndex()
            index = result
            isFetching = false
            let continuations = pendingContinuations
            pendingContinuations = []
            for c in continuations { c.resume(returning: result) }
            return result
        } catch {
            isFetching = false
            let continuations = pendingContinuations
            pendingContinuations = []
            for c in continuations { c.resume(throwing: error) }
            throw error
        }
    }

    private func fetchIndex() async throws -> [String: URL] {
        var request = URLRequest(url: indexURL, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return buildIndex(from: html)
    }

    private func buildIndex(from html: String) -> [String: URL] {
        var result = [String: URL]()
        guard let regex = try? NSRegularExpression(
            pattern: "<a href=\"([^\"]+\\.html)\">([^<]+)</a>"
        ) else { return result }

        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: nsRange)

        for match in matches {
            guard match.numberOfRanges == 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html) else { continue }

            let href = String(html[hrefRange])
            let displayName = String(html[nameRange])
                .decodeHTMLEntities()
                .trimmingCharacters(in: .whitespaces)

            guard !displayName.isEmpty,
                  let url = URL(string: baseURL + href) else { continue }
            result[displayName] = url
        }
        return result
    }

    // MARK: - Private: Normalization & Matching

    private func normalizeForLookup(_ name: String) -> String {
        ParsedTrackInfo.normalizeTrackName(name) ?? name
    }

    private func caseInsensitiveLookup(_ name: String, in index: [String: URL]) -> URL? {
        let lower = name.lowercased()
        for (key, url) in index where key.lowercased() == lower {
            return url
        }
        return nil
    }

    private func fuzzyMatch(normalizedName: String, in index: [String: URL]) -> URL? {
        let articles = ["the ", "a ", "an "]

        func stripArticle(_ s: String) -> String {
            let lower = s.lowercased()
            for article in articles where lower.hasPrefix(article) {
                return String(s.dropFirst(article.count))
            }
            return s
        }

        let candidateLower = normalizedName.lowercased()
        let candidateStripped = stripArticle(candidateLower)
        let candidatePlural = ParsedTrackInfo.normalizePluralForm(candidateStripped).lowercased()

        // Article-stripped + plural-normalized
        for (key, url) in index {
            let keyStripped = stripArticle(key.lowercased())
            let keyPlural = ParsedTrackInfo.normalizePluralForm(keyStripped).lowercased()
            if candidatePlural == keyPlural { return url }
        }

        // Prefix match: first 12 chars with at least 2 words
        let words = candidateStripped.split(separator: " ")
        guard words.count >= 2 else { return nil }
        let prefix12 = String(candidateStripped.prefix(12))

        var prefixMatches: [(key: String, url: URL)] = []
        for (key, url) in index where key.lowercased().hasPrefix(prefix12) {
            prefixMatches.append((key, url))
        }

        if prefixMatches.count == 1 { return prefixMatches[0].url }
        guard !prefixMatches.isEmpty else { return nil }

        // Multiple prefix matches — pick the longest common prefix
        return prefixMatches.max { a, b in
            commonPrefixLength(candidateLower, a.key.lowercased()) <
            commonPrefixLength(candidateLower, b.key.lowercased())
        }?.url
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (c1, c2) in zip(a, b) {
            if c1 == c2 { count += 1 } else { break }
        }
        return count
    }
}
