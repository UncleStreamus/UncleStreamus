# ZappaStream

A native macOS and iOS app for streaming the 24/7 Zappateers radio stream hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/).

![macOS Screenshot](<img width="894" height="856" alt="Screenshot 2026-02-13 at 13 06 46" src="https://github.com/user-attachments/assets/d2b055d8-4c58-4938-ae1a-5b02a67bc5ee" />)

![iOS Screenshot](<img width="565" height="1068" alt="Screenshot 2026-02-12 at 22 15 51" src="https://github.com/user-attachments/assets/a7fc43d1-b793-4258-80ef-0017f24cca79" />)

## Features

### Streaming
- **All 4 codec/quality options** — MP3 (128 kbps), AAC (192 kbps), OGG (256 kbps), FLAC (750 kbps lossless)
- **Automatic stream recovery** — Handles dropouts and reconnects gracefully
- **Resume on launch** — Optionally picks up where you left off (configure in the settings)

### Now Playing
- **Live track info** — Current song, show date, venue, and location
- **Full setlist** — Info pulled from [FZShows](https://www.zappateers.com/fzshows/index.html).  See every song in the show with the current track highlighted
- **Smart duplicate handling** — Correctly identifies repeated songs (hopefully) (e.g., multiple "Improvisations")
- **Acronym glossary** — Explains setlist abbreviations

### History & Favorites
- **Listening history** — Automatically tracks shows you've heard
- **Favorites** — Star shows to save them for later
- **Search & filter** — Find shows by period, tour, year, country, state & city

### Platform Features

**macOS:**
- Menu bar icon with quick controls
- Media key support (play/pause)
- Resizable window

**iOS/iPadOS:**
- Lock screen and Control Center integration
- Landscape mode on iPad
- Adaptive layout for all screen sizes

## Screenshots

*Add your screenshots here*

## Requirements

- **macOS**: 14.0 (Sonoma) or later
- **iOS/iPadOS**: 17 or later

## Installation

### macOS

Download the latest release from the [Releases](../../releases) page, or build from source:

```bash
git clone https://github.com/Datisit/ZappaStream.git
cd ZappaStream
pod install
open ZappaStream.xcworkspace
```

Build and run with Xcode.

Hopefully availabel in the App Store at some point.

### iOS

Build from source using Xcode, or hopefully available in the App Store eventually.

## Building from Source

### Prerequisites

- Xcode 15.0+
- [CocoaPods](https://cocoapods.org/)

### Steps

1. Clone the repository
2. Run `pod install` in the project directory
3. Open `ZappaStream.xcworkspace` (not `.xcodeproj`)
4. Select your target (macOS or iOS) and build

## Credits

- **Stream**: Hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/)
- **Setlist data**: [Zappateers](https://www.zappateers.com)
- **Audio playback**: [VLCKit](https://code.videolan.org/videolan/VLCKit)

## License

*License TBD*
