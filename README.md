# ZappaStream

A native macOS and iOS app for streaming the 24/7 Zappateers radio stream hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/).

<img width="894" height="856" alt="macOS" src="https://github.com/user-attachments/assets/d2b055d8-4c58-4938-ae1a-5b02a67bc5ee" />

<img width="565" height="1068" alt="iOS iPhone 15" src="https://github.com/user-attachments/assets/a7fc43d1-b793-4258-80ef-0017f24cca79" />

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

### Planned Features

**iCloud Sync across all Apple devices**

**Band Info:**
- Pull more data from FZshows of the band member linup for that particular tour (and specific show, ideally).

**Audio FX:**
To slightly mould certain shows into a more favourable sound if necassary

- L-R Panner
- Mono - Stereo - Stereo-Wider slider
- 3-band EQ
- Compressor

## Screenshots

**macOS:**

<img width="890" height="912" alt="Screenshot 2026-02-13 at 13 20 35" src="https://github.com/user-attachments/assets/f21dd90a-75f6-4b90-a189-ef6b3bc2180e" />
<img width="1126" height="932" alt="Screenshot 2026-02-13 at 12 06 25" src="https://github.com/user-attachments/assets/4010e54b-6034-4228-8d0c-5bac1827d6ab" />
<img width="869" height="504" alt="Screenshot 2026-02-13 at 13 21 49" src="https://github.com/user-attachments/assets/417ab528-1c15-464b-836f-63d1552a3597" />
<img width="753" height="768" alt="Screenshot 2026-02-13 at 13 23 18" src="https://github.com/user-attachments/assets/da78bd80-1e73-4df1-bc17-44db43b9421e" />

**iOS/iPadOS:**

<img width="565" height="1068" alt="Screenshot 2026-02-13 at 13 24 14" src="https://github.com/user-attachments/assets/399f4a80-6d44-48b3-bfbd-4686e95c9821" />
<img width="565" height="1068" alt="Screenshot 2026-02-13 at 13 25 08" src="https://github.com/user-attachments/assets/d8cdd1d5-657d-4946-9fe5-48a75e50d7f8" />
<img src="https://github.com/user-attachments/assets/557e9fd4-547f-410a-8cf1-4062c106a7c8" />





## Requirements

- **macOS**: 14.0 (Sonoma) or later
- **iOS/iPadOS**: 17 or later

## Installation

### macOS

Download the latest release from the [Releases](../../releases) page.

Hopefully availabel in the App Store at some point.

### iOS

Hopefully available in the App Store if there's enough interest.


## Credits

- **Stream**: Hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/)
- **Setlist data**: [Zappateers](https://www.zappateers.com)
- **Audio playback**: [VLCKit](https://code.videolan.org/videolan/VLCKit)

## License

*License TBD*
