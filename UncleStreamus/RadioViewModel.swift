//
//  RadioViewModel.swift
//  UncleStreamus
//
//  Shared @Observable model for the now-playing / show-fetch runtime state that
//  was previously duplicated between ContentView (macOS) and ContentView_iOS.
//  It owns the state produced by the metadata + show-fetch pipeline and the two
//  shared methods that drive it. Platform-specific side effects (now-playing
//  info, CarPlay mirroring) are delivered through injected closures so the
//  imperative call timing matches the previous per-view code exactly.
//
//  Ownership notes:
//  - `bassPlayer`, `showDataManager`, `fzShowsDB` remain `@State` on each view
//    (lifecycle + heavy reference churn); the view assigns them onto the model
//    once during setup, and the model uses those references in its methods.
//  - `@AppStorage`-backed prefs stay on the views; relevant values are passed in.
//

import Foundation

@Observable
final class RadioViewModel {

    // MARK: - Runtime state (produced by the metadata + fetch pipeline)

    var currentTrack: String = "No track info"
    var parsedTrack: ParsedTrackInfo?
    var currentShow: FZShow?
    var currentSetlistPosition: Int = 0
    var isFetchingShowInfo: Bool = false

    // MARK: - References (owned by the view; set once during setup)

    /// Set in the view's setupPlayer() before any metadata can arrive.
    var bassPlayer: BASSRadioPlayer!
    var showDataManager: ShowDataManager?
    var fzShowsDB: FZShowsDatabase?

    // MARK: - Platform side-effect hooks (set by each view in setupPlayer())

    /// Refresh the platform now-playing info (MPNowPlayingInfoCenter / menubar).
    var onNowPlayingShouldUpdate: () -> Void = {}
    /// Fired after show state changes — iOS mirrors to CarPlay; macOS no-ops.
    var onShowDidLoad: () -> Void = {}

    // MARK: - Track matching

    /// Current track's setlist position (see `currentTrackPosition` in ContentViewShared).
    func findCurrentTrackPosition() -> Int? {
        currentTrackPosition(trackName: parsedTrack?.trackName,
                             setlist: currentShow?.setlist,
                             after: currentSetlistPosition)
    }

    // MARK: - Metadata pipeline

    /// Handle a raw metadata string from BASS: merge with the previous track,
    /// publish, trigger the show fetch, and update derived state. Mirrors the
    /// `onMetadataUpdate` body that previously lived in each view.
    func handleMetadata(_ metadata: String, fxPersistAcrossShows: Bool) {
        let newParsed = ParsedTrackInfo.parse(metadata)

        // Block if nothing meaningful changed (track name, date, AND duration).
        let trackNameSame = (parsedTrack?.trackName == newParsed.trackName)
        let dateSame = (parsedTrack?.date == newParsed.date)
        let durationSame = (parsedTrack?.trackDuration == newParsed.trackDuration)
        guard !(trackNameSame && dateSame && durationSame) else { return }

        currentTrack = metadata
        parsedTrack = ParsedTrackInfo.merged(new: newParsed, previous: parsedTrack)

        if let date = parsedTrack?.date {
            let showTime = ShowTime(from: parsedTrack?.showTime)
            fetchShowInfo(date: date, showTime: showTime, fxPersistAcrossShows: fxPersistAcrossShows)
        }

        if let position = findCurrentTrackPosition() {
            currentSetlistPosition = position
        }

        onNowPlayingShouldUpdate()
        onShowDidLoad()
    }

    // MARK: - Show fetch

    /// Fetch a show's setlist/venue and update state. Mirrors the per-view
    /// `fetchShowInfo`, including the deferred per-show FX reset.
    func fetchShowInfo(date: String, showTime: ShowTime = .none, fxPersistAcrossShows: Bool) {
        let variant = variantDate(date: date, showTime: showTime)
        guard currentShow?.date != variant else { return }

        bassPlayer.currentShowDate = variant

        // On .restore with no snapshot yet, the reset is deferred to the fetch
        // completion below so a one-poll metadata glitch can't drop FX mid-song.
        let fxRememberPerShow = UserDefaults.standard.bool(forKey: "fxRememberPerShow")
        switch fxRestorePlan(variantDate: variant,
                             rememberPerShow: fxRememberPerShow,
                             persistAcrossShows: fxPersistAcrossShows) {
        case .restore(let showDate): bassPlayer.restorePerShowFX(showDate: showDate)
        case .reset: bassPlayer.resetAllFX()
        case .keep: break
        }

        isFetchingShowInfo = true
        let fetch: (@escaping (FZShow?) -> Void) -> Void = { [self] completion in
            if let db = fzShowsDB {
                db.fetchShow(date: date, showTime: showTime, completion: completion)
            } else {
                FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime, completion: completion)
            }
        }
        fetch { [weak self] show in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentShow = show
                self.currentSetlistPosition = 0  // reset for new show
                if let position = self.findCurrentTrackPosition() {
                    self.currentSetlistPosition = position
                }
                self.isFetchingShowInfo = false
                self.onShowDidLoad()

                // Per-show FX: reset to defaults now that a real show has loaded
                // and it has no saved snapshot (a genuine new show).
                if show != nil, fxRememberPerShow,
                   !self.bassPlayer.hasPerShowFX(showDate: variant) {
                    self.bassPlayer.resetAllFX()
                }

                if let show {
                    // Fill missing location from the fetched show.
                    if let parsed = self.parsedTrack, parsed.city == nil || parsed.state == nil {
                        self.parsedTrack = parsed.fillingLocation(city: show.city, state: show.state)
                    }
                    self.showDataManager?.recordListen(show: show)
                }

                self.onNowPlayingShouldUpdate()
            }
        }
    }
}
