import Foundation
import Network
#if os(macOS)
import Bass
import BassFLAC
import BassFX
import BassMix
#endif
// On iOS: BASS symbols are globally available via BASSBridgingHeader.h

// MARK: - Playback State

enum PlaybackState {
    case stopped
    case connecting
    case playing
    case buffering
    case stalled
    case error(Int32)
}

// MARK: - BASSRadioPlayer

@Observable class BASSRadioPlayer: NSObject {

    // MARK: - Constants

    /// User-Agent header for HTTP requests to identify the app to servers
    static let userAgentString: String = {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return "ZappaStream/1.0 (\(platform))"
    }()

    // MARK: - Public Interface

    /// Raw metadata string callback — same format as the old IcecastStreamReader callback.
    /// Called on main thread. ZappaStream uses this to drive ParsedTrackInfo parsing.
    var onMetadataUpdate: ((String) -> Void)?

    var isPlaying: Bool = false
    var playbackState: PlaybackState = .stopped

    /// Currently active format ("MP3", "OGG", "AAC", "FLAC")
    var currentQuality: String = ""

    // MARK: - BASS Handles

    private var streamHandle: DWORD = 0
    private var mixerHandle: DWORD = 0
    private var preMixerHandle: DWORD = 0  // All formats: DECODE-mode pre-mixer; stutter buffer (3s FLAC, 0.3s others) + click guard
    var preBufferProgress: Double = 0.0    // 0.0–1.0 during FLAC pre-buffer; drives UI progress bar
    private var preBufferTimer: Timer?     // updates preBufferProgress every 100ms during FLAC pre-buffer wait
    private var stallSync: HSYNC = 0
    private var endSync: HSYNC = 0
    private var oggChangeSync: HSYNC = 0

    // MARK: - Metadata State

    private var activeFormat = ""
    private var lastFlacTitle: String?
    private var lastIcecastTitle: String?
    private var lastPublishedTitle: String?
    private var oggStopConfirmed = false

    // MARK: - Timers

    private var metadataTimer: Timer?
    private var stateTimer: Timer?
    private var fadeTimer: Timer?
    private var fadeGeneration: Int = 0   // incremented by cancelFade(); guards stale async dispatches
    private let bassPollingQueue = DispatchQueue(label: "com.zappastream.bass-polling", qos: .utility)
    private let metaPollInterval: TimeInterval = 3.0
    private let statePollInterval: TimeInterval = 2.0
    private let fadeInDuration: TimeInterval = 0.5
    private let fadeOutDuration: TimeInterval = 0.4

    // MARK: - Network Resilience

    private var pathMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "com.zappastream.network-monitor", qos: .utility)

    /// True only while the user intends playback to be active.
    /// Set true in switchQuality(); false only in stop() / stopWithFadeOut().
    /// freeStream() and restartStream() must NOT touch this.
    private(set) var isUserIntendedPlay: Bool = false

    /// True while a reconnect attempt is scheduled or in-flight (drives UI).
    private(set) var isReconnecting: Bool = false

    /// Current attempt number (1-based). Reset to 0 on success or explicit stop.
    private(set) var reconnectAttempt: Int = 0

    private var reconnectTimer: DispatchSourceTimer?

    // Backoff delays in seconds. Stays at 60s after the last index.
    private let reconnectBackoffDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 60]
    /// How long to run FLAC muted before unmuting, giving the mixer output buffer time to fill.
    /// FLAC fade-in is triggered by checkStreamStatus() when playback buffer is sufficiently filled,
    /// not by a fixed timer. This flag tracks whether we're waiting for that condition.
    private var flacPendingFadeIn = false

    // MARK: - Stream URLs

    let qualities: [(format: String, url: String)] = [
        ("MP3",       "https://shoutcast.norbert.de/zappa.mp3"),
        ("OGG",       "https://shoutcast.norbert.de/zappa.ogg"),
        ("AAC",       "https://shoutcast.norbert.de/zappa.aac"),
        ("FLAC",      "https://shoutcast.norbert.de/zappa.flac"),
    ]

    // MARK: - Audio Effects

    private var eqLowFX:  HFX = 0   // BASS_BFX_BQF_LOWSHELF  @ 120 Hz
    private var eqMidFX:  HFX = 0   // BASS_BFX_BQF_PEAKINGEQ @ 1800 Hz
    private var eqHighFX: HFX = 0   // BASS_BFX_BQF_HIGHSHELF @ 7500 Hz
    private var compressorFX: HFX = 0
    private var levelMeterDSP: HDSP = 0
    private var stereoDSP: HDSP = 0
    private var limiterDSP: HDSP = 0
    private var clickGuardDSP: HDSP = 0

    // MARK: - Click Guard (OGG/FLAC only)
    // BASS_SYNC_OGG_CHANGE (MIXTIME) fires at bitstream boundaries. OGG fires 2 events per
    // track change (~0.4s apart); FLAC may fire 1 or 2. Timestamp-based debounce (1.5s window)
    // handles both: first event arms the guard, second is ignored. The guard silences 1 buffer
    // (~20ms) then fades in over 2 buffers (~40ms) for a ~60ms total gap.
    // MP3/AAC: no bitstream boundaries; no click guard needed.
    private let cgFadeBufferCount      = 2    // fade-in buffers (~40ms)
    private let cgSilenceBufferCount   = 1    // silent buffers (~20ms)
    private var cgFadeBuffersRemaining: Int   = 0  // total guard buffers left (silence + fade-in)
    private var cgLastGuardTime: Double       = 0  // ProcessInfo.processInfo.systemUptime of last armed guard

    // MARK: - FLAC Download Buffer Refill Pause
    // When dlBuf falls below a threshold at a track boundary, briefly mute the mixer
    // for ~1s to let the ring buffer refill, then fade back in.
    private let bufferRefillThreshold: Double   = 3.0   // dlBuf% below which to trigger
    private let bufferRefillTrackInterval: Int  = 5     // minimum track changes between pauses
    private let bufferRefillDuration: TimeInterval = 3.0
    private var trackChangeCount: Int           = 0
    private var isRefillPausing: Bool           = false

    var eqLowGain:  Float = 0
    var eqMidGain:  Float = 0
    var eqHighGain: Float = 0

    var compressorOn:     Bool  = false
    var compressorAmount: Float = 0.25

    // MARK: - Adaptive Compressor (program-dependent threshold)
    // A level-measurement DSP computes a slow-moving RMS average of the input signal.
    // The compressor threshold is set relative to this average, so it compresses
    // proportionally regardless of whether the track is quiet or loud.
    private var measuredRMSdB: Float = -20.0       // Current program level (dBFS), slow-moving
    private var rmsAccumulator: Float = 0.0        // Running sum-of-squares for current window
    private var rmsSampleCount: Int = 0            // Samples accumulated so far
    private let rmsWindowSamples: Int = 66150      // ~1.5s window @ 44.1 kHz (stereo frames)
    private var lastAppliedThreshold: Float = 0.0  // Avoid redundant BASS_FXSetParameters calls

    var stereoWidth: Float = 0.75
    var stereoPan:   Float = 0.5

    var eqEnabled:          Bool = true
    var stereoWidthEnabled: Bool = true
    var masterBypassEnabled: Bool = false

    // MARK: - Stereo DSP Parameter Smoothing
    // Per-buffer exponential smoothing with linear interpolation within each buffer
    // prevents pops/clicks from abrupt parameter jumps at buffer boundaries.
    private var smoothedStereoCoeff: Float = 1.0   // Tracks stereoWidthCoeff
    private var smoothedPanOffset:   Float = 0.0   // Tracks (stereoPan - 0.5) * 2.0

    // MARK: - Frequency-Dependent Stereo Processing (400 Hz crossover)
    private var centerSpreadLPFState: Float = 0.0  // Low-pass filter state for mono center channel
    private var sideChannelLPFState:  Float = 0.0  // Low-pass filter state for stereo side channel
    private let centerSpreadCrossoverHz: Float = 400.0
    // Precomputed filter coefficient for 400 Hz @ 44.1 kHz (1st-order butterworth)
    // alpha = 2*pi*f / (2*pi*f + sr) ≈ 0.0556 for 400 Hz @ 44.1 kHz
    private let centerSpreadLPFAlpha: Float = 0.0556

    // MARK: - Mono Stereo Synthesis (2-stage APF cascade for broad phase coverage)
    // Two APF stages in series (both g = -0.75) double the phase accumulation,
    // shifting the 90° crossover from ~5 kHz to ~2.5 kHz (centre of the audible band).
    // Above ~5 kHz the cascade exceeds 180°, biasing slightly right — balancing the
    // below-2.5 kHz left bias. Net result: much more even spread L and R across typical music.
    // Classic L+=, R-= M/S synthesis is retained; the cascade output drives both.
    private var synthAPFInput:   Float = 0.0   // Stage 1 x[n-1]
    private var synthAPFOutput:  Float = 0.0   // Stage 1 y[n-1]
    private var synthAPF2Input:  Float = 0.0   // Stage 2 x[n-1]
    private var synthAPF2Output: Float = 0.0   // Stage 2 y[n-1]
    private var smoothedMonoFraction: Float = 0.0  // Per-buffer mono detection (0=stereo, 1=mono)
    private let synthAPFCoeff: Float = -0.75   // APF coefficient for both stages
    // High-pass filter applied to M before the APF cascade — shapes widening by frequency:
    //   < 100 Hz → −12 dB (barely spread)   ~400 Hz → −3 dB (somewhat)   > 1 kHz → < −1 dB (most)
    // α = fs / (fs + 2π·fc) = 44100 / (44100 + 2π·400) ≈ 0.946
    private var synthHPFInput:  Float = 0.0
    private var synthHPFOutput: Float = 0.0
    private let synthHPFAlpha:  Float = 0.9461

    // MARK: - Center Spread APF (symmetric high-freq spread for right channel)
    // R channel gets APF-shifted M_highFreq rather than -M_highFreq so it also
    // gains high-frequency content (decorrelated from L) instead of losing it.
    private var spreadAPFInput:  Float = 0.0
    private var spreadAPFOutput: Float = 0.0

    // MARK: - DVR
    // macOS only at runtime; properties must be unconditionally declared so @Observable
    // macro can generate correct accessor code (macro-expanded files have no #if guards).

    enum DVRState { case live, paused, playing }

    /// Current DVR mode. `.live` = normal streaming, `.paused` = live stream muted
    /// while recording continues, `.playing` = playing back from WAV ring buffer.
    /// Always `.live` on iOS (DVR feature not implemented there yet).
    var dvrState: DVRState = .live

    /// How many seconds behind live the current DVR playback position is.
    private(set) var behindLiveSeconds: TimeInterval = 0

    private var streamBuffer:       StreamBuffer?  = nil
    private var recordingDSP:       DWORD          = 0
    private var dvrPlaybackStream:  DWORD          = 0
    private var dvrNextStream:      DWORD          = 0   // pre-loaded next segment (gapless)
    private var dvrPausedStreams:   [DWORD]        = []  // streams kept alive during dvrPausePlayback() fade-out
    private var dvrPauseTimestamp:  Double         = 0
    private var dvrCurrentSegNum:   Int            = 0
    private var dvrNextSegNum:      Int            = 0
    private var dvrBehindTimer:     Timer?         = nil

    // DVR metadata journal — maps recording timestamps to raw metadata strings.
    // Populated by publishTitle() during live streaming; consulted during DVR playback
    // to replay track-change notifications at the correct recorded position.
    // All reads/writes happen on the main thread (append dispatched from publishTitle).
    private var dvrMetadataJournal: [(timestamp: Double, metadata: String)] = []
    private var lastDVRPublishedMetadata: String? = nil
    private var dvrMetadataTimer: Timer? = nil
    private(set) var dvrBufferFull: Bool = false   // set when recording fills the window

    // MARK: - FX Blend (smooth on/off transitions)
    // Ramp blend 0→1 (passthrough→active) over ~83ms when toggling compressor/EQ or master bypass.
    // Prevents clicks/pops caused by abrupt compressor state jumps or filter coefficient changes.
    private var compressorBlend: Float = 0.0     // 0 = passthrough, 1 = fully active
    private var compressorBlendGoal: Float = 0.0 // desired target
    private var eqBlend: Float = 1.0             // 0 = all bands at 0 dB, 1 = active gains
    private var eqBlendGoal: Float = 1.0
    private var fxRampTimer: Timer?

    var stereoWidthCoeff: Float {
        stereoWidth <= 0.75
            ? stereoWidth / 0.75
            : 1.0 + (stereoWidth - 0.75) / 0.25
    }

    /// Whether any FX unit is actively being used (not at default values).
    /// Returns true if FX Bypass is off AND at least one unit is "being used":
    /// - EQ: enabled AND at least one gain is not at 0 dB
    /// - Compressor: on (always counts as used when enabled)
    /// - Stereo: enabled AND at least one control is not at default (width ≠ 0.75 OR pan ≠ 0.5)
    var isFXBeingUsed: Bool {
        guard !masterBypassEnabled else { return false }

        let eqIsUsed = eqEnabled && (eqLowGain != 0 || eqMidGain != 0 || eqHighGain != 0)
        let compressorIsUsed = compressorOn
        let stereoIsUsed = stereoWidthEnabled && (stereoWidth != 0.75 || stereoPan != 0.5)

        return eqIsUsed || compressorIsUsed || stereoIsUsed
    }

    // MARK: - Init / Deinit

    override init() {
        super.init()

        // Update thread period: 20ms balances decode efficiency vs responsiveness.
        // Too fast (5ms) = excessive context-switch overhead for CPU-heavy FLAC decode.
        // Too slow (100ms default) = long gaps between buffer refills.
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), 20)
        // Two update threads: FLAC decode is CPU-heavy and runs on the update thread alongside
        // mixer rendering + DSP chain. A second thread lets BASS parallelise decode and render,
        // preventing decode slowdowns from starving the mixer output buffer.
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATETHREADS), 2)
        // Larger device output buffer (default ~40ms → 500ms): last-resort defense before
        // hardware. Adds trivial latency for a radio stream but absorbs any upstream hiccup.
        // 500ms provides extra protection when the mixer output buffer hits 0ms during FLAC decode stalls.
        BASS_SetConfig(DWORD(BASS_CONFIG_DEV_BUFFER), 500)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)  // 25s download buffer for mobile resilience
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)    // Wait for 50% of net buffer before starting (~reduces initial stutter)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), 10000)
        // Max playback buffer (caps BASS_ATTRIB_BUFFER). Try 15s — BASS may clamp to 5s
        // internally, but if it accepts it the FLAC mixer gets more runway.
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), 15000)
        #if os(iOS)
        // Let our Swift configureAudioSession() own the AVAudioSession entirely.
        // Without this, BASS reconfigures the session on channel play, breaking MPNowPlayingInfoCenter.
        BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(BASS_IOS_SESSION_DISABLE))
        #endif
        guard BASS_Init(-1, 44100, 0, nil, nil) != 0 else {
            print("❌  BASS_Init failed — error: \(BASS_ErrorGetCode())")
            return
        }
        BASS_Start()
        print("✅  BASS initialised")
        startNetworkMonitoring()

        // Try to register the FLAC plugin so BASS_StreamCreateURL auto-detects FLAC.
        // With static linking (Swift Package), BASS_PluginLoad may find the plugin in the
        // Frameworks directory. If this succeeds, FLAC streams get full BASS_ATTRIB_BUFFER
        // support and proper download buffering.
        let pluginPaths = ["bassflac", "libbassflac.dylib", "libbassflac"]
        for path in pluginPaths {
            let h = BASS_PluginLoad(path, 0)
            if h != 0 {
                print("✅  FLAC plugin loaded via BASS_PluginLoad(\"\(path)\") — handle \(h)")
                break
            }
        }
        // If none loaded, BASS_FLAC_StreamCreateURL fallback still works (just without buffer support)
    }

    deinit {
        stop()
        BASS_Free()
    }

    // MARK: - Public Playback Interface

    /// Start playing the stream with the given format.
    /// `format` must be one of "MP3", "OGG", "AAC", "FLAC".
    /// `url` is accepted for API compatibility but the quality table is the source of truth.
    func play(format: String, url: String) {
        switchQuality(format)
    }

    /// Stop playback and reset state.
    func stop() {
        isUserIntendedPlay = false
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }
        freeStream()
        activeFormat = ""
        lastIcecastTitle = nil
        lastPublishedTitle = nil
        lastFlacTitle = nil
        DispatchQueue.main.async {
            self.currentQuality = ""
            self.isPlaying = false
            self.playbackState = .stopped
        }
    }

    /// Stop playback with a fade-out effect (user-initiated stop only).
    func stopWithFadeOut() {
        isUserIntendedPlay = false
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }
        let ph = playbackHandle
        guard ph != 0 else { stop(); return }
        startFadeOut(mixer: ph) { [weak self] in
            self?.stop()
        }
    }

    // MARK: - Network Resilience

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            guard path.status == .satisfied,
                  self.isUserIntendedPlay,
                  !self.isStreamActive else { return }
            print("🌐 Network restored — triggering immediate reconnect")
            self.cancelReconnectTimer()
            self.reconnectAttempt = 0
            self.bassPollingQueue.async { self.restartStream() }
        }
        monitor.start(queue: networkMonitorQueue)
    }

    private func scheduleReconnect() {
        guard isUserIntendedPlay else { return }
        let delay = reconnectBackoffDelays[min(reconnectAttempt, reconnectBackoffDelays.count - 1)]
        reconnectAttempt += 1
        print("⏳ Reconnect attempt \(reconnectAttempt) scheduled in \(Int(delay))s")
        DispatchQueue.main.async {
            self.isReconnecting = true
            self.playbackState = .connecting
        }
        cancelReconnectTimer()
        let timer = DispatchSource.makeTimerSource(queue: bassPollingQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isUserIntendedPlay else { return }
            self.restartStream()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    /// Public entry point for ContentViews to request an immediate reconnect
    /// (e.g., foreground resume, AVAudioSession interruption end, macOS wake).
    func triggerImmediateReconnect() {
        guard isUserIntendedPlay else { return }
        print("🔄 triggerImmediateReconnect called")
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = true }
        bassPollingQueue.async { self.restartStream() }
    }

    // MARK: - Internal Playback

    /// The handle to use for playback control (volume, play/stop, FX, DSP).
    /// All formats use the mixer, so this is always mixerHandle when playing.
    private var playbackHandle: DWORD { mixerHandle != 0 ? mixerHandle : streamHandle }

    /// True when BASS has a valid stream set up (not torn down).
    var isStreamActive: Bool { streamHandle != 0 && mixerHandle != 0 }

    private func switchQuality(_ format: String) {
        guard let entry = qualities.first(where: { $0.format == format }) else { return }
        isUserIntendedPlay = true
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }
        print("\n🔊 ── SWITCHING TO \(format) ──────────────────────────")
        print("   URL: \(entry.url)")

        freeStream()

        guard let cURL = entry.url.cString(using: .utf8) else { return }

        // FLAC needs a larger download pre-buffer due to ~900kbps bitrate
        if format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 30000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }

        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        streamHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)

        if format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }

        if streamHandle == 0 {
            let err = BASS_ErrorGetCode()
            print("❌  Stream creation failed (error \(err)) — scheduling reconnect")
            scheduleReconnect()
            return
        }

        if format == "FLAC" {
            // Two-mixer pipeline: DECODE-mode pre-mixer (3.0s stutter buffer + click guard)
            // feeds into the output post-mixer (0.1s FX latency). All DSP/FX live on the post-mixer.
            preMixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        } else {
            // Two-mixer pipeline for all formats: stream → DECODE-mode pre-mixer (0.3s buffer)
            // → FX output mixer (0.1s buffer). Uniform with FLAC; enables channel-vol fading
            // for DVR pause/resume without BASS output-mixer vol unreliability.
            preMixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        }

        activeFormat = format

        // Start DVR recording before attaching DSPs so no audio is missed.
        let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
        streamBuffer = StreamBuffer(maxMinutes: dvrMins > 0 ? dvrMins : 15)
        streamBuffer?.start()

        configureStreamAttributes(format: format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        let ph = playbackHandle
        DispatchQueue.main.async {
            self.currentQuality = format
            self.isPlaying = true
            self.playbackState = .connecting
        }

        if format == "FLAC" {
            // Delay mixer start by 10s so the download ring buffer fills with compressed data.
            // BASS_StreamCreateURL returns quickly (async); during the wait the server sends
            // ~1.125 MB of FLAC (~10s × 900 kbps/8), giving the pre-mixer a larger ring buffer
            // reserve at startup. Metadata polling starts after the mixer plays — avoids false
            // STOPPED detection. preBufferProgress drives the UI loading bar (0→1 over 10s).
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            flacPendingFadeIn = true
            let capturedPH = ph
            let capturedSH = streamHandle
            let totalDelay: TimeInterval = 10.0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.preBufferProgress = 0.0
                self.preBufferTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.preBufferProgress = min(self.preBufferProgress + 0.1 / totalDelay, 1.0)
                }
            }
            print("   handle=\(capturedSH) mixer=\(mixerHandle) preMix=\(preMixerHandle) playback=\(capturedPH) — pre-buffering \(Int(totalDelay))s before mixer start…")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + totalDelay) { [weak self] in
                guard let self = self, self.streamHandle == capturedSH else { return }
                DispatchQueue.main.async {
                    self.preBufferTimer?.invalidate()
                    self.preBufferTimer = nil
                }
                print("   🎬 FLAC pre-buffer complete — calling BASS_ChannelPlay")
                BASS_ChannelPlay(capturedPH, 0)
                DispatchQueue.main.async { self.startMetadataPolling() }
            }
        } else {
            print("   handle=\(streamHandle) preMix=\(preMixerHandle) mixer=\(mixerHandle) playback=\(ph) — calling BASS_ChannelPlay…")
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPlay(ph, 0)
            startFadeIn(mixer: ph)
            startMetadataPolling()
        }
    }

    private func freeStream() {
        fxRampTimer?.invalidate()
        fxRampTimer = nil
        cancelFade()
        stopMetadataPolling()
        oggStopConfirmed = false
        trackChangeCount = 0
        isRefillPausing  = false
        lastFlacTitle = nil
        lastIcecastTitle = nil

        // Stop DVR playback and timers before freeing channels.
        // Ordering: stop timer → free DVR stream → stop BASS channels (stops DSP) → cleanup buffer.
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        dvrMetadataTimer?.invalidate()
        dvrMetadataTimer = nil
        if dvrPlaybackStream != 0 {
            BASS_StreamFree(dvrPlaybackStream)
            dvrPlaybackStream = 0
        }
        if dvrNextStream != 0 {
            BASS_StreamFree(dvrNextStream)
            dvrNextStream = 0
        }
        for s in dvrPausedStreams { BASS_StreamFree(s) }
        dvrPausedStreams.removeAll()

        if mixerHandle != 0 {
            BASS_ChannelStop(mixerHandle)     // stops DSP callbacks including recordingDSP
            BASS_StreamFree(mixerHandle)
            print("⏹  mixer freed (handle was \(mixerHandle))")
            mixerHandle = 0
        }
        preBufferTimer?.invalidate()
        preBufferTimer = nil
        DispatchQueue.main.async { self.preBufferProgress = 0.0 }
        if preMixerHandle != 0 {
            BASS_ChannelStop(preMixerHandle)
            BASS_StreamFree(preMixerHandle)
            print("⏹  pre-mixer freed (handle was \(preMixerHandle))")
            preMixerHandle = 0
        }
        if streamHandle != 0 {
            // For FLAC direct playback the stream IS the playback channel (already stopped/freed
            // above if mixerHandle pointed at it — but in direct mode mixerHandle == 0, so we
            // stop/free the stream here).
            BASS_ChannelStop(streamHandle)
            BASS_StreamFree(streamHandle)
            print("⏹  stream freed (handle was \(streamHandle))")
            streamHandle = 0
        }
        eqLowFX  = 0
        eqMidFX  = 0
        eqHighFX = 0
        compressorFX = 0
        levelMeterDSP = 0
        stereoDSP = 0
        limiterDSP = 0
        rmsAccumulator = 0
        rmsSampleCount = 0
        lastAppliedThreshold = 0
        clickGuardDSP = 0
        cgFadeBuffersRemaining = 0
        cgLastGuardTime = 0
        flacPendingFadeIn = false

        // Channels are now stopped — safe to tear down StreamBuffer.
        recordingDSP = 0
        streamBuffer?.stop()
        streamBuffer?.cleanup()
        streamBuffer = nil
        dvrState = .live
        dvrBufferFull = false
        behindLiveSeconds = 0
        dvrCurrentSegNum = 0
        dvrNextSegNum    = 0
        dvrPauseTimestamp = 0
        dvrMetadataJournal.removeAll()
        lastDVRPublishedMetadata = nil
    }

    // MARK: - Stream Attributes

    private func configureStreamAttributes(format: String, handle: DWORD) {
        let ph = playbackHandle  // Always mixerHandle when playing (output post-mixer for FLAC, single mixer for others)

        let netResume: Float = 25
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), netResume)

        // All formats use two-mixer pipeline: pre-mixer gets a stutter-protection buffer
        // (3.0s for FLAC, 0.3s for others); the FX output mixer gets 0.1s so EQ/compressor
        // changes are heard within ~100ms on all formats.
        if mixerHandle != 0 {
            let preMixBuf: Float = format == "FLAC" ? 3.0 : 0.3
            BASS_ChannelSetAttribute(preMixerHandle, DWORD(BASS_ATTRIB_BUFFER), preMixBuf)
            BASS_ChannelSetAttribute(mixerHandle,    DWORD(BASS_ATTRIB_BUFFER), 0.1)
            print("⚙️  configureStreamAttributes format=\(format) preMixBuf=\(preMixBuf)s fxMixBuf=0.1s")
        } else {
            print("⚙️  configureStreamAttributes format=\(format) — no mixer (direct mode)")
        }

        // Click guard always on preMixerHandle: fires before the FX output mixer,
        // giving click-clean recordings since the recording DSP at priority -3 runs after.
        applyEffects(to: ph, clickGuardOn: preMixerHandle)
    }

    // MARK: - Audio Effects

    private func applyEffects(to handle: DWORD, clickGuardOn cgHandle: DWORD? = nil) {
        let userData = Unmanaged.passUnretained(self).toOpaque()

        eqLowFX  = BASS_ChannelSetFX(handle, DWORD(BASS_FX_BFX_BQF), 0)
        eqMidFX  = BASS_ChannelSetFX(handle, DWORD(BASS_FX_BFX_BQF), 0)
        eqHighFX = BASS_ChannelSetFX(handle, DWORD(BASS_FX_BFX_BQF), 0)
        // Snap blend to goal on stream start — no ramp needed for a fresh stream.
        eqBlend     = (eqEnabled && !masterBypassEnabled) ? 1.0 : 0.0
        eqBlendGoal = eqBlend
        applyEQAtCurrentBlend()

        // Level-meter DSP: measures RMS of the post-compression signal (feedback topology).
        // BASS FX (EQ, compressor) run before DSP callbacks, so this sees the compressed output.
        // Feedback measurement is intentional — like an LA-2A, the slow ~4.5s time constant
        // (1.5s window × 0.3 EMA) keeps it stable and tracks overall program level changes.
        levelMeterDSP = BASS_ChannelSetDSP(
            handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                guard player.compressorOn, !player.masterBypassEnabled else { return }

                let samples = buffer.assumingMemoryBound(to: Float.self)
                let count   = Int(length) / MemoryLayout<Float>.size
                let frames  = count / 2

                // Accumulate sum-of-squares (mono sum of L+R)
                var sumSq: Float = 0
                for frame in 0..<frames {
                    let L = samples[frame &* 2]
                    let R = samples[frame &* 2 &+ 1]
                    let mono = (L + R) * 0.5
                    sumSq += mono * mono
                }
                player.rmsAccumulator += sumSq
                player.rmsSampleCount += frames

                // When we've accumulated a full window, compute RMS and update compressor
                if player.rmsSampleCount >= player.rmsWindowSamples {
                    let rms = sqrtf(player.rmsAccumulator / Float(player.rmsSampleCount))
                    let dbFS = rms > 0 ? 20.0 * log10f(rms) : -80.0
                    // Smooth the measurement to avoid jitter (EMA, ~3s effective time constant)
                    let smoothAlpha: Float = 0.3
                    player.measuredRMSdB = player.measuredRMSdB + smoothAlpha * (dbFS - player.measuredRMSdB)
                    player.rmsAccumulator = 0
                    player.rmsSampleCount = 0
                    player.applyAdaptiveCompressor()
                }
            },
            userData,
            2
        )

        compressorFX = BASS_ChannelSetFX(handle, DWORD(BASS_FX_BFX_COMPRESSOR2), 0)
        // Snap blend to goal on stream start — no ramp needed for a fresh stream.
        compressorBlend     = (compressorOn && !masterBypassEnabled) ? 1.0 : 0.0
        compressorBlendGoal = compressorBlend
        applyCompressorBlend(compressorBlend)

        stereoDSP = BASS_ChannelSetDSP(
            handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                // When disabled or bypassed, ramp to neutral rather than cutting abruptly.
                // The existing per-buffer smoothing fades coeff→1.0 and pan→0.0 over ~3–4 buffers.
                // Once both reach neutral, the `guard applyWidth || applyPan` below skips work.
                let active = player.stereoWidthEnabled && !player.masterBypassEnabled
                let targetCoeff: Float = active ? player.stereoWidthCoeff : 1.0
                let targetPan:   Float = active ? (player.stereoPan - 0.5) * 2.0 : 0.0

                let prevCoeff = player.smoothedStereoCoeff
                let prevPan   = player.smoothedPanOffset

                // Exponential smoothing: converge ~80% per buffer (~3–4 buffers to settle)
                let alpha: Float = 0.3
                var newCoeff = prevCoeff + alpha * (targetCoeff - prevCoeff)
                var newPan   = prevPan   + alpha * (targetPan   - prevPan)
                // Snap when close to avoid perpetual tiny corrections
                if abs(newCoeff - targetCoeff) < 0.0001 { newCoeff = targetCoeff }
                if abs(newPan   - targetPan)   < 0.0001 { newPan   = targetPan }
                player.smoothedStereoCoeff = newCoeff
                player.smoothedPanOffset   = newPan

                // Skip if both smoothed endpoints are at neutral
                let applyWidth = abs(prevCoeff - 1.0) > 0.001 || abs(newCoeff - 1.0) > 0.001
                let applyPan   = abs(prevPan) > 0.001 || abs(newPan) > 0.001
                guard applyWidth || applyPan else { return }

                let samples = buffer.assumingMemoryBound(to: Float.self)
                let count   = Int(length) / MemoryLayout<Float>.size
                let frames  = count / 2

                // Mono detection: RMS ratio of side vs. mid over this buffer
                var sumM2: Float = 0, sumS2: Float = 0
                for f in 0..<frames {
                    let L0 = samples[f &* 2], R0 = samples[f &* 2 &+ 1]
                    let M0 = (L0 + R0) * 0.5, S0 = (L0 - R0) * 0.5
                    sumM2 += M0 * M0; sumS2 += S0 * S0
                }
                let rawMono: Float = max(0.0, 1.0 - sqrt(sumS2 / (sumM2 + Float(1e-10))))
                player.smoothedMonoFraction += 0.15 * (rawMono - player.smoothedMonoFraction)
                let monoFraction = player.smoothedMonoFraction

                // Pre-compute synth gain endpoints for per-frame interpolation.
                let prevSynthGain = max(0.0, prevCoeff - 1.0) * monoFraction * 0.4
                let newSynthGain  = max(0.0, newCoeff  - 1.0) * monoFraction * 0.4

                // Pre-compute pan trig at buffer start and end for interpolation
                let aS: Float = prevPan < 0 ? -prevPan : 0, bS: Float = prevPan > 0 ? prevPan : 0
                let aE: Float = newPan  < 0 ? -newPan  : 0, bE: Float = newPan  > 0 ? newPan  : 0
                let sinA_s = sin(aS * .pi / 2), cosA_s = cos(aS * .pi / 2)
                let sinB_s = sin(bS * .pi / 2), cosB_s = cos(bS * .pi / 2)
                let sinA_e = sin(aE * .pi / 2), cosA_e = cos(aE * .pi / 2)
                let sinB_e = sin(bE * .pi / 2), cosB_e = cos(bE * .pi / 2)

                let invFrames = 1.0 / Float(max(frames - 1, 1))
                for frame in 0..<frames {
                    let t     = Float(frame) * invFrames
                    let coeff = prevCoeff + t * (newCoeff - prevCoeff)

                    var L = samples[frame &* 2], R = samples[frame &* 2 &+ 1]

                    if applyWidth {
                        let M = (L + R) * 0.5
                        let S = (L - R) * 0.5

                        // Frequency-dependent side-channel scaling (400 Hz crossover).
                        // Narrowing (coeff ≤ 1): sub-400Hz uses coeff² so bass collapses toward
                        //   mono faster than high-freq content as the slider moves left.
                        // Widening (coeff > 1): sub-400Hz gets only half the width boost of
                        //   high-freq content, keeping bass centered and tight.
                        // Both reach 0 (mono) at coeff=0 and 1 (unchanged) at coeff=1.
                        let S_low  = player.lowPassFilterSide(S)
                        let S_high = S - S_low
                        let lowFreqCoeff: Float = coeff <= 1.0 ? coeff * coeff : 1.0 + (coeff - 1.0) * 0.5
                        L = M + S_low * lowFreqCoeff + S_high * coeff
                        R = M - S_low * lowFreqCoeff - S_high * coeff

                        // Frequency-Dependent Center Spreading (coeff > 1: spread high-freq mono)
                        // L gets in-phase M_highFreq; R gets APF-shifted M_highFreq so that
                        // R also *gains* high-frequency content (different phase) rather than
                        // losing it — making the widening feel balanced across both channels.
                        let M_lowFreq  = player.lowPassFilter400Hz(M)
                        let M_highFreq = M - M_lowFreq
                        let spreadAmount = max(0.0, coeff - 1.0) * 0.15
                        let gCS = player.synthAPFCoeff  // -0.75
                        let spreadAPFout = gCS * M_highFreq + player.spreadAPFInput - gCS * player.spreadAPFOutput
                        player.spreadAPFInput  = M_highFreq
                        player.spreadAPFOutput = spreadAPFout
                        L += M_highFreq * spreadAmount
                        R += spreadAPFout * spreadAmount  // phase-shifted high-freq (not subtracted)

                        // Mono stereo synthesis: 2-stage APF cascade.
                        // Cascading two identical APFs (g = -0.75) doubles the phase
                        // accumulation: 90° crossover shifts from ~5 kHz to ~2.5 kHz,
                        // and the curve continues to 180° at ~5 kHz, then beyond.
                        // This means the left bias (below crossover) is partially offset
                        // by a right bias (above ~5 kHz), giving a more even stereo field.
                        // APF states always updated even when synthGain=0 (keeps filters warm).
                        let synthGain = prevSynthGain + t * (newSynthGain - prevSynthGain)
                        // High-pass filter M at ~400 Hz before the APF cascade so that
                        // sub-bass content is barely spread and lows are only somewhat spread.
                        // y[n] = α*(y[n-1] + x[n] - x[n-1])
                        let a = player.synthHPFAlpha
                        let M_hp = a * (player.synthHPFOutput + M - player.synthHPFInput)
                        player.synthHPFInput  = M
                        player.synthHPFOutput = M_hp
                        let g = player.synthAPFCoeff  // -0.75
                        let stage1 = g * M_hp + player.synthAPFInput - g * player.synthAPFOutput
                        player.synthAPFInput  = M_hp;  player.synthAPFOutput  = stage1
                        let stage2 = g * stage1 + player.synthAPF2Input - g * player.synthAPF2Output
                        player.synthAPF2Input = stage1;  player.synthAPF2Output = stage2
                        L += stage2 * synthGain
                        R -= stage2 * synthGain
                    }
                    if applyPan {
                        let sinA = sinA_s + t * (sinA_e - sinA_s)
                        let cosA = cosA_s + t * (cosA_e - cosA_s)
                        let sinB = sinB_s + t * (sinB_e - sinB_s)
                        let cosB = cosB_s + t * (cosB_e - cosB_s)
                        let L2 = L, R2 = R
                        L = L2 * cosB + R2 * sinA
                        R = L2 * sinB + R2 * cosA
                    }
                    samples[frame &* 2]       = L
                    samples[frame &* 2 &+ 1] = R
                }
            },
            userData,
            0
        )

        limiterDSP = BASS_ChannelSetDSP(
            handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                guard !player.masterBypassEnabled else { return }
                let samples = buffer.assumingMemoryBound(to: Float.self)
                let count   = Int(length) / MemoryLayout<Float>.size
                let threshold: Float = 0.85   // –1.4 dBFS — soft knee starts here
                let knee: Float      = 0.05   // narrower curve, more decisive limiting
                let ceiling: Float   = 0.891  // –1.0 dBFS hard brick-wall (leaves ~1 dB for ISP)
                for i in 0..<count {
                    let x    = samples[i]
                    let absX = x < 0 ? -x : x
                    if absX > threshold {
                        let sign: Float = x > 0 ? 1.0 : -1.0
                        let excess      = absX - threshold
                        let limited     = threshold + knee * (1.0 - 1.0 / (1.0 + excess / knee))
                        samples[i]      = sign * min(limited, ceiling)  // hard clip safety net
                    }
                }
            },
            userData,
            -1
        )
        // Click guard DSP: runs after limiter (priority -2).
        // OGG/FLAC: for FLAC in two-mixer mode, attaches to the pre-mixer (cgHandle) so it fires
        // in the DECODE-mode render context at the bitstream boundary, before FX processing.
        // For OGG and all other formats, attaches to handle (the output mixer).
        clickGuardDSP = BASS_ChannelSetDSP(
            cgHandle ?? handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let p = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                guard p.cgFadeBuffersRemaining > 0 else { return }

                let samples = buffer.assumingMemoryBound(to: Float.self)
                let count = Int(length) / MemoryLayout<Float>.size
                let frames = count / 2
                let remaining = p.cgFadeBuffersRemaining
                p.cgFadeBuffersRemaining -= 1
                let n = p.cgFadeBufferCount

                if remaining > n {
                    // Silence phase: zero out all samples.
                    for i in 0 ..< count { samples[i] = 0 }
                } else {
                    // Fade-in phase: ramp gain 0→1 over n buffers.
                    let posInFade = n - remaining  // 0-based
                    for i in stride(from: 0, to: count - 1, by: 2) {
                        let gain = min(1.0, (Float(posInFade) + Float(i / 2) / Float(frames)) / Float(n))
                        samples[i]     *= gain
                        samples[i + 1] *= gain
                    }
                }
            },
            userData,
            -2
        )

        // Recording DSP — priority -3, after all FX, limiter, and click guard.
        attachRecordingDSP()
    }

    /// Attach the recording DSP to the pre-mixer, not the output mixer.
    /// preMixerHandle is always set for all formats (post-click-guard, pre-FX output chain).
    /// The WAV ring buffer stores original stream audio independent of user FX settings.
    /// DSP callbacks receive audio before volume scaling, so muting the pre-mixer during
    /// DVR playback does not silence the recording.
    private func attachRecordingDSP() {
        let sourceHandle: DWORD = preMixerHandle != 0 ? preMixerHandle : streamHandle
        guard sourceHandle != 0 else { return }
        let userData = Unmanaged.passUnretained(self).toOpaque()
        recordingDSP = BASS_ChannelSetDSP(
            sourceHandle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                Unmanaged<BASSRadioPlayer>.fromOpaque(user)
                    .takeUnretainedValue()
                    .streamBuffer?.append(buffer: buffer, length: Int(length))
            },
            userData,
            -3
        )
    }

    private func applyLowShelf(gain: Float) {
        guard eqLowFX != 0 else { return }
        var p = BASS_BFX_BQF()
        p.lFilter  = Int32(BASS_BFX_BQF_LOWSHELF)
        p.fCenter  = 120
        p.fGain    = gain
        p.fS       = 0.7
        p.lChannel = -1
        BASS_FXSetParameters(eqLowFX, &p)
    }

    private func applyMidPeak(gain: Float) {
        guard eqMidFX != 0 else { return }
        let bw = max(0.1, 2.0 - (abs(eqMidGain) / 6.0) * 1.0)
        var p = BASS_BFX_BQF()
        p.lFilter     = Int32(BASS_BFX_BQF_PEAKINGEQ)
        p.fCenter     = 1800
        p.fGain       = gain
        p.fBandwidth  = bw
        p.lChannel    = -1
        BASS_FXSetParameters(eqMidFX, &p)
    }

    private func applyHighShelf(gain: Float) {
        guard eqHighFX != 0 else { return }
        var p = BASS_BFX_BQF()
        p.lFilter  = Int32(BASS_BFX_BQF_HIGHSHELF)
        p.fCenter  = 7500
        p.fGain    = gain
        p.fS       = 0.7
        p.lChannel = -1
        BASS_FXSetParameters(eqHighFX, &p)
    }

    private func applyCompressorParams() {
        guard compressorFX != 0 else { return }
        let t = compressorAmount * 0.75  // Scale so slider max = old 0.75 (tamer ceiling)

        // Adaptive threshold: set relative to measured program level.
        // headroom = how far above the average RMS the threshold sits.
        // At gentle (t=0): threshold = measuredRMS + 6 dB (only peaks compressed)
        // At heavy (t=1):  threshold = measuredRMS + 2.25 dB
        let headroom: Float = 6.0 - 5.0 * t
        let adaptiveThreshold = max(min(measuredRMSdB + headroom, -2.0), -40.0)

        var p = BASS_BFX_COMPRESSOR2()
        p.fThreshold = adaptiveThreshold
        p.fRatio     = 1.5  + 6.5   * t
        p.fAttack    = 25   - 22    * t
        p.fRelease   = 300  - 220   * t
        p.fGain      = (-adaptiveThreshold) * (1.0 - 1.0 / p.fRatio) * (0.5 + 0.25 * t)
        p.lChannel   = -1
        BASS_FXSetParameters(compressorFX, &p)
        lastAppliedThreshold = adaptiveThreshold
    }

    /// Called from the level-meter DSP when a new RMS measurement is ready.
    /// Only updates the compressor if the threshold would change meaningfully (>0.5 dB).
    func applyAdaptiveCompressor() {
        guard compressorFX != 0, compressorOn, !masterBypassEnabled else { return }
        guard compressorBlend >= 0.99 else { return }  // Don't override an active blend ramp
        let t = compressorAmount * 0.75
        let headroom: Float = 6.0 - 5.0 * t
        let newThreshold = max(min(measuredRMSdB + headroom, -2.0), -40.0)
        // Skip if threshold hasn't changed meaningfully
        guard abs(newThreshold - lastAppliedThreshold) > 0.5 else { return }
        applyCompressorParams()
    }

    /// Set compressor to transparent passthrough (threshold 0 dB, ratio 1:1, no makeup gain).
    /// The FX stays in the chain — no add/remove discontinuity.
    private func applyCompressorPassthrough() {
        guard compressorFX != 0 else { return }
        var p = BASS_BFX_COMPRESSOR2()
        p.fThreshold = 0
        p.fRatio     = 1.0
        p.fAttack    = 20
        p.fRelease   = 200
        p.fGain      = 0
        p.lChannel   = -1
        BASS_FXSetParameters(compressorFX, &p)
    }

    // MARK: - FX Blend Helpers

    /// Interpolate compressor parameters between passthrough (blend=0) and fully active (blend=1).
    private func applyCompressorBlend(_ blend: Float) {
        guard compressorFX != 0 else { return }
        let t = compressorAmount * 0.75
        let headroom: Float = 6.0 - 5.0 * t
        let adaptiveThreshold = max(min(measuredRMSdB + headroom, -2.0), -40.0)
        let ratioOn: Float = 1.5 + 6.5 * t
        let gainOn: Float  = (-adaptiveThreshold) * (1.0 - 1.0 / ratioOn) * (0.5 + 0.25 * t)

        var p = BASS_BFX_COMPRESSOR2()
        p.fThreshold = blend * adaptiveThreshold         // 0.0 → adaptiveThreshold (negative)
        p.fRatio     = 1.0 + blend * (ratioOn - 1.0)    // 1.0 → ratioOn
        p.fAttack    = 25 - 22 * t
        p.fRelease   = 300 - 220 * t
        p.fGain      = blend * gainOn                    // 0.0 → gainOn
        p.lChannel   = -1
        BASS_FXSetParameters(compressorFX, &p)
        lastAppliedThreshold = p.fThreshold
    }

    /// Apply EQ band gains scaled by the current eqBlend (0=bypassed, 1=active).
    private func applyEQAtCurrentBlend() {
        applyLowShelf(gain:  eqLowGain  * eqBlend)
        applyMidPeak(gain:   eqMidGain  * eqBlend)
        applyHighShelf(gain: eqHighGain * eqBlend)
    }

    /// Start the FX ramp timer if it isn't already running.
    /// The timer fires at ~120 Hz and moves blends toward their goals in ~83ms.
    private func startFXRampIfNeeded() {
        guard fxRampTimer == nil else { return }
        fxRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.fxRampTick()
        }
    }

    private func fxRampTick() {
        let step: Float = 0.1  // 10 ticks × 8.3ms ≈ 83ms full transition
        var stillRamping = false

        if compressorBlend != compressorBlendGoal {
            let diff = compressorBlendGoal - compressorBlend
            if abs(diff) <= step {
                compressorBlend = compressorBlendGoal
            } else {
                compressorBlend += diff > 0 ? step : -step
            }
            applyCompressorBlend(compressorBlend)
            if compressorBlend != compressorBlendGoal { stillRamping = true }
        }

        if eqBlend != eqBlendGoal {
            let diff = eqBlendGoal - eqBlend
            if abs(diff) <= step {
                eqBlend = eqBlendGoal
            } else {
                eqBlend += diff > 0 ? step : -step
            }
            applyEQAtCurrentBlend()
            if eqBlend != eqBlendGoal { stillRamping = true }
        }

        flushEffects()
        if !stillRamping {
            fxRampTimer?.invalidate()
            fxRampTimer = nil
        }
    }

    // MARK: - Public FX Update Methods

    func updateEQ() {
        let newGoal: Float = (eqEnabled && !masterBypassEnabled) ? 1.0 : 0.0
        eqBlendGoal = newGoal
        if mixerHandle == 0 && streamHandle == 0 {
            // Not playing — snap immediately, no ramp
            eqBlend = eqBlendGoal
            applyEQAtCurrentBlend()
        } else if eqBlend == eqBlendGoal {
            // Already at target — apply directly (handles slider gain adjustments)
            applyEQAtCurrentBlend()
            flushEffects()
        } else {
            // State changed while playing — ramp smoothly
            startFXRampIfNeeded()
        }
        saveFXToDefaults()
    }

    func updateCompressor() {
        let newGoal: Float = (compressorOn && !masterBypassEnabled) ? 1.0 : 0.0
        compressorBlendGoal = newGoal
        if mixerHandle == 0 && streamHandle == 0 {
            // Not playing — snap immediately, no ramp
            compressorBlend = compressorBlendGoal
            applyCompressorBlend(compressorBlend)
        } else if compressorBlend == compressorBlendGoal {
            // Already at target — apply directly (handles amount slider changes)
            if compressorBlend >= 1.0 {
                applyCompressorParams()
            } else {
                applyCompressorPassthrough()
            }
            flushEffects()
        } else {
            // State changed while playing — ramp smoothly
            startFXRampIfNeeded()
        }
        saveFXToDefaults()
    }

    func updateCompressorAmount() {
        if compressorOn && !masterBypassEnabled && compressorBlend >= 0.99 {
            applyCompressorParams()
        }
        flushEffects()
        saveFXToDefaults()
    }

    func updateStereo() {
        flushEffects()
        saveFXToDefaults()
    }

    func resetAllFX() {
        masterBypassEnabled = false
        eqEnabled           = true
        eqLowGain           = 0
        eqMidGain           = 0
        eqHighGain          = 0
        compressorOn        = false
        compressorAmount    = 0.25
        stereoWidthEnabled  = true
        stereoWidth         = 0.75
        stereoPan           = 0.5
        measuredRMSdB       = -20.0
        rmsAccumulator      = 0
        rmsSampleCount      = 0
        lastAppliedThreshold = 0
        updateEQ()
        updateCompressor()
        // flushEffects() already called by updateEQ/updateCompressor above
    }

    func saveFXToDefaults() {
        let d = UserDefaults.standard
        d.set(eqLowGain,           forKey: "fx.eqLowGain")
        d.set(eqMidGain,           forKey: "fx.eqMidGain")
        d.set(eqHighGain,          forKey: "fx.eqHighGain")
        d.set(eqEnabled,           forKey: "fx.eqEnabled")
        d.set(compressorOn,        forKey: "fx.compressorOn")
        d.set(compressorAmount,    forKey: "fx.compressorAmount")
        d.set(stereoWidth,         forKey: "fx.stereoWidth")
        d.set(stereoPan,           forKey: "fx.stereoPan")
        d.set(stereoWidthEnabled,  forKey: "fx.stereoWidthEnabled")
        d.set(masterBypassEnabled, forKey: "fx.masterBypassEnabled")
    }

    func restoreFXFromDefaults() {
        let d = UserDefaults.standard
        guard d.object(forKey: "fx.eqLowGain") != nil else { return }
        eqLowGain           = d.float(forKey: "fx.eqLowGain")
        eqMidGain           = d.float(forKey: "fx.eqMidGain")
        eqHighGain          = d.float(forKey: "fx.eqHighGain")
        eqEnabled           = d.bool(forKey: "fx.eqEnabled")
        compressorOn        = d.bool(forKey: "fx.compressorOn")
        compressorAmount    = d.float(forKey: "fx.compressorAmount")
        stereoWidth         = d.float(forKey: "fx.stereoWidth")
        stereoPan           = d.float(forKey: "fx.stereoPan")
        stereoWidthEnabled  = d.bool(forKey: "fx.stereoWidthEnabled")
        masterBypassEnabled = d.bool(forKey: "fx.masterBypassEnabled")
        updateEQ()
        updateCompressor()
    }

    func updateMasterBypass() {
        updateEQ()
        updateCompressor()
    }

    /// Tops up the mixer output buffer with freshly-processed audio.
    /// Call after any FX parameter change so the new settings fill the buffer sooner.
    /// With reduced mixer buffers (0.5–1.0s), the remaining latency is at most the buffer size.
    func flushEffects() {
        let ph = playbackHandle
        guard ph != 0 else { return }
        BASS_ChannelUpdate(ph, 0)
    }

    // MARK: - BASS Syncs

    private func setupSyncs(for handle: DWORD) {
        let userData = Unmanaged.passUnretained(self).toOpaque()

        stallSync = BASS_ChannelSetSync(
            handle,
            DWORD(BASS_SYNC_STALL),
            0,
            { _, channel, data, user in
                guard data == 0, let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                player.handleStallSync(channel: channel)
            },
            userData
        )

        endSync = BASS_ChannelSetSync(
            handle,
            DWORD(BASS_SYNC_END),
            0,
            { _, channel, _, user in
                guard let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                player.handleEndSync(channel: channel)
            },
            userData
        )

        if activeFormat == "OGG" || activeFormat == "FLAC" {
            // Both OGG and FLAC use mixer path. BASS_Mixer_ChannelSetSync with BASS_SYNC_MIXTIME
            // fires during the mixer's render of the boundary buffer — sample-accurate.
            oggChangeSync = BASS_Mixer_ChannelSetSync(
                handle,
                DWORD(BASS_SYNC_OGG_CHANGE) | DWORD(BASS_SYNC_MIXTIME),
                0,
                { _, channel, _, user in
                    guard let user = user else { return }
                    let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                    player.handleOggChangeSync(channel: channel)
                },
                userData
            )
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync) oggChange=\(oggChangeSync) (mixer, mixtime)")
        } else {
            // MP3/AAC: no bitstream boundaries; no click guard needed.
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync)")
        }
    }

    private func handleStallSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }
        let bytes = BASS_ChannelGetPosition(channel, DWORD(BASS_POS_BYTE))
        let secs  = BASS_ChannelBytes2Seconds(channel, bytes)
        let dlBuf = BASS_StreamGetFilePosition(channel, DWORD(5))
        let dlEnd = BASS_StreamGetFilePosition(channel, DWORD(2))
        let rebuf = BASS_StreamGetFilePosition(channel, DWORD(9))
        print("⏸️  STALL pos=\(String(format: "%.2f", secs))s dlBuf=\(dlBuf)/\(dlEnd) rebuffering=\(rebuf)%")
        DispatchQueue.main.async { [weak self] in
            self?.playbackState = .buffering
        }
    }

    private func handleEndSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }
        if activeFormat == "OGG" || activeFormat == "FLAC" {
            print("🏁  BASS_SYNC_END fired for \(activeFormat) channel \(channel) — deferring to status poll")
            return
        }
        guard dvrState == .live else {
            print("🏁  BASS_SYNC_END fired during DVR mode — ignoring")
            return
        }
        print("🏁  BASS_SYNC_END fired for channel \(channel) — event-based restart")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.restartStream()
        }
    }

    private func handleOggChangeSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }

        // Debounce: OGG fires 2 events per track change (~0.4s apart). Ignore the second.
        // FLAC may fire 1 or 2 — debounce handles both correctly.
        let now = ProcessInfo.processInfo.systemUptime
        if now - cgLastGuardTime < 1.5 { return }
        cgLastGuardTime = now

        // Arm the guard: silence + fade-in starting immediately.
        cgFadeBuffersRemaining = cgSilenceBufferCount + cgFadeBufferCount

        // FLAC only: check if download buffer is low and a refill pause is due.
        if activeFormat == "FLAC" {
            trackChangeCount += 1
            if trackChangeCount >= bufferRefillTrackInterval, !isRefillPausing {
                let dlFill = BASS_StreamGetFilePosition(streamHandle, DWORD(5))           // BASS_FILEPOS_BUFFER
                let dlSize = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_END))
                let dlPct  = dlSize > 0 ? Double(dlFill) / Double(dlSize) * 100 : 100.0
                if dlPct < bufferRefillThreshold {
                    trackChangeCount = 0
                    DispatchQueue.main.async { [weak self] in self?.performRefillPause() }
                }
            }
        }
    }

    private func performRefillPause() {
        guard activeFormat == "FLAC", !isRefillPausing else { return }
        let ph = playbackHandle
        guard ph != 0, case .playing = playbackState else { return }
        isRefillPausing = true
        print("⏸️ FLAC dlBuf low — pausing \(bufferRefillDuration)s to refill")
        BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + bufferRefillDuration) { [weak self] in
            guard let self = self else { return }
            self.isRefillPausing = false
            guard case .playing = self.playbackState, self.playbackHandle == ph else { return }
            self.startFadeIn(mixer: ph)
        }
    }

    // MARK: - Metadata Polling

    private func startMetadataPolling() {
        stopMetadataPolling()
        bassPollingQueue.async { [weak self] in self?.pollMetadata() }
        metadataTimer = Timer.scheduledTimer(withTimeInterval: metaPollInterval, repeats: true) { [weak self] _ in
            self?.bassPollingQueue.async { self?.pollMetadata() }
        }
        startStatePolling()
    }

    private func stopMetadataPolling() {
        metadataTimer?.invalidate()
        metadataTimer = nil
        stopStatePolling()
    }

    private func startStatePolling() {
        stopStatePolling()
        stateTimer = Timer.scheduledTimer(withTimeInterval: statePollInterval, repeats: true) { [weak self] _ in
            self?.bassPollingQueue.async { self?.checkStreamStatus() }
        }
    }

    private func stopStatePolling() {
        stateTimer?.invalidate()
        stateTimer = nil
    }

    // MARK: - Fade In / Fade Out

    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeGeneration &+= 1
    }

    private func startFadeIn(mixer: DWORD) {
        let gen = fadeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.startFadeInOnMainThread(mixer: mixer)
        }
    }

    private func startFadeInOnMainThread(mixer: DWORD) {
        cancelFade()
        guard mixer != 0 else { return }

        BASS_ChannelSetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), 0)

        var currentVolume: Float = 0
        let startTime = Date()
        let tickInterval: TimeInterval = 1.0 / 60.0  // ~60Hz

        fadeTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self, mixer != 0 else { return }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / self.fadeInDuration, 1.0)
            currentVolume = Float(progress)

            BASS_ChannelSetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), currentVolume)

            if progress >= 1.0 {
                self.cancelFade()
            }
        }
    }

    private func startFadeOut(mixer: DWORD, completion: @escaping () -> Void) {
        let gen = fadeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.startFadeOutOnMainThread(mixer: mixer, completion: completion)
        }
    }

    private func startFadeOutOnMainThread(mixer: DWORD, completion: @escaping () -> Void) {
        cancelFade()
        guard mixer != 0 else {
            completion()
            return
        }

        var currentVolume: Float = 1.0
        BASS_ChannelGetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), &currentVolume)
        guard currentVolume > 0 else { completion(); return }
        let startVolume = currentVolume
        let startTime = Date()
        let tickInterval: TimeInterval = 1.0 / 60.0  // ~60Hz

        fadeTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self, mixer != 0 else { return }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / self.fadeOutDuration, 1.0)
            let newVolume = startVolume * Float(1.0 - progress)

            BASS_ChannelSetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), newVolume)

            if progress >= 1.0 {
                self.cancelFade()
                completion()
            }
        }
    }

    private func pollMetadata() {
        guard streamHandle != 0 else { return }

        // 1. ICY / Shoutcast (MP3)
        if let ptr = BASS_ChannelGetTags(streamHandle, DWORD(BASS_TAG_META)) {
            let raw = String(cString: ptr)
            if !raw.isEmpty, let title = parseICYTitle(raw), !title.isEmpty {
                print("📋  [ICY] \(title)")
                publishTitle(title)
                return
            }
        }

        // 2. Ogg Vorbis comments (OGG / FLAC)
        if let ptr = BASS_ChannelGetTags(streamHandle, DWORD(BASS_TAG_OGG)) {
            if let title = extractVorbisTitle(ptr) {
                if activeFormat == "FLAC" {
                    handleFlacTitleChange(shortTitle: title)
                    // Don't return: fall through to Icecast fetch below.
                    // The Vorbis tag can lag behind the actual track change by one poll cycle,
                    // so we always query Icecast as well. If the Vorbis title did change,
                    // handleFlacTitleChange already fires its own Icecast request; the second
                    // concurrent request is harmless (dedup'd by lastIcecastTitle).
                } else {
                    // OGG: do NOT publish the Vorbis title directly — fall through to Icecast JSON.
                    // Some shows send Format A (bracketed, per-track song name) but others send
                    // Format B (show-level venue/date metadata with no individual song info).
                    // Icecast JSON always mirrors the MP3 ICY stream which is always Format A,
                    // so routing OGG through Icecast JSON gives correct per-track names for both
                    // format variants without flashing wrong data for Format B shows.
                    _ = title  // suppress unused warning; intentionally not published
                }
            }
        }

        // 3. AAC / FLAC / OGG: fetch from Icecast JSON endpoint
        if activeFormat == "AAC" || activeFormat == "FLAC" || activeFormat == "OGG" {
            fetchIcecastMetadata()
        }
    }

    private func checkStreamStatus() {
        guard streamHandle != 0 else { return }

        let status = BASS_ChannelIsActive(streamHandle)
        let bytes  = BASS_ChannelGetPosition(streamHandle, DWORD(BASS_POS_BYTE))
        let secs   = BASS_ChannelBytes2Seconds(streamHandle, bytes)
        let bufferedBytes = BASS_StreamGetFilePosition(streamHandle, DWORD(5))

        DispatchQueue.main.async { [weak self] in
            switch Int32(status) {
            case 1:  self?.playbackState = .playing
            case 3:  self?.playbackState = .stalled
            case 0:  self?.playbackState = .stopped
            default: self?.playbackState = .connecting
            }
        }

        // FLAC buffer health: log download buffer and FX output buffer levels.
        // Note: BASS_DATA_AVAILABLE returns 0xFFFFFFFF for DECODE-mode channels (the pre-mixer),
        // so we only measure the output post-mixer (fxBuf) which has a real 0.1s fill buffer.
        if activeFormat == "FLAC", status == BASS_ACTIVE_PLAYING {
            let dlBufFill = BASS_StreamGetFilePosition(streamHandle, DWORD(5))
            let dlBufSize = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_END))
            let dlPct = dlBufSize > 0 ? Double(dlBufFill) / Double(dlBufSize) * 100 : -1

            // FX output buffer: readable fill level on the playing post-mixer (0.1s target).
            let ph = playbackHandle
            let fxAvail = ph != 0 ? BASS_ChannelGetData(ph, nil, DWORD(BASS_DATA_AVAILABLE)) : 0
            let fxBufMs = fxAvail > 0 ? Double(fxAvail) / (44100.0 * 2 * 4) * 1000 : 0

            print("📊 FLAC health: pos=\(String(format:"%.1f",secs))s dlBuf=\(String(format:"%.0f",dlPct))% fxBuf=\(String(format:"%.0f",fxBufMs))ms")

            // Trigger fade-in once the FX output buffer has ≥80ms of audio (80% of its 0.1s
            // capacity). This fires on the first health poll after BASS_ChannelPlay succeeds,
            // confirming that data is flowing from the pre-mixer through the FX chain.
            if flacPendingFadeIn, fxBufMs >= 80 {
                flacPendingFadeIn = false
                print("🔊 FLAC buffer ready (fxBuf=\(String(format:"%.0f",fxBufMs))ms) — starting fade-in")
                DispatchQueue.main.async { [weak self] in
                    self?.preBufferProgress = 0.0  // dismiss loading bar
                    self?.startFadeIn(mixer: ph)
                }
            }
        }

        if activeFormat == "AAC",
           status == BASS_ACTIVE_PLAYING,
           bufferedBytes == 0,
           bytes > 100000 {
            guard !isReconnecting else { return }
            if dvrState == .live {
                print("🔄 AAC buffer underrun detected (pos=\(String(format:"%.0f",secs)) buffered=0) — fast restart")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartStream() }
            } else {
                print("🔄 AAC buffer underrun in DVR mode — partial live restart")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.partialRestartLiveChannel() }
            }
            return
        }

        if status == BASS_ACTIVE_STOPPED {
            guard !isReconnecting else { return }
            if activeFormat == "OGG" || activeFormat == "FLAC" {
                if !oggStopConfirmed {
                    oggStopConfirmed = true
                    print("⏸️  \(activeFormat) STOPPED detected — confirming in next poll…")
                    return
                }
                oggStopConfirmed = false
            }
            let err = BASS_ErrorGetCode()
            if dvrState == .live {
                print("🔄 Stream STOPPED (err=\(err)) — fast auto restart")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartStream() }
            } else {
                print("🔄 Stream STOPPED (err=\(err)) in DVR mode — partial live restart")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.partialRestartLiveChannel() }
            }
            return
        } else {
            oggStopConfirmed = false
        }
    }

    private func restartStream() {
        print("🔄 Restarting \(activeFormat) stream...")
        // freeStream() resets dvrState → .live and cleans up DVR playback/recording.
        freeStream()

        guard let current = qualities.first(where: { $0.format == activeFormat }),
              let cURL = current.url.cString(using: .utf8) else { return }

        if current.format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 30000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }

        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)

        if current.format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }

        guard newHandle != 0 else {
            let err = BASS_ErrorGetCode()
            print("❌ restartStream: BASS_StreamCreateURL failed (err=\(err)) — scheduling reconnect")
            scheduleReconnect()
            return
        }
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }

        streamHandle = newHandle
        if current.format == "FLAC" {
            preMixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        } else {
            preMixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(44100, 2,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        }

        // Recreate StreamBuffer so recording resumes after restart (freeStream() cleared it).
        let dvrMins2 = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
        streamBuffer = StreamBuffer(maxMinutes: dvrMins2 > 0 ? dvrMins2 : 15)
        streamBuffer?.start()

        configureStreamAttributes(format: current.format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        let ph = playbackHandle
        if current.format == "FLAC" {
            // Same 10s pre-buffer as initial play — lets the ring buffer fill before decode starts.
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            flacPendingFadeIn = true
            let capturedPH = ph
            let capturedSH = newHandle
            let totalDelay: TimeInterval = 10.0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.preBufferProgress = 0.0
                self.preBufferTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.preBufferProgress = min(self.preBufferProgress + 0.1 / totalDelay, 1.0)
                }
            }
            print("   🔄 FLAC restart: pre-buffering \(Int(totalDelay))s — handle=\(capturedSH) mixer=\(mixerHandle) preMix=\(preMixerHandle)")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + totalDelay) { [weak self] in
                guard let self = self, self.streamHandle == capturedSH else { return }
                DispatchQueue.main.async {
                    self.preBufferTimer?.invalidate()
                    self.preBufferTimer = nil
                }
                print("   🎬 FLAC restart pre-buffer complete — calling BASS_ChannelPlay")
                BASS_ChannelPlay(capturedPH, 0)
                print("✅ Restarted handle=\(capturedSH) playback=\(capturedPH)")
                DispatchQueue.main.async {
                    self.playbackState = .playing
                    self.startMetadataPolling()
                }
            }
        } else {
            BASS_ChannelPlay(ph, 0)
            print("✅ Restarted handle=\(newHandle) preMix=\(preMixerHandle) mixer=\(mixerHandle) playback=\(ph)")
            DispatchQueue.main.async {
                self.playbackState = .playing
                self.startMetadataPolling()
            }
        }
    }

    // MARK: - Icecast JSON Metadata

    private func fetchIcecastMetadata() {
        guard let url = URL(string: "https://shoutcast.norbert.de/status-json.xsl") else { return }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgentString, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            guard self.activeFormat == "AAC" || self.activeFormat == "FLAC" || self.activeFormat == "OGG" else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let icestats = json["icestats"] as? [String: Any] else { return }

            let sources: [[String: Any]]
            if let arr = icestats["source"] as? [[String: Any]] {
                sources = arr
            } else if let obj = icestats["source"] as? [String: Any] {
                sources = [obj]
            } else {
                return
            }

            let mp3Source = sources.first { ($0["listenurl"] as? String)?.hasSuffix(".mp3") == true }
            let source = mp3Source ?? sources.first

            guard let title = source?["title"] as? String, !title.isEmpty else { return }

            if title != self.lastIcecastTitle {
                self.lastIcecastTitle = title
                print("🛰️  [ICECAST] \(title)")
                DispatchQueue.main.async {
                    self.publishTitle(title)
                }
            }
        }.resume()
    }

    // MARK: - FLAC Track Change

    private func handleFlacTitleChange(shortTitle: String) {
        if lastFlacTitle != shortTitle {
            print("📋  FLAC TITLE changed: '\(lastFlacTitle ?? "(none)")' -> '\(shortTitle)'")
            lastFlacTitle = shortTitle
            publishTitle(shortTitle)
            fetchIcecastMetadata()
        }
    }

    // MARK: - Audio DSP Helpers

    /// Simple 1st-order low-pass filter for 400 Hz crossover (44.1 kHz sampling).
    /// Maintains state internally; call once per sample. Used for mono center channel.
    private func lowPassFilter400Hz(_ input: Float) -> Float {
        let output = centerSpreadLPFAlpha * input + (1.0 - centerSpreadLPFAlpha) * centerSpreadLPFState
        centerSpreadLPFState = output
        return output
    }

    /// Same 400 Hz low-pass filter for the stereo side channel (S = (L−R)/2).
    /// Separate state from the center-spread filter to avoid cross-contamination.
    private func lowPassFilterSide(_ input: Float) -> Float {
        let output = centerSpreadLPFAlpha * input + (1.0 - centerSpreadLPFAlpha) * sideChannelLPFState
        sideChannelLPFState = output
        return output
    }

    // MARK: - Parsing Helpers

    private func parseICYTitle(_ raw: String) -> String? {
        if let start = raw.range(of: "StreamTitle='"),
           let end   = raw[start.upperBound...].range(of: "';") {
            let title = String(raw[start.upperBound..<end.lowerBound])
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private func extractVorbisTitle(_ ptr: UnsafePointer<CChar>) -> String? {
        var offset = ptr
        while offset.pointee != 0 {
            let tag = String(cString: offset)
            if tag.lowercased().hasPrefix("title=") {
                let val = String(tag.dropFirst(6))
                if !val.isEmpty { return val }
            }
            offset = offset.advanced(by: Int(strlen(offset)) + 1)
        }
        return nil
    }

    // MARK: - DVR Public Interface

    /// The effective buffer window for the current session, in seconds.
    /// Reads the live StreamBuffer's actual maxSegments so the UI denominator always
    /// reflects what the session is truly using — important when a decrease has been deferred.
    var dvrMaxBufferSeconds: Double {
        Double(streamBuffer?.maxSegments ?? 0) * 60.0
    }

    /// Apply a changed buffer-window setting from Settings.
    /// - Live state: recreates StreamBuffer entirely.
    /// - Paused/playing state: applies the new value if it still covers everything already
    ///   recorded (both increases and safe decreases). Defers only if the new value would
    ///   be smaller than what the user has already saved in this session.
    func updateDVRBufferSize() {
        guard let buffer = streamBuffer else { return }
        let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
        let newMax  = dvrMins > 0 ? dvrMins : 15
        guard newMax != buffer.maxSegments else { return }

        if dvrState == .live {
            buffer.stop()
            buffer.cleanup()
            streamBuffer = StreamBuffer(maxMinutes: newMax)
            streamBuffer?.start()
            print("📼 DVR buffer resized to \(newMax) min (live)")
        } else if Double(newMax) * 60.0 >= behindLiveSeconds {
            // Safe to apply: new window still covers everything already recorded.
            buffer.updateMaxSegments(newMax)
            print("📼 DVR buffer adjusted to \(newMax) min (recorded=\(Int(behindLiveSeconds))s, safe)")
        } else {
            // New value would truncate content the user could still play back — defer to next go-live.
            print("📼 DVR buffer decrease deferred (recorded \(Int(behindLiveSeconds / 60))min > new \(newMax)min)")
        }
    }

    /// Pause live output while keeping the stream + recording alive.
    /// Saves the current recording timestamp so `dvrResume()` plays from here.
    func dvrPause() {
        guard dvrState == .live else { return }
        guard mixerHandle != 0, preMixerHandle != 0 else { return }

        dvrPauseTimestamp = streamBuffer?.currentTimestamp ?? 0
        dvrState = .paused
        startBehindTimer()   // begin counting up how far behind live the user is

        // Fade the live source channel vol to 0; the output mixer vol stays at 1.0.
        // This avoids BASS output-mixer buffer smoothing that caused a double fade-in
        // when the user paused and quickly resumed (mid-fade mixer vol + DVR stream
        // ch-vol fade = two simultaneous fade-ins on non-FLAC's old 0.5s single mixer).
        let liveSource = preMixerHandle
        startFadeOut(mixer: liveSource) {
            // Ensure fully muted; stream and recording DSP remain active.
            BASS_ChannelSetAttribute(liveSource, DWORD(BASS_ATTRIB_VOL), 0)
        }
        print("⏸️ DVR paused at t=\(String(format: "%.2f", dvrPauseTimestamp))s")
    }

    /// Pause DVR playback (while in .playing state).
    /// Saves the current playback position as the new pause point so dvrResume() picks up from here.
    func dvrPausePlayback() {
        guard dvrState == .playing, let buffer = streamBuffer else { return }

        let posBytes = BASS_ChannelGetPosition(dvrPlaybackStream, DWORD(BASS_POS_BYTE))
        let posSecs  = BASS_ChannelBytes2Seconds(dvrPlaybackStream, posBytes)
        let currentRecordingTime = Double(dvrCurrentSegNum) * buffer.segmentDuration + posSecs

        // Stash the live BASS handles in dvrPausedStreams so they stay active during
        // the fade-out (the mixer needs an audio source to fade). They are freed in the
        // fade completion callback, or by dvrResume()/goLive()/freeStream() if the user
        // acts before the fade finishes.
        dvrPausedStreams = [dvrPlaybackStream, dvrNextStream].filter { $0 != 0 }
        dvrPlaybackStream = 0
        dvrNextStream = 0
        dvrMetadataTimer?.invalidate()
        dvrMetadataTimer = nil

        dvrPauseTimestamp = currentRecordingTime
        dvrState = .paused   // prevents handleDVRStreamEndMixtime from advancing the segment
        startBehindTimer()

        // Fade out the mixer, then free the streams and zero the mixer in the completion.
        let ph = mixerHandle
        startFadeOut(mixer: ph) { [weak self] in
            guard let self else { return }
            for s in self.dvrPausedStreams { BASS_StreamFree(s) }
            self.dvrPausedStreams.removeAll()
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
        }
        print("⏸️ DVR playback paused at recording t=\(String(format: "%.2f", currentRecordingTime))s")
    }

    /// Start DVR playback from the saved pause timestamp.
    /// The live stream stays muted and continues recording.
    func dvrResume() {
        // Buffer was full and cleared — go straight to live instead of resuming from files.
        if dvrBufferFull { goLive(); return }
        guard dvrState == .paused, let buffer = streamBuffer else { return }

        let stream = buffer.createPlaybackStream(from: dvrPauseTimestamp)
        guard stream != 0 else {
            print("❌ DVR: failed to create playback stream at t=\(dvrPauseTimestamp)")
            return
        }

        dvrPlaybackStream = stream
        dvrCurrentSegNum  = Int(dvrPauseTimestamp / buffer.segmentDuration)

        // Register gapless end-sync and pre-load the following segment.
        registerDVREndSync(on: stream)
        preloadDVRNextSegment()

        // Route DVR audio through the FX output mixer so EQ/compressor/stereo/limiter apply.
        // The recording DSP is on the pre-FX source (streamHandle/preMixerHandle), so it
        // continues capturing the live stream without picking up the DVR audio.
        // Silence the live source channel so only DVR audio is heard through the mixer.
        //
        // Free any streams that dvrPausePlayback() kept alive for its fade-out, in case
        // the user resumed before the fade completed (which cancels the completion callback).
        for s in dvrPausedStreams { BASS_StreamFree(s) }
        dvrPausedStreams.removeAll()
        //
        // Cancel any in-progress fade, then silence the live source so it doesn't
        // bleed through when the mixer comes back up.
        cancelFade()
        let liveSource: DWORD = preMixerHandle != 0 ? preMixerHandle : streamHandle
        if liveSource != 0 {
            BASS_ChannelSetAttribute(liveSource, DWORD(BASS_ATTRIB_VOL), 0.0)
        }
        // Add DVR stream and immediately silence its channel volume within the mixer.
        // We fade the STREAM's channel volume (not the mixer's output volume) because
        // BASS_ATTRIB_VOL on the mixer becomes unreliable after dvrPausePlayback()'s
        // fade-out on non-FLAC streams. Fading the channel vol is the robust alternative.
        BASS_Mixer_StreamAddChannel(mixerHandle, stream,
                                    DWORD(BASS_MIXER_CHAN_BUFFER | BASS_MIXER_CHAN_NORAMPIN))
        BASS_ChannelSetAttribute(stream, DWORD(BASS_ATTRIB_VOL), 0)
        // Ensure the mixer itself is at full output — both sources are at ch_vol=0 so
        // there is no burst. If the mixer was stopped (BASS_MIXER_END), restart it.
        BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 1.0)
        BASS_ChannelPlay(mixerHandle, 0)
        // Fade the DVR stream's channel volume from 0→1 directly on the main thread.
        startFadeInOnMainThread(mixer: stream)
        dvrState = .playing
        startBehindTimer()
        startDVRMetadataPolling()
        print("▶️  DVR playback started from t=\(String(format: "%.2f", dvrPauseTimestamp))s")
    }

    /// Exit DVR mode and return to the live stream immediately.
    /// The live stream is unmuted with a fade-in.
    func goLive() {
        guard dvrState != .live else { return }

        // Stop DVR playback (freeing the stream auto-removes it from mixerHandle).
        if dvrPlaybackStream != 0 {
            BASS_StreamFree(dvrPlaybackStream)
            dvrPlaybackStream = 0
        }
        if dvrNextStream != 0 {
            BASS_StreamFree(dvrNextStream)
            dvrNextStream = 0
        }
        // Free any streams kept alive for a dvrPausePlayback() fade-out that was cancelled.
        for s in dvrPausedStreams { BASS_StreamFree(s) }
        dvrPausedStreams.removeAll()
        // Restore live source volume (was silenced when DVR playback started).
        let liveSource: DWORD = preMixerHandle != 0 ? preMixerHandle : streamHandle
        if liveSource != 0 {
            BASS_ChannelSetAttribute(liveSource, DWORD(BASS_ATTRIB_VOL), 1.0)
        }
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        dvrMetadataTimer?.invalidate()
        dvrMetadataTimer = nil
        behindLiveSeconds = 0
        dvrState = .live
        lastPublishedTitle = nil
        lastIcecastTitle = nil
        lastDVRPublishedMetadata = nil

        // If the buffer filled and was cleared, recreate StreamBuffer so DVR is available
        // again immediately after returning to live (recording DSP picks up the new instance).
        if dvrBufferFull {
            dvrBufferFull = false
            let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
            streamBuffer = StreamBuffer(maxMinutes: dvrMins > 0 ? dvrMins : 15)
            streamBuffer?.start()
        }

        // FLAC: the live mixer has been muted and its download buffer stale for the duration of the
        // pause. Tear it down and do a full reconnect + pre-buffer (progress bar + fade-in) so the
        // user gets clean audio — identical to the first-play experience.
        if activeFormat == "FLAC" {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartStream() }
            print("📡 DVR → LIVE (FLAC full re-buffer)")
            return
        }

        // Non-FLAC: the live stream kept buffering while muted; just unmute with a fade-in.
        bassPollingQueue.async { [weak self] in self?.pollMetadata() }
        if preMixerHandle != 0 {
            cancelFade()                       // cancel any DVR stream ch-vol fade; advance generation
            startFadeIn(mixer: preMixerHandle) // fade live source ch-vol from 0→1
        }
        print("📡 DVR → LIVE")
    }

    // MARK: - DVR Private Helpers

    /// Called when the recording ring buffer has been completely filled.
    /// Stops and clears the recorded content, freezes the counter at the max,
    /// and sets `dvrBufferFull` so the next play press goes live rather than
    /// trying to resume from the (now-deleted) WAV files.
    private func handleDVRBufferFull(maxSecs: Double) {
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        behindLiveSeconds = maxSecs   // freeze counter at max
        dvrBufferFull = true
        streamBuffer?.stop()
        streamBuffer?.cleanup()       // delete the WAV segment files ("cleared")
        print("📼 DVR buffer full (\(Int(maxSecs / 60)) min) — recording stopped, awaiting go-live")
    }

    private func startBehindTimer() {
        dvrBehindTimer?.invalidate()
        // Fires on the main runloop so UI updates happen on the main thread.
        // Runs in both .paused (counts up as recording grows) and .playing (stays static).
        dvrBehindTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let buffer = self.streamBuffer,
                  self.dvrState != .live else { return }

            switch self.dvrState {
            case .paused:
                // While paused, behind = how much has been recorded since the pause point.
                let behind = max(0, buffer.bufferedDuration - self.dvrPauseTimestamp)
                let maxSecs = Double(buffer.maxSegments) * buffer.segmentDuration
                if behind >= maxSecs {
                    // Buffer completely full — stop recording and await user action.
                    self.handleDVRBufferFull(maxSecs: maxSecs)
                } else {
                    self.behindLiveSeconds = behind
                }
            case .playing where self.dvrPlaybackStream != 0:
                // While playing, behind = live recording head minus DVR playback position.
                // Both advance at ~1 s/s, so this value stays roughly constant.
                let posBytes = BASS_ChannelGetPosition(self.dvrPlaybackStream, DWORD(BASS_POS_BYTE))
                let posSecs  = BASS_ChannelBytes2Seconds(self.dvrPlaybackStream, posBytes)
                let currentRecordingTime = Double(self.dvrCurrentSegNum) * buffer.segmentDuration + posSecs
                self.behindLiveSeconds   = max(0, buffer.bufferedDuration - currentRecordingTime)

                // If the next segment wasn't available at resume time, retry now.
                // Once it's been recorded, preload it so the upcoming transition is gapless.
                if self.dvrNextStream == 0 { self.preloadDVRNextSegment() }
            default:
                break
            }
        }
    }

    /// Register a MIXTIME END sync on a DVR playback stream.
    /// BASS_SYNC_MIXTIME fires in the mixing thread at the exact sample boundary,
    /// enabling gapless segment transitions via handleDVRStreamEndMixtime.
    private func registerDVREndSync(on stream: DWORD) {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        BASS_ChannelSetSync(stream, DWORD(BASS_SYNC_END | BASS_SYNC_MIXTIME), 0, { _, ch, _, user in
            guard let user = user else { return }
            let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
            player.handleDVRStreamEndMixtime(oldStream: ch)
        }, userData)
    }

    /// Pre-create the stream for segment (dvrCurrentSegNum + 1) so it is ready to add
    /// to the mixer instantly when the current segment ends.  Must be called on main thread.
    private func preloadDVRNextSegment() {
        if dvrNextStream != 0 {
            BASS_StreamFree(dvrNextStream)
            dvrNextStream = 0
        }
        guard let buffer = streamBuffer else { return }
        let nextSeg = dvrCurrentSegNum + 1
        let nextTs  = Double(nextSeg) * buffer.segmentDuration
        guard nextTs < buffer.bufferedDuration else { return }
        let s = buffer.createPlaybackStream(from: nextTs)
        if s != 0 {
            dvrNextStream = s
            dvrNextSegNum = nextSeg
        }
    }

    /// Called from the BASS mixing thread (MIXTIME sync) when a DVR segment stream hits EOF.
    /// Adds the pre-loaded next segment to the mixer at the exact sample boundary (no gap),
    /// then dispatches state cleanup and next-segment pre-loading to the main thread.
    private func handleDVRStreamEndMixtime(oldStream: DWORD) {
        guard dvrState == .playing else { return }

        let nextStream = dvrNextStream  // capture before any async work
        let nextSegNum = dvrNextSegNum

        if nextStream != 0 {
            // Sample-accurate: add next stream NOW, in the mixing thread.
            // BASS_Mixer_StreamAddChannel is safe to call from MIXTIME callbacks.
            BASS_Mixer_StreamAddChannel(mixerHandle, nextStream,
                                        DWORD(BASS_MIXER_CHAN_BUFFER | BASS_MIXER_CHAN_NORAMPIN))
        }

        // Non-time-critical cleanup and pre-loading on main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dvrState == .playing else {
                // Cancelled during the async hop — free the pre-loaded stream if unused.
                if nextStream != 0 { BASS_StreamFree(nextStream) }
                return
            }

            BASS_StreamFree(oldStream)

            if nextStream != 0 {
                // Normal path: pre-loaded stream was added to mixer in MIXTIME callback.
                self.dvrPlaybackStream = nextStream
                self.dvrCurrentSegNum  = nextSegNum
                self.dvrNextStream     = 0
                self.registerDVREndSync(on: nextStream)
                self.preloadDVRNextSegment()
                print("⏭️  DVR → segment \(nextSegNum)")
            } else {
                // Fallback: preload was skipped (segment wasn't buffered yet at resume time).
                // Re-check now — the live recording may have caught up since then.
                let fallbackSeg = self.dvrCurrentSegNum + 1
                let fallbackTs  = Double(fallbackSeg) * (self.streamBuffer?.segmentDuration ?? 60.0)
                if let buffer = self.streamBuffer,
                   fallbackTs < buffer.bufferedDuration,
                   let lateStream = Optional(buffer.createPlaybackStream(from: fallbackTs)),
                   lateStream != 0 {
                    // Not sample-accurate (tiny gap possible), but far better than going live.
                    BASS_Mixer_StreamAddChannel(self.mixerHandle, lateStream,
                                                DWORD(BASS_MIXER_CHAN_BUFFER | BASS_MIXER_CHAN_NORAMPIN))
                    self.dvrPlaybackStream = lateStream
                    self.dvrCurrentSegNum  = fallbackSeg
                    self.dvrNextStream     = 0
                    self.registerDVREndSync(on: lateStream)
                    self.preloadDVRNextSegment()
                    print("⏭️  DVR → segment \(fallbackSeg) (late-open)")
                } else {
                    print("📡 DVR end-of-buffer reached — going live")
                    self.goLive()
                }
            }
        }
    }

    /// Rebuild only the live BASS stream + mixer while keeping DVR state intact.
    /// Called when the live stream dies (STOPPED or buffer underrun) during DVR pause/playback.
    /// The existing StreamBuffer keeps running, so WAV segments continue to grow and DVR
    /// playback is unaffected. The new live stream starts muted.
    private func partialRestartLiveChannel() {
        guard activeFormat != "FLAC" else {
            // FLAC two-mixer setup is too complex for a partial restart; go live as a fallback.
            DispatchQueue.main.async { self.goLive() }
            DispatchQueue.global(qos: .userInitiated).async { self.restartStream() }
            return
        }
        guard let current = qualities.first(where: { $0.format == activeFormat }),
              let cURL = current.url.cString(using: .utf8) else { return }

        print("🔄 DVR partial restart: rebuilding \(current.format) live channel (DVR state preserved)")

        cancelFade()
        stopMetadataPolling()   // also stops state polling timer
        oggStopConfirmed = false

        // Free only live BASS channels. BASS_ChannelFree removes all DSPs from the channel.
        if mixerHandle    != 0 { BASS_ChannelFree(mixerHandle);    mixerHandle    = 0 }
        if preMixerHandle != 0 { BASS_ChannelFree(preMixerHandle); preMixerHandle = 0 }
        if streamHandle   != 0 { BASS_StreamFree(streamHandle);    streamHandle   = 0 }
        stallSync = 0; endSync = 0; oggChangeSync = 0
        recordingDSP = 0; clickGuardDSP = 0; cgFadeBuffersRemaining = 0

        // Reconnect live stream.
        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        guard newHandle != 0 else {
            let err = BASS_ErrorGetCode()
            print("❌ DVR partial restart: BASS_StreamCreateURL failed (err=\(err)) — scheduling reconnect")
            scheduleReconnect()
            return
        }
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }

        streamHandle = newHandle
        preMixerHandle = BASS_Mixer_StreamCreate(44100, 2,
            DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
        BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
            DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
        mixerHandle = BASS_Mixer_StreamCreate(44100, 2, DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
        BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
            DWORD(BASS_MIXER_CHAN_BUFFER))

        // applyEffects inside configureStreamAttributes re-attaches the recording DSP.
        // self.streamBuffer is still alive, so recording continues without interruption.
        configureStreamAttributes(format: current.format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        // Start live source muted — DVR state controls when it unmutes.
        // Output mixer vol stays at 1.0 so any DVR stream still in the mixer plays through.
        BASS_ChannelSetAttribute(preMixerHandle, DWORD(BASS_ATTRIB_VOL), 0)
        BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 1.0)
        BASS_ChannelPlay(mixerHandle, 0)

        DispatchQueue.main.async {
            self.playbackState = .playing
            self.startMetadataPolling()
        }
        print("✅ DVR partial restart complete — dvrState=\(dvrState) seg=\(dvrCurrentSegNum)")
    }

    // MARK: - DVR Metadata Playback

    /// Consult the journal for the current DVR playback position and fire `onMetadataUpdate`
    /// if the track has changed. Called on the main thread.
    private func publishDVRMetadata() {
        guard dvrState == .playing, let buffer = streamBuffer, dvrPlaybackStream != 0 else { return }

        let posBytes = BASS_ChannelGetPosition(dvrPlaybackStream, DWORD(BASS_POS_BYTE))
        let posSecs  = BASS_ChannelBytes2Seconds(dvrPlaybackStream, posBytes)
        let currentRecordingTime = Double(dvrCurrentSegNum) * buffer.segmentDuration + posSecs

        // Find the latest journal entry at or before the current playback position.
        guard let entry = dvrMetadataJournal.last(where: { $0.timestamp <= currentRecordingTime }),
              entry.metadata != lastDVRPublishedMetadata else { return }

        lastDVRPublishedMetadata = entry.metadata
        print("📼 DVR metadata @ t=\(String(format: "%.1f", currentRecordingTime))s → \(entry.metadata)")
        onMetadataUpdate?(entry.metadata)
    }

    /// Start polling the metadata journal for DVR playback position every 3 s.
    /// Fires once immediately so the UI updates without waiting for the first tick.
    private func startDVRMetadataPolling() {
        dvrMetadataTimer?.invalidate()
        publishDVRMetadata()   // immediate update on resume
        dvrMetadataTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.dvrState == .playing else { return }
            self.publishDVRMetadata()
        }
    }

    // MARK: - Publish

    private func publishTitle(_ title: String) {
        print("🎵  \(title)")

        // Journal every track change with its recording timestamp so DVR playback can
        // replay track info at the correct position.  All journal mutations run on the
        // main thread to keep reads (DVR timer, also main) data-race-free.
        if let buffer = streamBuffer {
            let ts = buffer.currentTimestamp
            DispatchQueue.main.async { self.dvrMetadataJournal.append((timestamp: ts, metadata: title)) }
        }

        // In DVR mode the live metadata is NOT what the user is hearing.
        // Suppress live updates; the DVR metadata timer publishes historical track info.
        guard dvrState == .live else { return }

        // Only fire callback if title actually changed (dedup repeated polls)
        guard title != lastPublishedTitle else { return }
        lastPublishedTitle = title
        DispatchQueue.main.async {
            self.isPlaying = true
            self.onMetadataUpdate?(title)
        }
    }
}
