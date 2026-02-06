import SwiftUI
import SwiftData
import AVFoundation
import VLCKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showDataManager: ShowDataManager?

    @State private var isPlaying = false
    @State private var selectedStream: Stream?
    @State private var currentTrack: String = "No track info"
    @State private var parsedTrack: ParsedTrackInfo?
    @State private var mediaPlayer: VLCMediaPlayer?
    @State private var streamReader: IcecastStreamReader?
    @State private var currentShow: FZShow?
    @State private var showInfoExpanded: Bool = false
    @State private var isFetchingShowInfo: Bool = false
    @State private var availableWidth: CGFloat = 500
    @State private var isSidebarVisible: Bool = false

    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "AAC (192 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "OGG (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]

    private let sidebarWidth: CGFloat = 280
    private let maxWindowWidth: CGFloat = 900

    var body: some View {
        HStack(spacing: 0) {
            mainContentView

            if isSidebarVisible, let manager = showDataManager {
                Divider()
                SidebarView(showDataManager: manager)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(
            minWidth: isSidebarVisible ? 630 : 350,
            maxWidth: maxWindowWidth,
            minHeight: 520
        )
        .onAppear {
            if showDataManager == nil {
                showDataManager = ShowDataManager(modelContext: modelContext)
            }
            setupPlayer()
        }
        .onDisappear(perform: stopStream)
    }

    /// Toggles the sidebar and resizes the window to accommodate it
    private func toggleSidebar() {
        guard let window = NSApplication.shared.windows.first else {
            isSidebarVisible.toggle()
            return
        }

        let currentFrame = window.frame
        let sidebarDelta = sidebarWidth + 1 // +1 for divider

        if isSidebarVisible {
            // Closing sidebar - shrink window from the right
            let newWidth = max(350, currentFrame.width - sidebarDelta)
            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: newWidth,
                height: currentFrame.height
            )
            withAnimation(.easeInOut(duration: 0.25)) {
                isSidebarVisible = false
            }
            window.setFrame(newFrame, display: true, animate: true)
        } else {
            // Opening sidebar - grow window to the right (unless at max)
            let newWidth = min(maxWindowWidth, currentFrame.width + sidebarDelta)
            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: newWidth,
                height: currentFrame.height
            )
            window.setFrame(newFrame, display: true, animate: true)
            withAnimation(.easeInOut(duration: 0.25)) {
                isSidebarVisible = true
            }
        }
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        VStack(spacing: 0) {
            // === TOP: Title + Track Info (pinned) ===
            VStack(spacing: 12) {
                // Title with sidebar toggle
                HStack {
                    Spacer()
                    Text("Zappa Stream")
                        .font(.largeTitle)
                        .bold()
                    Spacer()
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.right")
                            .font(.title2)
                            .foregroundColor(isSidebarVisible ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Track info card
                VStack(alignment: .leading, spacing: 8) {
                    if let parsed = parsedTrack, currentTrack != "No track info" && !currentTrack.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let trackName = parsed.trackName {
                                    Text(trackName)
                                        .font(.title2)
                                        .fontWeight(.semibold)
                                }
                                
                                HStack {
                                    Text(artistName(from: parsed))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    if let trackNumber = parsed.trackNumber {
                                        Text("• Track \(trackNumber)").font(.caption).foregroundColor(.secondary)
                                    }
                                    if let trackDuration = parsed.trackDuration {
                                        Text("• \(trackDuration)").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            // Favorite star button
                            if let show = currentShow {
                                Button(action: {
                                    showDataManager?.toggleFavorite(show: show)
                                }) {
                                    Image(systemName: isCurrentShowFavorite ? "star.fill" : "star")
                                        .foregroundColor(isCurrentShowFavorite ? .yellow : .gray)
                                }
                                .buttonStyle(.plain)
                            }
                        
                        }
                        
                        Divider()
                        HStack {
                            if let date = parsed.date, let city = parsed.city, let state = parsed.state {
                                Text("\(date) • \(city), \(state)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let source = parsed.source {
                                Text(source)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                    } else {
                        Text("No track info")
                            .font(.headline)
                            .foregroundColor(.gray)
                    }
                }
                .frame(minHeight: 80)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 12)

            // === MIDDLE: Show Info (fills available space) ===
            showInfoSection
                .padding(.horizontal)

            Spacer(minLength: 12)

            // === BOTTOM: Stream controls (pinned) ===
            VStack(spacing: 12) {
                Divider()

                HStack(spacing: 12) {
                    // Stream picker
                    Menu {
                        ForEach(streams) { stream in
                            Button(action: {
                                selectedStream = stream
                            }) {
                                HStack {
                                    Text(stream.name)
                                    if selectedStream?.id == stream.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                            Text(selectedStream?.format ?? "Stream")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .onChange(of: selectedStream) { _, newValue in
                        if newValue != nil && isPlaying {
                            playStream()
                        }
                    }

                    // Play/Pause button
                    Button(action: {
                        if isPlaying { stopStream() } else { playStream() }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.body)
                            Text(isPlaying ? "Pause" : "Play")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .frame(minWidth: 100)
                        .background(isPlaying ? Color.red.opacity(0.85) : Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedStream == nil)
                }

                if isPlaying, let stream = selectedStream {
                    Text("Streaming \(stream.name)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(minWidth: 350, idealWidth: showInfoExpanded ? 450 : 350)
    }

    // MARK: - Show Info Section

    @ViewBuilder
    private var showInfoSection: some View {
        if let show = currentShow {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    showInfoExpanded.toggle()
                }) {
                    HStack {
                        // Venue info (same as expanded content, but more compact)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(show.venue)
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            if let note = show.note {
                                Text(try! AttributedString(markdown: note))
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            
                            if !show.showInfo.isEmpty {
                                Text(show.showInfo)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Image(systemName: showInfoExpanded ? "chevron.up" : "chevron.down")
                    }
                    .contentShape(Rectangle())  // Make entire area tappable
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                if showInfoExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        
                        Text("Setlist:")
                            .font(.headline)

                        ScrollView {
                            Group {
                                if availableWidth > 350 {
                                    HStack(alignment: .top, spacing: 20) {
                                        let midpoint = (show.setlist.count + 1) / 2

                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(Array(show.setlist.prefix(midpoint).enumerated()), id: \.offset) { index, song in
                                                HStack(alignment: .top, spacing: 4) {
                                                    Text("\(index + 1). ")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    formatSong(song, acronyms: show.acronyms)
                                                        .font(.caption)
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        if show.setlist.count > midpoint {
                                            VStack(alignment: .leading, spacing: 4) {
                                                ForEach(Array(show.setlist.dropFirst(midpoint).enumerated()), id: \.offset) { index, song in
                                                    HStack(alignment: .top, spacing: 4) {
                                                        Text("\(midpoint + index + 1). ")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                        formatSong(song, acronyms: show.acronyms)
                                                              .font(.caption)
                                                    }
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(show.setlist.enumerated()), id: \.offset) { index, song in
                                            HStack(alignment: .top, spacing: 4) {
                                                Text("\(index + 1). ")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                formatSong(song, acronyms: show.acronyms)
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 4)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.onAppear {
                                        availableWidth = geo.size.width
                                    }
                                    .onChange(of: geo.size.width) { _, newWidth in
                                        availableWidth = newWidth
                                    }
                                }
                            )
                        }
                        .frame(maxHeight: 200)

                        Button("View on FZShows") {
                            if let url = URL(string: show.url) {
                                #if os(macOS)
                                NSWorkspace.shared.open(url)
                                #else
                                // For iOS, we'll add Safari View Controller later
                                #endif
                            }
                        }
                        .font(.caption)
                        .padding(.top, 1)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                }
            }
        } else if isFetchingShowInfo {
            HStack {
                ProgressView()
                Text("Loading show info...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    // MARK: - Favorites

    private var isCurrentShowFavorite: Bool {
        // Reading favoriteVersion creates an @Observable dependency,
        // so this recomputes whenever any star is toggled anywhere
        let _ = showDataManager?.favoriteVersion
        guard let show = currentShow else { return false }
        return showDataManager?.isFavorite(showDate: show.date) ?? false
    }

    // MARK: - Artist Name Helper

    /// Returns the artist name from metadata, or infers it from the date.
    /// - 1966 through 1974: "The Mothers of Invention"
    /// - Jan-May 1975: "Zappa / Beefheart / Mothers" (Bongo Fury tour)
    /// - June 1975 through 1992: "Frank Zappa"
    private func artistName(from parsed: ParsedTrackInfo) -> String {
        // If metadata has an artist, use it
        if let artist = parsed.artist, !artist.isEmpty {
            return artist
        }

        // Otherwise, infer from date
        guard let dateStr = parsed.date else { return "Frank Zappa" }

        let parts = dateStr.components(separatedBy: " ")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            return "Frank Zappa"
        }

        // The Mothers of Invention era: 1966 through 1974
        if year < 1975 {
            return "The Mothers of Invention"
        }

        // Bongo Fury era: Jan-May 1975
        if year == 1975 && month <= 5 {
            return "Zappa / Beefheart / Mothers"
        }

        // Frank Zappa era: June 1975 onwards
        return "Frank Zappa"
    }

    // MARK: - Player Setup

    func setupPlayer() {
        mediaPlayer = VLCMediaPlayer()
        streamReader = IcecastStreamReader()

        streamReader?.onMetadataUpdate = { metadata in
            DispatchQueue.main.async {
                self.currentTrack = metadata
                self.parsedTrack = ParsedTrackInfo.parse(metadata)

                if let parsed = self.parsedTrack, let date = parsed.date {
                    print("📊 Parsed meta")
                    print("   Date: \(date)")
                    print("   City: \(parsed.city ?? "?"), State: \(parsed.state ?? "?")")
                    print("   Artist: \(parsed.artist ?? "?")")
                    print("   Track: #\(parsed.trackNumber ?? "?") - \(parsed.trackName ?? "?")")
                    print("   Source: \(parsed.source ?? "?") Gen: \(parsed.generation ?? "?")")
                    print("   Duration: \(parsed.trackDuration ?? "?")")
                    print("   ShowTime: \(parsed.showTime ?? "none")")

                    let showTime = ShowTime(from: parsed.showTime)
                    self.fetchShowInfo(date: date, showTime: showTime)
                }
            }
        }

        // Timers should be here, NOT inside the callback
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            self.pollMP3Metadata()
        }

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            self.checkAACState()
        }
    }

    private func checkAACState() {
        guard let player = mediaPlayer,
              isPlaying,
              selectedStream?.format == "AAC",
              player.state.rawValue == 6 else { return }

        print("🔄 AAC restart triggered")
        playStream()
    }

    func playStream() {
        mediaPlayer?.stop()
        streamReader?.stopStreaming()

        guard let stream = selectedStream, let url = URL(string: stream.url) else { return }

        if stream.format == "MP3" {
            streamReader?.startStreaming(url: url)
        } else {
            streamReader?.stopStreaming()
        }

        let media = VLCMedia(url: url)
        if stream.format == "AAC" {
            media.addOptions(["network-caching": "3000"])
        }
        mediaPlayer?.media = media
        mediaPlayer?.play()
        isPlaying = true
    }

    func stopStream() {
        mediaPlayer?.pause()
        streamReader?.stopStreaming()
        isPlaying = false
    }


    @ViewBuilder
    func formatSong(_ song: String, acronyms: [(short: String, full: String)]) -> some View {
        var result = Text("")
        var remainingText = song

        // 1. Process brackets [like this] with acronym highlighting
        while let bracketRange = remainingText.range(of: #"\[[^\]]+\]"#, options: .regularExpression) {
            let before = String(remainingText[..<bracketRange.lowerBound])
            if !before.isEmpty {
                result = result + Text(before)
            }

            let bracketContent = String(remainingText[bracketRange])
            result = result + formatBracketWithAcronyms(bracketContent, acronyms: acronyms)

            remainingText = String(remainingText[bracketRange.upperBound...])
        }

        // 2. Process parentheses (q: something) or (incl. something) ONLY
        while let parenRange = remainingText.range(of: #"\((q:|incl\.)[^)]+\)"#, options: .regularExpression) {
            let before = String(remainingText[..<parenRange.lowerBound])
            if !before.isEmpty {
                result = result + Text(before)
            }

            let parenContent = String(remainingText[parenRange])
            result = result + Text(parenContent)
                .italic()

            remainingText = String(remainingText[parenRange.upperBound...])
        }

        // 3. Remaining regular text
        if !remainingText.isEmpty {
            result = result + Text(remainingText)
        }

        return result
    }

    /// Formats bracketed content, highlighting any acronyms found within
    private func formatBracketWithAcronyms(_ bracket: String, acronyms: [(short: String, full: String)]) -> Text {
        var result = Text("")
        var remaining = bracket

        // Sort acronyms by position in the bracket text
        let sortedAcronyms = acronyms.sorted { first, second in
            let range1 = remaining.range(of: first.short)
            let range2 = remaining.range(of: second.short)
            if let r1 = range1, let r2 = range2 {
                return r1.lowerBound < r2.lowerBound
            }
            return range1 != nil
        }

        for acronym in sortedAcronyms {
            if let range = remaining.range(of: acronym.short) {
                // Text before the acronym
                let before = String(remaining[..<range.lowerBound])
                if !before.isEmpty {
                    result = result + Text(before)
                        .foregroundColor(.secondary)
                        .italic()
                }

                // The acronym itself - highlighted distinctly
                result = result + Text(acronym.short)
                    .foregroundColor(.blue)
                    .bold()

                remaining = String(remaining[range.upperBound...])
            }
        }

        // Any remaining bracket text after all acronyms
        if !remaining.isEmpty {
            result = result + Text(remaining)
                .foregroundColor(.secondary)
                .italic()
        }

        return result
    }

    func pollMP3Metadata() {
        guard let selectedStream = selectedStream,
              (selectedStream.format == "OGG" || selectedStream.format == "FLAC" || selectedStream.format == "AAC"),
              isPlaying else { return }

        let tempReader = IcecastStreamReader()
        tempReader.onMetadataUpdate = { metadata in
            if !metadata.isEmpty {
                DispatchQueue.main.async {
                    self.currentTrack = metadata
                    self.parsedTrack = ParsedTrackInfo.parse(metadata)

                    if let parsed = self.parsedTrack {
                        print("📊 Parsed metadata (from MP3 poll):")
                        print("   Track: #\(parsed.trackNumber ?? "?") - \(parsed.trackName ?? "?")")

                        if let date = parsed.date {
                            let showTime = ShowTime(from: parsed.showTime)
                            self.fetchShowInfo(date: date, showTime: showTime)
                        }
                    }
                }
            }
            tempReader.stopStreaming()
        }

        if let mp3URL = URL(string: "https://shoutcast.norbert.de/zappa.mp3") {
            tempReader.startStreaming(url: mp3URL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                tempReader.stopStreaming()
            }
        }
    }

    func fetchShowInfo(date: String, showTime: ShowTime = .none) {
        // Only fetch if we don't already have this show (and same showTime)
        guard currentShow?.date != date else { return }

        isFetchingShowInfo = true
        FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime) { show in
            DispatchQueue.main.async {
                self.currentShow = show
                self.isFetchingShowInfo = false

                if let show = show {
                    print("✅ Fetched show info for \(show.date)")
                    print("   Venue: \(show.venue)")
                    print("   Setlist: \(show.setlist.count) songs")

                    // Auto-record to history
                    self.showDataManager?.recordListen(show: show)
                }
            }
        }
    }
}
