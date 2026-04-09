# ZappaStream

A native macOS and iOS app for streaming the 24/7 Zappateers radio stream hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/).

<img width="762" height="838" alt="Screenshot 2026-04-09 at 18 32 17" src="https://github.com/user-attachments/assets/0d4ae11b-b5e6-4968-a3aa-ec068ae4bf4d" />
<img width="564" height="1062" alt="Screenshot 2026-04-07 at 13 01 17" src="https://github.com/user-attachments/assets/9cbed6b0-058a-4d8a-81de-409ef3c5f46a" />



## Features

### Streaming
- **All 4 codec/quality options** — MP3 (128 kbps), OGG (90 kbps), AAC (256 kbps), FLAC (750 kbps lossless)
- **Automatic stream recovery** — Handles dropouts and reconnects gracefully
- **Resume on launch** —  Continues with the last played stream
- **Continue buffering while paused** — Pick up from where you were for up to 30mins, continue playing delayed until you're ready to jump back to live

### Now Playing
- **Live track info** — Current song, show date, venue, and location
- **Full setlist** — Does it's best to pull the correct info from [FZShows](https://www.zappateers.com/fzshows/index.html). Hopefully, you see every song in the show with the currently playing track highlighted
- **Smart duplicate handling** — Correctly identifies repeated songs (hopefully) (e.g., multiple "Improvisations")
- **Acronym glossary** — Explains setlist abbreviations
- **Band lineup** — Scraped alongside the setlist, shows who was in the band for the current show
- **Track lookup** — Button to look up currently playing track on [donlope.net](https://www.donlope.net) in a built-in styled viewer
- **Full FZShows page** — Button to open the FZShows setlist page in a built-in viewer, auto-scrolled to the current show

### History & Favorites
- **Listening history** — Automatically tracks shows you've heard
- **Favorites** — Star shows to save them for later
- **Search & filter** — Find shows by period, tour, year, country, state & city

### Audio FX
- 3-band 'musical' EQ
- Adaptive Compressor
- Mono - Stereo - Stereo-Wider slider
- L-R Panner

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

- iCloud Sync across all Apple devices

- More inline data about the period, tour, band etc

- Customisable section headers for the Favourites tab:
  - Not just by year, but also period, tour, band member, location etc.


### Current issues & Feedback options

**Mismatched 'Now Playing' track to setlist:**
- This is largely unavoidable as often there are more audio files for sections of the show (.e.g., Preamble) than are listed in the setlist
- ... which means that often the track number is different from the setlist number
- Also, the filenames may differ sometimes from how the tracks are named in the FZShows setlist database which means no 'currently playing' track indicator
- And sometimes the html is inconsistent, leading to misinterpratations of the formatting

**Provide feedback on a currently playing show:**
- Right click or long press on a show either when it's currently playing, or in the History or Favourites sidebar and choose 'Report Issue...' to email me with the details of the show from the livestream metadata and I will look into why the full setlist wasn't fetched correctly from the FZShows database
<img width="447" height="660" alt="Screenshot 2026-03-05 at 11 31 08" src="https://github.com/user-attachments/assets/2b8a4867-440f-4059-9f7e-40df20839019" />
<img width="429" height="648" alt="Screenshot 2026-03-05 at 11 30 40" src="https://github.com/user-attachments/assets/41d701b6-7e05-40b9-a9c2-8b7a77ea7116" />



## Screenshots

**macOS:**

<img width="480" height="256" alt="Screenshot 2026-03-05 at 11 37 15" src="https://github.com/user-attachments/assets/54c52fb8-c6d2-45f1-a598-45a95063793a" />
<img width="839" height="672" alt="Screenshot 2026-03-05 at 11 35 38" src="https://github.com/user-attachments/assets/cefb8cda-1547-483c-b5b1-d3902da863d8" />
<img width="859" height="676" alt="Screenshot 2026-03-05 at 11 35 01" src="https://github.com/user-attachments/assets/828fe77a-57f5-4bae-bc38-944f4c490460" />
<img width="763" height="892" alt="Screenshot 2026-03-05 at 11 33 55" src="https://github.com/user-attachments/assets/be21a9d2-cbd5-487c-85f0-443a4ef4db4b" />
<img width="926" height="859" alt="Screenshot 2026-03-05 at 11 32 51" src="https://github.com/user-attachments/assets/8ef93bd3-c8bf-4735-9cb6-df932119e872" />
<img width="482" height="912" alt="Screenshot 2026-03-05 at 11 38 38" src="https://github.com/user-attachments/assets/ec9dd67c-1111-46cd-a1cf-0047d654f9a9" />


**iOS/iPadOS:**

<img width="559" height="1062" alt="Screenshot 2026-03-05 at 11 43 30" src="https://github.com/user-attachments/assets/d2e8c4f2-9dd4-483a-9a40-33c55986815d" />
<img width="559" height="1062" alt="Screenshot 2026-03-05 at 11 41 15" src="https://github.com/user-attachments/assets/5ac74d36-4125-4129-b591-8dbfa21dfec8" />
<img src="https://github.com/user-attachments/assets/90c244b3-bb42-4a6f-a2c8-ce89e5b8c44a" />





## Requirements

- **macOS**: 14.0 (Sonoma) or later
- **iOS/iPadOS**: 17 or later

## Installation

### macOS

Download the latest `.dmg` from the [Releases](../../releases) page, open it, and drag ZappaStream to your Applications folder.

**First launch — macOS security warning**

Because ZappaStream is not yet distributed through the Mac App Store, macOS will block it on first launch with a message like *"ZappaStream cannot be opened because the developer cannot be verified."* This is normal for apps downloaded outside the App Store. To open it:

1. In Finder, navigate to your Applications folder
2. **Right-click** (or Control-click) on ZappaStream
3. Choose **Open** from the menu
4. Click **Open** in the dialog that appears

You only need to do this once. After that, ZappaStream opens normally like any other app.

Alternatively, if you've already tried double-clicking and seen the warning, go to **System Settings → Privacy & Security** and scroll down to find an **"Open Anyway"** button next to the ZappaStream entry.

Hopefully available in the App Store at some point.

### iOS

Hopefully available in the App Store if there's enough interest.


## Credits

- **Stream**: Hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/)
- **Setlist data**: [Zappateers](https://www.zappateers.com)
- **Audio library**: [BASS](https://www.un4seen.com/) — Cross-platform audio library for all 4 codecs (MP3, AAC, OGG, FLAC)
- **TAGS library**: by Wraith (with contributions by Ian Luck and Dylan Fitterer) — Tag reading add-on for BASS; released into the public domain
- **Development**: Built with [Claude Code](https://claude.ai/code) — I'm not a developer, but I designed, directed, and managed this project while Claude wrote the code

## Contributing

This is a personal project. Feature suggestions are welcome via [Issues](../../issues). Pull requests may not be reviewed promptly.

## License

This project's source code is licensed under the [MIT License](LICENSE).

**Important — BASS audio library:**
This app uses the [BASS audio library](https://www.un4seen.com/) by Un4seen Developments, which is included as pre-built binaries in this repository. BASS is free for non-commercial use only. If you fork or build upon this project for any commercial purpose, you must obtain a commercial BASS license from [un4seen.com](https://www.un4seen.com/). The MIT license on this repository applies to the source code only and does not grant any rights to use BASS commercially.

**Setlist data:**
Show and setlist data is fetched at runtime by scraping [zappateers.com](https://www.zappateers.com). This is a free fan project — the app itself is not sold and contains no ads or in-app purchases. All setlist content belongs to its respective contributors at Zappateers.
