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

    // MARK: - Menubar command hooks (macOS)
    //
    // The AppKit menubar lives outside SwiftUI and can't reach the view's
    // @State, so ContentView assigns these in setupPlayer() and the AppDelegate
    // invokes them — replacing the old NotificationCenter command bridge. Same
    // side-effect-hook pattern as onNowPlayingShouldUpdate / onShowDidLoad above.
    #if os(macOS)
    var menubarToggle: () -> Void = {}
    var menubarStop: () -> Void = {}
    var menubarSelectStream: (String) -> Void = { _ in }
    var menubarShowWelcome: () -> Void = {}
    var menubarShowWhatsNew: () -> Void = {}

    /// Mirrors the view's `isPlaying` @State so the menubar can render Play/Pause
    /// and enable Stop at rebuild time without observing a notification.
    var isPlaying: Bool = false
    #endif

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

        if parsedTrack?.isNonZappaShow == true {
            // Non-Zappa broadcast (cover band / guest set): no zappateers setlist
            // exists, so skip the futile fetch. Clear any prior show so the previous
            // Zappa setlist doesn't linger under the new track.
            currentShow = nil
            currentSetlistPosition = 0
            isFetchingShowInfo = false
        } else if let date = parsedTrack?.date {
            let showTime = ShowTime(from: parsedTrack?.showTime)
            fetchShowInfo(date: date, showTime: showTime, fxPersistAcrossShows: fxPersistAcrossShows)
        }

        if let position = findCurrentTrackPosition() {
            currentSetlistPosition = position
        }

        armAACShowChangeResetIfAtLastTrack(fxPersistAcrossShows: fxPersistAcrossShows)

        onNowPlayingShouldUpdate()
        onShowDidLoad()
    }

    /// AAC only: when the metadata reaches the last setlist track, arm an early FX
    /// reset on the next stream restart (AAC restarts every track change), so the
    /// old show's FX don't bleed over the next show's audio during the metadata lag.
    /// Only arms when FX would reset/restore on show change anyway — when the user
    /// has "keep FX across shows" on (and per-show off), we leave FX untouched.
    ///
    /// Live only: during buffer playback the metadata is replayed from the journal
    /// (`publishDVRMetadata`), so reaching a "last track" there reflects historical
    /// audio, not a live show boundary. The early reset only fires in `restartStream()`
    /// (skipped in DVR mode), so an arm made off replayed metadata would just sit set
    /// until the next genuine live restart — gate it out here so it can't.
    private func armAACShowChangeResetIfAtLastTrack(fxPersistAcrossShows: Bool) {
        guard bassPlayer.activeFormat == "AAC",
              bassPlayer.dvrState == .live,
              let setlist = currentShow?.setlist, !setlist.isEmpty,
              let pos = findCurrentTrackPosition(), pos == setlist.count else { return }
        let willResetOrRestore = PerShowFXSync.rememberPerShowEnabled || !fxPersistAcrossShows
        guard willResetOrRestore else { return }
        bassPlayer.pendingAACShowChangeReset = true
    }

    // MARK: - Show fetch

    /// Fetch a show's setlist/venue and update state. Mirrors the per-view
    /// `fetchShowInfo`, including the deferred per-show FX reset.
    func fetchShowInfo(date: String, showTime: ShowTime = .none, fxPersistAcrossShows: Bool) {
        let variant = variantDate(date: date, showTime: showTime)
        guard currentShow?.date != variant else { return }

        bassPlayer.currentShowDate = variant

        // Metadata has now caught up to the new show, so the AAC carry-over window
        // (if any) is over. Capture whether the user dialed in FX during it and clear
        // the window synchronously — from here, saving resumes normally against the
        // new show.
        let carriedOver = bassPlayer.aacCarryoverActive && bassPlayer.aacCarryoverFXAdjusted
        bassPlayer.aacCarryoverActive = false
        bassPlayer.aacCarryoverFXAdjusted = false

        // On .restore with no snapshot yet, the reset is deferred to the fetch
        // completion below so a one-poll metadata glitch can't drop FX mid-song.
        let fxRememberPerShow = PerShowFXSync.rememberPerShowEnabled
        switch fxShowChangeAction(carriedOver: carriedOver,
                                  rememberPerShow: fxRememberPerShow,
                                  persistAcrossShows: fxPersistAcrossShows,
                                  variantDate: variant) {
        case .carryOver(let save):
            // Keep the user's window edits for the incoming show; persist as its
            // snapshot (currentShowDate is already `variant`). `save == false` is the
            // reset-mode case with no per-show storage — just keep, don't persist.
            if save { bassPlayer.savePerShowFX(showDate: variant) }
        case .restore(let showDate): bassPlayer.restorePerShowFX(showDate: showDate)
        case .reset: bassPlayer.resetAllFX()
        case .keep: break
        }

        isFetchingShowInfo = true
        let fetch: (@escaping (FZShow?) -> Void) -> Void = { [self] completion in
            if let db = fzShowsDB {
                db.fetchShow(date: date, showTime: showTime, completion: completion)
            } else {
                // No local DB: the view layer only needs the show, so collapse the
                // Result back to an optional (network vs not-found is logged downstream).
                FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime) { completion(try? $0.get()) }
            }
        }
        fetch { [weak self] show in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentShow = show
                // A real new show loaded → disarm any stale AAC early-reset arm so it
                // can't double-fire if metadata caught up before the next restart.
                self.bassPlayer.pendingAACShowChangeReset = false
                self.currentSetlistPosition = 0  // reset for new show
                if let position = self.findCurrentTrackPosition() {
                    self.currentSetlistPosition = position
                }
                self.isFetchingShowInfo = false
                self.onShowDidLoad()

                // Per-show FX: reset to defaults now that a real show has loaded
                // and it has no saved snapshot (a genuine new show). Skipped on a
                // carry-over, where the user's window edits are kept (and already
                // saved as this show's snapshot).
                if show != nil, fxRememberPerShow, !carriedOver,
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
