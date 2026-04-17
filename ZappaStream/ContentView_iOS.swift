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
import MediaPlayer

private enum FooterSection { case bandInfo, officialReleases }

struct ContentView_iOS: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDataManager: ShowDataManager?
    @State private var safariURL: IdentifiableURL?
    @State private var setlistInfoItem: SetlistInfoItem?

    @State private var isPlaying = false
    @State private var selectedStream: Stream?
    @State private var currentTrack: String = "No track info"
    @State private var parsedTrack: ParsedTrackInfo?
    @State private var bassPlayer = BASSRadioPlayer()
    @State private var currentShow: FZShow?
    @AppStorage("showInfoExpanded") private var showInfoExpanded: Bool = false
    @State private var isFetchingShowInfo: Bool = false
    @State private var availableWidth: CGFloat = 500
    @AppStorage("textScale") private var textScale: Double = 1.1
    @AppStorage("lastStreamFormat") private var lastStreamFormat: String = "MP3"
    @AppStorage("wasPlayingOnQuit") private var wasPlayingOnQuit: Bool = false
    @AppStorage("fxPersistAcrossShows") private var fxPersistAcrossShows: Bool = false
    @AppStorage("fxPersistOnRestart") private var fxPersistOnRestart: Bool = false
    @AppStorage("dvrEnabled") private var dvrEnabled: Bool = true
    @AppStorage("dvrBufferMinutes") private var dvrBufferMinutes: Int = 15
    @State private var expandedFooterSection: FooterSection? = nil
    @State private var showSettings: Bool = false
    @State private var showSidebar: Bool = false
    @State private var showFXPane: Bool = false
    @State private var showTrackInfoPane: Bool = false
    @State private var bugReportData: BugReportData?
    @State private var showDelayWarning: Bool = false  // Temporarily show delay warning for non-MP3 streams
    @State private var currentSetlistPosition: Int = 0  // Track position in setlist for duplicate song names
    @State private var selectedSidebarTab: SidebarView.SidebarTab = .history  // Preserve sidebar tab selection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "OGG (90 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "AAC (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]

    @State private var sidebarNavigationActive: Bool = false
    @State private var contentBounceOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            // iPad: inline settings sidebar from left
            if horizontalSizeClass == .regular && showSettings {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .frame(width: 390)
                .transition(.move(edge: .leading))

                Divider()
                    .overlay(
                        // Invisible wider hit area for swipe gesture
                        Color.clear
                            .frame(width: 30)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 30)
                                    .onEnded { value in
                                        // Swipe left to push sidebar away
                                        if value.translation.width < -30 && abs(value.translation.height) < 100 {
                                            withAnimation(.easeInOut(duration: 0.25)) {
                                                showSettings = false
                                            }
                                        }
                                    }
                            )
                    )
            }

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

                            // Show info section OR Track Info pane (with fade transition)
                            if showTrackInfoPane, let trackName = parsedTrack?.trackName {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("Track Info")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button(action: {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                                showTrackInfoPane = false
                                            }
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                                    TrackInfoView(trackName: trackName, openURL: { url in
                                        safariURL = IdentifiableURL(url: url)
                                    })
                                    .id(trackName)
                                    .padding(.horizontal)
                                    .padding(.bottom, 8)
                                }
                                .transition(.opacity)
                            } else {
                                showInfoSection
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                                    .transition(.opacity)
                            }

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
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(isPresented: $sidebarNavigationActive) {
                        if let manager = showDataManager {
                            SidebarView(showDataManager: manager, selectedTab: $selectedSidebarTab)
                                .navigationTitle("")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("ZappaStream")
                                .font(.system(size: 30, weight: .semibold))
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showSettings.toggle()
                                }
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
                                        SidebarView(showDataManager: manager, selectedTab: $selectedSidebarTab)
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

                SidebarView(showDataManager: manager, selectedTab: $selectedSidebarTab)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .environment(\.fontScale, textScale)
        .overlay {
            // iPhone: Settings drawer slides in from left edge
            if horizontalSizeClass == .compact {
                ZStack(alignment: .leading) {
                    Color.black.opacity(showSettings ? 0.3 : 0.0)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showSettings = false
                            }
                        }
                        .allowsHitTesting(showSettings)

                    if showSettings {
                        NavigationStack {
                            SettingsView()
                                .navigationTitle("Settings")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") {
                                            withAnimation(.easeInOut(duration: 0.25)) {
                                                showSettings = false
                                            }
                                        }
                                    }
                                }
                        }
                        .frame(width: 300)
                        .background(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.2), radius: 12, x: 6, y: 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ignoresSafeArea(edges: .vertical)
                        .transition(.move(edge: .leading))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: showSettings)
            }
        }
        .sheet(isPresented: $showFXPane) {
            NavigationStack {
                AudioFXView(player: bassPlayer)
                    .navigationTitle("Audio FX")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showFXPane = false }
                        }
                    }
            }
            .presentationDetents([.fraction(0.78), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $safariURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $setlistInfoItem) { item in
            SetlistInfoPaneView(item: item)
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
            configureAudioSession()
            if showDataManager == nil {
                showDataManager = ShowDataManager(modelContext: modelContext)
            }
            if selectedStream == nil {
                selectedStream = streams.first { $0.format == lastStreamFormat } ?? streams.first
            }
            setupPlayer()
            setupInterruptionHandler()

            // Auto-play if was playing when app quit (and auto-resume is enabled)
            let wasPlaying = UserDefaults.standard.bool(forKey: "wasPlayingOnQuit")
            let autoResumeEnabled = UserDefaults.standard.object(forKey: "autoResumeOnLaunch") as? Bool ?? true
            if wasPlaying && autoResumeEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.playStream()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                UserDefaults.standard.set(isPlaying, forKey: "wasPlayingOnQuit")
            }
            if newPhase == .active {
                // Reconnect whenever the user intended to play but the stream isn't
                // healthy — covers both zero handles (app was suspended during reconnect
                // backoff) and stalled/stopped handles (BASS timed out but handles
                // weren't cleared before suspension). triggerImmediateReconnect() guards
                // internally against disrupting a legitimately playing stream.
                if bassPlayer.isUserIntendedPlay {
                    bassPlayer.triggerImmediateReconnect()
                }
            }
        }
        .onChange(of: dvrBufferMinutes) { _, _ in
            bassPlayer.updateDVRBufferSize()
        }
        .onChange(of: bassPlayer.dvrState) { _, _ in
            updateNowPlayingInfo()
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
                if let source = displaySource, currentTrack != "No track info" && !currentTrack.isEmpty {
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

    private func dvrFormattedBehind(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Stream Controls Bar

    private var streamControlsBar: some View {
        VStack(spacing: 4) {
            // DVR status row
            if isPlaying {
                HStack(spacing: 8) {
                    if bassPlayer.dvrState != .live {
                        Text("\(dvrFormattedBehind(bassPlayer.behindLiveSeconds)) / \(dvrFormattedBehind(bassPlayer.dvrMaxBufferSeconds))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Go Live") { bassPlayer.goLive(); updateNowPlayingInfo() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.72, green: 0.07, blue: 0.07))
                            .controlSize(.small)
                    } else {
                        Text("● LIVE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: bassPlayer.dvrState == .live)
            }

            // Stream status notes (above controls)
            if isPlaying, let stream = selectedStream {
                VStack(spacing: 2) {
                    if bassPlayer.isReconnecting {
                        HStack(spacing: 6) {
                            ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                            Text(bassPlayer.reconnectAttempt > 1
                                 ? "Reconnecting (attempt \(bassPlayer.reconnectAttempt))..."
                                 : "Reconnecting...")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else {
                    let isBuffering = stream.format == "FLAC" && bassPlayer.preBufferProgress > 0
                    Text("\(isBuffering ? "Buffering" : "Streaming") \(stream.name)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // FLAC pre-buffer loading bar: fills 0→100% over 7s then disappears
                    if isBuffering {
                        ProgressView(value: bassPlayer.preBufferProgress)
                            .progressViewStyle(.linear)
                            .tint(colorScheme == .dark ? .secondary : .blue)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .animation(.easeInOut(duration: 0.3), value: isBuffering)
                    }

                    // Delay warning when using AAC stream - shows briefly then hides
                    if stream.format == "AAC" && showDelayWarning {
                        Text("Info can be up to 1min behind when using AAC...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    } // end else (!isReconnecting)
                }
                .animation(.easeInOut(duration: 0.3), value: showDelayWarning)
                .animation(.easeInOut(duration: 0.3), value: bassPlayer.isReconnecting)
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

                // FX button
                Button {
                    showFXPane.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                        Text("FX")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(width: horizontalSizeClass == .regular ? 240 : nil)
                    .padding(.horizontal, horizontalSizeClass == .regular ? 0 : 12)
                    .padding(.vertical, 8)
                    .background(
                        showFXPane
                            ? Color.accentColor.opacity(0.18)
                            : bassPlayer.isFXBeingUsed
                                ? Color.accentColor.opacity(0.12)
                                : Color(.tertiarySystemBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                showFXPane || bassPlayer.isFXBeingUsed
                                    ? Color.accentColor.opacity(0.45)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .cornerRadius(8)
                    .foregroundColor(showFXPane || bassPlayer.isFXBeingUsed ? .accentColor : .primary)
                }

                // Play/Pause button
                Button {
                    guard bassPlayer.checkUserActionAllowed() else { return }
                    switch (isPlaying, bassPlayer.dvrState) {
                    case (false, _):
                        playStream()
                    case (true, .live):
                        if dvrEnabled { bassPlayer.dvrPause() } else { stopStream() }
                        updateNowPlayingInfo()
                    case (true, .paused):
                        bassPlayer.dvrResume()
                        updateNowPlayingInfo()
                    case (true, .playing):
                        bassPlayer.dvrPausePlayback()
                        updateNowPlayingInfo()
                    }
                } label: {
                    HStack(spacing: 4) {
                        let activelyPlaying = isPlaying && bassPlayer.dvrState != .paused
                        Image(systemName: activelyPlaying ? (dvrEnabled ? "pause.fill" : "stop.fill") : "play.fill")
                            .font(.body)
                        Text(activelyPlaying ? (dvrEnabled ? "Pause" : "Stop") : "Play")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isPlaying && bassPlayer.dvrState != .paused ? Color.red.opacity(0.85) : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(selectedStream == nil)

                // Stop button (DVR enabled only) — stops stream and clears buffer
                if dvrEnabled {
                    Button {
                        guard bassPlayer.checkUserActionAllowed() else { return }
                        stopStream()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.body)
                            Text("Stop")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .foregroundColor(isPlaying ? .primary : .secondary)
                        .cornerRadius(8)
                    }
                    .disabled(!isPlaying)
                }
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
                        // Band Info / Official Releases tab row
                        let hasBandInfo = show.bandInfo != nil
                        let hasAcronyms = !show.acronyms.isEmpty
                        if hasBandInfo || hasAcronyms {
                            HStack(spacing: 12) {
                                if let bandInfo = show.bandInfo {
                                    let _ = bandInfo  // suppress unused warning
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedFooterSection = expandedFooterSection == .bandInfo ? nil : .bandInfo
                                        }
                                    } label: {
                                        HStack(spacing: 2) {
                                            Text("[")
                                                .scaledFont(.caption, weight: .medium)
                                                .foregroundColor(.secondary)
                                            Text("Band Info")
                                                .scaledFont(.caption, weight: .medium)
                                                .foregroundColor(.primary)
                                            Text("]")
                                                .scaledFont(.caption, weight: .medium)
                                                .foregroundColor(.secondary)
                                            Image(systemName: expandedFooterSection == .bandInfo ? "chevron.down" : "chevron.right")
                                                .scaledFont(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                if hasAcronyms {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedFooterSection = expandedFooterSection == .officialReleases ? nil : .officialReleases
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
                                            Image(systemName: expandedFooterSection == .officialReleases ? "chevron.down" : "chevron.right")
                                                .scaledFont(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                            }
                            .padding(.top, 16)

                            // Expanded content (only one at a time)
                            if expandedFooterSection == .bandInfo, let bandInfo = show.bandInfo {
                                let parts = bandInfo.split(separator: "\n", maxSplits: 1).map(String.init)
                                VStack(alignment: .leading, spacing: 4) {
                                    if parts.count >= 1 {
                                        Text(parts[0])
                                            .scaledFont(.caption, weight: .medium)
                                            .foregroundColor(.secondary)
                                            .italic()
                                    }
                                    if parts.count >= 2 {
                                        Text(parts[1])
                                            .scaledFont(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 8)
                            } else if expandedFooterSection == .officialReleases {
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

                        HStack(spacing: 8) {
                            Button("Track Info (IINK)...") {
                                guard let trackName = parsedTrack?.trackName else { return }
                                Task {
                                    let result = await DonlopeIndexCache.shared.lookupURL(for: trackName)
                                    let url: URL
                                    if case .found(let found) = result {
                                        url = found
                                    } else {
                                        url = URL(string: "https://www.donlope.net/fz/songs/index.html")!
                                    }
                                    await MainActor.run { safariURL = IdentifiableURL(url: url) }
                                }
                            }
                            .disabled(parsedTrack?.trackName == nil)
                            Spacer()
                            Button("Setlist Info (FZShows)...") {
                                if let url = URL(string: show.url) {
                                    // Strip E/L variant suffix — scroll-to search matches raw HTML dates
                                    let baseDate = show.date.components(separatedBy: " ").prefix(3).joined(separator: " ")
                                    setlistInfoItem = SetlistInfoItem(url: url, showDate: baseDate)
                                }
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
        // Use the confirmed position directly — re-calling findCurrentTrackPosition() here
        // would use "> currentSetlistPosition" and always highlight the *next* duplicate, not the current one.
        let isCurrent = currentSetlistPosition == index
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

    /// Source type (AUD/SBD/FM) from metadata, falling back to showInfo HTML when metadata lacks it
    private var displaySource: String? {
        if let s = parsedTrack?.source { return s }
        guard let info = currentShow?.showInfo else { return nil }
        let upper = info.uppercased()
        for src in ["SBD-AUD", "AUD-SBD", "SBD-FM", "FM-SBD", "AUD-FM", "FM-AUD"] where upper.contains(src) { return src }
        for src in ["AUD", "SBD", "FM", "STAGE"] where upper.contains(src) { return src }
        return nil
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
            if songWords == trackWords || ParsedTrackInfo.tracksMatch(trackName, song) {
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

    // MARK: - Audio Session Interruption Handler

    private func setupInterruptionHandler() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak bassPlayer] notification in
            guard let bassPlayer = bassPlayer,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended {
                let opts = AVAudioSession.InterruptionOptions(
                    rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if opts.contains(.shouldResume) && bassPlayer.isUserIntendedPlay {
                    configureAudioSession()
                    bassPlayer.triggerImmediateReconnect()
                }
            }
        }
    }

    // MARK: - Audio Session Setup

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
            // Request a larger hardware IO buffer to reduce scheduling pressure and micro-stutters.
            // 0.5s means CoreAudio calls BASS 2×/sec instead of 10×/sec, giving the FLAC decoder
            // far more time per callback. Fine for a radio app where output latency doesn't matter.
            try audioSession.setPreferredIOBufferDuration(0.5)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #if DEBUG
            print("✅ Audio session configured for playback")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to configure audio session: \(error)")
            #endif
        }
    }

    // MARK: - Player Setup

    func setupPlayer() {
        bassPlayer.onMetadataUpdate = { metadata in
            DispatchQueue.main.async {
                let newParsed = ParsedTrackInfo.parse(metadata)

                // Block if truly nothing meaningful changed (same track name and same date).
                let trackNameSame = (self.parsedTrack?.trackName == newParsed.trackName)
                let dateSame = (self.parsedTrack?.date == newParsed.date)
                guard !(trackNameSame && dateSame) else { return }

                // For FLAC: Vorbis short title arrives first (trackName only, date=nil).
                // Merge it with the existing parsedTrack's show metadata so date/location/artist
                // stay visible in the UI — no flash from sections disappearing mid-show.
                let merged: ParsedTrackInfo
                if newParsed.date == nil, let old = self.parsedTrack {
                    merged = ParsedTrackInfo(
                        date: old.date, showTime: old.showTime,
                        city: old.city, state: old.state,
                        showDuration: old.showDuration, source: old.source,
                        generation: old.generation, creator: old.creator,
                        artist: old.artist, trackNumber: newParsed.trackNumber ?? old.trackNumber,
                        trackName: newParsed.trackName, year: newParsed.year,
                        trackDuration: newParsed.trackDuration ?? old.trackDuration, rawTitle: newParsed.rawTitle
                    )
                } else {
                    merged = newParsed
                }

                self.currentTrack = metadata
                self.parsedTrack = merged

                if let parsed = self.parsedTrack, let date = parsed.date {
                    let showTime = ShowTime(from: parsed.showTime)
                    self.fetchShowInfo(date: date, showTime: showTime)
                }

                if let position = self.findCurrentTrackPosition() {
                    self.currentSetlistPosition = position
                }

                self.updateNowPlayingInfo()
            }
        }

        setupRemoteCommandCenter()
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            DispatchQueue.main.async {
                #if DEBUG
                print("▶️  remoteCmd PLAY — isPlaying=\(self.isPlaying) dvrState=\(self.bassPlayer.dvrState)")
                #endif
                guard self.bassPlayer.checkUserActionAllowed() else { return }
                if self.bassPlayer.dvrState == .paused {
                    self.bassPlayer.dvrResume()
                    self.updateNowPlayingInfo()
                } else if !self.isPlaying {
                    self.playStream()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                #if DEBUG
                print("⏸️  remoteCmd PAUSE — isPlaying=\(self.isPlaying) dvrState=\(self.bassPlayer.dvrState)")
                #endif
                guard self.isPlaying else { return }
                // Don't call checkUserActionAllowed for a no-op (already paused) — avoid
                // consuming the debounce when iOS/AirPods send a stale pause while we're
                // already paused, which would block the subsequent play press.
                guard self.bassPlayer.dvrState != .paused else { return }
                guard self.bassPlayer.checkUserActionAllowed() else { return }
                switch self.bassPlayer.dvrState {
                case .live:
                    if self.dvrEnabled { self.bassPlayer.dvrPause() } else { self.stopStream() }
                    self.updateNowPlayingInfo()
                case .paused:
                    break  // unreachable; guarded above
                case .playing:
                    self.bassPlayer.dvrPausePlayback()
                    self.updateNowPlayingInfo()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                #if DEBUG
                print("⏯️  remoteCmd TOGGLE — isPlaying=\(self.isPlaying) dvrState=\(self.bassPlayer.dvrState)")
                #endif
                guard self.bassPlayer.checkUserActionAllowed() else { return }
                switch (self.isPlaying, self.bassPlayer.dvrState) {
                case (false, _):
                    self.playStream()
                case (true, .live):
                    if self.dvrEnabled { self.bassPlayer.dvrPause() } else { self.stopStream() }
                    self.updateNowPlayingInfo()
                case (true, .paused):
                    self.bassPlayer.dvrResume()
                    self.updateNowPlayingInfo()
                case (true, .playing):
                    self.bassPlayer.dvrPausePlayback()
                    self.updateNowPlayingInfo()
                }
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        if let parsed = parsedTrack {
            nowPlayingInfo[MPMediaItemPropertyTitle] = parsed.trackName ?? "ZappaStream"

            if let show = currentShow {
                // Put all info in Artist line: "Frank Zappa • 1975 10 04 • Paramount Theatre, Seattle, WA"
                // The venue field already includes location, so no need to add city/state/country
                let artist = artistName(from: parsed)
                let artistLine = "\(artist) • \(show.date) • \(show.venue)"
                nowPlayingInfo[MPMediaItemPropertyArtist] = artistLine
                #if DEBUG
                print("🎵 Now Playing: \(parsed.trackName ?? "?") | \(artistLine)")
                #endif
            } else {
                nowPlayingInfo[MPMediaItemPropertyArtist] = artistName(from: parsed)
                #if DEBUG
                print("🎵 Now Playing: No show info available yet")
                #endif
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "ZappaStream"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "FZShows Radio"
            #if DEBUG
            print("🎵 Now Playing: Default (no parsed track)")
            #endif
        }

        let dvrPaused = bassPlayer.dvrState == .paused
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = (isPlaying && !dvrPaused) ? 1.0 : 0.0
        // IsLiveStream=true causes iOS to ignore playbackRate=0, so clear it when DVR is paused
        // so the lock screen and AirPods correctly reflect the paused state.
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = !dvrPaused
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func playStream(showWarning: Bool = true) {
        guard let stream = selectedStream else { return }

        configureAudioSession()
        bassPlayer.play(format: stream.format, url: stream.url)
        isPlaying = true
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
    }

    func stopStream() {
        bassPlayer.stopWithFadeOut()
        isPlaying = false
        updateNowPlayingInfo()

        UserDefaults.standard.set(false, forKey: "wasPlayingOnQuit")
    }

    func fetchShowInfo(date: String, showTime: ShowTime = .none) {
        // Build the variant date key (e.g. "1980 12 11 E") for accurate early/late deduplication
        let variantDate: String
        switch showTime {
        case .early: variantDate = "\(date) E"
        case .late:  variantDate = "\(date) L"
        case .none:  variantDate = date
        }
        guard currentShow?.date != variantDate else { return }

        // Determine whether to restore or reset FX based on show change and persistence settings
        let lastShowDate = UserDefaults.standard.string(forKey: "lastShowDateOnQuit")
        let showHasChanged = lastShowDate != nil && lastShowDate != variantDate

        if showHasChanged {
            if !fxPersistAcrossShows {
                bassPlayer.resetAllFX()
            }
        } else if lastShowDate == nil {
            if !fxPersistAcrossShows {
                bassPlayer.resetAllFX()
            }
        } else {
            // Same show as when app quit: restore FX if "persist on restart" is enabled
            if fxPersistOnRestart {
                bassPlayer.restoreFXFromDefaults()
            } else {
                bassPlayer.resetAllFX()
            }
        }

        isFetchingShowInfo = true
        FZShowsFetcher.fetchShowInfo(date: date, showTime: showTime) { show in
            DispatchQueue.main.async {
                self.currentShow = show
                self.currentSetlistPosition = 0  // Reset position for new show
                // Re-compute from parsedTrack so the speaker appears on first load
                // without waiting for the next metadata poll.
                if let position = self.findCurrentTrackPosition() {
                    self.currentSetlistPosition = position
                }
                self.isFetchingShowInfo = false

                if let show = show {
                    UserDefaults.standard.set(show.date, forKey: "lastShowDateOnQuit")

                    // If parsed metadata lacks location, fill in from FZShow
                    if let parsed = self.parsedTrack, parsed.city == nil || parsed.state == nil {
                        let updatedParsed = ParsedTrackInfo(
                            date: parsed.date,
                            showTime: parsed.showTime,
                            city: parsed.city ?? show.city,
                            state: parsed.state ?? show.state,
                            showDuration: parsed.showDuration,
                            source: parsed.source,
                            generation: parsed.generation,
                            creator: parsed.creator,
                            artist: parsed.artist,
                            trackNumber: parsed.trackNumber,
                            trackName: parsed.trackName,
                            year: parsed.year,
                            trackDuration: parsed.trackDuration,
                            rawTitle: parsed.rawTitle
                        )
                        self.parsedTrack = updatedParsed
                    }

                    self.showDataManager?.recordListen(show: show)
                }

                // Update Now Playing info with show details
                self.updateNowPlayingInfo()
            }
        }
    }
}
#endif
