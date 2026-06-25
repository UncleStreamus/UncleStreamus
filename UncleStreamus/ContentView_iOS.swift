//
//  ContentView_iOS.swift
//  UncleStreamus
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
    @Environment(\.cacheModelContainer) private var cacheModelContainer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDataManager: ShowDataManager?
    @State private var fzShowsDB: FZShowsDatabase?
    @State private var safariURL: IdentifiableURL?
    @State private var setlistInfoItem: SetlistInfoItem?

    @State private var isPlaying = false
    @State private var selectedStream: Stream?
    @State private var bassPlayer = BASSRadioPlayer()
    /// Shared runtime state (track/show pipeline). See RadioViewModel.
    @State private var vm = RadioViewModel()
    @State private var availableWidth: CGFloat = 500
    @AppStorage("textScale") private var textScale: Double = 1.1
    @AppStorage("lastStreamFormat") private var lastStreamFormat: String = "OGG"
    @AppStorage("wasPlayingOnQuit") private var wasPlayingOnQuit: Bool = false
    @AppStorage("fxPersistAcrossShows") private var fxPersistAcrossShows: Bool = false
    @AppStorage("dvrEnabled") private var dvrEnabled: Bool = true
    @AppStorage("dvrBufferMinutes") private var dvrBufferMinutes: Int = 15
    @State private var expandedFooterSection: FooterSection? = nil
    @State private var showSettings: Bool = false
    @State private var showSidebar: Bool = false
    @State private var showFXPane: Bool = false
    @State private var showTrackInfoPane: Bool = false
    @State private var bugReportData: BugReportData?
    @AppStorage("lastSeenBuild") private var lastSeenBuild: String = ""
    @State private var whatsNewNotes: ReleaseNotes?
    @State private var didCheckWhatsNew: Bool = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @State private var showWelcome: Bool = false
    @AppStorage("delayWarningDismissed") private var delayWarningDismissed: Bool = false
    @State private var selectedSidebarTab: SidebarView.SidebarTab = .history  // Preserve sidebar tab selection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // MARK: - Layout Constants

    /// Horizontal drag (pt) past which an edge panel is dismissed.
    private let panelSwipeDismissThreshold: CGFloat = 30
    /// FX sheet detent height (fraction of screen) on regular-width (iPad) layouts.
    private let fxSheetDetentRegular: CGFloat = 0.88
    /// FX sheet detent height (fraction of screen) on compact-width (iPhone) layouts.
    private let fxSheetDetentCompact: CGFloat = 0.78

    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "OGG (90 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "AAC (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]

    @State private var sidebarNavigationActive: Bool = false
    @State private var contentBounceOffset: CGFloat = 0
    @State private var interruptionHandlerSetUp = false
    @State private var carPlayObserversSetUp = false

    var body: some View {
        HStack(spacing: 0) {
            // iPad: inline settings sidebar from left. The width-reveal transition grows
            // its width 0↔391 so the main content (and transport buttons) push in lockstep
            // with the visible sidebar rather than the sidebar sliding into reserved space.
            if horizontalSizeClass == .regular && showSettings {
                HStack(spacing: 0) {
                    NavigationStack {
                        SettingsView()
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .frame(width: 360)

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
                .transition(.widthReveal(361, alignment: .leading))
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
                            if showTrackInfoPane, let trackName = vm.parsedTrack?.trackName {
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
                                    .padding(.top, 8)
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
                            Text("UncleStreamus")
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

            // iPad: inline sidebar from right. The width-reveal transition grows its width
            // 0↔321 so the main content (and transport buttons) push in lockstep with it.
            if horizontalSizeClass == .regular && showSidebar, let manager = showDataManager {
                HStack(spacing: 0) {
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
                                            if value.translation.width > panelSwipeDismissThreshold && abs(value.translation.height) < 100 {
                                                withAnimation(.easeInOut(duration: 0.25)) {
                                                    showSidebar = false
                                                }
                                            }
                                        }
                                )
                        )

                    SidebarView(showDataManager: manager, selectedTab: $selectedSidebarTab)
                        .frame(width: 360)
                }
                .transition(.widthRevealTrailing(361))
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
            .presentationDetents(horizontalSizeClass == .regular
                ? [.fraction(fxSheetDetentRegular), .large]
                : [.fraction(fxSheetDetentCompact), .large])
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
        .sheet(item: $whatsNewNotes) { notes in
            WhatsNewView(notes: notes) { whatsNewNotes = nil }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { showWelcome = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Buffered Audio Available", isPresented: Binding(
            get: { bassPlayer.dvrReturnOfferPending },
            set: { bassPlayer.dvrReturnOfferPending = $0 }
        )) {
            Button("Play Buffer") {
                configureAudioSession()
                bassPlayer.dvrResume()
                updateNowPlayingInfo()
            }
            Button("Go Live") {
                bassPlayer.goLive()
                updateNowPlayingInfo()
            }
        } message: {
            Text("You have buffered audio from before. Play it back, or jump to the live stream?")
        }
        .onAppear {
            configureAudioSession()
            checkWhatsNew()
            if showDataManager == nil {
                showDataManager = ShowDataManager(modelContext: modelContext)
            }
            if fzShowsDB == nil {
                let cacheContext = cacheModelContainer.map { ModelContext($0) } ?? modelContext
                let db = FZShowsDatabase(modelContext: cacheContext)
                fzShowsDB = db
                if db.totalCachedShows == 0 {
                    db.downloadAllPages()
                } else {
                    db.refreshStalePages()
                }
            }
            if selectedStream == nil {
                selectedStream = streams.first { $0.format == lastStreamFormat } ?? streams.first
            }
            setupPlayer()
            if !interruptionHandlerSetUp {
                setupInterruptionHandler()
                interruptionHandlerSetUp = true
            }
            if !carPlayObserversSetUp {
                CarPlayBridge.shared.availableFormats = streams.map { .init(format: $0.format, label: $0.name) }
                setupCarPlayObservers()
                carPlayObserversSetUp = true
            }
            syncCarPlayBridge()

            // Auto-play if was playing when app quit (and auto-resume is enabled)
            let wasPlaying = UserDefaults.standard.bool(forKey: "wasPlayingOnQuit")
            let autoResumeEnabled = UserDefaults.standard.object(forKey: "autoResumeOnLaunch") as? Bool ?? false
            if wasPlaying && autoResumeEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.playStream()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshShowDatabase)) { _ in
            fzShowsDB?.downloadAllPages()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Track foreground state first so startSilenceKeepalive()'s foreground guard sees the
            // correct value when the background-keepalive start below runs. Only .active counts as
            // foreground; .inactive is treated as backgrounding (matches the check below).
            bassPlayer.isAppInForeground = (newPhase == .active)
            if newPhase == .background || newPhase == .inactive {
                UserDefaults.standard.set(isPlaying, forKey: "wasPlayingOnQuit")
                // Safety net: start keepalive on backgrounding if DVR is paused and it
                // isn't already running (e.g. paused while already in background).
                if bassPlayer.dvrState == .paused {
                    bassPlayer.startSilenceKeepalive()
                }
                #if DEBUG
                // Logged AFTER the keepalive-start above so the snapshot confirms the keepalive
                // actually started for the background window (the linchpin of recording survival).
                if bassPlayer.dvrState == .paused { bassPlayer.logDVRDiag("→background") }
                #endif
            }
            if newPhase == .active {
                #if DEBUG
                if bassPlayer.dvrState == .paused { bassPlayer.logDVRDiag("→foreground") }
                #endif
                // Reconnect whenever the user intended to play but the stream isn't
                // healthy — covers both zero handles (app was suspended during reconnect
                // backoff) and stalled/stopped handles (BASS timed out but handles
                // weren't cleared before suspension). triggerImmediateReconnect() guards
                // internally against disrupting a legitimately playing stream.
                // Skip while the buffer is paused: reconnecting would restart the live
                // stream and wipe a full buffer. The play-buffer-vs-go-live choice is offered
                // when the user presses play (resumeOrOfferBuffer()), not on returning.
                if bassPlayer.dvrState == .paused {
                    // no-op: leave the paused buffer intact
                } else if bassPlayer.isUserIntendedPlay {
                    bassPlayer.triggerImmediateReconnect()
                }
                // Only stop the keepalive on foreground resume if DVR is no longer paused.
                // If DVR is still paused, the keepalive must stay alive so the recording
                // pump keeps filling the buffer. dvrResume()/goLive() stop it when the
                // user actually plays.
                if bassPlayer.dvrState != .paused {
                    bassPlayer.stopSilenceKeepalive()
                }
            }
        }
        .onChange(of: dvrBufferMinutes) { _, _ in
            bassPlayer.updateDVRBufferSize()
        }
        .onChange(of: bassPlayer.dvrState) { _, newState in
            updateNowPlayingInfo()
            syncCarPlayBridge()
            // Try to start the keepalive when DVR pauses so the recording pump keeps the ring
            // buffer filling if/when the app is backgrounded. This is a NO-OP in the foreground:
            // startSilenceKeepalive() guards on isAppInForeground because an active silent player
            // makes iOS think audio is rendering and route the AirPods/lock-screen button to
            // pauseCommand (a no-op while paused) — we can't correct that via playbackState, since
            // the set-playback-state entitlement is private. The background case is also covered by
            // the scenePhase handler above. dvrResume()/goLive() call stopSilenceKeepalive().
            if newState == .paused {
                bassPlayer.startSilenceKeepalive()
            }
        }
        .onChange(of: bassPlayer.isReconnecting) { _, _ in
            updateNowPlayingInfo()
        }
        .onChange(of: bassPlayer.playbackState) { _, newState in
            // Reconnect attempts exhausted (~1 min of failures): the engine has truly
            // stopped, but `isPlaying` (intent-based, drives the big transport button on
            // CarPlay/lock screen/in-app) was never reset — it stays "Pause" even though
            // no audio is playing. Bring it back in sync once the engine gives up for real.
            if newState == .stopped, isPlaying, !bassPlayer.isReconnecting,
               bassPlayer.reconnectAttempt >= bassPlayer.reconnectMaxAttempts {
                isPlaying = false
                updateNowPlayingInfo()
                syncCarPlayBridge()
            }
        }
        .onChange(of: bassPlayer.preBufferProgress > 0) { _, _ in
            updateNowPlayingInfo()
        }
    }

    // MARK: - Track Info Card

    private var trackInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let parsed = vm.parsedTrack, let trackName = parsed.trackName, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                        Text(trackName)
                            .scaledFont(.title2, weight: .semibold)
                            .lineLimit(2)
                    } else {
                        Text(placeholderText)
                            .scaledFont(.title2, weight: .semibold)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        if let parsed = vm.parsedTrack, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                            Text(parsed.inferredArtist)
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

                if let show = vm.currentShow {
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
                if let parsed = vm.parsedTrack, let date = parsed.date, let city = parsed.city, let state = parsed.state, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                    Text("\(date) • \(city), \(state)")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(" ")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let source = displaySource, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
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

    // FX gets a smaller share of the transport row than the other buttons. The
    // proportional sizing is handled by `ProportionalHStack` + `.buttonWeight(0.62)`
    // on the FX button (see TransportControlsLayout.swift) — no width measurement.

    private var streamControlsBar: some View {
        VStack(spacing: 4) {
            // DVR status row
            if isPlaying {
                HStack(spacing: 8) {
                    if bassPlayer.dvrState != .live {
                        Text("\(dvrFormattedBehind(bassPlayer.behindLiveSeconds)) / \(dvrFormattedBehind(bassPlayer.dvrMaxBufferSeconds))")
                            .scaledFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Go Live") { bassPlayer.goLive(); updateNowPlayingInfo() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.72, green: 0.07, blue: 0.07))
                            .controlSize(.small)
                    } else {
                        Text("● LIVE")
                            .scaledFont(.caption, weight: .semibold)
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
                                .scaledFont(.caption2).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else {
                    let isFlacBuffering = stream.format == "FLAC" && bassPlayer.preBufferProgress > 0
                    let streamStatusText: String = {
                        if isFlacBuffering { return "Buffering FLAC…" }
                        if dvrEnabled && bassPlayer.dvrBufferFull && bassPlayer.dvrState == .playing { return "Draining buffer" }
                        if dvrEnabled && bassPlayer.dvrBufferFull { return "Buffer full" }
                        if dvrEnabled && bassPlayer.dvrState == .playing { return "Playing from rolling buffer" }
                        if dvrEnabled && bassPlayer.dvrState == .paused { return "Stream paused – recording to buffer" }
                        return "Streaming \(stream.name)"
                    }()
                    Text(streamStatusText)
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)

                    // FLAC pre-buffer loading bar: fills 0→100% over 7s then disappears
                    if isFlacBuffering {
                        ProgressView(value: bassPlayer.preBufferProgress)
                            .progressViewStyle(.linear)
                            .tint(colorScheme == .dark ? .secondary : .blue)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .animation(.easeInOut(duration: 0.3), value: isFlacBuffering)
                    }

                    // Show database first-launch download progress bar
                    if let db = fzShowsDB, db.isDownloading && db.totalCachedShows == 0 {
                        ProgressView(value: db.downloadProgress)
                            .progressViewStyle(.linear)
                            .tint(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Delay warning when using AAC stream - permanent until dismissed
                    if stream.format == "AAC" && !delayWarningDismissed {
                        HStack(spacing: 4) {
                            Text("Track info can be several mins behind when using AAC...")
                                .scaledFont(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                            Button("Dismiss") {
                                withAnimation { delayWarningDismissed = true }
                            }
                            .scaledFont(.caption2)
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    } // end else (!isReconnecting)
                }
                .animation(.easeInOut(duration: 0.3), value: delayWarningDismissed)
                .animation(.easeInOut(duration: 0.3), value: bassPlayer.isReconnecting)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }

            ProportionalHStack(spacing: 10) {
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
                            .scaledFont(.caption)
                        Text(selectedStream?.format ?? "Stream")
                            .scaledFont(.subheadline, weight: .medium)
                        Image(systemName: "chevron.up.chevron.down")
                            .scaledFont(.caption2)
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
                        syncCarPlayBridge()
                    }
                }

                // FX button
                Button {
                    showFXPane.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .scaledFont(.caption)
                        Text("FX")
                            .scaledFont(.subheadline, weight: .medium)
                    }
                    .frame(maxWidth: .infinity)
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
                .buttonWeight(0.62)   // FX stays proportionally narrower than the other buttons

                // Play/Pause button
                Button {
                    guard bassPlayer.checkUserActionAllowed() else { return }
                    switch (isPlaying, bassPlayer.dvrState) {
                    case (false, _):
                        playStream()
                    case (true, .live):
                        if !bassPlayer.isStreamActive {
                            // Stream died — restart rather than DVR pausing a dead stream.
                            playStream()
                        } else if dvrEnabled {
                            bassPlayer.dvrPause()
                            updateNowPlayingInfo()
                        } else {
                            stopStream()
                        }
                    case (true, .paused):
                        resumeOrOfferBuffer()
                    case (true, .playing):
                        bassPlayer.dvrPausePlayback()
                        updateNowPlayingInfo()
                    }
                } label: {
                    HStack(spacing: 4) {
                        let activelyPlaying = isPlaying && bassPlayer.dvrState != .paused
                        Image(systemName: activelyPlaying ? (dvrEnabled ? "pause.fill" : "stop.fill") : "play.fill")
                            .scaledFont(.body)
                        Text(activelyPlaying ? (dvrEnabled ? "Pause" : "Stop") : "Play")
                            .scaledFont(.subheadline, weight: .medium)
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
                                .scaledFont(.body)
                            Text("Stop")
                                .scaledFont(.subheadline, weight: .medium)
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let show = vm.currentShow {
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
                    } else if vm.isFetchingShowInfo {
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
            }
            .padding()
            .background(Color.blue.opacity(0.2))
            .cornerRadius(12)
            .simultaneousGesture(contentBounceGesture)

            if let show = vm.currentShow {
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
                            Button("Track Info (donlope)...") {
                                guard let trackName = vm.parsedTrack?.trackName else { return }
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
                            .disabled(vm.parsedTrack?.trackName == nil)
                            Spacer()
                            Button("Setlist Context (FZShows)...") {
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
            if let show = vm.currentShow {
                Button(action: {
                    bugReportData = BugReportData(
                        showDate: show.date,
                        venue: show.venue,
                        url: show.url,
                        rawMetadata: vm.parsedTrack?.rawTitle,
                        trackName: vm.parsedTrack?.trackName,
                        source: vm.parsedTrack?.source,
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
        // would use "> vm.currentSetlistPosition" and always highlight the *next* duplicate, not the current one.
        let isCurrent = vm.currentSetlistPosition == index
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
        if let s = vm.parsedTrack?.source { return s }
        guard let info = vm.currentShow?.showInfo else { return nil }
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
        guard let show = vm.currentShow else { return false }
        return showDataManager?.isFavorite(showDate: show.date) ?? false
    }

    // MARK: - Current Track Matching

    /// Finds the current track position in the setlist. Delegates to the shared
    /// view model (which holds the track/show state).
    private func findCurrentTrackPosition() -> Int? {
        vm.findCurrentTrackPosition()
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
            if type == .began {
                #if DEBUG
                // Interruption is the prime suspect for DVR background-recording loss: another app
                // (e.g. a video call) claiming the session stops our silence keepalive, after which
                // iOS suspends us and the recording pump freezes. Snapshot to capture that moment.
                print("🔔 AVAudioSession interruption BEGAN — dvrState=\(bassPlayer.dvrState)")
                bassPlayer.logDVRDiag("interrupt-began")
                #endif
                // Stop audio immediately on interruption (phone call, Siri, another app
                // claiming the session). Use DVR-aware pause so the ring buffer keeps
                // recording through the call; user can catch up when it ends.
                let dvrEnabled = UserDefaults.standard.object(forKey: "dvrEnabled") as? Bool ?? true
                switch bassPlayer.dvrState {
                case .live:
                    if dvrEnabled { bassPlayer.dvrPause() } else { bassPlayer.stopWithFadeOut() }
                case .playing:
                    bassPlayer.dvrPausePlayback()
                case .paused:
                    break  // already paused
                }
            } else if type == .ended {
                let opts = AVAudioSession.InterruptionOptions(
                    rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                #if DEBUG
                print("🔔 AVAudioSession interruption ENDED — shouldResume=\(opts.contains(.shouldResume)) dvrState=\(bassPlayer.dvrState) userIntendedPlay=\(bassPlayer.isUserIntendedPlay)")
                bassPlayer.logDVRDiag("interrupt-ended")
                #endif
                if opts.contains(.shouldResume) && bassPlayer.isUserIntendedPlay {
                    configureAudioSession()
                    bassPlayer.triggerImmediateReconnect()
                }
            }
        }

        // Pause to DVR when headphones are removed (AirPod taken out of ear, Bluetooth
        // disconnect, wired headphones unplugged). Without this, audio routes to the
        // iPhone speaker and the DVR ring buffer never gets created.
        // ContentView_iOS is a struct so [weak self] is invalid; capture bassPlayer as a
        // weak class reference instead. dvrEnabled is read from UserDefaults at fire time
        // so it reflects the current setting, not the value at observer-registration time.
        // updateNowPlayingInfo() is triggered automatically via .onChange(of: bassPlayer.dvrState).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak bassPlayer] notification in
            guard let bassPlayer,
                  let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }

            let prevRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            let wasHeadphones = prevRoute?.outputs.contains {
                [.headphones, .bluetoothA2DP, .bluetoothHFP].contains($0.portType)
            } ?? false

            guard wasHeadphones, bassPlayer.isUserIntendedPlay else { return }

            #if DEBUG
            print("🎧 Route change: headphones removed — DVR pause")
            #endif

            let dvrEnabled = UserDefaults.standard.object(forKey: "dvrEnabled") as? Bool ?? true
            switch bassPlayer.dvrState {
            case .live:
                if dvrEnabled { bassPlayer.dvrPause() } else { bassPlayer.stopWithFadeOut() }
            case .playing:
                bassPlayer.dvrPausePlayback()
            case .paused:
                break   // already paused
            }
        }

        // Re-activate the audio session when a Bluetooth device (AirPods) reconnects.
        // After BASS_ChannelPause during DVR pause, CoreAudio's output unit goes idle.
        // Re-calling setActive(true) here re-routes the session to the new device so
        // BASS_ChannelPlay in dvrResume() can start rendering audio immediately.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak bassPlayer] notification in
            guard let bassPlayer,
                  let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .newDeviceAvailable,
                  bassPlayer.isUserIntendedPlay else { return }

            let session = AVAudioSession.sharedInstance()
            let hasBluetoothOutput = session.currentRoute.outputs.contains {
                [.bluetoothA2DP, .bluetoothHFP].contains($0.portType)
            }
            guard hasBluetoothOutput else { return }

            #if DEBUG
            print("🎧 Route change: Bluetooth device available — re-activating audio session")
            #endif
            // Re-set category here: on launch after a process kill (e.g. Xcode install-over),
            // the -50 session lock from the Bluetooth transition prevents setCategory from
            // succeeding in configureAudioSession(). By the time this routeChange fires the
            // lock is released, so we set it now to enable A2DP before restarting BASS.
            try? session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
            try? session.setActive(true)
            bassPlayer.restartOutputAfterRouteChange()
        }
    }

    // MARK: - Audio Session Setup

    /// Shows the "What's New" sheet once per build update. A first-ever install is
    /// recorded silently (no What's New sheet) and instead shows the one-time
    /// Welcome sheet; thereafter What's New appears when the bundled build number
    /// changes and there are non-empty notes to display.
    private func checkWhatsNew() {
        guard !didCheckWhatsNew else { return }
        didCheckWhatsNew = true

        let result = decideWhatsNew(currentBuild: ReleaseNotes.currentBuild,
                                    lastSeenBuild: lastSeenBuild,
                                    hasSeenWelcome: hasSeenWelcome,
                                    loadNotes: ReleaseNotes.loadBundled)
        if let build = result.buildToRecord { lastSeenBuild = build }
        switch result.action {
        case .nothing:
            break
        case .showWelcome:
            showWelcome = true
            hasSeenWelcome = true
        case .showNotes(let notes):
            whatsNewNotes = notes
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        // setCategory is best-effort: may throw -50 during a Bluetooth route transition
        // when iOS has the session temporarily locked. The category was already set correctly
        // during playStream(), so failure here is harmless — we just need setActive(true).
        try? audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
        // IO buffer duration is best-effort: can fail during hardware handover.
        try? audioSession.setPreferredIOBufferDuration(0.5)
        // setActive(true) always runs (not gated by setCategory success) so BASS's audio
        // unit gets a properly active session before BASS_ChannelPlay is called.
        do {
            try audioSession.setActive(true)
            // Reconnect BASS's RemoteIO output unit to the now-active session. After a
            // BASS_ChannelPause (DVR pause/resume cycle) + freeStream + new stream, the
            // RemoteIO unit can become stale and output silence even though BASS reports
            // ACTIVE_PLAYING. BASS_Stop/Start forces it to re-bind to the current route.
            bassPlayer.reconnectOutputToAudioSession()
            #if DEBUG
            print("✅ Audio session activated")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to activate audio session: \(error)")
            #endif
        }
    }

    // MARK: - Player Setup

    func setupPlayer() {
        // Wire the shared view model: references it needs + platform side-effect
        // hooks (now-playing refresh + CarPlay mirror).
        vm.bassPlayer = bassPlayer
        vm.showDataManager = showDataManager
        vm.fzShowsDB = fzShowsDB
        vm.onNowPlayingShouldUpdate = { [self] in updateNowPlayingInfo() }
        vm.onShowDidLoad = { [self] in syncCarPlayBridge() }

        bassPlayer.onMetadataUpdate = { metadata in
            DispatchQueue.main.async {
                self.vm.handleMetadata(metadata, fxPersistAcrossShows: self.fxPersistAcrossShows)
            }
        }

        setupRemoteCommandCenter()
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            DispatchQueue.main.async {
                #if DEBUG
                print("▶️  remoteCmd PLAY — isPlaying=\(self.isPlaying) dvrState=\(self.bassPlayer.dvrState) streamActive=\(self.bassPlayer.isStreamActive)")
                #endif
                guard self.bassPlayer.checkUserActionAllowed() else { return }
                if self.bassPlayer.dvrState == .paused {
                    configureAudioSession()
                    self.bassPlayer.dvrResume()
                    self.updateNowPlayingInfo()
                } else if self.bassPlayer.dvrState == .playing {
                    // iOS sent play while DVR is already in playback state — mixer may have
                    // stopped silently after an audio route change. Re-route and kick it.
                    configureAudioSession()
                    self.bassPlayer.ensureOutputPlaying()
                    self.updateNowPlayingInfo()
                } else if !self.isPlaying || !self.bassPlayer.isStreamActive {
                    // Start or restart: covers initial play AND the case where isPlaying is
                    // true but handles are gone (stream died in a tunnel while device was locked).
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
                // If DVR is already paused, iOS routed a *resume* intent to pauseCommand: it can't
                // read our paused state (no com.apple.mediaremote.set-playback-state entitlement),
                // so once it last saw us "playing" it keeps sending pause. Treat it as resume. The
                // 1.2s debounce blocks an iOS double-fired pause right after the real pause from
                // accidentally resuming.
                if self.bassPlayer.dvrState == .paused {
                    guard self.bassPlayer.checkUserActionAllowed() else { return }
                    configureAudioSession()
                    self.bassPlayer.dvrResume()
                    self.updateNowPlayingInfo()
                    return
                }
                guard self.bassPlayer.checkUserActionAllowed() else { return }
                switch self.bassPlayer.dvrState {
                case .live:
                    if self.dvrEnabled { self.bassPlayer.dvrPause() } else { self.stopStream() }
                    self.updateNowPlayingInfo()
                case .paused:
                    break  // unreachable; handled above
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
                print("⏯️  remoteCmd TOGGLE — isPlaying=\(self.isPlaying) dvrState=\(self.bassPlayer.dvrState) streamActive=\(self.bassPlayer.isStreamActive)")
                #endif
                guard self.bassPlayer.checkUserActionAllowed() else { return }
                switch (self.isPlaying, self.bassPlayer.dvrState) {
                case (false, _):
                    self.playStream()
                case (true, .live):
                    if !self.bassPlayer.isStreamActive {
                        // Stream died (tunnel) — restart instead of trying to DVR pause a dead stream.
                        // Without this, the second tap would dvrResume() and create a DVR playback
                        // stream that plays simultaneously with the reconnecting live stream.
                        self.playStream()
                    } else if self.dvrEnabled {
                        self.bassPlayer.dvrPause()
                        self.updateNowPlayingInfo()
                    } else {
                        self.stopStream()
                    }
                case (true, .paused):
                    configureAudioSession()
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

    /// Transient status text ("Reconnecting...", "Buffering...") shown in place of the
    /// track title — the only text CarPlay's Now Playing screen can display comes from
    /// MPNowPlayingInfoCenter, so this also flashes briefly on the lock screen.
    private var nowPlayingStatusOverride: String? {
        if bassPlayer.isReconnecting {
            return bassPlayer.reconnectAttempt > 1
                ? "Reconnecting (attempt \(bassPlayer.reconnectAttempt))..."
                : "Reconnecting..."
        }
        if let stream = selectedStream, stream.format == "FLAC", bassPlayer.preBufferProgress > 0 {
            return "Buffering \(stream.name)..."
        }
        return nil
    }

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        if let parsed = vm.parsedTrack {
            nowPlayingInfo[MPMediaItemPropertyTitle] = parsed.trackName ?? "UncleStreamus"

            if let show = vm.currentShow {
                // Put all info in Artist line: "Frank Zappa • 1975 10 04 • Paramount Theatre, Seattle, WA"
                // The venue field already includes location, so no need to add city/state/country
                let artist = parsed.inferredArtist
                let artistLine = "\(artist) • \(show.date) • \(show.venue)"
                nowPlayingInfo[MPMediaItemPropertyArtist] = artistLine
                #if DEBUG
                print("🎵 Now Playing: \(parsed.trackName ?? "?") | \(artistLine)")
                #endif
            } else {
                nowPlayingInfo[MPMediaItemPropertyArtist] = parsed.inferredArtist
                #if DEBUG
                print("🎵 Now Playing: No show info available yet")
                #endif
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "UncleStreamus"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "UncleStreamus"
            #if DEBUG
            print("🎵 Now Playing: Default (no parsed track)")
            #endif
        }

        if let statusOverride = nowPlayingStatusOverride {
            nowPlayingInfo[MPMediaItemPropertyTitle] = statusOverride
        }

        let dvrPaused = bassPlayer.dvrState == .paused
        let isActuallyPlaying = isPlaying && !dvrPaused
        // CarPlay/lock screen derive the big transport button's icon from which of
        // playCommand/pauseCommand is currently *enabled* — not from a passive read of
        // MPNowPlayingInfoPropertyPlaybackRate. Confirmed by debug logs: after Stop,
        // tapping the (still "pause"-shaped) button fired `pauseCommand` even though
        // isPlaying was already false, and vice versa while actively playing. Toggling
        // these in lockstep with actual state keeps the displayed icon truthful.
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = !isActuallyPlaying
        commandCenter.pauseCommand.isEnabled = isActuallyPlaying
        // KNOWN LIMITATION (accepted — see memory ios_lockscreen_playstate_limitation.md):
        // iOS *ignores* every playbackState write below — it requires the private
        // `com.apple.mediaremote.set-playback-state` entitlement, which a third-party app
        // cannot have (device logs: "Ignoring setPlaybackState because application does not
        // contain entitlement…"). So the lock-screen/Control-Center transport icon is NOT
        // driven by playbackState. iOS falls back to (a) playbackRate below and (b) its own
        // observation of whether we're producing audio. While DVR-paused *and locked*, the
        // silence keepalive is deliberately running (it must, to keep the recording pump
        // filling the buffer in the background), so iOS sees active audio and shows the PAUSE
        // icon even though we're paused. A direct lock-screen button tap flips the icon
        // optimistically; an AirPods press does not, so the icon can lag when paused via
        // AirPods while locked. This is a cosmetic-only issue — playback pause/resume itself
        // is correct (the pauseCommand→resume branch in setupRemoteCommandCenter handles the
        // case where iOS routes the resume press to pauseCommand). We still set playbackState
        // and playbackRate because they're honored on platforms/contexts that DO read them
        // (e.g. CarPlay) and cost nothing where they're ignored.
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        if isActuallyPlaying {
            nowPlayingCenter.playbackState = .playing
        } else if isPlaying {
            // DVR paused (or DVR playback momentarily stalled) — still "in session", not stopped.
            nowPlayingCenter.playbackState = .paused
        } else {
            nowPlayingCenter.playbackState = .stopped
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isActuallyPlaying ? 1.0 : 0.0
        // Only set IsLiveStream=true when actively at the live edge. iOS treats
        // IsLiveStream=true as "broadcast in progress" — if left true while stopped,
        // it can block AirPods/lock screen from offering a play command (interpreted
        // as "the live broadcast ended"). Tying it to isActuallyPlaying ensures the
        // play affordance is always available when stopped or DVR-paused.
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = isActuallyPlaying
        // Marks "now" as the playhead position for a live item — recommended for live
        // streams, and also gives the system a fresh, changing value on every publish
        // so it has a reason to re-evaluate (and not cache) the displayed transport state.
        if isActuallyPlaying {
            nowPlayingInfo[MPNowPlayingInfoPropertyCurrentPlaybackDate] = Date()
        }
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - CarPlay

    /// Mirrors current state into `CarPlayBridge.shared` and notifies the CarPlay
    /// scene delegate to refresh its templates. CarPlay runs in a separate scene and
    /// can't read this view's `@State`, so this is the one-way data path to it —
    /// the reverse path (CarPlay buttons → playback actions) is `setupCarPlayObservers()`.
    private func syncCarPlayBridge() {
        let bridge = CarPlayBridge.shared
        bridge.isPlaying = isPlaying
        bridge.dvrState = bassPlayer.dvrState
        bridge.setlist = vm.currentShow?.setlist ?? []
        bridge.currentTrackIndex = vm.currentShow != nil ? vm.currentSetlistPosition : nil
        bridge.selectedFormat = selectedStream?.format ?? lastStreamFormat
        NotificationCenter.default.post(name: .carPlayDataChanged, object: nil)
    }

    /// Observes commands posted by `CarPlaySceneDelegate`'s buttons and routes them
    /// to the actual `bassPlayer` instance — mirrors how the macOS menubar drives
    /// `ContentView` via `togglePlayback`/`stopPlayback`/`selectStream`.
    private func setupCarPlayObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: .carPlayStop, object: nil, queue: .main) { [self] _ in
            stopStream()
        }
        nc.addObserver(forName: .carPlayGoLive, object: nil, queue: .main) { [self] _ in
            bassPlayer.goLive()
            updateNowPlayingInfo()
            syncCarPlayBridge()
        }
        nc.addObserver(forName: .carPlaySelectFormat, object: nil, queue: .main) { [self] notification in
            if let format = notification.userInfo?["format"] as? String,
               let stream = streams.first(where: { $0.format == format }) {
                selectedStream = stream
            }
        }
        // CarPlay can connect after this app already published its initial Now
        // Playing state (e.g. auto-resume on launch) — force a fresh republish so
        // its transport controls never start out of sync with actual playback.
        nc.addObserver(forName: .carPlaySceneDidConnect, object: nil, queue: .main) { [self] _ in
            updateNowPlayingInfo()
            syncCarPlayBridge()
        }
    }

    /// Resume from a paused buffer (in-app play button only). If the buffer has filled and the
    /// user hasn't started draining it yet, offer the play-buffer-vs-go-live choice instead of
    /// resuming directly; the alert presents on the foreground app UI. Once draining has begun
    /// (or the buffer isn't full), resume directly. Remote/lock-screen play paths intentionally
    /// bypass this and resume directly with no prompt.
    func resumeOrOfferBuffer() {
        if bassPlayer.dvrBufferFull && !bassPlayer.dvrFullBufferDrainStarted {
            bassPlayer.dvrReturnOfferPending = true
        } else {
            configureAudioSession()
            bassPlayer.dvrResume()
            updateNowPlayingInfo()
        }
    }

    func playStream(showWarning: Bool = true) {
        guard let stream = selectedStream else { return }

        configureAudioSession()
        bassPlayer.play(format: stream.format, url: stream.url)
        isPlaying = true
        updateNowPlayingInfo()
        syncCarPlayBridge()

        UserDefaults.standard.set(true, forKey: "wasPlayingOnQuit")
    }

    func stopStream() {
        bassPlayer.stopWithFadeOut()
        isPlaying = false
        updateNowPlayingInfo()
        syncCarPlayBridge()
        UserDefaults.standard.set(false, forKey: "wasPlayingOnQuit")
        // After the 0.4s fade, deactivate the session so other audio apps (Spotify,
        // Podcasts, Music) receive interruptionNotification .ended and auto-resume.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !bassPlayer.isUserIntendedPlay else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func fetchShowInfo(date: String, showTime: ShowTime = .none) {
        vm.fetchShowInfo(date: date, showTime: showTime, fxPersistAcrossShows: fxPersistAcrossShows)
    }
}
#endif
