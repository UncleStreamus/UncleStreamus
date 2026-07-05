# UncleStreamus

A native macOS and iOS app for streaming the 24/7 Zappateers radio stream hosted by [norbert.de](https://www.norbert.de/index.php/frank-zappa/).

<img width="778" height="912" alt="Screenshot 2026-07-03 at 13 29 06" src="https://github.com/user-attachments/assets/71abd70f-c34f-439e-a78a-e1112698c860" />
<img width="564" height="1062" alt="Screenshot 2026-07-03 at 13 53 58" src="https://github.com/user-attachments/assets/31489344-1ad5-48aa-ba9d-50da82eb5d48" />





## Features

### Streaming
- **All 4 codec/quality options** — MP3 (128 kbps), OGG (90 kbps), AAC (256 kbps), FLAC (750 kbps lossless)
- **Automatic stream recovery** — Handles dropouts and reconnects gracefully
- **Resume on launch** —  Continues with the last played codec
- **Continue buffering while paused** — Pick up from where you were for up to 30mins, continue playing delayed until you're ready to jump back to live

### Now Playing
- **Live track info** — Current song, show date, venue, and location
- **Full setlist** — Does it's best to pull the correct info from [FZShows](https://www.zappateers.com/fzshows/index.html). Hopefully, you see every song in the show with the currently playing track highlighted
- **Smart duplicate handling** — Correctly identifies repeated songs (hopefully) (e.g., multiple "Improvisations")
- **Acronym glossary** — Explains setlist abbreviations
- **Band lineup** — Shows who was in the band for the current show
- **Track lookup** — Button to look up currently playing track on [donlope.net](https://www.donlope.net) in a built-in styled viewer
- **Full FZShows page** — Button to open the FZShows setlist page in a built-in viewer, auto-scrolled to the current show

### History & Favorites
- **Listening history** — Automatically tracks shows you've heard
- **Favorites** — Star shows to save them for later
- **Search & filter** — Find shows by period, tour, year, country, state & city
- **iCloud sync** — Listening history and favourites automatically sync across all your Apple devices
- **Export** – Get a txt file record of your History and Favourites that you can referrence outside the app

### Audio FX
- 3-band 'musical' EQ
- Adaptive Compressor
- Mono - Stereo - Stereo-Wider slider
- L-R Panner
- Synthesised Sub Bass
- **Per-show FX memory** — optionally saves your FX settings so they are recalled automatically when the show next plays on the stream

→ See the [in-depth Audio FX guide](docs/AUDIO_FX.md) for what every control does and the subtleties behind each one.

### Platform Features

**macOS:**
- A Menu bar only app
- Media key support (play/pause)
- Resizable window with adaptable layout

**iOS/iPadOS:**
- Lock screen and Control Center integration
- CarPlay support
- Landscape mode on iPad
- Adaptive layout for all screen sizes


### Other Possible Features

- More inline data about the period, tour, band etc

- Customisable section headers for the Favourites tab:
  - Not just by year, but also period, tour, band member, location etc.

### Current issues & Feedback options

 **Mismatched 'Now Playing' track to setlist:**
- This isargely unavoidable as often there are more audio files for sections of the show (.e.g., Preamble) than are listed in the setlist
- ... which means that often the track number is different from the setlist number
- Also, the filenames may differ sometimes from how the tracks are named in the FZShows setlist database which means no 'currently playing' track indicator
- And sometimes the html is inconsistent, leading to misinterpratations of the formatting

**AAC quirks**
- The AAC stream has no native track metadata, so it's taken from the MP3 stream which is often several minutes behind, so the now playing track will generally always be out of sync
- The AAC stream appers to require a restart at the end of each track, which is why there's a short gap between tracks when listening to the AAC stream. Something I will come back around to at somepoint to try and solve. 

**Provide feedback on a currently playing show:**
- Right click or long press on a show either when it's currently playing, or in the History or Favourites sidebar and choose 'Report Issue...' to email me with the details of the show from the livestream metadata and I will look into why the full setlist didn't display or had a formatting issue

<img width="447" height="660" alt="Screenshot 2026-03-05 at 11 31 08" src="https://github.com/user-attachments/assets/4fcdeb51-7fdf-4d80-9db6-47199f66b50a" />
<img width="427" height="682" alt="Screenshot 2026-07-03 at 13 31 59" src="https://github.com/user-attachments/assets/62e2d69e-e04c-48a7-8f08-5bbf2881f917" />





## Screenshots

**macOS:**

<img width="446" height="426" alt="Screenshot 2026-07-03 at 13 33 12" src="https://github.com/user-attachments/assets/14036cbe-1954-4598-ab88-69e52d6eb770" />
<img width="855" height="708" alt="Screenshot 2026-07-03 at 13 34 19" src="https://github.com/user-attachments/assets/2c0ed19c-f8e3-432d-a847-e1858e86869a" />
<img width="778" height="767" alt="Screenshot 2026-07-03 at 13 35 23" src="https://github.com/user-attachments/assets/18fea225-a885-421e-8fcb-a26fe6d4db2b" />
<img width="936" height="1071" alt="Screenshot 2026-07-03 at 13 35 57" src="https://github.com/user-attachments/assets/6c91cb02-75f5-4cf8-94ea-e223c2475361" />
<img width="497" height="912" alt="Screenshot 2026-07-03 at 13 36 13" src="https://github.com/user-attachments/assets/4853ca7f-87cf-4b17-b43d-0169cc328c1d" />
<img width="512" height="392" alt="Screenshot 2026-07-03 at 13 36 41" src="https://github.com/user-attachments/assets/2107bed0-800a-4bf1-9a04-7f0ea63096c4" />
<img width="512" height="689" alt="Screenshot 2026-07-03 at 13 37 45" src="https://github.com/user-attachments/assets/fa8c33fc-84d8-4c31-b472-b90e7330e8fc" />
<img width="512" height="846" alt="Screenshot 2026-07-03 at 13 38 01" src="https://github.com/user-attachments/assets/10637e35-7499-464e-aae7-700c8a502f6d" />


**iOS/iPadOS:**

<img width="564" height="1062" alt="Screenshot 2026-07-03 at 13 54 36" src="https://github.com/user-attachments/assets/8c8a604d-3874-4a52-9fd1-0b5f9d351c07" />
<img width="559" height="1062" alt="Screenshot 2026-03-05 at 11 41 15" src="https://github.com/user-attachments/assets/3287cf48-d28d-422d-a529-62586d390d9a" />
<img width="2360" height="1640" alt="Screenshot 2026-07-03 at 13 57 36" src="https://github.com/user-attachments/assets/b0d0b500-c1ca-49f5-9e40-be71b4aad1bf" />







## Requirements

- **macOS**: 14.0 (Sonoma) or later
- **iOS/iPadOS**: 16.5 or later

## Installation

### macOS

Download the latest `.dmg` from the [Releases](../../releases) page, open it, and drag UncleStreamus to your Applications folder.

UncleStreamus is notarized by Apple — it will open normally on first launch.

Soon to be available via TestFlight: https://testflight.apple.com/join/KdhXVGyY

### iOS

Now available via TestFlight: https://testflight.apple.com/join/KdhXVGyY


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
