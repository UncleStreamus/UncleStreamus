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
    @Environment(\.colorScheme) private var colorScheme
    @State private var safariURL: IdentifiableURL?
    @State private var setlistInfoItem: SetlistInfoItem?

    /// App-lifetime owner of the player, playback verbs, remote-command/CarPlay wiring,
    /// and now-playing publishing. Bootstrapped in `UncleStreamusApp.init` so it's live
    /// even on a CarPlay-only cold launch where this view's `onAppear` never fires. The
    /// view consumes it through the thin forwarding accessors just below, so the large
    /// body and subviews keep referencing `bassPlayer` / `vm` / `isPlaying` / … unchanged.
    @State private var controller = PlaybackController.shared

    private var bassPlayer: BASSRadioPlayer { controller.bassPlayer }
    private var vm: RadioViewModel { controller.vm }
    private var showDataManager: ShowDataManager? { controller.showDataManager }
    private var fzShowsDB: FZShowsDatabase? { controller.fzShowsDB }
    private var streams: [Stream] { controller.streams }
    private var isPlaying: Bool {
        get { controller.isPlaying }
        nonmutating set { controller.isPlaying = newValue }
    }
    private var selectedStream: Stream? {
        get { controller.selectedStream }
        nonmutating set { controller.selectedStream = newValue }
    }
    @State private var availableWidth: CGFloat = 500
    @AppStorage("textScale") private var textScale: Double = 1.1
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

    @State private var sidebarNavigationActive: Bool = false
    /// Whether the setlist auto-follows the now-playing track on advance. Turned
    /// off the moment the user manually scrolls the setlist; reset to true at
    /// natural reset points (launch, new show, returning from the sidebar).
    @State private var autoFollowSetlist: Bool = true
    @State private var contentBounceOffset: CGFloat = 0

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
                                // iPhone: navigation push via the shared sidebarNavigationActive
                                // flag (same path as the swipe gesture) so its dismissal is
                                // observable — see the .navigationDestination above.
                                Button {
                                    sidebarNavigationActive = true
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
            // Player/DB/command wiring now lives in PlaybackController (bootstrapped from
            // UncleStreamusApp.init so it survives a CarPlay-only cold launch). This view
            // just activates the controller (one-shot auto-resume + a fresh now-playing/
            // bridge publish for the freshly-mounted window) and does its own UI-only work.
            controller.activate()
            // Only (re)configure the audio session on mount when nothing is playing yet.
            // If the app was cold-launched by CarPlay and audio is already live, the session
            // is already active and correctly configured — re-running configureAudioSession()
            // here would call setActive(true) + BASS_Stop()/BASS_Start() on the live output,
            // briefly cutting out the audio the user just started from the car.
            if !isPlaying {
                configureAudioSession()
            }
            checkWhatsNew()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshShowDatabase)) { _ in
            fzShowsDB?.downloadAllPages()
        }
        .onChange(of: dvrBufferMinutes) { _, _ in
            bassPlayer.updateDVRBufferSize()
        }
        // Reactions to bassPlayer state changes (dvrState → now-playing + CarPlay mirror +
        // keepalive; reconnect-exhausted → reset isPlaying; reconnect/pre-buffer → now-playing)
        // moved to PlaybackController.startObservingPlayerState(), so they also run on a
        // CarPlay-only session where this view's `.onChange` never fires. Likewise the
        // foreground/background lifecycle (was `.onChange(of: scenePhase)`) and the audio-
        // session interruption/route-change observers now live in PlaybackController — keyed
        // off UIApplication/AVAudioSession notifications so they too work with no window scene.
    }

    // MARK: - Track Info Card

    private var trackInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let parsed = vm.parsedTrack, let trackName = parsed.trackName, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                        // verbatim: scraped metadata, not a localization key (crashes on a `%`)
                        Text(verbatim: trackName)
                            .scaledFont(.title2, weight: .semibold)
                            .lineLimit(2)
                    } else {
                        Text(placeholderText)
                            .scaledFont(.title2, weight: .semibold)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        if let parsed = vm.parsedTrack, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                            Text(verbatim: parsed.inferredArtist)
                                .scaledFont(.subheadline)
                                .foregroundColor(.secondary)
                            if let trackNumber = parsed.trackNumber {
                                Text(verbatim: "• Track \(trackNumber)")
                                    .scaledFont(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let trackDuration = parsed.trackDuration {
                                Text(verbatim: "• \(trackDuration)")
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
                if let parsed = vm.parsedTrack, let date = parsed.date, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                    // Location appended only when both city and state are known
                    // (non-Zappa broadcasts have a date but no location).
                    let location = (parsed.city != nil && parsed.state != nil) ? " • \(parsed.city!), \(parsed.state!)" : ""
                    Text(verbatim: "\(date)\(location)")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(" ")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let source = displaySource, vm.currentTrack != "No track info" && !vm.currentTrack.isEmpty {
                    Text(verbatim: source)
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
                            controller.selectStream(stream)
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
                        // verbatim: scraped strings, not localization keys — a plain Text(String)
                        // is a LocalizedStringKey and crashes on a `%` in the scraped data.
                        Text(verbatim: show.venue)
                            .scaledFont(.headline, weight: .semibold)
                            .foregroundColor(.primary)

                        if let note = show.note {
                            Text((try? AttributedString(markdown: note)) ?? AttributedString(note))
                                .scaledFont(.caption)
                                .foregroundColor(Color.red.opacity(0.8))
                        }

                        if !show.showInfo.isEmpty {
                            Text(verbatim: show.showInfo)
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
                    } else if vm.parsedTrack?.isNonZappaShow == true {
                        Text("Not a Zappa show — no setlist available.")
                            .scaledFont(.headline)
                            .foregroundColor(.gray)
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
                    ScrollViewReader { proxy in
                    ScrollView {
                        if availableWidth > 500 {
                            // Two-column layout for landscape
                            HStack(alignment: .top, spacing: 20) {
                                let midpoint = (show.setlist.count + 1) / 2

                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(show.setlist.prefix(midpoint).enumerated()), id: \.offset) { index, song in
                                        setlistRow(index: index + 1, song: song, acronyms: show.acronyms)
                                            .id(index + 1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if show.setlist.count > midpoint {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(show.setlist.dropFirst(midpoint).enumerated()), id: \.offset) { index, song in
                                            setlistRow(index: midpoint + index + 1, song: song, acronyms: show.acronyms)
                                                .id(midpoint + index + 1)
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
                                        .id(index + 1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // Auto-follow the now-playing track: jump on open, animate as the
                    // track advances — but only while auto-follow is on. Manual scrolling
                    // turns it off (so we don't fight the user); it resets at launch, on a
                    // new show, and on returning from the sidebar. No-op for the no-match state.
                    .onAppear {
                        autoFollowSetlist = true
                        scrollToNowPlaying(proxy, animated: false)
                    }
                    .onChange(of: vm.currentSetlistPosition) { _, _ in
                        if autoFollowSetlist { scrollToNowPlaying(proxy, animated: true) }
                    }
                    .onChange(of: vm.currentShow?.date) { _, _ in
                        autoFollowSetlist = true
                    }
                    .onChange(of: sidebarNavigationActive) { _, active in
                        if !active {
                            autoFollowSetlist = true
                            scrollToNowPlaying(proxy, animated: false)
                        }
                    }
                    .onChange(of: showSidebar) { _, shown in
                        if !shown {
                            autoFollowSetlist = true
                            scrollToNowPlaying(proxy, animated: false)
                        }
                    }
                    // A manual drag on the setlist stops auto-follow (programmatic
                    // scrollTo does not fire this, so following never fights itself).
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8).onChanged { _ in
                            autoFollowSetlist = false
                        }
                    )
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
                                        Text(verbatim: parts[0])
                                            .scaledFont(.caption, weight: .medium)
                                            .foregroundColor(.secondary)
                                            .italic()
                                    }
                                    if parts.count >= 2 {
                                        Text(verbatim: parts[1])
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
                                        (Text(verbatim: acronym.short)
                                            .foregroundColor(.blue)
                                            .bold()
                                         + Text(verbatim: " = \(acronym.full)")
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

    /// Scrolls the setlist just enough to make the now-playing row
    /// (`vm.currentSetlistPosition`, 1-based) visible — `anchor: nil` does the
    /// minimum scroll and no-ops if it's already on screen. `animated: false` is the
    /// quiet jump on open; track changes animate. Deferred to the next runloop so the
    /// row `.id()`s are registered before we scroll — without this, scrolling fails
    /// when the setlist is already open at first play (the position lands in the same
    /// layout pass that first mounts the rows). No-op when there's no match.
    private func scrollToNowPlaying(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            let pos = vm.currentSetlistPosition
            guard pos > 0 else { return }
            if animated {
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(pos, anchor: nil) }
            } else {
                proxy.scrollTo(pos, anchor: nil)
            }
        }
    }

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

    // MARK: - Playback (forwards to the app-lifetime PlaybackController)
    //
    // The player, remote-command/CarPlay wiring, now-playing publishing and the
    // playback verbs moved to PlaybackController (see its header) so they survive a
    // CarPlay-only cold launch. These thin forwards keep the view body, the buffered-
    // audio alert, the onChange handlers and subview closures calling the same names.

    private func configureAudioSession() { controller.configureAudioSession() }
    private func updateNowPlayingInfo() { controller.updateNowPlayingInfo() }
    func playStream(showWarning: Bool = true) { controller.playStream(showWarning: showWarning) }
    func stopStream() { controller.stopStream() }
    func resumeOrOfferBuffer() { controller.resumeOrOfferBuffer() }
}
#endif
