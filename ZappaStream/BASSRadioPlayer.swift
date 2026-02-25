import Foundation
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
    private let bassPollingQueue = DispatchQueue(label: "com.zappastream.bass-polling", qos: .utility)
    private let metaPollInterval: TimeInterval = 3.0
    private let statePollInterval: TimeInterval = 2.0
    private let fadeInDuration: TimeInterval = 0.5
    private let fadeOutDuration: TimeInterval = 0.4
    /// How long to run FLAC muted before unmuting, giving BASS_MIXER_CHAN_BUFFER time to fill.
    private let flacPreBufferDuration: TimeInterval = 4.0

    // MARK: - Stream URLs

    let qualities: [(format: String, url: String)] = [
        ("MP3",  "https://shoutcast.norbert.de/zappa.mp3"),
        ("OGG",  "https://shoutcast.norbert.de/zappa.ogg"),
        ("AAC",  "https://shoutcast.norbert.de/zappa.aac"),
        ("FLAC", "https://shoutcast.norbert.de/zappa.flac"),
    ]

    // MARK: - Audio Effects

    private var eqFX: HFX = 0
    private var compressorFX: HFX = 0
    private var levelMeterDSP: HDSP = 0
    private var stereoDSP: HDSP = 0
    private var limiterDSP: HDSP = 0
    private var clickGuardDSP: HDSP = 0

    // MARK: - Click Guard (OGG/FLAC bitstream boundary click suppression)
    // The mixtime OGG_CHANGE sync sets this counter to 2; the DSP callback decrements
    // it each buffer. Buffer 1 = fade out (end of old track), buffer 2 = fade in (start
    // of new track). Together they crossfade across the boundary.
    private var cgFadeBuffersRemaining: Int = 0

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

    // MARK: - Frequency-Dependent Center Spreading (400 Hz crossover)
    private var centerSpreadLPFState: Float = 0.0  // Low-pass filter state for mono center channel
    private let centerSpreadCrossoverHz: Float = 400.0
    // Precomputed filter coefficient for 400 Hz @ 44.1 kHz (1st-order butterworth)
    // alpha = 2*pi*f / (2*pi*f + sr) ≈ 0.0556 for 400 Hz @ 44.1 kHz
    private let centerSpreadLPFAlpha: Float = 0.0556

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

        // Faster update thread (default 100ms → 5ms): the BASS update thread pre-decodes audio
        // into the BASS_MIXER_CHAN_BUFFER async buffer. With 5ms cycles the buffer stays
        // consistently topped up, minimising the chance of any momentary decode or scheduling
        // hiccup propagating to the output — benefits all formats but critical for FLAC.
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), 5)
        // Larger device output buffer (default ~40ms → 150ms): final defense before hardware.
        // Trivial latency for a radio stream, but absorbs any upstream pipeline hiccup that
        // makes it past the decode and mixer buffers.
        BASS_SetConfig(DWORD(BASS_CONFIG_DEV_BUFFER), 150)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)  // 25s download buffer for mobile resilience
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)    // Wait for 50% of net buffer before starting (~reduces initial stutter)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), 10000)
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), 5000)
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
        guard mixerHandle != 0 else { stop(); return }
        let capturedMixer = mixerHandle
        startFadeOut(mixer: capturedMixer) { [weak self] in
            self?.stop()
        }
    }

    // MARK: - Internal Playback

    private func switchQuality(_ format: String) {
        guard let entry = qualities.first(where: { $0.format == format }) else { return }
        print("\n🔊 ── SWITCHING TO \(format) ──────────────────────────")
        print("   URL: \(entry.url)")

        freeStream()

        guard let cURL = entry.url.cString(using: .utf8) else { return }

        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        if format == "FLAC" {
            // FLAC is ~900 kbps — burns through the download buffer 7× faster than MP3.
            // Set a 60s download buffer and 75% prebuf so playback doesn't start until
            // ~45s of compressed data is already downloaded. Restore defaults after connecting.
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 60000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 75)
            streamHandle = BASS_FLAC_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        } else {
            streamHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        }

        if streamHandle == 0 {
            let err = BASS_ErrorGetCode()
            print("❌  Stream creation failed (error \(err))")
            DispatchQueue.main.async {
                self.playbackState = .error(err)
                self.isPlaying = false
            }
            return
        }

        mixerHandle = BASS_Mixer_StreamCreate(44100, 2, DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
        // BASS_MIXER_CHAN_BUFFER: BASS's update thread pre-decodes into a background buffer
        // asynchronously. This keeps decoded audio ready so FX parameter changes take effect
        // immediately when the mixer re-renders, rather than waiting for synchronous decode.
        // BASS_MIXER_CHAN_NORAMPIN: disables initial volume ramp at channel start (non-FLAC only;
        // FLAC uses fade-in after pre-buffer delay instead).
        // Note: BASS_MIXER_CHAN_NORAMPIN only affects channel *start*, not OGG/FLAC bitstream
        // boundaries, so there is no built-in BASS protection against track-change clicks.
        var addFlags = DWORD(BASS_MIXER_CHAN_BUFFER)
        if format != "FLAC" { addFlags |= DWORD(BASS_MIXER_CHAN_NORAMPIN) }
        BASS_Mixer_StreamAddChannel(mixerHandle, streamHandle, addFlags)

        activeFormat = format

        configureStreamAttributes(format: format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        print("   handle=\(streamHandle) mixer=\(mixerHandle) — calling BASS_ChannelPlay on mixer…")
        if format == "FLAC" {
            // Start muted so the BASS_MIXER_CHAN_BUFFER decode buffer can fill before any audio
            // reaches the hardware. The update thread fills the buffer while we're "playing" silently.
            // BASS_CONFIG_NET_PREBUF is ignored by the FLAC plugin, so this is the reliable path.
            BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPlay(mixerHandle, 0)
            let capturedMixer = mixerHandle
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + flacPreBufferDuration) { [weak self] in
                guard let self, self.mixerHandle == capturedMixer, capturedMixer != 0 else { return }
                self.startFadeIn(mixer: capturedMixer)
                print("🔊 FLAC pre-buffer complete — starting fade-in")
            }
        } else {
            BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPlay(mixerHandle, 0)
            startFadeIn(mixer: mixerHandle)
        }

        DispatchQueue.main.async {
            self.currentQuality = format
            self.isPlaying = true
            self.playbackState = .connecting
        }

        startMetadataPolling()
    }

    private func freeStream() {
        cancelFade()
        stopMetadataPolling()
        oggStopConfirmed = false
        lastFlacTitle = nil
        lastIcecastTitle = nil
        if mixerHandle != 0 {
            BASS_ChannelStop(mixerHandle)
            BASS_StreamFree(mixerHandle)
            print("⏹  mixer freed (handle was \(mixerHandle))")
            mixerHandle = 0
        }
        if streamHandle != 0 {
            BASS_ChannelStop(streamHandle)
            BASS_StreamFree(streamHandle)
            print("⏹  stream freed (handle was \(streamHandle))")
            streamHandle = 0
        }
        eqFX = 0
        compressorFX = 0
        levelMeterDSP = 0
        stereoDSP = 0
        limiterDSP = 0
        rmsAccumulator = 0
        rmsSampleCount = 0
        lastAppliedThreshold = 0
        clickGuardDSP = 0
        cgFadeBuffersRemaining = 0
    }

    // MARK: - Stream Attributes

    private func configureStreamAttributes(format: String, handle: DWORD) {
        let bufferSeconds: Float
        switch format {
        case "MP3":  bufferSeconds = 1.0
        case "OGG":  bufferSeconds = 2.0
        case "AAC":  bufferSeconds = 1.5
        case "FLAC": bufferSeconds = 8.0
        default:     bufferSeconds = 1.0
        }
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_BUFFER), bufferSeconds)

        // 25% NET_RESUME: resume downloading after a stall once 25% of the net buffer refills.
        // Lower = faster recovery, which is better when the output buffer is large enough to bridge the gap.
        let netResume: Float = 25
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), netResume)

        var actualBuf: Float = 0
        BASS_ChannelGetAttribute(handle, DWORD(BASS_ATTRIB_BUFFER), &actualBuf)
        var actualResume: Float = 0
        BASS_ChannelGetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), &actualResume)
        let dlBufBytes = BASS_StreamGetFilePosition(handle, DWORD(5))
        let dlBufSize  = BASS_StreamGetFilePosition(handle, DWORD(BASS_FILEPOS_END))
        let mixerBuffer: Float
        switch format {
        case "FLAC": mixerBuffer = 4.0   // FLAC decode is CPU-heavy; needs more headroom than lighter codecs
        case "OGG":  mixerBuffer = 0.5
        default:     mixerBuffer = 0.5   // MP3, AAC — low enough for responsive FX, high enough to avoid audio-thread scheduling gaps
        }
        BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_BUFFER), mixerBuffer)

        print("⚙️  configureStreamAttributes format=\(format) buffer=\(actualBuf)s netResume=\(actualResume)% dlBuf=\(dlBufBytes)/\(dlBufSize) mixerBuf=\(mixerBuffer)s")

        applyEffects(to: mixerHandle)
    }

    // MARK: - Audio Effects

    private func applyEffects(to handle: DWORD) {
        let userData = Unmanaged.passUnretained(self).toOpaque()

        eqFX = BASS_ChannelSetFX(handle, DWORD(BASS_FX_BFX_PEAKEQ), 0)
        applyEQBand(0, center: 100,   gain: eqLowGain)
        applyEQBand(1, center: 1000,  gain: eqMidGain)
        applyEQBand(2, center: 10000, gain: eqHighGain)

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
        if compressorOn && !masterBypassEnabled {
            applyCompressorParams()
        } else {
            applyCompressorPassthrough()
        }

        stereoDSP = BASS_ChannelSetDSP(
            handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                guard player.stereoWidthEnabled, !player.masterBypassEnabled else { return }

                let targetCoeff = player.stereoWidthCoeff
                let targetPan   = (player.stereoPan - 0.5) * 2.0

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
                        L = M + S * coeff
                        R = M - S * coeff

                        // Frequency-Dependent Center Spreading
                        let M_lowFreq  = player.lowPassFilter400Hz(M)
                        let M_highFreq = M - M_lowFreq
                        let spreadAmount = (coeff - 1.0) * 0.15
                        L += M_highFreq * spreadAmount
                        R -= M_highFreq * spreadAmount
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
        // Click guard DSP: runs after limiter (priority -2). When the mixtime OGG_CHANGE
        // sync arms cgFadeBuffersRemaining=2, this DSP applies fades across two consecutive
        // buffers: fade-out on the first (end of old track), fade-in on the second (start
        // of new track). Together they crossfade across the bitstream boundary.
        clickGuardDSP = BASS_ChannelSetDSP(
            handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let p = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                guard p.cgFadeBuffersRemaining > 0 else { return }

                let remaining = p.cgFadeBuffersRemaining
                p.cgFadeBuffersRemaining -= 1

                let samples = buffer.assumingMemoryBound(to: Float.self)
                let count = Int(length) / MemoryLayout<Float>.size
                let frames = count / 2  // stereo frame count
                // Fade only the last/first 10ms of each buffer (not the full 100ms).
                // The click is at the junction of the two buffers.
                let fadeDuration = min(441, frames)  // 441 frames ≈ 10ms @ 44.1 kHz

                if remaining == 2 {
                    // First buffer: fade out only the TAIL (last 10ms) → 1.0 to 0.0
                    let startFrame = frames - fadeDuration
                    let startSample = startFrame * 2
                    for i in stride(from: startSample, to: count - 1, by: 2) {
                        let fadeFrame = (i / 2) - startFrame
                        let gain = 1.0 - Float(fadeFrame) / Float(fadeDuration)
                        samples[i]     *= gain
                        samples[i + 1] *= gain
                    }
                    print("🔕  click guard: fade-OUT tail (\(String(format: "%.1f", Double(fadeDuration) / 44.1))ms)")
                } else {
                    // Second buffer: fade in only the HEAD (first 10ms) → 0.0 to 1.0
                    for i in stride(from: 0, to: min(fadeDuration * 2, count) - 1, by: 2) {
                        let fadeFrame = i / 2
                        let gain = Float(fadeFrame) / Float(fadeDuration)
                        samples[i]     *= gain
                        samples[i + 1] *= gain
                    }
                    print("🔕  click guard: fade-IN head (\(String(format: "%.1f", Double(fadeDuration) / 44.1))ms)")
                }
            },
            userData,
            -2
        )
        print("🎛️  Effects applied — eqFX=\(eqFX) compFX=\(compressorFX) levelDSP=\(levelMeterDSP) stereoDSP=\(stereoDSP) limiterDSP=\(limiterDSP) clickGuardDSP=\(clickGuardDSP)")
    }

    private func applyEQBand(_ band: Int32, center: Float, gain: Float) {
        guard eqFX != 0 else { return }
        var p = BASS_BFX_PEAKEQ()
        p.lBand      = band
        p.fCenter    = center
        p.fBandwidth = 1.0
        p.fQ         = 0
        p.fGain      = gain
        p.lChannel   = -1
        BASS_FXSetParameters(eqFX, &p)
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

    // MARK: - Public FX Update Methods

    func updateEQ() {
        if eqEnabled && !masterBypassEnabled {
            applyEQBand(0, center: 100,   gain: eqLowGain)
            applyEQBand(1, center: 1000,  gain: eqMidGain)
            applyEQBand(2, center: 10000, gain: eqHighGain)
        } else {
            applyEQBand(0, center: 100,   gain: 0)
            applyEQBand(1, center: 1000,  gain: 0)
            applyEQBand(2, center: 10000, gain: 0)
        }
        flushEffects()
        saveFXToDefaults()
    }

    func updateCompressor() {
        if compressorOn && !masterBypassEnabled {
            applyCompressorParams()
        } else {
            applyCompressorPassthrough()
        }
        flushEffects()
        saveFXToDefaults()
    }

    func updateCompressorAmount() {
        if compressorOn && !masterBypassEnabled {
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
        guard mixerHandle != 0 else { return }
        BASS_ChannelUpdate(mixerHandle, 0)
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
            // Use BASS_Mixer_ChannelSetSync with BASS_SYNC_MIXTIME so the callback fires
            // during mixing — at the exact sample position of the bitstream boundary.
            // In the callback we set a volume envelope via BASS_Mixer_ChannelSetEnvelope
            // that dips at the boundary position. This is sample-accurate because the
            // envelope operates within the mixer's sample pipeline, before the output buffer.
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
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync) oggChange=\(oggChangeSync) (via Mixer_ChannelSetSync, mixtime+envelope)")
        } else {
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
        print("🏁  BASS_SYNC_END fired for channel \(channel) — event-based restart")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.restartStream()
        }
    }

    private func handleOggChangeSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }
        // Set flag for the click guard DSP — it runs in the same mixer render cycle,
        // so it will process the buffer containing the boundary before it reaches output.
        cgFadeBuffersRemaining = 2
        print("🔀  OGG_CHANGE mixtime: armed click guard for 2 buffers")
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
    }

    private func startFadeIn(mixer: DWORD) {
        DispatchQueue.main.async { [weak self] in
            self?.startFadeInOnMainThread(mixer: mixer)
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
        DispatchQueue.main.async { [weak self] in
            self?.startFadeOutOnMainThread(mixer: mixer, completion: completion)
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
        let startTime = Date()
        let tickInterval: TimeInterval = 1.0 / 60.0  // ~60Hz

        fadeTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self, mixer != 0 else { return }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / self.fadeOutDuration, 1.0)
            let newVolume = Float(1.0 - progress)

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
                    publishTitle(title)
                    return
                }
            }
        }

        // 3. AAC / FLAC: fetch from Icecast JSON endpoint
        if activeFormat == "AAC" || activeFormat == "FLAC" {
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

        // FLAC buffer health: log download buffer fill % every poll so we can correlate
        // with audible stutters. If dlFill% drops low, the network can't keep up with
        // FLAC's ~900 kbps; if it stays healthy, the problem is downstream (decode/mixer).
        if activeFormat == "FLAC", status == BASS_ACTIVE_PLAYING {
            let dlBufSize = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_END))
            let dlFill = dlBufSize > 0 ? Double(bufferedBytes) / Double(dlBufSize) * 100 : 0
            print("📊 FLAC health: pos=\(String(format:"%.1f",secs))s dlBuf=\(String(format:"%.0f",dlFill))% (\(bufferedBytes)/\(dlBufSize))")
        }

        if activeFormat == "AAC",
           status == BASS_ACTIVE_PLAYING,
           bufferedBytes == 0,
           bytes > 100000 {
            print("🔄 AAC buffer underrun detected (pos=\(String(format:"%.0f",secs)) buffered=0) — fast restart")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.restartStream()
            }
            return
        }

        if status == BASS_ACTIVE_STOPPED {
            if activeFormat == "OGG" || activeFormat == "FLAC" {
                if !oggStopConfirmed {
                    oggStopConfirmed = true
                    print("⏸️  \(activeFormat) STOPPED detected — confirming in next poll…")
                    return
                }
                oggStopConfirmed = false
            }
            let err = BASS_ErrorGetCode()
            print("🔄 Stream STOPPED (err=\(err)) — fast auto restart")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.restartStream()
            }
            return
        } else {
            oggStopConfirmed = false
        }
    }

    private func restartStream() {
        print("🔄 Restarting \(activeFormat) stream...")
        freeStream()

        guard let current = qualities.first(where: { $0.format == activeFormat }),
              let cURL = current.url.cString(using: .utf8) else { return }

        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle: DWORD
        if current.format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 60000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 75)
            newHandle = BASS_FLAC_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        } else {
            newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        }

        guard newHandle != 0 else { return }

        streamHandle = newHandle
        mixerHandle = BASS_Mixer_StreamCreate(44100, 2, DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
        var restartAddFlags = DWORD(BASS_MIXER_CHAN_BUFFER)
        if current.format != "FLAC" { restartAddFlags |= DWORD(BASS_MIXER_CHAN_NORAMPIN) }
        BASS_Mixer_StreamAddChannel(mixerHandle, streamHandle, restartAddFlags)
        configureStreamAttributes(format: current.format, handle: streamHandle)
        setupSyncs(for: streamHandle)
        if current.format == "FLAC" {
            BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPlay(mixerHandle, 0)
            let capturedMixer = mixerHandle
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + flacPreBufferDuration) { [weak self] in
                guard let self, self.mixerHandle == capturedMixer, capturedMixer != 0 else { return }
                self.startFadeIn(mixer: capturedMixer)
                print("🔊 FLAC pre-buffer complete (restart) — starting fade-in")
            }
        } else {
            BASS_ChannelPlay(mixerHandle, 0)
        }
        print("✅ Restarted handle=\(newHandle) mixer=\(mixerHandle)")
        DispatchQueue.main.async {
            self.playbackState = .playing
            self.startMetadataPolling()
        }
    }

    // MARK: - Icecast JSON Metadata

    private func fetchIcecastMetadata() {
        guard let url = URL(string: "https://shoutcast.norbert.de/status-json.xsl") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            guard self.activeFormat == "AAC" || self.activeFormat == "FLAC" else { return }

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
    /// Maintains state internally; call once per sample.
    private func lowPassFilter400Hz(_ input: Float) -> Float {
        let output = centerSpreadLPFAlpha * input + (1.0 - centerSpreadLPFAlpha) * centerSpreadLPFState
        centerSpreadLPFState = output
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

    // MARK: - Publish

    private func publishTitle(_ title: String) {
        print("🎵  \(title)")
        // Only fire callback if title actually changed (dedup repeated polls)
        guard title != lastPublishedTitle else { return }
        lastPublishedTitle = title
        DispatchQueue.main.async {
            self.isPlaying = true
            self.onMetadataUpdate?(title)
        }
    }
}
