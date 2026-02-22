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
    private var oggStopConfirmed = false

    // MARK: - Timers

    private var metadataTimer: Timer?
    private var stateTimer: Timer?
    private let metaPollInterval: TimeInterval = 3.0
    private let statePollInterval: TimeInterval = 0.25

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
    private var stereoDSP: HDSP = 0
    private var limiterDSP: HDSP = 0

    var eqLowGain:  Float = 0
    var eqMidGain:  Float = 0
    var eqHighGain: Float = 0

    var compressorOn:     Bool  = false
    var compressorAmount: Float = 0.5

    var stereoWidth: Float = 0.75
    var stereoPan:   Float = 0.5

    var eqEnabled:          Bool = true
    var stereoWidthEnabled: Bool = true
    var masterBypassEnabled: Bool = false

    var stereoWidthCoeff: Float {
        stereoWidth <= 0.75
            ? stereoWidth / 0.75
            : 1.0 + (stereoWidth - 0.75) / 0.25
    }

    // MARK: - Init / Deinit

    override init() {
        super.init()

        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)  // Increased from 15s for FLAC resilience on mobile
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 20)    // Reduced from 30% to keep startup time similar (~same byte threshold)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), 10000)
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), 5000)
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
        DispatchQueue.main.async {
            self.currentQuality = ""
            self.isPlaying = false
            self.playbackState = .stopped
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
            streamHandle = BASS_FLAC_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
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
        BASS_Mixer_StreamAddChannel(mixerHandle, streamHandle, DWORD(BASS_MIXER_CHAN_NORAMPIN))

        activeFormat = format

        configureStreamAttributes(format: format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        print("   handle=\(streamHandle) mixer=\(mixerHandle) — calling BASS_ChannelPlay on mixer…")
        BASS_ChannelPlay(mixerHandle, 0)

        DispatchQueue.main.async {
            self.currentQuality = format
            self.isPlaying = true
            self.playbackState = .connecting
        }

        startMetadataPolling()
    }

    private func freeStream() {
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
        stereoDSP = 0
        limiterDSP = 0
    }

    // MARK: - Stream Attributes

    private func configureStreamAttributes(format: String, handle: DWORD) {
        let bufferSeconds: Float
        switch format {
        case "MP3":  bufferSeconds = 1.0
        case "OGG":  bufferSeconds = 2.0
        case "AAC":  bufferSeconds = 1.5
        case "FLAC": bufferSeconds = 5.0
        default:     bufferSeconds = 1.0
        }
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_BUFFER), bufferSeconds)

        let netResume: Float = 25
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), netResume)

        var actualBuf: Float = 0
        BASS_ChannelGetAttribute(handle, DWORD(BASS_ATTRIB_BUFFER), &actualBuf)
        var actualResume: Float = 0
        BASS_ChannelGetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), &actualResume)
        let dlBufBytes = BASS_StreamGetFilePosition(handle, DWORD(5))
        let dlBufSize  = BASS_StreamGetFilePosition(handle, DWORD(BASS_FILEPOS_END))
        let mixerBuffer: Float = format == "FLAC" ? 0.5 : 0.1
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

        if compressorOn {
            compressorFX = BASS_ChannelSetFX(handle, DWORD(BASS_FX_BFX_COMPRESSOR2), 0)
            applyCompressorParams()
        }

        stereoDSP = BASS_ChannelSetDSP(
            handle,
            { _, _, buffer, length, user in
                guard let buffer = buffer, let user = user else { return }
                let player     = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                guard player.stereoWidthEnabled, !player.masterBypassEnabled else { return }
                let coeff      = player.stereoWidthCoeff
                let pOffset    = (player.stereoPan - 0.5) * 2.0
                let applyWidth = coeff != 1.0
                let applyPan   = pOffset != 0.0
                guard applyWidth || applyPan else { return }
                let samples    = buffer.assumingMemoryBound(to: Float.self)
                let count      = Int(length) / MemoryLayout<Float>.size
                let a: Float = pOffset < 0 ? -pOffset : 0.0
                let b: Float = pOffset > 0 ?  pOffset : 0.0
                let sinA: Float = sin(a * .pi / 2.0)
                let cosA: Float = cos(a * .pi / 2.0)
                let sinB: Float = sin(b * .pi / 2.0)
                let cosB: Float = cos(b * .pi / 2.0)
                var i = 0
                while i + 1 < count {
                    var L = samples[i], R = samples[i + 1]
                    if applyWidth {
                        let M = (L + R) * 0.5
                        let S = (L - R) * 0.5
                        L = M + S * coeff
                        R = M - S * coeff
                    }
                    if applyPan {
                        let L2 = L, R2 = R
                        L = L2 * cosB + R2 * sinA
                        R = L2 * sinB + R2 * cosA
                    }
                    samples[i]     = L
                    samples[i + 1] = R
                    i += 2
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
                let threshold: Float = 0.89
                let knee: Float = 0.11
                for i in 0..<count {
                    let x    = samples[i]
                    let absX = x < 0 ? -x : x
                    if absX > threshold {
                        let sign: Float  = x > 0 ? 1.0 : -1.0
                        let excess       = absX - threshold
                        let limited      = threshold + knee * (1.0 - 1.0 / (1.0 + excess / knee))
                        samples[i]       = sign * limited
                    }
                }
            },
            userData,
            -1
        )
        print("🎛️  Effects applied — eqFX=\(eqFX) compFX=\(compressorFX) stereoDSP=\(stereoDSP) limiterDSP=\(limiterDSP)")
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
        let t = compressorAmount
        var p = BASS_BFX_COMPRESSOR2()
        p.fThreshold = -8  + (-15) * t
        p.fRatio     = 1.5  + 6.5   * t
        p.fAttack    = 25   - 22    * t
        p.fRelease   = 300  - 220   * t
        p.fGain      = (-p.fThreshold) * (1.0 - 1.0 / p.fRatio) * (0.5 + 0.25 * t)
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
    }

    func updateCompressor() {
        if compressorOn {
            if compressorFX == 0, mixerHandle != 0 {
                compressorFX = BASS_ChannelSetFX(mixerHandle, DWORD(BASS_FX_BFX_COMPRESSOR2), 0)
            }
            applyCompressorParams()
        } else {
            if compressorFX != 0 {
                BASS_ChannelRemoveFX(mixerHandle, compressorFX)
                compressorFX = 0
            }
        }
    }

    func updateCompressorAmount() {
        applyCompressorParams()
    }

    func resetAllFX() {
        masterBypassEnabled = false
        eqEnabled           = true
        eqLowGain           = 0
        eqMidGain           = 0
        eqHighGain          = 0
        compressorOn        = false
        compressorAmount    = 0.5
        stereoWidthEnabled  = true
        stereoWidth         = 0.75
        stereoPan           = 0.5
        updateEQ()
        updateCompressor()
    }

    func updateMasterBypass() {
        updateEQ()
        if masterBypassEnabled {
            if compressorFX != 0 {
                BASS_ChannelRemoveFX(mixerHandle, compressorFX)
                compressorFX = 0
            }
        } else {
            if compressorOn, compressorFX == 0, mixerHandle != 0 {
                compressorFX = BASS_ChannelSetFX(mixerHandle, DWORD(BASS_FX_BFX_COMPRESSOR2), 0)
                applyCompressorParams()
            }
        }
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
            oggChangeSync = BASS_ChannelSetSync(
                handle,
                DWORD(BASS_SYNC_OGG_CHANGE),
                0,
                { _, channel, _, user in
                    guard let user = user else { return }
                    let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                    player.handleOggChangeSync(channel: channel)
                },
                userData
            )
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync) oggChange=\(oggChangeSync)")
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
        print("🔀  BASS_SYNC_OGG_CHANGE fired — new bitstream (track change)")
        DispatchQueue.main.async { [weak self] in
            self?.pollMetadata()
        }
    }

    // MARK: - Metadata Polling

    private func startMetadataPolling() {
        stopMetadataPolling()
        pollMetadata()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: metaPollInterval, repeats: true) { [weak self] _ in
            self?.pollMetadata()
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
            self?.checkStreamStatus()
        }
    }

    private func stopStatePolling() {
        stateTimer?.invalidate()
        stateTimer = nil
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
                } else {
                    publishTitle(title)
                }
                return
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
            newHandle = BASS_FLAC_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        } else {
            newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        }

        guard newHandle != 0 else { return }

        streamHandle = newHandle
        mixerHandle = BASS_Mixer_StreamCreate(44100, 2, DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
        BASS_Mixer_StreamAddChannel(mixerHandle, streamHandle, DWORD(BASS_MIXER_CHAN_NORAMPIN))
        configureStreamAttributes(format: current.format, handle: streamHandle)
        setupSyncs(for: streamHandle)
        BASS_ChannelPlay(mixerHandle, 0)
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
        DispatchQueue.main.async {
            self.isPlaying = true
            self.onMetadataUpdate?(title)
        }
    }
}
