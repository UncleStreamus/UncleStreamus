#if os(macOS)
import SwiftUI
import SwiftData
import AVFoundation
import MediaPlayer

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showDataManager: ShowDataManager?

    @State private var isPlaying = false
    @State private var selectedStream: Stream?
    @State private var currentTrack: String = "No track info"
    @State private var parsedTrack: ParsedTrackInfo?
    @State private var bassPlayer = BASSRadioPlayer()
    @State private var currentShow: FZShow?
    @AppStorage("showInfoExpanded") private var showInfoExpanded: Bool = false
    @State private var isFetchingShowInfo: Bool = false
    @State private var availableWidth: CGFloat = 500
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = false
    @AppStorage("textScale") private var textScale: Double = 1.1
    @AppStorage("lastStreamFormat") private var lastStreamFormat: String = "MP3"
    @AppStorage("wasPlayingOnQuit") private var wasPlayingOnQuit: Bool = false
    @State private var panelOpen: Bool = false  // Local state for panel visibility
    @State private var acronymsExpanded: Bool = false  // Collapsible acronyms section
    @State private var contentBounceOffset: CGFloat = 0
    @State private var bounceResetTask: DispatchWorkItem?
    @State private var setlistFrameInWindow: CGRect = .zero  // Track setlist area to exclude from bounce
    @State private var showDelayWarning: Bool = false  // Temporarily show delay warning for non-MP3 streams
    @State private var currentSetlistPosition: Int = 0  // Track position in setlist for duplicate song names
    @State private var selectedSidebarTab: SidebarView.SidebarTab = .history  // Preserve sidebar tab selection

    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "OGG (90 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "AAC (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]

    private let sidebarWidth: CGFloat = 280
    private let dividerWidth: CGFloat = 1  // Width of the visible divider line
    private let mainContentMinWidth: CGFloat = 360  // Min width for main content area
    private let mainContentMaxWidth: CGFloat = 619  // Max width for main content area

    /// Minimum height when setlist is expanded, scales with text size
    private var expandedMinHeight: CGFloat {
        // 520 at 1.0 scale, 570 at 1.1, 620 at 1.2
        let baseHeight: CGFloat = 520
        let scaleBonus = (textScale - 1.0) * 500  // +50 per 0.1 scale increase
        return baseHeight + scaleBonus
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main content - flexible, fills available space
            mainContentView
                .frame(minWidth: mainContentMinWidth, maxWidth: .infinity)

            // Right panel
            if panelOpen, let manager = showDataManager {
                DraggableDivider(
                    minMainWidth: mainContentMinWidth,
                    maxMainWidth: mainContentMaxWidth,
                    panelWidth: sidebarWidth,
                    dividerWidth: dividerWidth
                )
                SidebarView(showDataManager: manager, selectedTab: $selectedSidebarTab)
                    .frame(width: sidebarWidth)
            }
        }
        .frame(minHeight: showInfoExpanded ? expandedMinHeight : 380)
        .environment(\.fontScale, textScale)
        .onAppear {
            if showDataManager == nil {
                showDataManager = ShowDataManager(modelContext: modelContext)
            }
            // Restore last used stream
            if selectedStream == nil {
                selectedStream = streams.first { $0.format == lastStreamFormat } ?? streams.first
            }
            // Sync panel state with persisted sidebar state
            panelOpen = isSidebarVisible
            setupPlayer()
            configureWindowConstraints()
            setupMenubarObservers()

            // Send initial state to menubar
            if let stream = selectedStream {
                NotificationCenter.default.post(name: .streamSelectionChanged, object: nil, userInfo: ["format": stream.format])
            }

            // Auto-play if stream was playing when app was last quit (and auto-resume is enabled)
            // Read directly from UserDefaults to ensure we get the persisted value
            let wasPlaying = UserDefaults.standard.bool(forKey: "wasPlayingOnQuit")
            let autoResumeEnabled = UserDefaults.standard.object(forKey: "autoResumeOnLaunch") as? Bool ?? true
            #if DEBUG
            print("🚀 Launch - was playing: \(wasPlaying), auto-resume enabled: \(autoResumeEnabled)")
            #endif
            if wasPlaying && autoResumeEnabled {
                // Small delay to ensure player is fully initialized
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    #if DEBUG
                    print("▶️ Auto-playing stream...")
                    #endif
                    self.playStream()
                }
            }
        }
        .onDisappear {
            // Save playing state before quitting
            UserDefaults.standard.set(isPlaying, forKey: "wasPlayingOnQuit")
            #if DEBUG
            print("💾 onDisappear - saving playing state: \(isPlaying)")
            #endif
            stopStream()
        }
    }

    private let maxWindowHeight: CGFloat = 800

    /// Configures the window's min/max size constraints
    private func configureWindowConstraints() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.windows.first else { return }
            let panelDelta = sidebarWidth + dividerWidth
            let minHeight: CGFloat = showInfoExpanded ? expandedMinHeight : 380

            let maxWidth: CGFloat
            if panelOpen {
                window.minSize = NSSize(width: mainContentMinWidth + panelDelta, height: minHeight)
                maxWidth = mainContentMaxWidth + panelDelta
            } else {
                window.minSize = NSSize(width: mainContentMinWidth, height: minHeight)
                maxWidth = mainContentMaxWidth
            }
            window.maxSize = NSSize(width: maxWidth, height: maxWindowHeight)

            // Install window delegate to enforce size constraints
            WindowSizeEnforcer.shared.install(on: window, maxWidth: maxWidth, maxHeight: maxWindowHeight)

            #if DEBUG
            print("configureWindowConstraints: maxSize set to \(maxWidth) x \(maxWindowHeight)")
            #endif
        }
    }

    /// Updates window constraints when setlist is expanded/collapsed
    private func updateWindowMinHeight() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow })
                  ?? NSApplication.shared.windows.first else { return }

            let panelDelta = sidebarWidth + dividerWidth
            let minHeight: CGFloat = self.showInfoExpanded ? self.expandedMinHeight : 380

            // Set constraints based on panel state
            if self.panelOpen {
                window.minSize = NSSize(width: mainContentMinWidth + panelDelta, height: minHeight)
                window.maxSize = NSSize(width: self.mainContentMaxWidth + panelDelta, height: self.maxWindowHeight)
            } else {
                window.minSize = NSSize(width: mainContentMinWidth, height: minHeight)
                window.maxSize = NSSize(width: self.mainContentMaxWidth, height: self.maxWindowHeight)
            }
        }
    }

    /// Toggles the right panel by expanding/contracting window to the right
    /// Main content stays in place - panel appears/disappears to its right
    private func toggleSidebar() {
        guard let window = NSApplication.shared.windows.first else { return }

        let panelDelta = sidebarWidth + dividerWidth // +1 for divider
        let currentFrame = window.frame

        #if DEBUG
        print("=== TOGGLE PANEL ===")
        print("Current window frame: \(currentFrame.width) x \(currentFrame.height)")
        print("Panel currently open: \(panelOpen)")
        #endif

        if panelOpen {
            // === CLOSING PANEL ===
            // Calculate current main content width (window minus panel)
            let currentMainWidth = currentFrame.width - panelDelta
            #if DEBUG
            print("CLOSING - current main width: \(currentMainWidth)")
            #endif

            // Hide panel first
            panelOpen = false
            isSidebarVisible = false

            // Update constraints
            window.minSize = NSSize(width: mainContentMinWidth, height: window.minSize.height)
            window.maxSize = NSSize(width: mainContentMaxWidth, height: maxWindowHeight)
            WindowSizeEnforcer.shared.updateMaxWidth(mainContentMaxWidth)

            // Shrink window - just remove the panel width, keeping main content the same
            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: currentMainWidth,
                height: currentFrame.height
            )
            window.setFrame(newFrame, display: true, animate: false)
            #if DEBUG
            print("Window frame set to: \(window.frame.width)")
            #endif
        } else {
            // === OPENING PANEL ===
            let desiredWidth = currentFrame.width + panelDelta
            #if DEBUG
            print("OPENING - expanding to: \(desiredWidth)")
            #endif

            // Update constraints to allow larger window (main content max + panel)
            window.minSize = NSSize(width: mainContentMinWidth + panelDelta, height: window.minSize.height)
            window.maxSize = NSSize(width: mainContentMaxWidth + panelDelta, height: maxWindowHeight)
            WindowSizeEnforcer.shared.updateMaxWidth(mainContentMaxWidth + panelDelta)

            // Expand window
            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: desiredWidth,
                height: currentFrame.height
            )
            window.setFrame(newFrame, display: true, animate: false)
            #if DEBUG
            print("Window frame set to: \(window.frame.width)")
            #endif

            // Show panel
            panelOpen = true
            isSidebarVisible = true
        }
        #if DEBUG
        print("=== END TOGGLE ===\n")
        #endif
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        VStack(spacing: 0) {
            // === TOP: Title (fixed, no bounce) ===
            HStack {
                    Spacer()
                    Text("ZappaStream")
                        .scaledFont(.largeTitle, weight: .bold)
                    Spacer()
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.right")
                            .scaledFont(.title2)
                            .foregroundColor(panelOpen ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.top)

                // === Track Info Card (bounces) ===
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let parsed = parsedTrack, let trackName = parsed.trackName, currentTrack != "No track info" && !currentTrack.isEmpty {
                                MarqueeText(text: trackName, style: .title2, weight: .semibold)
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
                                        Text("• Track \(trackNumber)").scaledFont(.caption).foregroundColor(.secondary)
                                    }
                                    if let trackDuration = parsed.trackDuration {
                                        Text("• \(trackDuration)").scaledFont(.caption).foregroundColor(.secondary)
                                    }
                                } else {
                                    Text(" ")
                                        .scaledFont(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        // Favorite star button (only when show is loaded)
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
                .frame(minHeight: 80)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .offset(y: contentBounceOffset)

                // === MIDDLE: Show Info (fills available space when expanded) ===
            if showInfoExpanded && currentShow != nil {
                showInfoSection
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .frame(maxHeight: .infinity)
            } else {
                showInfoSection
                    .padding(.horizontal)

                Spacer(minLength: 12)
            }

            // === BOTTOM: Stream controls (pinned) ===
            VStack(spacing: 12) {
                Divider()

                // Stream status (now above controls)
                if isPlaying, let stream = selectedStream {
                    VStack(spacing: 2) {
                        Text("Streaming \(stream.name)")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)

                        // Delay warning when using AAC stream - shows briefly then hides
                        if stream.format == "AAC" && showDelayWarning {
                            Text("Info can be up to 1min behind when using AAC...")
                                .scaledFont(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: showDelayWarning)
                }

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
                                .scaledFont(.caption)
                            Text(selectedStream?.format ?? "Stream")
                                .scaledFont(.subheadline, weight: .medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .scaledFont(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .onChange(of: selectedStream) { _, newValue in
                        if let stream = newValue {
                            lastStreamFormat = stream.format
                            NotificationCenter.default.post(name: .streamSelectionChanged, object: nil, userInfo: ["format": stream.format])
                            if isPlaying {
                                playStream()
                            }
                        }
                    }

                    // Play/Pause button
                    Button(action: {
                        if isPlaying { stopStream() } else { playStream() }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .scaledFont(.body)
                            Text(isPlaying ? "Pause" : "Play")
                                .scaledFont(.subheadline, weight: .semibold)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .frame(minWidth: 100)
                        .background(isPlaying ? Color.red.opacity(0.85) : Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(selectedStream == nil)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(minWidth: mainContentMinWidth, idealWidth: showInfoExpanded ? 450 : mainContentMinWidth)
        .coordinateSpace(name: "mainContent")
        .overlay(
            ScrollWheelOverlay(excludeZone: setlistFrameInWindow) { delta in
                handleScrollWheel(delta: delta)
            }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                // Dismiss focus from search field when tapping main content
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        )
    }

    private func handleScrollWheel(delta: CGFloat) {
        // Apply rubber band effect with immediate visual feedback
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8, blendDuration: 0)) {
            let newOffset = contentBounceOffset + delta * 0.12
            // Clamp to reasonable bounds
            contentBounceOffset = max(-25, min(25, newOffset))
        }

        // Cancel any pending reset
        bounceResetTask?.cancel()

        // Schedule spring back after scrolling stops
        let task = DispatchWorkItem { [self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                contentBounceOffset = 0
            }
        }
        bounceResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
    }

    // MARK: - Show Info Section

    @ViewBuilder
    private var showInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show info header button (always visible)
            Button(action: {
                // Only allow expanding if we have show data
                if currentShow != nil {
                    showInfoExpanded.toggle()
                    updateWindowMinHeight()
                }
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let show = currentShow {
                            Text(show.venue)
                                .scaledFont(.headline, weight: .semibold)

                            if let note = show.note {
                                Text((try? AttributedString(markdown: note)) ?? AttributedString(note))
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

                    // Only show chevron if we have show data
                    if currentShow != nil {
                        Image(systemName: showInfoExpanded ? "chevron.up" : "chevron.down")
                    }
                }
                .contentShape(Rectangle())
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(currentShow == nil)
            .offset(y: contentBounceOffset)

            // Expanded setlist section (only when show is loaded)
            if showInfoExpanded, let show = currentShow {
                VStack(alignment: .leading, spacing: 12) {

                    Text("Setlist:")
                        .scaledFont(.headline)

                    ScrollView {
                        Group {
                            if availableWidth > 385 {
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
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(show.setlist.enumerated()), id: \.offset) { index, song in
                                        setlistRow(index: index + 1, song: song, acronyms: show.acronyms)
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
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    setlistFrameInWindow = geo.frame(in: .named("mainContent"))
                                }
                                .onChange(of: geo.frame(in: .named("mainContent"))) { _, newFrame in
                                    setlistFrameInWindow = newFrame
                                }
                        }
                    )

                    // Collapsible official releases section
                    if !show.acronyms.isEmpty {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                acronymsExpanded.toggle()
                            }
                        }) {
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
                            // Deduplicate acronyms (same short form only listed once)
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
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #else
                            // For iOS, we'll add Safari View Controller later
                            #endif
                        }
                    }
                    .scaledFont(.caption)
                    .padding(.top, 8)
                }
                .frame(maxHeight: .infinity)
                .padding()
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .offset(y: contentBounceOffset)
            }
        }
        .contextMenu {
            if let show = currentShow {
                Button(action: {
                    let reportData = BugReportData(
                        showDate: show.date,
                        venue: show.venue,
                        url: show.url,
                        rawMetadata: parsedTrack?.rawTitle,
                        trackName: parsedTrack?.trackName,
                        source: parsedTrack?.source,
                        streamFormat: selectedStream?.format
                    )
                    reportData.openMailClient()
                }) {
                    Label("Report Issue...", systemImage: "envelope")
                }
            }
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

    // MARK: - Favorites

    private var isCurrentShowFavorite: Bool {
        // Reading favoriteVersion creates an @Observable dependency,
        // so this recomputes whenever any star is toggled anywhere
        let _ = showDataManager?.favoriteVersion
        guard let show = currentShow else { return false }
        return showDataManager?.isFavorite(showDate: show.date) ?? false
    }

    // MARK: - Current Track Matching

    /// Extracts the first N words from a string for comparison
    private func firstWords(_ text: String, count: Int = 2) -> String {
        // Remove content in parentheses/brackets first, then get words
        let base = text.components(separatedBy: CharacterSet(charactersIn: "([")).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // Strip punctuation from each word (like commas, apostrophes, etc.)
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

    /// Renders a setlist row with current track highlighting
    @ViewBuilder
    private func setlistRow(index: Int, song: String, acronyms: [(short: String, full: String)]) -> some View {
        let currentPosition = findCurrentTrackPosition()
        let isCurrent = currentPosition == index
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Speaker icon for currently playing track (or invisible placeholder)
            Image(systemName: "speaker.wave.2.fill")
                .scaledFont(.caption2)
                .foregroundColor(isCurrent ? .blue : .clear)
                .frame(width: 14, alignment: .center)

            // Track number
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

    // MARK: - Menubar Menu Observers

    private func setupMenubarObservers() {
        // Listen for play/pause toggle from menubar
        NotificationCenter.default.addObserver(
            forName: .togglePlayback,
            object: nil,
            queue: .main
        ) { [self] _ in
            if isPlaying {
                stopStream()
            } else {
                playStream()
            }
        }

        // Listen for stream selection from menubar
        NotificationCenter.default.addObserver(
            forName: .selectStream,
            object: nil,
            queue: .main
        ) { [self] notification in
            if let format = notification.userInfo?["format"] as? String,
               let stream = streams.first(where: { $0.format == format }) {
                selectedStream = stream
            }
        }
    }

    // MARK: - Player Setup

    func setupPlayer() {
        bassPlayer.onMetadataUpdate = { metadata in
            DispatchQueue.main.async {
                self.currentTrack = metadata
                self.parsedTrack = ParsedTrackInfo.parse(metadata)

                if let parsed = self.parsedTrack, let date = parsed.date {
                    #if DEBUG
                    print("📊 Parsed meta")
                    print("   Date: \(date)")
                    print("   City: \(parsed.city ?? "?"), State: \(parsed.state ?? "?")")
                    print("   Artist: \(parsed.artist ?? "?")")
                    print("   Track: #\(parsed.trackNumber ?? "?") - \(parsed.trackName ?? "?")")
                    print("   Source: \(parsed.source ?? "?") Gen: \(parsed.generation ?? "?")")
                    print("   Duration: \(parsed.trackDuration ?? "?")")
                    print("   ShowTime: \(parsed.showTime ?? "none")")
                    #endif

                    let showTime = ShowTime(from: parsed.showTime)
                    self.fetchShowInfo(date: date, showTime: showTime)
                }

                if let position = self.findCurrentTrackPosition() {
                    self.currentSetlistPosition = position
                }

                self.updateNowPlayingInfo()
            }
        }

        // Setup media key controls
        setupRemoteCommandCenter()

        // Save playing state when app is about to terminate
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            let currentlyPlaying = self.isPlaying
            UserDefaults.standard.set(currentlyPlaying, forKey: "wasPlayingOnQuit")
            UserDefaults.standard.synchronize()
            #if DEBUG
            print("💾 willTerminate - saving playing state: \(currentlyPlaying)")
            #endif
        }
    }

    // MARK: - Media Key Support

    /// Sets up the remote command center for media key support (play/pause buttons on keyboard)
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [self] _ in
            if !isPlaying {
                DispatchQueue.main.async {
                    self.playStream()
                }
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [self] _ in
            if isPlaying {
                DispatchQueue.main.async {
                    self.stopStream()
                }
            }
            return .success
        }

        // Toggle play/pause command (for F8 key on Mac keyboards)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [self] _ in
            DispatchQueue.main.async {
                if self.isPlaying {
                    self.stopStream()
                } else {
                    self.playStream()
                }
            }
            return .success
        }

        // Disable skip commands (we're streaming live, can't skip)
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    /// Updates the Now Playing info center with current track info
    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        if let parsed = parsedTrack {
            nowPlayingInfo[MPMediaItemPropertyTitle] = parsed.trackName ?? "ZappaStream"
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName(from: parsed)

            if let show = currentShow {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "\(show.date) • \(show.venue)"
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "ZappaStream"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "FZShows Radio"
        }

        // Set playback state
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true

        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nowPlayingInfo

        // On macOS, we must set the playback state to register as the Now Playing app
        infoCenter.playbackState = isPlaying ? .playing : .paused

        // Update menubar tooltip
        updateMenubarTooltip()
    }

    /// Posts notification to update menubar icon tooltip with current track info
    private func updateMenubarTooltip() {
        var userInfo: [String: Any] = [:]

        // Mirror track info card - show info regardless of playing state
        if let parsed = parsedTrack, currentTrack != "No track info" && !currentTrack.isEmpty {
            userInfo["trackName"] = parsed.trackName
            userInfo["artist"] = artistName(from: parsed)

            if let show = currentShow {
                userInfo["showInfo"] = "\(show.date) • \(show.venue)"
            }
        }

        NotificationCenter.default.post(
            name: .trackInfoUpdated,
            object: nil,
            userInfo: userInfo
        )
    }


    func playStream(showWarning: Bool = true) {
        guard let stream = selectedStream else { return }

        bassPlayer.play(format: stream.format, url: stream.url)
        isPlaying = true
        NotificationCenter.default.post(name: .playbackStateChanged, object: nil, userInfo: ["isPlaying": true])
        updateNowPlayingInfo()

        if showWarning && stream.format != "MP3" {
            showDelayWarning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation {
                    self.showDelayWarning = false
                }
            }
        } else if stream.format == "MP3" {
            showDelayWarning = false
        }

        UserDefaults.standard.set(true, forKey: "wasPlayingOnQuit")
        #if DEBUG
        print("▶️ Playing - saved state: true")
        #endif
    }

    func stopStream() {
        bassPlayer.stop()
        isPlaying = false
        NotificationCenter.default.post(name: .playbackStateChanged, object: nil, userInfo: ["isPlaying": false])
        updateNowPlayingInfo()

        UserDefaults.standard.set(false, forKey: "wasPlayingOnQuit")
        #if DEBUG
        print("⏸️ Stopped - saved state: false")
        #endif
    }


    /// Formats a song name using the shared SongFormatter
    func formatSong(_ song: String, acronyms: [(short: String, full: String)]) -> Text {
        SongFormatter.format(song, acronyms: acronyms)
    }

    func fetchShowInfo(date: String, showTime: ShowTime = .none) {
        // Only fetch if we don't already have this show (and same showTime)
        guard currentShow?.date != date else { return }

        isFetchingShowInfo = true
        FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime) { show in
            DispatchQueue.main.async {
                self.currentShow = show
                self.currentSetlistPosition = 0  // Reset position for new show
                self.isFetchingShowInfo = false

                if let show = show {
                    #if DEBUG
                    print("✅ Fetched show info for \(show.date)")
                    print("   Venue: \(show.venue)")
                    print("   Setlist: \(show.setlist.count) songs")
                    #endif

                    // Auto-record to history
                    self.showDataManager?.recordListen(show: show)

                    // Update menubar tooltip with show info
                    self.updateNowPlayingInfo()
                }
            }
        }
    }
}

// MARK: - Window Size Enforcer

/// A helper class that enforces window size constraints via NSWindowDelegate
class WindowSizeEnforcer: NSObject, NSWindowDelegate {
    static let shared = WindowSizeEnforcer()

    private var maxWidth: CGFloat = 619
    private var maxHeight: CGFloat = 800
    private weak var installedWindow: NSWindow?

    private override init() {
        super.init()
    }

    func install(on window: NSWindow, maxWidth: CGFloat, maxHeight: CGFloat) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight

        // Only install once
        if installedWindow !== window {
            installedWindow = window
            window.delegate = self
        }
    }

    func updateMaxWidth(_ width: CGFloat) {
        self.maxWidth = width
    }

    // MARK: - NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var newSize = frameSize

        // Enforce max width
        if newSize.width > maxWidth {
            newSize.width = maxWidth
        }

        // Enforce max height
        if newSize.height > maxHeight {
            newSize.height = maxHeight
        }

        return newSize
    }
}

// MARK: - Draggable Divider

/// A draggable divider that resizes the window width when dragged
struct DraggableDivider: View {
    let minMainWidth: CGFloat
    let maxMainWidth: CGFloat
    let panelWidth: CGFloat
    let dividerWidth: CGFloat

    @State private var isDragging = false
    @State private var initialWindowWidth: CGFloat = 0

    private let hitAreaExtension: CGFloat = 4  // How far hit area extends beyond visible divider on each side

    var body: some View {
        // Thin visible divider line
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: dividerWidth)
            // Extend hit area beyond visual bounds using padding + contentShape
            .padding(.horizontal, hitAreaExtension)
            .contentShape(Rectangle())
            // Negative margin to pull adjacent views closer, overlapping with hit area
            .padding(.horizontal, -hitAreaExtension)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isDragging {
                        NSCursor.resizeLeftRight.push()
                    }
                case .ended:
                    if !isDragging {
                        NSCursor.pop()
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard let window = NSApplication.shared.windows.first else { return }

                        // Capture initial width on first drag event
                        if !isDragging {
                            isDragging = true
                            initialWindowWidth = window.frame.width
                            NSCursor.resizeLeftRight.push()
                        }

                        let panelDelta = panelWidth + dividerWidth

                        // Calculate new window width based on drag from initial position
                        let newWindowWidth = initialWindowWidth + value.translation.width

                        // Calculate main content width and clamp
                        let newMainWidth = newWindowWidth - panelDelta
                        let clampedMainWidth = min(max(newMainWidth, minMainWidth), maxMainWidth)
                        let clampedWindowWidth = clampedMainWidth + panelDelta

                        // Only resize if width actually changed
                        let currentFrame = window.frame
                        if abs(clampedWindowWidth - currentFrame.width) > 0.5 {
                            let newFrame = NSRect(
                                x: currentFrame.origin.x,
                                y: currentFrame.origin.y,
                                width: clampedWindowWidth,
                                height: currentFrame.height
                            )
                            window.setFrame(newFrame, display: true, animate: false)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        NSCursor.pop()
                    }
            )
    }
}

// MARK: - Scroll Wheel Overlay

/// A transparent overlay that monitors scroll wheel events at the window level
struct ScrollWheelOverlay: NSViewRepresentable {
    let excludeZone: CGRect  // Area to exclude from bounce effect (e.g., setlist ScrollView)
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelMonitorNSView {
        let view = ScrollWheelMonitorNSView()
        view.onScroll = onScroll
        view.excludeZone = excludeZone
        return view
    }

    func updateNSView(_ nsView: ScrollWheelMonitorNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.excludeZone = excludeZone
    }
}

class ScrollWheelMonitorNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var excludeZone: CGRect = .zero
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Remove existing monitor
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }

        // Add local event monitor for scroll wheel events
        guard window != nil else { return }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }

            // Check if the scroll is happening over this view's window
            guard let window = self.window,
                  event.window == window else { return event }

            // Get mouse location relative to this view (which overlays mainContent)
            let locationInWindow = event.locationInWindow
            let locationInView = self.convert(locationInWindow, from: nil)

            // Check if mouse is within our bounds (the main content area)
            guard self.bounds.contains(locationInView) else { return event }

            // Check if mouse is within the exclude zone (setlist ScrollView)
            // excludeZone is in SwiftUI's named coordinate space (top-left origin relative to mainContent)
            // locationInView is in NSView coordinates (bottom-left origin relative to this view)
            // Since this overlay spans the same area as mainContent, we just need to flip Y
            if !self.excludeZone.isEmpty {
                // Convert NSView coordinates (bottom-left origin) to SwiftUI coordinates (top-left origin)
                let mouseInSwiftUI = CGPoint(
                    x: locationInView.x,
                    y: self.bounds.height - locationInView.y
                )

                if self.excludeZone.contains(mouseInSwiftUI) {
                    // Mouse is over setlist - let it scroll normally, no bounce
                    return event
                }
            }

            // Only handle if this is a trackpad/mouse scroll, not momentum
            if event.momentumPhase == [] || event.phase != [] {
                DispatchQueue.main.async {
                    self.onScroll?(event.scrollingDeltaY)
                }
            }

            return event  // Always return the event to allow normal handling
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Make this view fully transparent to all interactions
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
#endif
