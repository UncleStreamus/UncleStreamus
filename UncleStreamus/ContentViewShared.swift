//
//  ContentViewShared.swift
//  UncleStreamus
//
//  Pure, platform-neutral logic shared by ContentView (macOS) and
//  ContentView_iOS. These functions were previously duplicated verbatim in both
//  views; they live here so there is a single source of truth and they can be
//  unit-tested without a SwiftUI host. The views keep their thin @State-mutating
//  shells and call into these.
//

import Foundation

// MARK: - DVR Formatting

/// Formats a "behind live" interval as M:SS.
func dvrFormattedBehind(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Current Track Matching

/// Extracts the first N words from a string for comparison, stripping bracketed
/// content and punctuation. Lower-cased for case-insensitive matching.
func firstWords(_ text: String, count: Int = 2) -> String {
    let base = text.components(separatedBy: CharacterSet(charactersIn: "([")).first?
        .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    let punctuation = CharacterSet.punctuationCharacters
    let words = base.split(separator: " ").prefix(count).map { word in
        String(word.unicodeScalars.filter { !punctuation.contains($0) })
    }
    return words.joined(separator: " ")
}

/// Finds the current track's 1-based position in the setlist, handling duplicate
/// song names by picking the first match after `lastPosition`. Returns nil when
/// there's no track/setlist or no match.
func currentTrackPosition(trackName: String?, setlist: [String]?, after lastPosition: Int) -> Int? {
    guard let trackName, let setlist else { return nil }

    let normalizedTrack = ParsedTrackInfo.normalizeTrackName(trackName) ?? trackName
    let trackWords = firstWords(normalizedTrack)
    guard !trackWords.isEmpty else { return nil }

    // Find all positions where the song name matches
    var matchingPositions: [Int] = []
    for (index, song) in setlist.enumerated() {
        let normalizedSong = ParsedTrackInfo.normalizeTrackName(song) ?? song
        let songWords = firstWords(normalizedSong)
        if songWords == trackWords || ParsedTrackInfo.tracksMatch(normalizedTrack, song) {
            matchingPositions.append(index + 1)  // 1-based position
        }
    }

    guard !matchingPositions.isEmpty else { return nil }

    // First match after the last confirmed position (handles repeated songs like
    // multiple "Improvisations"); otherwise fall back to the first match.
    for pos in matchingPositions where pos > lastPosition { return pos }
    return matchingPositions.first
}

// MARK: - Show Fetch Helpers

/// Builds the variant date key (e.g. "1980 12 11 E") used for early/late show
/// deduplication.
func variantDate(date: String, showTime: ShowTime) -> String {
    switch showTime {
    case .early: return "\(date) E"
    case .late:  return "\(date) L"
    case .none:  return date
    }
}

/// What to do with per-show FX when a new show begins, based on persistence
/// settings. `.restore` returns to a saved snapshot (or defers the reset to the
/// fetch completion when none exists yet); `.reset` clears FX; `.keep` leaves
/// them untouched (persist-across-shows).
enum FXRestorePlan {
    case restore(showDate: String)
    case reset
    case keep
}

func fxRestorePlan(variantDate: String, rememberPerShow: Bool, persistAcrossShows: Bool) -> FXRestorePlan {
    if rememberPerShow { return .restore(showDate: variantDate) }
    if !persistAcrossShows { return .reset }
    return .keep
}

// MARK: - What's New / Welcome Gating

/// The UI action that should follow a "What's New" check.
enum WhatsNewAction {
    case nothing
    case showWelcome
    case showNotes(ReleaseNotes)
}

/// Pure result of the launch-time gating decision.
struct WhatsNewResult {
    let action: WhatsNewAction
    /// The build to record into `lastSeenBuild`, or nil to leave it unchanged.
    let buildToRecord: String?
}

/// Decides whether to show the Welcome guide, the "What's New" sheet, or nothing,
/// and which build (if any) to record. `loadNotes` is injected for testability.
func decideWhatsNew(currentBuild: String,
                    lastSeenBuild: String,
                    hasSeenWelcome: Bool,
                    loadNotes: () -> ReleaseNotes?) -> WhatsNewResult {
    guard !currentBuild.isEmpty else { return WhatsNewResult(action: .nothing, buildToRecord: nil) }

    if lastSeenBuild.isEmpty {
        // First-ever install: don't show What's New; offer the one-time Welcome guide.
        return WhatsNewResult(action: hasSeenWelcome ? .nothing : .showWelcome,
                              buildToRecord: currentBuild)
    }

    if lastSeenBuild != currentBuild {
        // Only auto-popup for changes genuinely new in this build; a re-cut with no
        // user-facing changes carries fallback notes (isCurrent == false).
        if let notes = loadNotes(), !notes.isEmpty, notes.isCurrent {
            return WhatsNewResult(action: .showNotes(notes), buildToRecord: currentBuild)
        }
        return WhatsNewResult(action: .nothing, buildToRecord: currentBuild)
    }

    return WhatsNewResult(action: .nothing, buildToRecord: nil)
}
