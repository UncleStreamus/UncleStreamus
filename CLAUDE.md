# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZappaStream is a native macOS and iOS app for streaming the 24/7 Zappateers radio stream (Frank Zappa music). It scrapes setlist data from zappateers.com and displays live now-playing info alongside historical show data.

- **macOS**: Menubar-only app for quick access to now-playing and controls
- **iOS**: Full-featured app with Now Playing, history, favorites, and search/filter

## Build & Run

**Open the project:**

```bash
open ZappaStream.xcodeproj
```

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
- Menubar icon appears in top-right; click to open popover

**Run on iOS (from Xcode):**
- Select `ZappaStream-iOS` scheme, then Cmd+R
- Choose simulator or connected device

**Manual iOS Setup (one-time):**

After first checkout, iOS build requires manual Xcode steps (not scripted):

1. **Bridging header:** Set in Build Settings under `SWIFT_OBJC_BRIDGING_HEADER` to `ZappaStream/BASSBridgingHeader.h`
2. **Header search path:** Add `$(PROJECT_DIR)/Frameworks/iOS/include` to `HEADER_SEARCH_PATHS`
3. **Embed BASS frameworks:** In Build Phases → Embed Frameworks, add the 6 BASS xcframeworks from `Frameworks/iOS/`:
   - `bass.xcframework`
   - `bass_fx.xcframework`
   - `bassflac.xcframework`
   - `basshls.xcframework`
   - `bassmix.xcframework`
   - `tags.xcframework`

**Dependencies:**
- **BASS** — Cross-platform audio library (handles all 4 formats: MP3, AAC, OGG, FLAC)
  - macOS: CBass Swift Package from `https://github.com/Treata11/CBass.git` (added via File → Add Package)
  - iOS: Pre-built XCFrameworks in `Frameworks/iOS/` (manually embedded)

**Platform requirements:**
- macOS 14.0 (Sonoma)+
- iOS/iPadOS 17+

**Testing:**
No automated test suite. All testing is done by building and running in Xcode. Common manual testing:
- Stream connection and metadata parsing
- Setlist fetching and display
- History/favorites persistence
- Filter and search functionality
- macOS menubar behavior and window resizing

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
- Metadata format varies: MP3 sends ICY metadata, OGG/FLAC use Vorbis comments, fallback to Icecast JSON
- Single metadata callback (`onMetadataUpdate`) unifies all formats for downstream parsing

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

### Known Limitations & Workarounds

1. **Metadata mismatches:** Zappateers.com sometimes has wrong dates or incomplete setlists. App includes exceptions dict and graceful fallbacks.
2. **HTML inconsistency:** Venue/acronym formatting on zappateers varies by era. Regex-based parsing is fragile; test when modifying.
3. **SwiftData JSON serialization:** Setlist/acronym arrays stored as JSON `Data` (not native arrays) — see `SavedShow` model.
4. **iOS bridging header:** BASS C symbols globally available on iOS; header search path must include `Frameworks/iOS/include`.
5. **No async/await:** Codebase uses `DispatchQueue` + completion handlers for consistency with older iOS/macOS versions.
6. **Single metadata source:** All 4 stream formats routed through single `onMetadataUpdate` callback — format handling logic unified in `ParsedTrackInfo`.

### Testing Strategy

Since there's no test suite, focus on manual testing:
- **Smoke test:** Connect to stream, verify metadata updates every 3 seconds, setlist appears
- **Regression test:** After changes, verify show appears in History, can be favorited, filter works
- **Format test:** Test all 4 stream formats (MP3, AAC, OGG, FLAC) if you modify `BASSRadioPlayer`
- **Platform test:** Changes to shared code should be tested on both macOS and iOS
- **Date test:** Changes to metadata/date parsing should be tested with shows from different eras
