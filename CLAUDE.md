# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZappaStream is a native macOS and iOS app for streaming the 24/7 Zappateers radio stream (Frank Zappa music). It scrapes setlist data from zappateers.com and displays live now-playing info alongside historical show data.

- **macOS**: Menubar-only app for quick access to now-playing and controls
- **iOS**: Full-featured app with Now Playing, history, favorites, and search/filter

## Build & Run

**Requirements:**
- Xcode 15.0 or later
- macOS 14.0 (Sonoma) or later (required to build macOS target; iOS target requires Xcode on macOS)
- Deployment targets: macOS 14.0, iOS/iPadOS 17.5

**Open the project:**

```bash
open ZappaStream.xcodeproj
```

Xcode will automatically resolve the CBass Swift Package dependency (macOS target only). This may take a few seconds on first open.

**Build macOS target:**
```bash
xcodebuild -scheme ZappaStream -configuration Debug
```

**Build iOS target:**
```bash
xcodebuild -scheme ZappaStream-iOS -configuration Debug
```

**Run on macOS (from Xcode):**
- Select `ZappaStream` scheme, then Cmd+R
- Menubar icon appears in top-right corner; click to open popover
- Resizable window: drag edges to adjust width (min 300pt, max 600pt)

**Run on iOS (from Xcode):**
- Select `ZappaStream-iOS` scheme, then Cmd+R
- Choose simulator (iPhone 15, iPad Pro recommended for testing landscape) or connected device

**iOS Build Configuration (one-time after checkout):**

⚠️ **Critical: These manual steps are required; automated tooling does not apply them. Build will fail without them.**

The iOS target requires manual configuration in Xcode Build Settings. If you encounter "BASSRadioPlayer" symbol not found or BASS linker errors, verify these for the **ZappaStream-iOS target only**:

1. **Bridging header:**
   - Build Settings → `SWIFT_OBJC_BRIDGING_HEADER = ZappaStream/BASSBridgingHeader.h`
   - **Why:** iOS requires global availability of BASS C symbols (via `BASSBridgingHeader.h`); this setting makes them visible to the Swift compiler
   - **Verify:** Search "SWIFT_OBJC_BRIDGING_HEADER" in Build Settings; value should appear for ZappaStream-iOS target only, NOT macOS target

2. **Header search path:**
   - Build Settings → `HEADER_SEARCH_PATHS += $(PROJECT_DIR)/Frameworks/iOS/include`
   - **Why:** Points compiler to BASS C header files (`bass.h`, `bass_fx.h`, etc.) needed by the bridging header
   - **Verify:** Search "HEADER_SEARCH_PATHS" in Build Settings; should include `$(PROJECT_DIR)/Frameworks/iOS/include`

3. **Embed BASS frameworks:**
   - Build Phases → Embed Frameworks should contain all **6 BASS xcframeworks** from `Frameworks/iOS/`:
     - `bass.xcframework` — core playback engine
     - `bass_fx.xcframework` — effects (EQ, compressor, reverb)
     - `bassflac.xcframework` — FLAC decoder (critical for 750k lossy-free stream)
     - `basshls.xcframework` — HLS streaming support
     - `bassmix.xcframework` — mixer and DSP callbacks for effects
     - `tags.xcframework` — metadata reading (ID3, Vorbis, etc.)
   - **If missing:** Xcode Build Phases → Embed Frameworks → "+" button → Select all 6 from `Frameworks/iOS/`
   - **Do NOT:** Add to "Link Binary With Libraries" — embedding handles linking automatically
   - **Verify:** Build Phases → Embed Frameworks section should list all 6 frameworks

**macOS target:** No manual setup required; CBass Swift Package resolves automatically via `Package.resolved`.

**Dependencies:**
- **BASS** — Cross-platform audio library (handles all 4 codecs: MP3, AAC, OGG, FLAC)
  - macOS: CBass Swift Package (automatically resolved from `https://github.com/Treata11/CBass.git`)
  - iOS: Pre-built XCFrameworks in `Frameworks/iOS/` (manually configured in build settings above)

## Architecture

### Layers

1. **Audio Playback & Metadata** — `BASSRadioPlayer` (@Observable) wraps the BASS audio library and handles streaming all 4 formats (MP3, AAC, OGG, FLAC). It exposes `onMetadataUpdate` callback with raw ICY/Vorbis/Icecast metadata strings. `ParsedTrackInfo` regex-parses these strings (format: `[Date ShowTime Location] Artist: (Track#) Track Name (Year) [Duration]`) into structured fields.

2. **Show Data Fetching** — `FZShowsFetcher` takes the parsed date/time, scrapes zappateers.com HTML for the full setlist, venue, acronyms, tour info. Has a hardcoded exceptions dictionary for known date mismatches and falls back to `rehearsals.html` when a show isn't found.

3. **Persistence** — `ShowDataManager` wraps SwiftData operations. `SavedShow` is the `@Model` with `showDate` as unique identifier (format `"YYYY MM DD"`). Setlist entries and acronyms are JSON-encoded into `Data` fields.

4. **UI** — `ContentView.swift` (macOS) and `ContentView_iOS.swift` (iOS) are separate files with platform-specific layouts. `SidebarView` handles history/favorites with collapsible time-period headers. `FilterView` provides tour/year/location tag filtering. `ShowEntryRow` is the shared row component. Platform conditionals use `#if os(macOS)` / `#if os(iOS)`. Cross-platform helpers in `PlatformHelpers.swift`.

5. **App Entry & Menubar** — `ZappaStreamApp.swift` sets up SwiftData `ModelContainer`, registers menubar icon (macOS via `NSStatusBar`), handles `AppDelegate` lifecycle. Menubar popover and main window communicate via `NotificationCenter`.

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
          │ (@Observable)     │   3-band EQ, compressor, stereo, limiter
          └────────┬──────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
    (metadata)          (state updates)
        │                     │
    ┌───▼──────────┐      ┌───▼─────────────┐
    │ ParsedTrack  │      │ ContentView /   │
    │ Info.parse() │      │ ContentView_iOS │
    │ (4 formats)  │      │ + AudioFXView   │
    └───┬──────────┘      └────────┬────────┘
        │                          │
    (show date/time)       (format selection)
        │                          │
    ┌───▼──────────────┐          │
    │ FZShowsFetcher   │◄─────────┘
    │ .fetchShowInfo() │ ← HTML scraping, setlist fetch
    │ (tour mapping)   │
    └───┬──────────────┘
        │
    (full show data)
        │
    ┌───▼──────────────┐
    │ ShowDataManager  │ ← Persistence, history/favorites
    │ .recordListen()  │
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
│ SettingsView                        │ ← Format, resume, text scale
│ MarqueeText                         │ ← Animated scrolling titles
└─────────────────────────────────────┘

Platform-Specific:
┌─────────────────────────────┬─────────────────────────────┐
│ macOS (ContentView)         │ iOS (ContentView_iOS)       │
│ • Menubar + main window     │ • Tab navigation            │
│ • NSStatusBar icon          │ • Adaptive iPad landscape   │
│ • NotificationCenter comms  │ • Lock screen controls      │
│ • AudioFXView integration   │ • Pull-down filter reveal   │
└─────────────────────────────┴─────────────────────────────┘
```

### Key Patterns & Architecture Decisions

**State Management:**
- `@State` for local view state, `@AppStorage` for persistent user preferences (app defaults)
- `ShowDataManager` is `@Observable` global singleton, shared across both platforms
- `@Query` properties on views reactively track SwiftData model changes

**Async/Concurrency:**
- Uses `DispatchQueue` + `URLSession.dataTask` with completion handlers (not async/await)
- No Combine or RxSwift; state updates manually via property setters or `DispatchQueue.main.async`

**Streaming & Metadata:**
- `BASSRadioPlayer` polls metadata every 3 seconds via `Timer` (not a streaming callback, due to BASS architecture)
- **Four Metadata Formats Supported:**
  1. **ICY (MP3):** `StreamTitle='[1973 11 07 Boston MA] Artist: (01) Track Name (1973) [3:30]';`
  2. **Vorbis Comments (OGG/FLAC):** Bitstream tags like `TITLE=[1973 11 07 Boston MA] Artist: (01) Track...`
  3. **Icecast JSON (AAC/FLAC fallback):** `{"title": "...", "artist": "..."}`
  4. **Bare Track Name (ultimate fallback):** Simple string when parsing fails, used as-is
- **Format-Specific Handling:**
  - MP3: Exclusively ICY metadata
  - OGG: Primarily Vorbis; Icecast JSON as secondary source
  - AAC/FLAC: Always query Icecast JSON in parallel due to 1-poll-cycle lag in Vorbis comments
- Single metadata callback (`onMetadataUpdate`) unifies all formats for downstream parsing via `ParsedTrackInfo.parse()`

**Audio Effects DSP Pipeline:**
- **3-Band EQ** (via BASS `BASS_FX_BFX_PEAKEQ`):
  - Low band: 100 Hz center frequency
  - Mid band: 1 kHz center frequency
  - High band: 10 kHz center frequency
  - Each band supports ±24 dB gain adjustment
  - Applied first in DSP chain
- **Compressor** (via BASS `BASS_FX_BFX_COMPRESSOR2`):
  - **Adaptive program-dependent threshold:** A level-meter DSP measures RMS of the post-compression signal over ~1.5s windows with EMA smoothing (~4.5s effective time constant). The compressor threshold is set relative to this measured program level, so it compresses proportionally regardless of track loudness.
  - Threshold headroom: At gentle (`compressorAmount`=0): RMS + 6 dB; at heavy (=1): RMS + 2.25 dB
  - Threshold updates only when change exceeds 0.5 dB (avoids jitter)
  - FX stays in chain always; when off or bypassed, set to passthrough (threshold 0 dB, ratio 1:1) instead of add/remove to avoid discontinuity
  - Applied after EQ
- **Stereo Width/Pan** (custom DSP callback, priority 0):
  - Mid-Side (M/S) processing: M = (L+R)/2, S = (L-R)/2
  - Width coefficient mapped from slider: 0.75 (original) → 1.0 (maximum width beyond default)
  - Pan uses sine/cosine angle blending for smooth stereo field positioning
  - **Parameter smoothing:** Per-buffer exponential smoothing (α=0.3) with linear interpolation within each buffer prevents pops/clicks from abrupt parameter jumps at buffer boundaries (~3–4 buffers to settle)
  - Frequency-dependent center spreading — high-freq mono content spreads while bass stays centered (see memory files for implementation details)
- **Soft Limiter** (custom DSP callback, priority -1):
  - Soft knee threshold at 0.89 amplitude prevents digital clipping
  - Knee width: 0.11 (gradual limiting for transparent sound, not audible compression)
  - Applied after all other effects
  - Continuously active to protect audio output
- **Click Guard (custom DSP callback, priority -2):**
  - Suppresses clicks at OGG/FLAC bitstream boundaries during track changes
  - Triggered by `BASS_SYNC_OGG_CHANGE` (mixtime sync) on bitstream boundary detection
  - Applies 10ms fade-out to tail of last audio buffer before boundary, 10ms fade-in to head of first buffer after
  - Seamless 20ms crossfade masks waveform discontinuity; inaudible as musical gap
  - Applied last in DSP chain to ensure clean sample-level modification
  - Format-specific: OGG and FLAC only (MP3 has no bitstream boundaries; AAC restarts the entire stream at each track change due to a server-side issue, so no click suppression is needed or possible)
- **Effect Control:**
  - `isFXBeingUsed` property: returns true if EQ ≠ 0 dB, compressor enabled, or stereo ≠ default
  - Affects UI indication of active processing
  - Master bypass (`masterBypassEnabled`) skips all DSP callbacks when true

**Audio Fade-In/Fade-Out:**
- Fade-in: 0.5s duration on play start (non-FLAC streams and after FLAC pre-buffer completion)
- Fade-out: 0.4s duration when user presses pause/stop button (via `stopWithFadeOut()`)
- Implementation: `BASSRadioPlayer` uses BASS mixer volume attribute (`BASS_ATTRIB_VOL`) ramped via 60Hz timer
- No fade applied on: track format changes, app deinit, internal stream restarts without user interaction
- Public API: Call `stopWithFadeOut()` instead of `stop()` in UI when user initiates pause/stop

**FLAC Streaming & Buffer Management:**
- **Download buffering:** FLAC (~900 kbps compressed) requires aggressive pre-buffering due to 7× higher bitrate than MP3 (128 kbps). On stream start, BASS config is temporarily set to 60s download buffer + 75% pre-buffer threshold (~45s of data required before playback starts), then restored to normal (25s + 50%) after stream creation.
- **Asynchronous decoding:** All formats use `BASS_MIXER_CHAN_BUFFER` flag to pre-decode on a background thread, keeping decoded audio ready so FX parameter changes take effect immediately when the mixer re-renders. Non-FLAC formats additionally use `BASS_MIXER_CHAN_NORAMPIN` to disable initial volume ramp at channel start (FLAC uses fade-in after pre-buffer delay instead).
- **Output buffers:** Mixer output buffer set per format (FLAC: 2.5s for CPU-heavy decode headroom, OGG/MP3/AAC: 0.5s for responsive FX with minimal latency).
- **Pre-buffer delay:** FLAC stream starts muted with volume = 0, then waits 4 seconds for the mixer's decode buffer to fill before fade-in starts. This ensures smooth, uninterrupted playback from the start; without it, initial audio dropout is likely.
- **Metadata lag:** Vorbis comments (FLAC/OGG bitstream metadata) can lag by one 3-second poll cycle. For FLAC/AAC, always query the Icecast JSON endpoint in parallel to get the most current track info.
- **Buffer flush:** `flushEffects()` calls `BASS_ChannelUpdate` to top up the mixer output buffer with freshly-processed audio after FX parameter changes. Works for all formats including FLAC (previously skipped for FLAC due to larger buffers). With reduced mixer buffers (0.5–2.5s), remaining latency is at most the buffer size.
- **Stream restart:** When stream reconnects, the same 60s download buffer + 75% pre-buffer + 4s mute delay applies to FLAC. No fade applied on auto-restart; fade-in only happens on user-initiated play or after pre-buffer.

**HTML Scraping:**
- No external HTML parser; uses `NSRegularExpression` + string slicing
- Handles malformed/inconsistent zappateers.com HTML with careful regex patterns and fallbacks
- `FZShowsFetcher` has hardcoded exceptions dict for known bad dates; maintainable via code changes

**Data Models:**
- `SavedShow` unique identifier is `showDate` (format `"YYYY MM DD"`)
- Setlist/acronym arrays JSON-serialized into `Data` fields (SwiftData limitation workaround)
- `Stream` is a lightweight struct (BASS stream metadata), not persisted

**Platform-Specific Code:**
- Files suffixed `_iOS` (e.g., `ContentView_iOS.swift`) are iOS-only
- Files without suffix are shared (imported by both targets)
- Use `#if os(macOS)` / `#if os(iOS)` for inline conditional compilation
- Minimize platform-specific logic; push differences to dedicated files

**UI Components:**
- `ShowEntryRow` (shared) renders setlist rows with highlight logic
- `SidebarView` (shared) implements history/favorites with collapsible time headers
- `FilterView` (shared) tag-based filtering; leverages `GeoData` (TourPeriods.swift) for hierarchical location data
- `SettingsView` (shared) handles format selection, resume-on-launch toggle
- `MarqueeText` (shared) scrolls long titles smoothly

**Tour/Geo Data:**
- `GeoData` (in `TourPeriods.swift`) static struct maps tour periods to zappateers.com HTML filenames
- Used by `FZShowsFetcher.fetchShowInfo()` to construct URLs
- Also used by `FilterView` to build hierarchical city/state/country filters
- Update this struct when new tours are added to zappateers

**macOS-Specific:**
- Menubar popover uses `NSStatusBar` + `NSPopover`
- Main window resizing constrained via `NSWindowDelegate` (min/max widths)
- Communicates with menubar via `NotificationCenter` (shown/hidden state)
- Media key support via dedicated input event listener

**iOS-Specific:**
- Lock screen and Control Center media controls via `MediaPlayer.framework` + `MPNowPlayingInfoCenter`
- Adaptive layout for iPad landscape mode
- List-based sidebar for history/favorites

## File Organization Quick Reference

| File | Purpose |
|------|---------|
| `BASSRadioPlayer.swift` | Audio playback engine, all 4 codecs, metadata polling, DSP effects — stream state machine, FLAC pre-buffering, fade-in/out, adaptive compressor, stereo smoothing, metadata callback |
| `ParsedTrackInfo.swift` | Metadata parsing (4 formats), date/location/track extraction — regex-based extraction from ICY/Vorbis/Icecast/fallback formats |
| `FZShowsFetcher.swift` | HTML scraping for zappateers.com setlists, exceptions handling — NSRegularExpression, tour period mapping, fallback to rehearsals.html |
| `ShowDataManager.swift` | SwiftData persistence wrapper, history/favorites operations — @Observable singleton managing saves, queries, bulk operations |
| `SavedShow.swift` | SwiftData @Model for persisted shows with JSON-encoded arrays — unique key: `showDate` (format "YYYY MM DD"); setlist/acronyms stored as Data |
| `ContentView.swift` | macOS main window UI, setlist display, now-playing info — sidebar with history/favorites, filter integration, progress display |
| `ContentView_iOS.swift` | iOS/iPadOS app UI with tabs, lock screen integration — Now Playing, History, Favorites, Settings tabs; adaptive landscape layout |
| `AudioFXView.swift` | macOS audio effects control panel (3-band EQ, compressor, stereo, limiter) — Canvas-based UI with vertical sliders; integrates with BASSRadioPlayer DSP |
| `SidebarView.swift` | Shared history/favorites sidebar with collapsible time periods — groups shows by Day/Week/Month/Year; search/filter integration |
| `FilterView.swift` | Tag-based filtering (tour, year, location hierarchies) — leverages GeoData for country/state/city selection |
| `ShowEntryRow.swift` | Shared row component for setlist entries with highlighting — displays duration, notes, handles duplicates, tracks now-playing |
| `TourPeriods.swift` | `GeoData` struct with tour periods and location data — maps years to zappateers.com filenames; US states, Canadian provinces, countries |
| `ZappaStreamApp.swift` | App entry point, SwiftData setup, menubar (macOS), app delegate — ModelContainer setup, NSStatusBar registration, NotificationCenter comms |
| `MarqueeText.swift` | Animated scrolling text for long track titles |
| Shared utilities | `Acronym.swift`, `Stream.swift`, `PlatformHelpers.swift`, `SongFormatter.swift` — platform helpers (email, SafariView, system colors); lightweight data models |
| iOS-only | `BASSBridgingHeader.h` — makes BASS C symbols globally available to Swift; set via SWIFT_OBJC_BRIDGING_HEADER |

## Recent Work & In-Progress Features

See project memory files for current status, decisions, and deferred work:

- `/Users/Datisit/.claude/projects/-Users-Datisit-Developer-ZappaStream/memory/MEMORY.md` — Active plans, completed work, deferred features
- `/Users/Datisit/.claude/projects/-Users-Datisit-Developer-ZappaStream/memory/audio_fx_ui_plan.md` — Audio FX panel UI design and implementation notes
- `/Users/Datisit/.claude/projects/-Users-Datisit-Developer-ZappaStream/memory/fx_code_analysis.md` — FX code analysis
- `/Users/Datisit/.claude/plans/cosmic-twirling-pie.md` — Stereo Widener Extension full implementation plan

## Development Notes

### Finding Key Code

**Stream metadata parsing:** `ParsedTrackInfo.parse()` — handles all metadata format variations
**Show data fetching:** `FZShowsFetcher.fetchShowInfo()` — HTML scraping logic; update `tourFilenames` dict when tours change
**Audio playback:** `BASSRadioPlayer` — all stream formats, metadata polling, state management
**Data persistence:** `ShowDataManager` — SwiftData wrappers; see `recordListen()` and `@Query` properties
**UI state:** `ShowDataManager.uiState` tracks now-playing selection and highlight
**Menubar (macOS):** `ZappaStreamApp.setupMenubar()` — icon registration and popover setup
**Media controls (iOS):** `ContentView_iOS` → `setupMediaControls()` — lock screen and Control Center integration

### Common Tasks

**Adding a new tour:**
1. Add entry to `GeoData.tourPeriods` in `TourPeriods.swift` with correct zappateers.com filename
2. If special date handling needed, add exception to `FZShowsFetcher.dateExceptions`
3. Test by playing a show from that period

**Changing metadata parsing format:**
1. Update regex in `ParsedTrackInfo.parse()`
2. Update `FZShowsFetcher` to handle new date format if needed
3. Test with shows from different eras (some have inconsistent formatting)

**Fixing a show's setlist:**
- If setlist is wrong, first check `FZShowsFetcher.dateExceptions` (might be date mismatch)
- Then check if zappateers.com HTML itself is malformed
- Regex debugging tip: use `#if DEBUG` blocks to print raw HTML and parsed results

**Adding UI filtering:**
- Extend `FilterView` — add new `@State` filter and `predicate` clause
- Leverage existing `GeoData` for hierarchical data (tour, period, location)
- `SidebarView` already groups shows; extend if new grouping needed

**Diagnosing stream issues:**
- Check `BASSRadioPlayer.playbackState` — should progress from `.connecting` → `.buffering` → `.playing`
- Metadata callback (`onMetadataUpdate`) should fire every 3 seconds if stream is live
- Debug metadata format: add `#if DEBUG` print statements in `ParsedTrackInfo.parse()`
- Check BASS error codes (returned by BASS C functions) — logged in `BASSRadioPlayer`
- For FLAC issues on iOS: Check BASS buffering state; FLAC pre-buffers audio before playback (shorter duration tolerance than MP3/AAC)

### Project Memory & Planning

The project uses persistent memory files to track architectural decisions and ongoing work across Claude Code sessions:

**Memory Files:**
- `/Users/Datisit/.claude/projects/-Users-Datisit-Developer-ZappaStream/memory/MEMORY.md` — Active plans, completed work, deferred features (concise reference)
- `/Users/Datisit/.claude/projects/-Users-Datisit-Developer-ZappaStream/memory/audio_fx_ui_plan.md` — Audio FX panel UI design and implementation notes
- `/Users/Datisit/.claude/projects/-Users-Datisit-Developer-ZappaStream/memory/fx_code_analysis.md` — FX code analysis comparing BASSTest vs ZappaStream

**Plan Files:**
- `/Users/Datisit/.claude/plans/cosmic-twirling-pie.md` — Stereo Widener Extension full implementation plan (Approach 3: Frequency-Dependent Center Spreading)

**How to Use:**
- When starting new work, check memory files to understand prior decisions and architectural patterns
- Update relevant memory file after significant changes to document decisions for future sessions
- Link to memory files from code comments when implementing complex features
- When deferring features, document them in MEMORY.md with rationale and next steps

### Known Limitations & Workarounds

1. **Metadata mismatches:** Zappateers.com sometimes has wrong dates or incomplete setlists. App includes exceptions dict and graceful fallbacks.
2. **HTML inconsistency:** Venue/acronym formatting on zappateers varies by era. Regex-based parsing is fragile; test when modifying.
3. **SwiftData JSON serialization:** Setlist/acronym arrays stored as JSON `Data` (not native arrays) — see `SavedShow` model.
4. **iOS bridging header:** BASS C symbols globally available on iOS; header search path must include `Frameworks/iOS/include`.
5. **No async/await:** Codebase uses `DispatchQueue` + completion handlers for consistency with older iOS/macOS versions.
6. **Single metadata source:** All 4 stream formats routed through single `onMetadataUpdate` callback — format handling logic unified in `ParsedTrackInfo`.

### Testing Strategy

Since there's no test suite, focus on manual testing:

**Smoke test:**
- Connect to stream, verify playback starts
- Metadata updates every 3 seconds (observable in `BASSRadioPlayer.currentMetadata`)
- Now-playing track is highlighted in setlist
- Setlist fetches from zappateers.com within a few seconds

**Regression test (after code changes):**
- Verify show appears in History after playback
- Can favorite and unfavorite shows
- Filter/search works correctly
- No crashes or hangs on stream reconnect

**Format test (if modifying audio playback):**
- Test all 4 stream formats: MP3 (128k), AAC (192k), OGG (256k), FLAC (750k lossless)
- Verify each format transitions to `.playing` state
- Check metadata parsing doesn't differ between formats
- Test on both macOS and iOS (different audio stacks)

**Platform test (for shared code changes):**
- Test on both macOS (menubar + main window) and iOS (full app)
- Verify layout adapts correctly on iPad landscape vs portrait
- Check that data persists correctly (History, Favorites)

**Date/parsing test:**
- Test with shows from different eras (pre-2000, 2000s, 2010s, recent)
- Metadata formats vary by era; some have inconsistent formatting
- If adding date parsing changes, test with edge cases like "1999-12-31" shows

### Troubleshooting

**iOS build fails with "BASSRadioPlayer" symbol not found**
- Verify `SWIFT_OBJC_BRIDGING_HEADER` is set in Build Settings (should be `ZappaStream/BASSBridgingHeader.h`)
- Verify `HEADER_SEARCH_PATHS` includes `$(PROJECT_DIR)/Frameworks/iOS/include`
- Run Product → Clean Build Folder, then rebuild

**Stream connects but metadata never updates**
- Confirm `BASSRadioPlayer.playbackState` is `.playing` (not `.buffering`)
- Add debug print to `ParsedTrackInfo.parse()` to see raw metadata string
- Check that Zappateers stream is actually live (visit the stream URL in browser)
- Verify network access is allowed in app entitlements (no sandbox restrictions on macOS)

**Setlist doesn't appear or is incomplete**
- Check `FZShowsFetcher.fetchShowInfo()` — it may not have found a matching show on zappateers.com
- Verify the parsed date/time from metadata is correct (debug `ParsedTrackInfo.parse()`)
- Check if date is in `FZShowsFetcher.dateExceptions` — may need exception for known bad dates
- Try the zappateers.com URL manually in browser to see if HTML is malformed
- If HTML parsing fails, regex in `FZShowsFetcher` may need updating

**macOS menubar icon doesn't appear**
- Verify `ZappaStreamApp.setupMenubar()` is called in `ZappaStreamApp.init()`
- Check System Preferences → General → Login Items to confirm app has access to menubar
- Try restarting the app; menubar registration can be finicky on first launch

**FLAC playback fails on iOS**
- FLAC decoder on iOS requires longer buffering — check `BASSRadioPlayer` pre-buffer duration
- Verify all BASS frameworks are embedded in Build Phases (including `bassflac.xcframework`)
- Check BASS error code returned from stream creation (logged in `BASSRadioPlayer`)

**History or Favorites not persisting**
- Verify SwiftData `ModelContainer` is created correctly in `ZappaStreamApp.init()`
- Check file permissions — app may not have access to app's Documents directory on iOS
- Try uninstalling and reinstalling the app (clears local storage)

**Simulator runs but crashes when toggling format selection**
- Verify `SettingsView` properly notifies `BASSRadioPlayer` of format changes
- Ensure stream is stopped before changing format (see `SettingsView.onChangeFormat`)
- Check that `BASSRadioPlayer` handles rapid format changes gracefully
