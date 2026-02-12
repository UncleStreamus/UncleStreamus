//
//  ContentView_iOS.swift
//  ZappaStream
//
//  iOS-specific ContentView without window management code
//

#if os(iOS)
import SwiftUI
import SwiftData
import AVFoundation
import MobileVLCKit
import MediaPlayer

struct ContentView_iOS: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDataManager: ShowDataManager?
    @State private var safariURL: IdentifiableURL?

    @State private var isPlaying = false
    @State private var selectedStream: Stream?
    @State private var currentTrack: String = "No track info"
    @State private var parsedTrack: ParsedTrackInfo?
    @State private var mediaPlayer: VLCMediaPlayer?
    @State private var streamReader: IcecastStreamReader?
    @State private var currentShow: FZShow?
    @AppStorage("showInfoExpanded") private var showInfoExpanded: Bool = false
    @State private var isFetchingShowInfo: Bool = false
    @State private var availableWidth: CGFloat = 500
    @AppStorage("textScale") private var textScale: Double = 1.1
    @AppStorage("lastStreamFormat") private var lastStreamFormat: String = "MP3"
    @AppStorage("wasPlayingOnQuit") private var wasPlayingOnQuit: Bool = false
    @State private var acronymsExpanded: Bool = false
    @State private var showSettings: Bool = false
    @State private var showSidebar: Bool = false
    @State private var bugReportData: BugReportData?
    @State private var consecutiveBadStates: Int = 0  // Track bad states for AAC recovery
    @State private var showDelayWarning: Bool = false  // Temporarily show delay warning for non-MP3 streams
    @State private var currentSetlistPosition: Int = 0  // Track position in setlist for duplicate song names
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "AAC (192 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "OGG (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]

    @State private var sidebarNavigationActive: Bool = false
    @State private var contentBounceOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            // Main content with play bar
            VStack(spacing: 0) {
                NavigationStack {
                    ZStack {
                        // Background layer to capture gestures on empty space
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(contentBounceGesture)

                        VStack(spacing: 0) {
                            // Track info card - with bounce gesture
                            trackInfoCard
                                .padding(.horizontal)
                                .padding(.top)
                                .simultaneousGesture(contentBounceGesture)

                            // Show info section - with internal scrolling setlist
                            showInfoSection
                                .padding(.horizontal)
                                .padding(.top, 16)
                                .padding(.bottom, 8)

                            // Push content to top
                            Spacer(minLength: 0)
                        }
                    }
                    .offset(y: contentBounceOffset)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            // Dismiss keyboard when tapping main content (useful on iPad with sidebar visible)
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    )
                    .navigationTitle("Zappa Stream")
                    .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(isPresented: $sidebarNavigationActive) {
                        if let manager = showDataManager {
                            SidebarView(showDataManager: manager)
                                .navigationTitle("")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gear")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if horizontalSizeClass == .regular {
                                // iPad: toggle inline sidebar
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        showSidebar.toggle()
                                    }
                                } label: {
                                    Image(systemName: "sidebar.right")
                                }
                            } else {
                                // iPhone: use navigation push
                                NavigationLink {
                                    if let manager = showDataManager {
                                        SidebarView(showDataManager: manager)
                                            .navigationTitle("")
                                            .navigationBarTitleDisplayMode(.inline)
                                    }
                                } label: {
                                    Image(systemName: "sidebar.right")
                                }
                            }
                        }
                    }
                }

                // Stream controls always visible at bottom
                streamControlsBar
            }

            // iPad: inline sidebar from right
            if horizontalSizeClass == .regular && showSidebar, let manager = showDataManager {
                Divider()
                    .overlay(
                        // Invisible wider hit area for swipe gesture
                        Color.clear
                            .frame(width: 30)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 30)
                                    .onEnded { value in
                                        // Swipe right to push sidebar away
                                        if value.translation.width > 30 && abs(value.translation.height) < 100 {
                                            withAnimation(.easeInOut(duration: 0.25)) {
                                                showSidebar = false
                                            }
                                        }
                                    }
                            )
                    )

                SidebarView(showDataManager: manager)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .environment(\.fontScale, textScale)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
        .sheet(item: $safariURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $bugReportData) { data in
            if MailComposerView.canSendMail {
                MailComposerView(data: data)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Mail Not Available")
                        .font(.headline)
                    Text("Please configure a mail account in Settings to send bug reports.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("OK") {
                        bugReportData = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .onAppear {
            if showDataManager == nil {
                showDataManager = ShowDataManager(modelContext: modelContext)
            }
            if selectedStream == nil {
                selectedStream = streams.first { $0.format == lastStreamFormat } ?? streams.first
            }
            setupPlayer()

            // Auto-play if was playing when app quit
            let shouldAutoPlay = UserDefaults.standard.bool(forKey: "wasPlayingOnQuit")
            if shouldAutoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.playStream()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                UserDefaults.standard.set(isPlaying, forKey: "wasPlayingOnQuit")
            }
        }
    }

    // MARK: - Track Info Card

    private var trackInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let parsed = parsedTrack, let trackName = parsed.trackName, currentTrack != "No track info" && !currentTrack.isEmpty {
                        Text(trackName)
                            .scaledFont(.title2, weight: .semibold)
                            .lineLimit(2)
                    } else {
                        Text(placeholderText)
                            .scaledFont(.title2, weight: .semibold)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        if let parsed = parsedTrack, currentTrack != "No track info" && !currentTrack.isEmpty {
                            Text(artistName(from: parsed))
                                .scaledFont(.subheadline)
                                .foregroundColor(.secondary)
                            if let trackNumber = parsed.trackNumber {
                                Text("• Track \(trackNumber)")
                                    .scaledFont(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let trackDuration = parsed.trackDuration {
                                Text("• \(trackDuration)")
                                    .scaledFont(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(" ")
                                .scaledFont(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if let show = currentShow {
                    Button {
                        showDataManager?.toggleFavorite(show: show)
                    } label: {
                        Image(systemName: isCurrentShowFavorite ? "star.fill" : "star")
                            .foregroundColor(isCurrentShowFavorite ? .yellow : .gray)
                            .font(.title2)
                    }
                }
            }

            Divider()

            HStack {
                if let parsed = parsedTrack, let date = parsed.date, let city = parsed.city, let state = parsed.state, currentTrack != "No track info" && !currentTrack.isEmpty {
                    Text("\(date) • \(city), \(state)")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(" ")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let parsed = parsedTrack, let source = parsed.source, currentTrack != "No track info" && !currentTrack.isEmpty {
                    Text(source)
                        .scaledFont(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Stream Controls Bar

    private var streamControlsBar: some View {
        VStack(spacing: 4) {
            // Stream status notes (above controls)
            if isPlaying, let stream = selectedStream {
                VStack(spacing: 2) {
                    Text("Streaming \(stream.name)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Delay warning when not using MP3 stream - shows briefly then hides
                    if stream.format != "MP3" && showDelayWarning {
                        Text("Info can be ~30s behind when not using MP3 stream")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showDelayWarning)
                .padding(.top, 4)
            }

            HStack(spacing: 10) {
                // Stream picker
                Menu {
                    ForEach(streams) { stream in
                        Button {
                            selectedStream = stream
                        } label: {
                            HStack {
                                Text(stream.name)
                                if selectedStream?.id == stream.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                        Text(selectedStream?.format ?? "Stream")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(8)
                }
                .onChange(of: selectedStream) { _, newValue in
                    if let stream = newValue {
                        lastStreamFormat = stream.format
                        if isPlaying {
                            playStream()
                        }
                    }
                }

                // Play/Pause button
                Button {
                    if isPlaying { stopStream() } else { playStream() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                        Text(isPlaying ? "Pause" : "Play")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isPlaying ? Color.red.opacity(0.85) : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(selectedStream == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Show Info Section

    @ViewBuilder
    private var showInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Venue header - with bounce effect
            Button {
                if currentShow != nil {
                    withAnimation {
                        showInfoExpanded.toggle()
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let show = currentShow {
                            Text(show.venue)
                                .scaledFont(.headline, weight: .semibold)
                                .foregroundColor(.primary)

                            if let note = show.note {
                                Text(try! AttributedString(markdown: note))
                                    .scaledFont(.caption)
                                    .foregroundColor(Color.red.opacity(0.8))
                            }

                            if !show.showInfo.isEmpty {
                                Text(show.showInfo)
                                    .scaledFont(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if isFetchingShowInfo {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading show info...")
                                    .scaledFont(.headline)
                                    .foregroundColor(.gray)
                            }
                        } else {
                            Text(showInfoPlaceholderText)
                                .scaledFont(.headline)
                                .foregroundColor(.gray)
                        }
                    }

                    Spacer()

                    if currentShow != nil {
                        Image(systemName: showInfoExpanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .padding()
                .background(Color.blue.opacity(0.2))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(currentShow == nil)
            .simultaneousGesture(contentBounceGesture)

            if showInfoExpanded, let show = currentShow {
                VStack(alignment: .leading, spacing: 0) {
                    // Setlist header
                    Text("Setlist:")
                        .scaledFont(.headline)
                        .padding(.bottom, 8)

                    GeometryReader { geo in
                        Color.clear.onAppear { availableWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in availableWidth = newWidth }
                    }
                    .frame(height: 0)

                    // Scrollable setlist - NO bounce, just normal scrolling
                    ScrollView {
                        if availableWidth > 500 {
                            // Two-column layout for landscape
                            HStack(alignment: .top, spacing: 20) {
                                let midpoint = (show.setlist.count + 1) / 2

                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(show.setlist.prefix(midpoint).enumerated()), id: \.offset) { index, song in
                                        setlistRow(index: index + 1, song: song, acronyms: show.acronyms)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if show.setlist.count > midpoint {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(show.setlist.dropFirst(midpoint).enumerated()), id: \.offset) { index, song in
                                            setlistRow(index: midpoint + index + 1, song: song, acronyms: show.acronyms)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        } else {
                            // Single-column layout for portrait
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(show.setlist.enumerated()), id: \.offset) { index, song in
                                    setlistRow(index: index + 1, song: song, acronyms: show.acronyms)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Footer section - with bounce effect
                    VStack(alignment: .leading, spacing: 0) {
                        // Official releases
                        if !show.acronyms.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    acronymsExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Text("[")
                                        .scaledFont(.caption, weight: .medium)
                                        .foregroundColor(.secondary)
                                    Text("Official Releases")
                                        .scaledFont(.caption, weight: .medium)
                                        .foregroundColor(Color.orange.opacity(0.8))
                                    Text("]")
                                        .scaledFont(.caption, weight: .medium)
                                        .foregroundColor(.secondary)
                                    Image(systemName: acronymsExpanded ? "chevron.down" : "chevron.right")
                                        .scaledFont(.caption2)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 16)

                            if acronymsExpanded {
                                let uniqueAcronyms = show.acronyms.reduce(into: [(short: String, full: String)]()) { result, acronym in
                                    if !result.contains(where: { $0.short == acronym.short }) {
                                        result.append(acronym)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(uniqueAcronyms, id: \.short) { acronym in
                                        (Text(acronym.short)
                                            .foregroundColor(.blue)
                                            .bold()
                                         + Text(" = \(acronym.full)")
                                            .foregroundColor(.secondary))
                                            .scaledFont(.caption2)
                                            .italic()
                                    }
                                }
                                .padding(.leading, 8)
                            }
                        }

                        Button("Go to FZShows...") {
                            if let url = URL(string: show.url) {
                                safariURL = IdentifiableURL(url: url)
                            }
                        }
                        .scaledFont(.caption)
                        .padding(.top, show.acronyms.isEmpty ? 16 : 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
        }
        .contextMenu {
            if let show = currentShow {
                Button(action: {
                    bugReportData = BugReportData(
                        showDate: show.date,
                        venue: show.venue,
                        url: show.url,
                        rawMetadata: parsedTrack?.rawTitle,
                        trackName: parsedTrack?.trackName,
                        source: parsedTrack?.source,
                        streamFormat: selectedStream?.format
                    )
                }) {
                    Label("Report Issue...", systemImage: "envelope")
                }
            }
        }
    }

    // MARK: - Setlist Row

    @ViewBuilder
    private func setlistRow(index: Int, song: String, acronyms: [(short: String, full: String)]) -> some View {
        let currentPosition = findCurrentTrackPosition()
        let isCurrent = currentPosition == index
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "speaker.wave.2.fill")
                .scaledFont(.caption2)
                .foregroundColor(isCurrent ? .blue : .clear)
                .frame(width: 14, alignment: .center)

            Text("\(index).")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 20, alignment: .trailing)

            formatSong(song, acronyms: acronyms)
                .scaledFont(.caption)
        }
    }

    // MARK: - Placeholder Text

    private var placeholderText: String {
        if !isPlaying {
            return "Nothing playing"
        } else if selectedStream?.format != "MP3" {
            return "Waiting for info..."
        } else {
            return "No track info"
        }
    }

    private var showInfoPlaceholderText: String {
        if !isPlaying {
            return "Show Info"
        } else {
            return "Waiting for show info..."
        }
    }

    // MARK: - Content Bounce Gesture

    private var contentBounceGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Apply subtle rubber band effect in both directions
                contentBounceOffset = value.translation.height * 0.15
            }
            .onEnded { value in
                // Spring back to original position
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    contentBounceOffset = 0
                }

                // Handle sidebar swipe gesture
                if value.translation.width < -50 && abs(value.translation.height) < 100 {
                    if horizontalSizeClass == .regular {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showSidebar = true
                        }
                    } else {
                        sidebarNavigationActive = true
                    }
                }
            }
    }

    // MARK: - Favorites

    private var isCurrentShowFavorite: Bool {
        let _ = showDataManager?.favoriteVersion
        guard let show = currentShow else { return false }
        return showDataManager?.isFavorite(showDate: show.date) ?? false
    }

    // MARK: - Current Track Matching

    private func firstWords(_ text: String, count: Int = 2) -> String {
        let base = text.components(separatedBy: CharacterSet(charactersIn: "([")).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let punctuation = CharacterSet.punctuationCharacters
        let words = base.split(separator: " ").prefix(count).map { word in
            String(word.unicodeScalars.filter { !punctuation.contains($0) })
        }
        return words.joined(separator: " ")
    }

    /// Finds the current track position in the setlist, handling duplicate song names
    /// by picking the first match after the last confirmed position
    private func findCurrentTrackPosition() -> Int? {
        guard let trackName = parsedTrack?.trackName,
              let setlist = currentShow?.setlist else { return nil }

        let trackWords = firstWords(trackName)
        guard !trackWords.isEmpty else { return nil }

        // Find all positions where the song name matches
        var matchingPositions: [Int] = []
        for (index, song) in setlist.enumerated() {
            let songWords = firstWords(song)
            if songWords == trackWords {
                matchingPositions.append(index + 1)  // 1-based position
            }
        }

        guard !matchingPositions.isEmpty else { return nil }

        // Find the first match that comes after our last confirmed position
        // This handles cases like multiple "Improvisations" in a setlist
        for pos in matchingPositions {
            if pos > currentSetlistPosition {
                return pos
            }
        }

        // If no match after current position, return the first match
        // (handles edge cases like restarting mid-show)
        return matchingPositions.first
    }

    // MARK: - Artist Name Helper

    private func artistName(from parsed: ParsedTrackInfo) -> String {
        if let artist = parsed.artist, !artist.isEmpty {
            return artist
        }

        guard let dateStr = parsed.date else { return "Frank Zappa" }

        let parts = dateStr.components(separatedBy: " ")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            return "Frank Zappa"
        }

        if year < 1975 {
            return "The Mothers of Invention"
        }

        if year == 1975 && month <= 5 {
            return "Zappa / Beefheart / Mothers"
        }

        return "Frank Zappa"
    }

    // MARK: - Song Formatting

    func formatSong(_ song: String, acronyms: [(short: String, full: String)]) -> Text {
        SongFormatter.format(song, acronyms: acronyms)
    }

    // MARK: - Player Setup

    func setupPlayer() {
        // Configure audio session for high-quality playback
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setPreferredIOBufferDuration(0.005)
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        mediaPlayer = VLCMediaPlayer()
        streamReader = IcecastStreamReader()

        streamReader?.onMetadataUpdate = { metadata in
            DispatchQueue.main.async {
                self.currentTrack = metadata
                self.parsedTrack = ParsedTrackInfo.parse(metadata)

                if let parsed = self.parsedTrack, let date = parsed.date {
                    let showTime = ShowTime(from: parsed.showTime)
                    self.fetchShowInfo(date: date, showTime: showTime)
                }

                // Update current setlist position for duplicate track name handling
                if let position = self.findCurrentTrackPosition() {
                    self.currentSetlistPosition = position
                }

                self.updateNowPlayingInfo()
            }
        }

        setupRemoteCommandCenter()

        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            self.pollMP3Metadata()
        }

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkStreamState()
        }
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            if !isPlaying {
                DispatchQueue.main.async { self.playStream() }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            if isPlaying {
                DispatchQueue.main.async { self.stopStream() }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                if self.isPlaying { self.stopStream() } else { self.playStream() }
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        if let parsed = parsedTrack {
            nowPlayingInfo[MPMediaItemPropertyTitle] = parsed.trackName ?? "Zappa Stream"

            if let show = currentShow {
                // Put all info in Artist line: "Frank Zappa • 1975 10 04 • Paramount Theatre, Seattle, WA"
                // The venue field already includes location, so no need to add city/state/country
                let artist = artistName(from: parsed)
                let artistLine = "\(artist) • \(show.date) • \(show.venue)"
                nowPlayingInfo[MPMediaItemPropertyArtist] = artistLine
                print("🎵 Now Playing: \(parsed.trackName ?? "?") | \(artistLine)")
            } else {
                nowPlayingInfo[MPMediaItemPropertyArtist] = artistName(from: parsed)
                print("🎵 Now Playing: No show info available yet")
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "Zappa Stream"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "FZShows Radio"
            print("🎵 Now Playing: Default (no parsed track)")
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func checkStreamState() {
        guard let player = mediaPlayer,
              isPlaying,
              let format = selectedStream?.format,
              format != "MP3" else {
            consecutiveBadStates = 0
            return
        }

        // VLC Player States:
        // 0 = NothingSpecial, 1 = Opening, 2 = Buffering, 3 = Playing
        // 4 = Paused, 5 = Stopped, 6 = Ended, 7 = Error
        let state = player.state.rawValue

        // If playing normally, reset counter
        if state == 3 {
            consecutiveBadStates = 0
            return
        }

        // Opening or Buffering states are fine, just wait
        if state == 1 || state == 2 {
            return
        }

        // Bad state detected (0, 5, 6, 7) - increment counter
        consecutiveBadStates += 1

        // First attempt: just nudge VLC to resume
        if consecutiveBadStates == 1 {
            print("⚠️ Bad state detected (state: \(state)), nudging player...")
            player.play()
            return
        }

        // Second attempt: full restart
        if consecutiveBadStates >= 2 {
            print("🔄 Stream restart triggered (state: \(state), format: \(format), consecutive: \(consecutiveBadStates))")
            consecutiveBadStates = 0
            playStream()
        }
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
            // AAC streams need options to handle track boundary discontinuities
            // The server sends AAC with discontinuities at track changes that cause decode errors
            media.addOptions([
                "network-caching": "10000",     // 10 second buffer
                "live-caching": "10000",
                "file-caching": "10000",
                "clock-jitter": "0",
                "clock-synchro": "0",           // Disable clock sync to avoid drops
                "demux": "avformat",
                "avformat-options": "{analyzeduration:20000000,probesize:20000000,err_detect:ignore_err,fflags:+discardcorrupt+ignidx}",
                "codec": "avcodec",
                "avcodec-skiploopfilter": "4",
                "avcodec-skip-frame": "0",
                "avcodec-skip-idct": "0",
                "avcodec-fast": "1",
                "avcodec-hurry-up": "0",
                "avcodec-error-resilience": "4" // Maximum error resilience
            ])
        } else if stream.format == "FLAC" {
            media.addOptions(["network-caching": "3000"])
        }
        mediaPlayer?.media = media
        mediaPlayer?.play()
        isPlaying = true
        updateNowPlayingInfo()

        // Show delay warning for non-MP3 streams, then hide after 5 seconds
        if stream.format != "MP3" {
            showDelayWarning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation {
                    self.showDelayWarning = false
                }
            }
        } else {
            showDelayWarning = false
        }

        UserDefaults.standard.set(true, forKey: "wasPlayingOnQuit")
    }

    func stopStream() {
        mediaPlayer?.pause()
        isPlaying = false
        updateNowPlayingInfo()

        streamReader?.stopStreaming()

        UserDefaults.standard.set(false, forKey: "wasPlayingOnQuit")
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

                    if let parsed = self.parsedTrack, let date = parsed.date {
                        let showTime = ShowTime(from: parsed.showTime)
                        self.fetchShowInfo(date: date, showTime: showTime)
                    }

                    // Update current setlist position for duplicate track name handling
                    if let position = self.findCurrentTrackPosition() {
                        self.currentSetlistPosition = position
                    }

                    self.updateNowPlayingInfo()
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
        guard currentShow?.date != date else { return }

        isFetchingShowInfo = true
        FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime) { show in
            DispatchQueue.main.async {
                self.currentShow = show
                self.currentSetlistPosition = 0  // Reset position for new show
                self.isFetchingShowInfo = false

                if let show = show {
                    self.showDataManager?.recordListen(show: show)
                }

                // Update Now Playing info with show details
                self.updateNowPlayingInfo()
            }
        }
    }
}
#endif
