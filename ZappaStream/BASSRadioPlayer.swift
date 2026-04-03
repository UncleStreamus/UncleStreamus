import Foundation
import Network
#if os(macOS)
import Bass
import BassFLAC
import BassFX
import BassMix
#else
import UIKit
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

    var streamHandle: DWORD = 0
    var mixerHandle: DWORD = 0
    var preMixerHandle: DWORD = 0  // All formats: DECODE-mode pre-mixer; stutter buffer (3s FLAC, 0.3s others) + click guard
    var preBufferProgress: Double = 0.0    // 0.0–1.0 during FLAC pre-buffer; drives UI progress bar
    var preBufferTimer: Timer?     // updates preBufferProgress every 100ms during FLAC pre-buffer wait
    var stallSync: HSYNC = 0
    var endSync: HSYNC = 0
    var oggChangeSync: HSYNC = 0
    var metaChangeSync: HSYNC = 0

    // MARK: - Metadata State

    var activeFormat = ""
    var lastFlacTitle: String?
    var lastOGGVorbisTitle: String?
    var lastIcecastTitle: String?
    var lastPublishedTitle: String?
    var oggStopConfirmed = false

    // MARK: - Timers

    var metadataTimer: Timer?
    var stateTimer: Timer?
    var fadeTimer: Timer?
    var fadeGeneration: Int = 0   // incremented by cancelFade(); guards stale async dispatches
    let bassPollingQueue = DispatchQueue(label: "com.zappastream.bass-polling", qos: .utility)
    let metaPollInterval: TimeInterval = 3.0
    let statePollInterval: TimeInterval = 2.0
    let fadeInDuration: TimeInterval = 0.5
    let fadeOutDuration: TimeInterval = 0.4

    // MARK: - Network Resilience

    var pathMonitor: NWPathMonitor?
    let networkMonitorQueue = DispatchQueue(label: "com.zappastream.network-monitor", qos: .utility)

    /// Background task token used on iOS to keep the app alive during reconnect
    /// after audio output stops (network loss while locked).
    #if os(iOS)
    var bgReconnectTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// True only while the user intends playback to be active.
    /// Set true in switchQuality(); false only in stop() / stopWithFadeOut().
    /// freeStream() and restartStream() must NOT touch this.
    var isUserIntendedPlay: Bool = false

    /// True while a reconnect attempt is scheduled or in-flight (drives UI).
    var isReconnecting: Bool = false

    /// Current attempt number (1-based). Reset to 0 on success or explicit stop.
    var reconnectAttempt: Int = 0

    var reconnectTimer: DispatchSourceTimer?

    // Flat 5s retry interval, giving up after 12 attempts (~1 minute total).
    let reconnectRetryInterval: TimeInterval = 5
    let reconnectMaxAttempts: Int = 12
    /// How long to run FLAC muted before unmuting, giving the mixer output buffer time to fill.
    /// FLAC fade-in is triggered by checkStreamStatus() when playback buffer is sufficiently filled,
    /// not by a fixed timer. This flag tracks whether we're waiting for that condition.
    var flacPendingFadeIn = false

    // MARK: - Stream URLs

    let qualities: [(format: String, url: String)] = [
        ("MP3",       "https://shoutcast.norbert.de/zappa.mp3"),
        ("OGG",       "https://shoutcast.norbert.de/zappa.ogg"),
        ("AAC",       "https://shoutcast.norbert.de/zappa.aac"),
        ("FLAC",      "https://shoutcast.norbert.de/zappa.flac"),
    ]

    // MARK: - Audio Effects

    var eqLowFX:  HFX = 0   // BASS_BFX_BQF_LOWSHELF  @ 120 Hz
    var eqMidFX:  HFX = 0   // BASS_BFX_BQF_PEAKINGEQ @ 1800 Hz
    var eqHighFX: HFX = 0   // BASS_BFX_BQF_HIGHSHELF @ 7500 Hz
    var compressorFX: HFX = 0
    var levelMeterDSP: HDSP = 0
    var stereoDSP: HDSP = 0
    var limiterDSP: HDSP = 0
    var clickGuardDSP: HDSP = 0

    // MARK: - Click Guard (OGG/FLAC/MP3)
    // OGG/FLAC: BASS_SYNC_OGG_CHANGE (MIXTIME) fires at bitstream boundaries — sample-accurate.
    //   Guard = silence (1 buf ~20ms) + fade-in (2 bufs ~40ms) = ~60ms total.
    // MP3: BASS_SYNC_META (MIXTIME) fires on ICY metadata change — NOT sample-accurate.
    //   Two-phase guard:
    //   Phase 1 — Immediate gate: 1 silence buf + 2 fade-in bufs (~60ms total) fires the moment
    //     SYNC triggers, covering subtle artifacts (MDCT overlap, DC step) near the metadata
    //     position. These produce spikes ≤2.0 and can't be reliably detected; the unconditional
    //     gate is the only safe approach (same strategy as OGG/FLAC).
    //   Phase 2 — Post-gate scan: after the initial gate completes, a 600ms scan window watches
    //     for late-arriving detectable artifacts (spike > 4.0 via max|d2|/RMS). When one is
    //     found, a second identical gate fires. If nothing is found, scan expires silently.
    //   Together these cover both immediate-position artifacts and late-arriving MDCT splices.
    // AAC: no click guard.
    var lastMetaSyncTitle: String?    // tracks last ICY title seen by BASS_SYNC_META callback
    let cgFadeBufferCount    = 1      // OGG/FLAC/MP3 fade-in buffers (~20ms)
    let cgSilenceBufferCount = 1      // OGG/FLAC/MP3 silent buffers: buf 1 = fade-out (~20ms); no hard-zero (scan catches late splices)
    var cgFadeBuffersRemaining: Int = 0   // gate buffers remaining (OGG/FLAC/MP3 shared)
    var cgMP3ScanActive: Bool       = false
    var cgMP3ScanEnd:    Double     = 0   // systemUptime when scan expires
    var cgMP3ScanEMA:    Float      = 0   // EMA of D2 spike values (primed at 1.0 on arm)
    var cgMP3ScanRMSEMA: Float      = 0   // EMA of per-buffer RMS (primed at 1.0 on arm)
    var cgScanPrevL:     Float      = 0   // last L sample of previous scan buffer (cross-buffer d2)
    var cgScanPrevPrevL: Float      = 0   // second-to-last L sample (cross-buffer d2)
    var cgMP3SpikeCount: Int        = 0   // consecutive scan buffers with spike > 1.0 (sustained detector)
    var cgSyncTime:      Double     = 0   // systemUptime when SYNC fired (for logging)
    var cgLastGuardTime: Double     = 0   // debounce: systemUptime of last armed guard

    // MARK: - FLAC Download Buffer Refill Pause
    // When dlBuf falls below a threshold at a track boundary, freeze the stream channel
    // inside the pre-mixer so the download buffer can refill without interrupting recording.
    let bufferRefillThreshold: Double   = 4.0   // dlBuf% below which to trigger
    let bufferRefillTrackInterval: Int  = 3     // minimum track changes between pauses
    let bufferRefillDuration: TimeInterval = 2.5 // must stay < 3.0s (FLAC pre-mixer buffer) to avoid recording gaps
    var trackChangeCount: Int           = 0
    var isRefillPausing: Bool           = false

    // MARK: - FLAC Network Recovery
    // When dlBuf drops below 20% while playing FLAC, a recovery stream is pre-created
    // so it can start downloading while the old buffer plays out. When the old stream
    // goes STOPPED, the recovery stream is activated in-place (no 10s pre-buffer).
    var recoveryStreamHandle: DWORD = 0
    var isAttemptingRecovery: Bool  = false
    var recoveryStartTime: Date?    = nil
    /// True while the recovery stream's download ring buffer is filling back up after a network
    /// drop. The recovery stream is paused (BASS_MIXER_CHAN_PAUSE) in the pre-mixer so no data
    /// is consumed until the buffer reaches the target threshold, matching initial-connect behaviour.
    var flacRebufferingAfterRecovery = false

    var eqLowGain:  Float = 0
    var eqMidGain:  Float = 0
    var eqHighGain: Float = 0

    // MARK: - Master Volume

    var masterVolume: Float = {
        guard UserDefaults.standard.object(forKey: "masterVolume") != nil else { return 1.0 }
        return UserDefaults.standard.float(forKey: "masterVolume")
    }()

    func setMasterVolume(_ volume: Float) {
        masterVolume = max(0.0, min(1.0, volume))
        UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
        BASS_SetConfig(DWORD(BASS_CONFIG_GVOL_STREAM), DWORD(masterVolume * 10000))
    }

    func volumeUp() { setMasterVolume(masterVolume + 0.1) }
    func volumeDown() { setMasterVolume(masterVolume - 0.1) }

    var compressorOn:     Bool  = false
    var compressorAmount: Float = 0.25

    // MARK: - Adaptive Compressor (program-dependent threshold)
    // A level-measurement DSP computes a slow-moving RMS average of the input signal.
    // The compressor threshold is set relative to this average, so it compresses
    // proportionally regardless of whether the track is quiet or loud.
    var measuredRMSdB: Float = -20.0       // Current program level (dBFS), slow-moving
    var rmsAccumulator: Float = 0.0        // Running sum-of-squares for current window
    var rmsSampleCount: Int = 0            // Samples accumulated so far
    let rmsWindowSamples: Int = 66150      // ~1.5s window @ 44.1 kHz (stereo frames)
    var lastAppliedThreshold: Float = 0.0  // Avoid redundant BASS_FXSetParameters calls

    var stereoWidth: Float = 0.75
    var stereoPan:   Float = 0.5

    var eqEnabled:          Bool = true
    var stereoWidthEnabled: Bool = true
    var masterBypassEnabled: Bool = false

    // MARK: - Stereo DSP Parameter Smoothing
    // Per-buffer exponential smoothing with linear interpolation within each buffer
    // prevents pops/clicks from abrupt parameter jumps at buffer boundaries.
    var smoothedStereoCoeff: Float = 1.0   // Tracks stereoWidthCoeff
    var smoothedPanOffset:   Float = 0.0   // Tracks (stereoPan - 0.5) * 2.0

    // MARK: - Frequency-Dependent Stereo Processing (400 Hz and 3.5 kHz crossovers)
    var centerSpreadLPFState:  Float = 0.0  // Low-pass filter state for mono center channel
    var sideChannelLPFState:   Float = 0.0  // Low-pass filter state for side channel (low/mid crossover ~400 Hz)
    var sideChannelMidLPFState: Float = 0.0 // Low-pass filter state for side channel (mid/high crossover ~3.5 kHz)
    let centerSpreadCrossoverHz: Float = 400.0
    // alpha = 2*pi*f / (2*pi*f + sr) ≈ 0.0556 for 400 Hz @ 44.1 kHz
    let centerSpreadLPFAlpha: Float = 0.0556
    // alpha = 2*pi*3500 / (2*pi*3500 + 44100) ≈ 0.333 for 3.5 kHz @ 44.1 kHz
    let sideChannelMidLPFAlpha: Float = 0.333

    // MARK: - Mono Stereo Synthesis (2-stage APF cascade for broad phase coverage)
    // Two APF stages in series (both g = -0.75) double the phase accumulation,
    // shifting the 90° crossover from ~5 kHz to ~2.5 kHz (centre of the audible band).
    // Above ~5 kHz the cascade exceeds 180°, biasing slightly right — balancing the
    // below-2.5 kHz left bias. Net result: much more even spread L and R across typical music.
    // Classic L+=, R-= M/S synthesis is retained; the cascade output drives both.
    var synthAPFInput:   Float = 0.0   // Stage 1 x[n-1]
    var synthAPFOutput:  Float = 0.0   // Stage 1 y[n-1]
    var synthAPF2Input:  Float = 0.0   // Stage 2 x[n-1]
    var synthAPF2Output: Float = 0.0   // Stage 2 y[n-1]
    var smoothedMonoFraction: Float = 0.0  // Per-buffer mono detection (0=stereo, 1=mono)
    let synthAPFCoeff: Float = -0.75   // APF coefficient for both stages
    // High-pass filter applied to M before the APF cascade — shapes widening by frequency:
    //   < 100 Hz → −12 dB (barely spread)   ~400 Hz → −3 dB (somewhat)   > 1 kHz → < −1 dB (most)
    // α = fs / (fs + 2π·fc) = 44100 / (44100 + 2π·400) ≈ 0.946
    var synthHPFInput:  Float = 0.0
    var synthHPFOutput: Float = 0.0
    let synthHPFAlpha:  Float = 0.9461

    // MARK: - Center Spread APF (symmetric high-freq spread for right channel)
    // R channel gets APF-shifted M_highFreq rather than -M_highFreq so it also
    // gains high-frequency content (decorrelated from L) instead of losing it.
    var spreadAPFInput:  Float = 0.0
    var spreadAPFOutput: Float = 0.0

    // MARK: - DVR
    // macOS only at runtime; properties must be unconditionally declared so @Observable
    // macro can generate correct accessor code (macro-expanded files have no #if guards).

    enum DVRState { case live, paused, playing }

    /// Current DVR mode. `.live` = normal streaming, `.paused` = live stream muted
    /// while recording continues, `.playing` = playing back from WAV ring buffer.
    /// Always `.live` on iOS (DVR feature not implemented there yet).
    var dvrState: DVRState = .live

    /// How many seconds behind live the current DVR playback position is.
    var behindLiveSeconds: TimeInterval = 0

    var streamBuffer:       StreamBuffer?  = nil
    var recordingDSP:       DWORD          = 0
    var dvrPlaybackStream:  DWORD          = 0
    var dvrNextStream:      DWORD          = 0   // pre-loaded next segment (gapless)
    var dvrPausedStreams:   [DWORD]        = []  // streams kept alive during dvrPausePlayback() fade-out
    var dvrPauseTimestamp:  Double         = 0
    var dvrCurrentSegNum:   Int            = 0
    var dvrNextSegNum:      Int            = 0
    var dvrBehindTimer:     Timer?         = nil

    // DVR metadata journal — maps recording timestamps to raw metadata strings.
    // Populated by publishTitle() during live streaming; consulted during DVR playback
    // to replay track-change notifications at the correct recorded position.
    // All reads/writes happen on the main thread (append dispatched from publishTitle).
    var dvrMetadataJournal: [(timestamp: Double, metadata: String)] = []
    var lastDVRPublishedMetadata: String? = nil
    var dvrMetadataTimer: Timer? = nil
    var dvrBufferFull: Bool = false        // set when recording fills the window
    var dvrBufferFullExpired: Bool = false // set after 15-min playback window elapses
    var dvrBufferExpiryTimer: Timer? = nil

    // Keeps DVREndSyncContext objects alive while BASS holds raw pointers to them.
    // Keys are DVR stream handles; values are the context objects. Entries removed
    // when the corresponding stream is freed (so objects outlive their BASS channels).
    var dvrSyncContexts: [DWORD: AnyObject] = [:]

    // MARK: - FX Blend (smooth on/off transitions)
    // Ramp blend 0→1 (passthrough→active) over ~83ms when toggling compressor/EQ or master bypass.
    // Prevents clicks/pops caused by abrupt compressor state jumps or filter coefficient changes.
    var compressorBlend: Float = 0.0     // 0 = passthrough, 1 = fully active
    var compressorBlendGoal: Float = 0.0 // desired target
    var eqBlend: Float = 1.0             // 0 = all bands at 0 dB, 1 = active gains
    var eqBlendGoal: Float = 1.0
    var fxRampTimer: Timer?

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
        BASS_SetConfig(DWORD(BASS_CONFIG_GVOL_STREAM), DWORD(masterVolume * 10000))
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
        #if os(iOS)
        endBackgroundReconnectTask()
        #endif
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

    /// Public entry point for ContentViews to request an immediate reconnect
    /// (e.g., foreground resume, AVAudioSession interruption end, macOS wake).
    func triggerImmediateReconnect() {
        guard isUserIntendedPlay else { return }
        print("🔄 triggerImmediateReconnect called")
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = true }
        bassPollingQueue.async { [weak self] in
            guard let self = self else { return }
            // Skip if stream is already active and playing — avoids disrupting a healthy
            // stream or double-restarting when both scenePhase and NWPathMonitor fire together.
            if self.isStreamActive && BASS_ChannelIsActive(self.streamHandle) == DWORD(BASS_ACTIVE_PLAYING) {
                // For FLAC: use the network-change signal as the earliest possible trigger to
                // pre-create a recovery stream in the background. This gives it the full remaining
                // download-buffer lifetime (e.g. ~8s at dlBuf=32%) to refill before we need it,
                // minimising the rebuffer wait after the old stream drains.
                if self.activeFormat == "FLAC", !self.isAttemptingRecovery, self.recoveryStreamHandle == 0,
                   !self.flacRebufferingAfterRecovery {
                    print("🔄 triggerImmediateReconnect: FLAC stream playing — pre-starting recovery stream")
                    self.isAttemptingRecovery = true
                    self.recoveryStartTime = Date()
                    self.startFlacRecovery()
                } else {
                    print("🔄 triggerImmediateReconnect: stream already playing — skipping")
                }
                DispatchQueue.main.async { self.isReconnecting = false }
                return
            }
            // If FLAC recovery is already in progress (stream stalled/stopped while recovery
            // stream is downloading or rebuffering), don't disrupt it with a full restart —
            // the STOPPED handler and rebuffer logic will complete the handoff.
            if self.activeFormat == "FLAC",
               self.isAttemptingRecovery || self.recoveryStreamHandle != 0 || self.flacRebufferingAfterRecovery {
                print("🔄 triggerImmediateReconnect: FLAC recovery in progress — skipping restart")
                DispatchQueue.main.async { self.isReconnecting = false }
                return
            }
            self.restartStream()
        }
    }

    // MARK: - Internal Helpers

    /// The handle to use for playback control (volume, play/stop, FX, DSP).
    /// All formats use the mixer, so this is always mixerHandle when playing.
    var playbackHandle: DWORD { mixerHandle != 0 ? mixerHandle : streamHandle }

    /// True when BASS has a valid stream set up (not torn down).
    var isStreamActive: Bool { streamHandle != 0 && mixerHandle != 0 }
}
