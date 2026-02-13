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
- **Full setlist** — Does it's best to pull the correct info from [FZShows](https://www.zappateers.com/fzshows/index.html). Hopefully, you see every song in the show with the currently playing track highlighted
- **Smart duplicate handling** — Correctly identifies repeated songs (hopefully) (e.g., multiple "Improvisations")
- **Acronym glossary** — Explains setlist abbreviations

### History & Favorites
- **Listening history** — Automatically tracks shows you've heard
- **Favorites** — Star shows to save them for later
- **Search & filter** — Find shows by period, tour, year, country, state & city

### Platform Features

**macOS:**
- A Menu bar only app
- Media key support (play/pause)
- Resizable window with adaptable layout

**iOS/iPadOS:**
- Lock screen and Control Center integration
- Landscape mode on iPad
- Adaptive layout for all screen sizes

### Planned Features

**iCloud Sync across all Apple devices**

**Band Info:**
- Pull more data from FZshows of the band member linup for that particular tour (and specific show, ideally).

**Customisable section headers for the Favourites tab:**
- Not just by year, but also period, tour, band member, location etc.

**Audio FX:**
To slightly mould certain shows into a more favourable sound if necassary

- L-R Panner
- Mono - Stereo - Stereo-Wider slider
- 3-band EQ
- Compressor


### Current issues & Feedback options

**Mismatched 'Now Playing' track to setlist:**
- This is largely unavoidable as often there are more audio files for sections of the show (.e.g., Preamble) than are listed in the setlist
- ... which means that often the track number is different from the setlist number
- Also, the filenames may differ sometimes from how the tracks are named in the FZShows setlist database which means no 'currently playing' track indicator
- And sometimes the html is inconsistent, leading to misinterpratations of the formatting

**Provide feedback on a currently playing show:**
- Right click or long press on a show either when it's currently playing, or in the History or Favourites sidebar and choose 'Report Issue...' to email me with the details of the show from the livestream metadata and I will look into why the full setlist wasn't fetched correctly from the FZShows database
<img width="482" height="663" alt="Screenshot 2026-02-13 at 13 56 33" src="https://github.com/user-attachments/assets/fad12c2a-16ed-459f-b12b-7f22cf4e3209" />
<img width="461" height="652" alt="Screenshot 2026-02-13 at 13 56 54" src="https://github.com/user-attachments/assets/35bc7608-d446-4d9a-9ffc-c621239e6a1d" />


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
- **Development**: Built with [Claude Code](https://claude.ai/code) — I'm not a developer, but I designed, directed, and managed this project while Claude wrote the code

## Contributing

This is a personal project. Feature suggestions are welcome via [Issues](../../issues). Pull requests may not be reviewed promptly.

## License

This project is licensed under the [MIT License](LICENSE).
