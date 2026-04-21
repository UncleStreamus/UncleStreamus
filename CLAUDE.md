# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) and other AI coding agents when working with code in this repository.

## Project Overview

ZappaStream is a native macOS and iOS app for streaming the 24/7 Zappateers radio stream (Frank Zappa music). It scrapes setlist data from zappateers.com and displays live now-playing info alongside historical show data.

- **macOS**: Menubar-only app plus a resizable main window. Click the menubar icon to open the popover/window.
- **iOS/iPadOS**: Full-featured app. NavigationStack-based layout (NOT tab-based). Settings slide in from the left; history sidebar from the right. iPad shows sidebars inline; iPhone uses an overlay drawer.

**Stream formats (all from shoutcast.norbert.de):**
- MP3 128 kbit/s — `zappa.mp3`
- OGG 90 kbit/s — `zappa.ogg`
- AAC 256 kbit/s — `zappa.aac`
- FLAC 750 kbit/s — `zappa.flac`

## Build & Run

**Requirements:**
- Xcode 26.3 (current as of Apr 2026)
- macOS 15 Sequoia (required to build; iOS target requires Xcode on macOS)
- Deployment targets: macOS 14.0, iOS/iPadOS 17.5

**Open the project:**
```bash
open ZappaStream.xcodeproj
```
Xcode will automatically resolve the CBass Swift Package dependency (macOS target only).

**Build macOS target:**
```bash
xcodebuild -scheme ZappaStream -configuration Debug
```

**Build iOS target:**
```bash
xcodebuild -scheme ZappaStream-iOS -configuration Debug
```

**Run unit tests (macOS only):**
```bash
xcodebuild test -scheme ZappaStream -destination 'platform=macOS'
```

**Run a single test class:**
```bash
xcodebuild test -scheme ZappaStream -destination 'platform=macOS' -only-testing:ZappaStreamTests/ParsedTrackInfoTests
```

**Run on macOS (from Xcode):** Select `ZappaStream` scheme → Cmd+R. Menubar icon appears in top-right; click to open. Window is resizable (min 385pt, max 618pt wide).

**Run on iOS (from Xcode):** Select `ZappaStream-iOS` scheme → Cmd+R. Choose simulator (iPhone 15, iPad Pro recommended for testing landscape) or device.

**iOS Build Configuration (one-time after checkout):**

⚠️ **Critical: These manual steps are required; automated tooling does not apply them. Build will fail without them.**

1. **Bridging header:**
   - Build Settings → `SWIFT_OBJC_BRIDGING_HEADER = ZappaStream/BASSBridgingHeader.h`
   - **Why:** iOS requires global availability of BASS C symbols via `BASSBridgingHeader.h`
   - **Verify:** Search "SWIFT_OBJC_BRIDGING_HEADER" in Build Settings; iOS target only, NOT macOS

2. **Header search path:**
   - Build Settings → `HEADER_SEARCH_PATHS += $(PROJECT_DIR)/Frameworks/iOS/include`
   - **Why:** Points compiler to BASS C headers (`bass.h`, `bass_fx.h`, etc.)

3. **Embed BASS frameworks:**
   - Build Phases → Embed Frameworks: all **6 BASS xcframeworks** from `Frameworks/iOS/`:
     - `bass.xcframework` — core playback engine
     - `bass_fx.xcframework` — effects (EQ, compressor, reverb)
     - `bassflac.xcframework` — FLAC decoder (critical for 750k stream)
     - `basshls.xcframework` — HLS streaming support
     - `bassmix.xcframework` — mixer and DSP callbacks
     - `tags.xcframework` — metadata reading (ID3, Vorbis, etc.)
   - **Do NOT** add to "Link Binary With Libraries" — embedding handles linking automatically

**macOS target:** No manual setup; CBass Swift Package resolves automatically via `Package.resolved`.

**Dependencies:**
- **BASS** — Cross-platform audio library (all 4 codecs: MP3, AAC, OGG, FLAC)
  - macOS: CBass Swift Package (`https://github.com/Treata11/CBass.git`)
  - iOS: Pre-built XCFrameworks in `Frameworks/iOS/`

## Architecture

### Layers

1. **Audio Playback & Metadata** — `BASSRadioPlayer` (`@Observable`) wraps BASS and handles all 4 formats. Exposes `onMetadataUpdate` callback. `ParsedTrackInfo` regex-parses raw ICY/Vorbis/Icecast strings into structured fields.

2. **Show Data Fetching** — `FZShowsFetcher` takes parsed date/time, scrapes zappateers.com HTML for setlist, venue, acronyms, tour info. Hardcoded exceptions dict for known date mismatches; falls back to `rehearsals.html`.

3. **Persistence** — `ShowDataManager` wraps SwiftData. `SavedShow` is the `@Model` with `showDate` as unique identifier (`"YYYY MM DD"`). Setlist entries and acronyms are JSON-encoded into `Data` fields.

4. **UI** — `ContentView.swift` (macOS) and `ContentView_iOS.swift` (iOS) are separate files. `SidebarView`, `FilterView`, `ShowEntryRow`, `AudioFXView` are shared. Platform conditionals use `#if os(macOS)` / `#if os(iOS)`.

5. **App Entry & Menubar** — `ZappaStreamApp.swift` sets up SwiftData `ModelContainer`, registers menubar icon (macOS via `NSStatusBar`), handles `AppDelegate`. Menubar popover and main window communicate via `NotificationCenter`.

### Data Flow Summary

```
BASS Audio Stream
  → BASSRadioPlayer.pollMetadata() (raw ICY/Vorbis/JSON metadata)
  → ParsedTrackInfo.parse() (structured show/track info via regex)
  → FZShowsFetcher.fetchShowInfo() (scrape HTML for full setlist)
  → ShowDataManager.recordListen() (persist via SwiftData)
  → UI update (now playing highlight, setlist display, menubar tooltip)
```

### Component Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│ BASS Audio Library                                       │
│ (macOS Swift Package / iOS XCFrameworks)                │
└──────────────────┬───────────────────────────────────────┘
                   │ (all 4 codecs: MP3/AAC/OGG/FLAC)
          ┌────────▼──────────┐
          │ BASSRadioPlayer   │ ← Playback state machine, metadata polling
          │ (@Observable)     │   3-band EQ, compressor, stereo, limiter, DVR
          └────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
    (metadata)          (state updates)
        │                     │
    ┌───▼──────────┐      ┌───▼──────────────────────┐
    │ ParsedTrack  │      │ ContentView (macOS)       │
    │ Info.parse() │      │ ContentView_iOS (iOS)     │
    │ (4 formats)  │      │ + AudioFXView (shared)    │
    └───┬──────────┘      └────────┬──────────────────┘
        │                          │
    (show date/time)       (format selection)
        │                          │
    ┌───▼──────────────┐          │
    │ FZShowsFetcher   │◄─────────┘
    │ .fetchShowInfo() │ ← HTML scraping, setlist fetch
    └───┬──────────────┘
        │
    ┌───▼──────────────┐
    │ ShowDataManager  │ ← Persistence, history/favorites
    │ (@Observable)    │
    └───┬──────────────┘
        │
    ┌───▼──────────┐
    │ SavedShow     │ ← SwiftData @Model
    │ (persisted)   │   showDate unique key
    └───────────────┘

UI Components (Shared):
┌─────────────────────────────────────┐
│ ShowEntryRow                        │ ← Setlist row with highlighting
│ SidebarView (History/Favorites)     │ ← Collapsible time periods
│ FilterView (Tag-based filtering)    │ ← Tour/year/location
│ AudioFXView                         │ ← EQ/compressor/stereo sliders
│ SettingsView                        │ ← Format, resume, text scale, DVR
│ MarqueeText                         │ ← Animated scrolling titles
└─────────────────────────────────────┘

Platform-Specific:
┌────────────────────────────────┬──────────────────────────────────┐
│ macOS (ContentView)            │ iOS (ContentView_iOS)            │
│ • Menubar + main window        │ • NavigationStack layout         │
│ • NSStatusBar icon             │ • iPhone: settings overlay drawer│
│ • NotificationCenter comms     │ • iPad: inline sidebars          │
│ • Media keys (MPRemoteCommand) │ • Lock screen controls           │
│ • Scroll wheel bounce effect   │ • Drag bounce gesture            │
│ • FX panel replaces setlist    │ • FX panel as sheet              │
│ • Window resizes for FX        │ • TrackInfoView pane             │
└────────────────────────────────┴──────────────────────────────────┘
```

### Key Patterns & Architecture Decisions

**State Management:**
- `@State` for local view state, `@AppStorage` for persistent user preferences
- `ShowDataManager` is `@Observable` global singleton, shared across both platforms
- `@Query` properties on views reactively track SwiftData model changes

**Key AppStorage Keys (both platforms unless noted):**
- `showInfoExpanded` — setlist expand/collapse state
- `textScale` — font scale multiplier (default 1.1)
- `lastStreamFormat` — last stream format selected (default "MP3")
- `wasPlayingOnQuit` — for auto-resume on launch
- `autoResumeOnLaunch` — auto-resume setting (default true)
- `fxPersistAcrossShows` — keep FX settings when show changes (default false)
- `fxPersistOnRestart` — restore FX on app restart for same show (default false)
- `dvrEnabled` — DVR mode on/off (default true, both platforms)
- `dvrBufferMinutes` — DVR ring buffer size in minutes (default 15, both platforms)
- `isSidebarVisible` — sidebar open state (macOS only)
- `setlistWasOpenBeforeFX` — macOS: restore setlist after closing FX panel
- `lastShowDateOnQuit` — date of last show, for FX persistence logic

**Async/Concurrency:**
- Uses `DispatchQueue` + `URLSession.dataTask` with completion handlers (not async/await)
- No Combine or RxSwift; state updates via property setters or `DispatchQueue.main.async`

**Streaming & Metadata:**
- `BASSRadioPlayer` polls metadata every 3 seconds via `Timer`
- **Metadata Transport Sources:**
  1. **ICY** (`BASS_TAG_META`): `StreamTitle='...';` — MP3 only
  2. **Vorbis Comments** (`BASS_TAG_OGG`): `TITLE=...` — OGG and FLAC; published immediately on change
  3. **Icecast JSON** (`https://shoutcast.norbert.de/status-json.xsl`): used by OGG, FLAC, AAC; always reads `.mp3` mountpoint
- **Format-Specific Handling:**
  - MP3: ICY metadata only → `publishTitle()` → return
  - OGG: Vorbis tag checked; if changed, `publishTitle()` immediately (fast per-track for Format A). Icecast JSON fetched and supersedes. Format B uses only Icecast JSON.
  - FLAC: Vorbis tag fires short title immediately; `fetchIcecastMetadata()` always runs for full metadata. Short title is superseded by Icecast response.
  - AAC: No Vorbis tags; Icecast JSON fetched directly every poll cycle.
- Single `onMetadataUpdate` callback unifies all formats
- **`ParsedTrackInfo.parse()` handles four string formats:**
  1. **Full bracket:** `[1973 11 07 Boston MA] Artist: (01) Track Name (1973) [3:30]`
  2. **Simple date:** `1973 11 07 Boston MA - 01 Intro [0:03:30]`
  3. **Numbered track:** `01 Intro` — bare FLAC Vorbis
  4. **Bare name:** `When The Lie's So Big` — fallback; displayed until Icecast responds

**Artist Name Inference (both platforms):**
- If metadata includes an artist field, use it directly
- Otherwise, infer from show date:
  - Pre-1975: "The Mothers of Invention"
  - Jan–May 1975: "Zappa / Beefheart / Mothers" (Bongo Fury tour)
  - June 1975+: "Frank Zappa"

**Source Type Display (AUD/SBD/FM):**
- Derived first from `parsedTrack.source` (metadata field)
- Falls back to scanning `currentShow.showInfo` HTML for AUD/SBD/FM/STAGE strings
- Displayed as a blue badge in the track info card

**FX Persistence Logic (on show change):**
- `fxPersistAcrossShows=false`: `resetAllFX()` whenever show changes (default)
- `fxPersistAcrossShows=true`: keep FX settings across shows
- `fxPersistOnRestart=true`: if same show as when app quit, `restoreFXFromDefaults()` on next launch; otherwise `resetAllFX()`
- Controlled by `fetchShowInfo()` comparing `lastShowDateOnQuit` to new show date

**Audio Effects DSP Pipeline:**
- **3-Band EQ** (via `BASS_FX_BFX_PEAKEQ`):
  - Low: 100 Hz, Mid: 1 kHz, High: 10 kHz — each ±6 dB
  - Applied first in DSP chain
- **Compressor** (via `BASS_FX_BFX_COMPRESSOR2`):
  - Adaptive threshold: level-meter DSP measures RMS over ~1.5s windows (EMA ~4.5s). Threshold = RMS + headroom (gentle: +6 dB, heavy: +2.25 dB).
  - Threshold updates only when change exceeds 0.5 dB (avoids jitter)
  - FX stays in chain always; when off/bypassed, set to passthrough (threshold 0 dB, ratio 1:1)
  - Applied after EQ
- **Stereo Width/Pan** (custom DSP callback, priority 0):
  - Mid-Side (M/S) processing; width coefficient 0→1 maps to mono→wide
  - Snap point at 0.75 = "original" stereo width; double-tap resets to snap point
  - Frequency-dependent center spreading: high-freq spreads, bass stays centered; 400 Hz crossover
  - Pan uses sine/cosine angle blending; parameter smoothing α=0.3 prevents pops
  - APF-based mono synthesis for mono source material: 2-stage all-pass + HPF, `synthGain = (coeff-1) * monoFraction * 0.6`
- **Soft Limiter** (custom DSP, priority -1):
  - Soft knee at 0.85 (–1.4 dBFS), knee width 0.05, hard ceiling 0.891 (–1.0 dBFS)
- **Click Guard** (custom DSP, priority -2):
  - Triggered by `BASS_SYNC_OGG_CHANGE` (MIXTIME) at bitstream boundaries
  - Silences 1 buffer (~20ms), fades in over 2 buffers (~40ms); ~60ms total
  - Debounced 1.5s (OGG fires 2× per track change); FLAC attaches to pre-mixer; OGG to output mixer
- **Effect Control:**
  - `isFXBeingUsed`: true if EQ ≠ 0 dB, compressor enabled, or stereo ≠ default
  - `masterBypassEnabled`: skips all DSP when true

**AudioFXView (shared macOS + iOS):**
- Canvas-based vertical EQ sliders, horizontal sliders for compressor/stereo/pan
- **macOS**: inline panel replacing the setlist section; window expands to max height when open, restores on close
- **iOS**: presented as a sheet (`.presentationDetents([.fraction(0.78), .large])`)
- **EQ sliders on iOS**: relative drag at 0.5× sensitivity (needs 2× travel for same dB change); haptic feedback (`UIImpactFeedbackGenerator(style: .light)`) at every 2 dB crossing
- **macOS EQ sliders**: absolute position mapping with square-root curve for fine control near zero
- Double-tap any slider to reset to default; double-tap EQ band label also resets
- "Reset All" button resets all FX to defaults; master bypass toggle

**DVR Ring Buffer (both macOS and iOS):**
- Implemented in `BASSRadioPlayer+DVR.swift` and UI in both ContentViews
- Rolling 15 × 60s WAV segments, 16-bit PCM 44.1 kHz stereo; ~157 MB max on disk
- `DVRState` enum: `.live`, `.paused`, `.playing`
- `dvrPause()` → saves buffer timestamp, fades out pre-mixer channel volume (keeps recording)
- `dvrResume()` → creates BASS file stream from WAV at pause timestamp
- `dvrPausePlayback()` → pauses DVR playback while in `.playing` state
- `goLive()` → frees DVR stream, fades back to live (FLAC does full restart)
- Recording DSP at priority -3 on `preMixerHandle` — fires before vol scaling, so muting doesn't silence recording
- `behindLiveSeconds` formula: `buffer.bufferedDuration - (dvrCurrentSegNum * 60 + BASS_ChannelBytes2Seconds(pos))`
- UI: "● LIVE" badge in live mode; "M:SS / maxTime + Go Live" in DVR mode; "Stop" button always stops and clears buffer
- `dvrBufferFullExpired` flag: macOS hides DVR status row once buffer has been used and expired

**Audio Fade-In/Fade-Out:**
- Fade-in: 0.5s on play start (non-FLAC) or after FLAC pre-buffer completion
- Fade-out: 0.4s when user presses pause/stop (via `stopWithFadeOut()`)
- Implementation: BASS mixer volume attribute (`BASS_ATTRIB_VOL`) ramped via 60Hz timer
- No fade on: track changes, app deinit, internal restarts without user interaction
- **Important:** Always call `stopWithFadeOut()` from UI, never `stop()` directly

**FLAC Streaming & Buffer Management:**
- **Global BASS config** (set in `BASSRadioPlayer.init`):
  - `UPDATEPERIOD` = 20ms, `UPDATETHREADS` = 2
  - `DEV_BUFFER` = 500ms, `NET_BUFFER` = 25s (30s temp during FLAC creation), `NET_PREBUF` = 50%, `BUFFER` = 15s
- **FLAC two-mixer pipeline:** stream → DECODE-mode pre-mixer (3.0s buffer) → FX output mixer (0.1s buffer) → hardware
- **Non-FLAC two-mixer pipeline:** OGG pre-mixer 1.5s; others 0.3s; FX output mixer 0.1s
- **FLAC pre-buffer sequence:** create stream (30s net buf) → mixer muted → 7s wait → `BASS_ChannelPlay` → poll FX output buffer → fade-in when ≥80ms. `preBufferProgress` (0→1 over 7s) drives UI loading bar.
- **Auto-restart:**
  - OGG: 2-poll STOPPED confirmation
  - AAC: immediate on buffer underrun (status=playing + bufferedBytes=0 + pos>100KB)
  - FLAC: proactive on network change or download buffer < 10%; recovery stream created with `BASS_MIXER_CHAN_PAUSE`
- **Reconnect:** flat 5s retry; gives up after 12 attempts (~1 min) → `.stopped`
- **iOS audio session:** `.playback` category, `.allowBluetoothA2DP`, preferred IO buffer 0.5s

**HTML Scraping:**
- No external parser; uses `NSRegularExpression` + string slicing
- `FZShowsFetcher` has hardcoded exceptions dict for known date mismatches
- Falls back to `rehearsals.html` when show not found

**Data Models:**
- `SavedShow` unique identifier: `showDate` (format `"YYYY MM DD"`)
- Setlist/acronym arrays JSON-serialized into `Data` fields (SwiftData workaround)
- `Stream` is a lightweight struct (format/URL metadata), not persisted

**UI Features — Both Platforms:**
- Track info card: track name, artist, track number, duration, date/location, AUD/SBD/FM source badge, favorite star
- Show info section: venue, note (in red), showInfo string, expandable setlist with current track highlighted
- Setlist: two-column layout when width > 500pt (landscape/iPad), single-column otherwise
- Current track highlighting: speaker icon on matching setlist row; handles duplicate song names by advancing through matches
- Band Info / Official Releases: collapsible footer section; acronyms decoded inline
- "Track Info (donlope)..." button: looks up current track on donlope.net via `DonlopeIndexCache`
- "Setlist Info (FZShows)..." button: opens `SetlistInfoPaneView` scrolled to show date
- Context menu "Report Issue...": opens `BugReportData` → email via `MailComposerView` (iOS) or `openMailClient()` (macOS)
- Bounce/rubber-band effect: macOS via `ScrollWheelOverlay` (excludes setlist area); iOS via `DragGesture`
- Swipe left gesture → opens history sidebar (both platforms)
- Delay warning: 5-second "info can be up to 1min behind" notice shown when switching to non-MP3 stream

**iOS-Specific UI:**
- **iPhone**: Settings slide in as overlay drawer from left (`.move(edge: .leading)`, dark overlay behind); history via NavigationLink push
- **iPad** (regular horizontal size class): Settings and history as inline panels from edges; swipe gesture on divider to dismiss
- **TrackInfoView pane**: Tap a region on the main screen to reveal an inline track info pane with donlope lookup; "×" button to dismiss
- Lock screen / Control Center media controls via `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`; supports play, pause, togglePlayPause
- Now Playing info format: title = track name, artist = "Artist • Date • Venue" (all info in one line), `IsLiveStream = true`
- Interruption handling: resumes stream on `AVAudioSession.InterruptionType.ended` with `.shouldResume`
- App foreground/background transitions (`scenePhase`) trigger `triggerImmediateReconnect()` if user intended to play
- Bluetooth A2DP allowed for AirPods/headphones

**macOS-Specific UI:**
- Menubar popover (`NSStatusBar` + `NSPopover`); menubar icon shows tooltip with current track
- Main window: resizable, min 385pt wide, max 618pt + 281pt (when sidebar open), max 800pt tall
- Sidebar (history/favorites) opens as inline right panel; window expands to accommodate (+281pt)
- FX panel: replaces setlist section, window expands to max height; setlist state restored on close
- `DraggableDivider`: drag to resize main content width when sidebar open
- `ScrollWheelOverlay`: tracks scroll events, triggers bounce animation on non-setlist areas
- Media keys support via `MPRemoteCommandCenter` (play/pause/toggle on F8 key)
- Now Playing: title = track, artist = artist name, album = "Date • Venue"
- Menubar observers via `NotificationCenter`: `togglePlayback`, `stopPlayback`, `selectStream`, `volumeUp`, `volumeDown`, `setVolume`
- Reconnects on `NSApplication.didBecomeActiveNotification` and `NSWorkspace.didWakeNotification`

**Tour/Geo Data:**
- `GeoData` (in `TourPeriods.swift`) maps tour periods to zappateers.com HTML filenames
- Used by `FZShowsFetcher.fetchShowInfo()` for URL construction
- Also drives `FilterView` hierarchical filters (city/state/country/tour)
- Update this struct when new tours are added to zappateers

## File Organization Quick Reference

| File | Purpose |
|------|---------|
| `BASSRadioPlayer.swift` | Core `@Observable` class: state properties, BASS handles, `PlaybackState` enum, `init` (global BASS config), `deinit`, `play()`, `stop()`, `stopWithFadeOut()`, stream quality list |
| `BASSRadioPlayer+Playback.swift` | Stream lifecycle — `switchQuality()`, `freeStream()`, `restartStream()`, FLAC two-mixer pipeline, pre-buffer sequence, auto-restart, fade-in/out timers, `triggerImmediateReconnect()` |
| `BASSRadioPlayer+Metadata.swift` | Metadata polling — `startMetadataPolling()`, `pollMetadata()`, `fetchIcecastMetadata()`, `publishTitle()`, stall detection |
| `BASSRadioPlayer+AudioFX.swift` | DSP pipeline — `applyEffects()`, EQ, adaptive compressor, stereo M/S + freq-spreading + APF mono synthesis, soft limiter, click guard, `flushEffects()`, `resetAllFX()`, `restoreFXFromDefaults()`, `masterBypassEnabled` |
| `BASSRadioPlayer+DVR.swift` | DVR ring buffer (both platforms) — `dvrPause()`, `dvrResume()`, `dvrPausePlayback()`, `goLive()`, `handleDVRStreamEnd()`, `behindLiveSeconds`, `updateDVRBufferSize()`, recording DSP |
| `ParsedTrackInfo.swift` | Metadata parsing (4 formats), date/location/track extraction via regex |
| `FZShowsFetcher.swift` | HTML scraping for zappateers.com setlists, exceptions dict, fallback to rehearsals.html |
| `ShowDataManager.swift` | SwiftData persistence — `@Observable` singleton, `recordListen()`, history/favorites queries, `toggleFavorite()` |
| `SavedShow.swift` | SwiftData `@Model` — unique key `showDate` ("YYYY MM DD"); setlist/acronyms as JSON `Data` |
| `ContentView.swift` | macOS main window — track info card, show info section, FX panel (inline), DVR controls, menubar observers, `DraggableDivider`, `ScrollWheelOverlay` |
| `ContentView_iOS.swift` | iOS/iPadOS — NavigationStack, iPhone overlay + iPad inline sidebars, DVR controls, sheet-based FX/settings, lock screen integration |
| `AudioFXView.swift` | Shared FX panel — `VerticalEQSlider` (iOS: relative drag + haptics; macOS: absolute), `FXHorizontalSlider`, `StereoWidthSlider`, `StereoPanSlider`, `EQScaleView`; Canvas-based rendering |
| `SidebarView.swift` | Shared history/favorites — collapsible time periods (Day/Week/Month/Year), search/filter integration |
| `FilterView.swift` | Tag-based filtering (tour, year, location) — leverages `GeoData` |
| `ShowEntryRow.swift` | Shared setlist row — duration, notes, duplicate handling, now-playing indicator |
| `TourPeriods.swift` | `GeoData` struct — tour period → zappateers filename map; US states, Canadian provinces, countries |
| `ZappaStreamApp.swift` | App entry, SwiftData `ModelContainer`, menubar (macOS), `AppDelegate` |
| `MarqueeText.swift` | Animated scrolling text for long track titles (macOS) |
| `StreamBuffer.swift` | Rolling WAV segment ring buffer for DVR (both platforms) — 16-bit PCM, 44.1 kHz stereo, 15 × 60s segments |
| `DonlopeIndexCache.swift` | Async cache for donlope.net track URL lookups |
| `SetlistInfoPaneView.swift` | Sheet that loads zappateers.com show page and scrolls to the show date |
| `TrackInfoView.swift` | iOS inline pane showing donlope track info with Safari link |
| `BugReportData.swift` / `MailComposerView.swift` | Bug reporting via email — captures show/track/metadata context |
| Shared utilities | `Acronym.swift`, `Stream.swift`, `PlatformHelpers.swift`, `SongFormatter.swift`, `ScaledFont.swift` |
| iOS-only | `BASSBridgingHeader.h` — BASS C symbols globally available to Swift |

## Development Notes

### Finding Key Code

- **Stream metadata parsing:** `ParsedTrackInfo.parse()` — all format variations
- **Show data fetching:** `FZShowsFetcher.fetchShowInfo()` — update `tourFilenames` when tours change
- **Audio playback:** `BASSRadioPlayer` + extensions
- **FX pipeline:** `BASSRadioPlayer+AudioFX.swift` — `applyEffects()` and DSP callbacks
- **DVR logic:** `BASSRadioPlayer+DVR.swift` — state machine, recording, playback
- **Data persistence:** `ShowDataManager` — `recordListen()`, `@Query` properties
- **UI state:** `ShowDataManager.uiState` — now-playing selection and highlight
- **Menubar (macOS):** `ZappaStreamApp.setupMenubar()` — icon and popover setup
- **Media controls (both):** `ContentView` / `ContentView_iOS` → `setupRemoteCommandCenter()`
- **FX persistence:** `fetchShowInfo()` in both ContentViews — `fxPersistAcrossShows`/`fxPersistOnRestart` logic
- **Track position matching:** `findCurrentTrackPosition()` — handles duplicate song names
- **iOS layout:** `ContentView_iOS.body` — iPad inline sidebar vs iPhone overlay via `horizontalSizeClass`

### Common Tasks

**Adding a new tour:**
1. Add entry to `GeoData.tourPeriods` in `TourPeriods.swift`
2. If special date handling needed, add to `FZShowsFetcher.dateExceptions`
3. Test by playing a show from that period

**Changing metadata parsing format:**
1. Update regex in `ParsedTrackInfo.parse()`
2. Update `FZShowsFetcher` if date format changes
3. Test with shows from multiple eras (metadata formats vary significantly)

**Fixing a show's setlist:**
1. Check `FZShowsFetcher.dateExceptions` first (often a date mismatch)
2. Check if zappateers.com HTML is malformed
3. Debug tip: `#if DEBUG` prints in `ParsedTrackInfo.parse()` and `FZShowsFetcher`

**Adding a new FX control:**
1. Add property to `BASSRadioPlayer+AudioFX.swift`
2. Add corresponding DSP logic in `applyEffects()` or a new DSP callback
3. Add UI control in `AudioFXView.swift` (shared; Canvas-based sliders)
4. Update `isFXBeingUsed` if the new control should trigger the FX indicator
5. Update `resetAllFX()` and `restoreFXFromDefaults()`

**Diagnosing stream issues:**
- Check `playbackState` — should progress `.connecting` → `.buffering` → `.playing`
- `onMetadataUpdate` fires every 3 seconds if stream is live
- Debug metadata: `#if DEBUG` prints in `ParsedTrackInfo.parse()`
- BASS error codes logged in `BASSRadioPlayer`
- FLAC: 7s pre-buffer must complete before playback; monitor `preBufferProgress`

### Project Memory & Planning

Memory files track architectural decisions across Claude Code sessions:

**Memory Files** (`.claude/projects/<project-path>/memory/`):
- `MEMORY.md` — index of all memory files
- `audio_fx_ui_plan.md` — Audio FX panel UI design notes
- `fx_code_analysis.md` — FX code analysis
- `feedback_git.md` — git commit preferences

### Known Limitations & Workarounds

1. **Metadata mismatches:** Zappateers.com sometimes has wrong dates. Exceptions dict + graceful fallbacks handle this.
2. **HTML inconsistency:** Venue/acronym formatting varies by era. Regex-based parsing is fragile; test when modifying.
3. **SwiftData JSON serialization:** Setlist/acronym arrays stored as JSON `Data` — see `SavedShow` model.
4. **No async/await:** Codebase uses `DispatchQueue` + completion handlers throughout.
5. **Single metadata callback:** All 4 formats routed through `onMetadataUpdate` — format handling in `ParsedTrackInfo`.
6. **FLAC metadata lag:** Vorbis short title fires first (bare track name), full metadata arrives via Icecast JSON in next poll; UI merges both to avoid flashing.
7. **OGG Format B:** Some shows have static Vorbis tags that never change per track; Icecast JSON is the only reliable source for these.
8. **DVR at live edge:** Preload guard (`buffer.bufferedDuration - nextTs >= 2.0`) prevents premature segment cycling; `BASS_ChannelPlay` always called in MIXTIME callback to keep mixer alive.

### Testing Strategy

**Unit test suite** (`ZappaStreamTests/`, macOS only, 188 tests as of Mar 2026):
- `ParsedTrackInfoTests` — 4 metadata formats, `tracksMatch`, `normalizeTrackName`, `normalizePluralForm`
- `TourMappingTests` — tour boundaries, gap years, `GeoData.parseLocation`, `GeoData.periodName`, state/province sets
- `ShowTimeFetcherTests` — `ShowTime` enum, exceptions dict, `decodeHTMLEntities`, `parseSetlist`, `parseShowFromHTML` with mock HTML
- `SavedShowTests` — `SavedShow.from()`, computed properties, corrupt-data fallbacks, `toFZShow()` round-trip
- `StreamBufferTests` — `init` clamping, `bufferedDuration` formula, WAV header validation, `updateMaxSegments`

All tests cover pure/stateless business logic. `BASSRadioPlayer` has no unit tests (requires audio hardware).

**Manual verification checklist:**
- After audio changes: verify all 4 formats (MP3 128k, AAC 256k, OGG 90k, FLAC 750k) reach `.playing` and metadata updates every 3s
- After UI changes: test macOS (menubar + window) and iOS (iPhone portrait + iPad landscape)
- After DVR changes: test pause → wait → resume → go live; also test Stop button
- After parsing changes: test shows from pre-2000, 2000s, and recent eras

### Troubleshooting

**iOS build fails:** Verify bridging header and header search path in iOS target Build Settings. Clean build folder and rebuild.

**Metadata never updates:** Confirm `playbackState == .playing`. For FLAC, 7s pre-buffer must complete. Add `#if DEBUG` prints in `ParsedTrackInfo.parse()`.

**Setlist missing:** Check `FZShowsFetcher.dateExceptions`. Debug parsed date — wrong date → wrong URL → empty setlist. Verify zappateers.com URL manually.

**FLAC won't play on iOS:** Verify all 6 BASS xcframeworks in Build Phases → Embed Frameworks (especially `bassflac.xcframework`). Check BASS error logs.

**Stream keeps restarting:** AAC restarts on buffer underrun; OGG needs 2 consecutive STOPPED polls; FLAC uses proactive recovery. After 12 attempts (~1 min) state → `.stopped`.

**FX not persisting across shows:** Check `fxPersistAcrossShows` setting (default off). Also check `fxPersistOnRestart` for same-show-on-restart behaviour.

**DVR going live prematurely:** Check `preloadDVRNextSegment` guard (`bufferedDuration - nextTs >= 2.0`). Verify `BASS_ChannelPlay(mixerHandle, 0)` is called outside the `if nextStream != 0` block in `handleDVRStreamEndMixtime`.
