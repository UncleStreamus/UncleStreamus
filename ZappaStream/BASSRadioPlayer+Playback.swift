import Foundation
import Network
#if os(macOS)
import Bass
import BassFLAC
import BassFX
import BassMix
#endif

// MARK: - Stream Lifecycle, Network Resilience & Fade

extension BASSRadioPlayer {

    // MARK: - Stream Creation

    func switchQuality(_ format: String) {
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

    // MARK: - Stream Teardown

    func freeStream() {
        fxRampTimer?.invalidate()
        fxRampTimer = nil
        cancelFade()
        stopMetadataPolling()
        oggStopConfirmed = false
        trackChangeCount = 0
        isRefillPausing  = false
        lastFlacTitle = nil
        lastOGGVorbisTitle = nil
        lastIcecastTitle = nil
        lastMetaSyncTitle = nil

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
        dvrSyncContexts.removeAll()

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
        cgMP3ScanActive = false
        cgMP3ScanEnd = 0
        cgMP3ScanEMA    = 0
        cgMP3ScanRMSEMA = 0
        cgScanPrevL     = 0
        cgScanPrevPrevL = 0
        cgMP3SpikeCount = 0
        cgSyncTime = 0
        cgLastGuardTime = 0
        flacPendingFadeIn = false

        if recoveryStreamHandle != 0 {
            BASS_Mixer_ChannelRemove(recoveryStreamHandle)
            BASS_StreamFree(recoveryStreamHandle)
            recoveryStreamHandle = 0
        }
        isAttemptingRecovery = false
        recoveryStartTime = nil

        // Channels are now stopped — safe to tear down StreamBuffer.
        recordingDSP = 0
        streamBuffer?.stop()
        streamBuffer?.cleanup()
        streamBuffer = nil
        dvrState = .live
        dvrBufferFull = false
        dvrBufferFullExpired = false
        dvrBufferExpiryTimer?.invalidate()
        dvrBufferExpiryTimer = nil
        behindLiveSeconds = 0
        dvrCurrentSegNum = 0
        dvrNextSegNum    = 0
        dvrPauseTimestamp = 0
        dvrMetadataJournal.removeAll()
        lastDVRPublishedMetadata = nil
    }

    // MARK: - Stream Attributes

    func configureStreamAttributes(format: String, handle: DWORD) {
        let ph = playbackHandle  // Always mixerHandle when playing (output post-mixer for FLAC, single mixer for others)

        let netResume: Float = 25
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), netResume)

        // All formats use two-mixer pipeline: pre-mixer gets a stutter-protection buffer;
        // the FX output mixer gets 0.1s so EQ/compressor changes are heard within ~100ms.
        // FLAC: 3.0s — absorbs decode jitter from high-bitrate FLAC frames.
        // OGG: 1.5s — OGG bitstream chain boundaries cause a ~0.4s decoder reinit gap
        //   (BASS fires two OGG_CHANGE events ~0.4s apart while headers are processed).
        //   0.3s was smaller than this gap, causing pre-mixer underruns → stutter.
        // MP3/AAC: 0.3s — no bitstream boundaries; 0.3s is ample.
        if mixerHandle != 0 {
            let preMixBuf: Float = format == "FLAC" ? 3.0 : (format == "OGG" ? 1.5 : 0.3)
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

    // MARK: - BASS Syncs

    func setupSyncs(for handle: DWORD) {
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
        } else if activeFormat == "MP3" {
            // MP3: use BASS_SYNC_META to detect ICY metadata changes as a proxy
            // for track boundaries. Arms the same click guard DSP used by OGG/FLAC.
            metaChangeSync = BASS_Mixer_ChannelSetSync(
                handle,
                DWORD(BASS_SYNC_META) | DWORD(BASS_SYNC_MIXTIME),
                0,
                { _, channel, _, user in
                    guard let user = user else { return }
                    let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                    player.handleMetaChangeSync(channel: channel)
                },
                userData
            )
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync) metaChange=\(metaChangeSync) (mixer, mixtime)")
        } else {
            // AAC: no bitstream boundaries or ICY metadata; no click guard.
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync)")
        }
    }

    func handleStallSync(channel: DWORD) {
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

    func handleEndSync(channel: DWORD) {
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

    func handleMetaChangeSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }

        // Read current ICY metadata from the stream
        guard let ptr = BASS_ChannelGetTags(channel, DWORD(BASS_TAG_META)) else { return }
        guard let title = parseICYTitle(String(cString: ptr)), !title.isEmpty else { return }

        // Only arm guard when title actually changes
        guard title != lastMetaSyncTitle else { return }
        lastMetaSyncTitle = title

        // Debounce (same 1.5s window as OGG/FLAC)
        let now = ProcessInfo.processInfo.systemUptime
        if now - cgLastGuardTime < 1.5 { return }
        cgLastGuardTime = now

        // Phase 1: immediate gate covers subtle/undetectable artifacts at the SYNC position.
        // Phase 2: post-gate scan watches for late detectable artifacts (absolute spike > 4.0
        //   OR relative spike > 3× EMA — catches local outliers like a 2.0 spike vs 0.4 baseline).
        cgFadeBuffersRemaining = cgSilenceBufferCount + cgFadeBufferCount  // immediate ~60ms gate
        cgMP3ScanActive = true
        cgMP3ScanEnd = now + 1.2   // 1200ms scan window (covers ~650ms observed metadata-to-splice lead)
        cgMP3ScanEMA    = 1.0       // primed high to prevent false trigger on very first buffer
        cgMP3ScanRMSEMA = 1.0       // primed high to prevent false trigger on very first buffer
        cgScanPrevL     = 0         // reset cross-buffer d2 state; gate's last fade-in will overwrite
        cgScanPrevPrevL = 0
        cgMP3SpikeCount = 0
        cgSyncTime = now
        print("🛡️  MP3 guard armed (60ms + scan) — title: \(title)")
    }

    func handleOggChangeSync(channel: DWORD) {
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

    func performRefillPause() {
        guard activeFormat == "FLAC", !isRefillPausing else { return }
        let ph = playbackHandle
        let sh = streamHandle
        guard ph != 0, sh != 0, case .playing = playbackState else { return }
        isRefillPausing = true
        print("⏸️ FLAC dlBuf low — freezing stream in pre-mixer \(bufferRefillDuration)s to refill")
        // Mute the output mixer so the user hears silence.
        BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
        // Freeze the stream channel inside the pre-mixer — BASS stops consuming the download
        // buffer while the pre-mixer itself keeps running (recording DSP unaffected).
        // The pre-mixer has a 3s buffer; bufferRefillDuration must stay < 3s to avoid silence
        // reaching the recording DSP. We use 2.5s (0.5s safety margin).
        BASS_Mixer_ChannelFlags(sh, DWORD(BASS_MIXER_CHAN_PAUSE), DWORD(BASS_MIXER_CHAN_PAUSE))
        DispatchQueue.main.asyncAfter(deadline: .now() + bufferRefillDuration) { [weak self] in
            guard let self = self else { return }
            self.isRefillPausing = false
            guard case .playing = self.playbackState, self.playbackHandle == ph, self.streamHandle == sh else { return }
            // Unfreeze the stream — resume consuming download buffer from where it left off.
            BASS_Mixer_ChannelFlags(sh, 0, DWORD(BASS_MIXER_CHAN_PAUSE))
            self.startFadeIn(mixer: ph)
        }
    }

    // MARK: - FLAC Network Recovery

    /// Called when dlBuf drops below 20% during FLAC playback. Creates a new HTTP stream
    /// and adds it muted to the existing pre-mixer so it can download in the background
    /// while the old buffer plays out. Called on bassPollingQueue.
    func startFlacRecovery() {
        guard activeFormat == "FLAC",
              streamHandle != 0,
              preMixerHandle != 0,
              let current = qualities.first(where: { $0.format == "FLAC" }),
              let cURL = current.url.cString(using: .utf8) else {
            isAttemptingRecovery = false
            recoveryStartTime = nil
            return
        }

        print("🔄 FLAC recovery: dlBuf < 20% — pre-creating recovery stream")

        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 30000)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        let streamErr = BASS_ErrorGetCode()  // capture before SetConfig overwrites it
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), 25000)

        guard newHandle != 0 else {
            print("❌ FLAC recovery: stream creation failed (err=\(streamErr)) — will fall back to normal restart")
            isAttemptingRecovery = false
            recoveryStartTime = nil
            return
        }

        // Add to pre-mixer muted — it downloads in background while old stream plays out.
        BASS_Mixer_StreamAddChannel(preMixerHandle, newHandle,
            DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
        BASS_ChannelSetAttribute(newHandle, DWORD(BASS_ATTRIB_VOL), 0)

        recoveryStreamHandle = newHandle
        print("🔄 FLAC recovery: stream \(newHandle) added to pre-mixer (muted) — downloading…")
    }

    /// Swaps the pre-created recovery stream in place of the exhausted old stream.
    /// Avoids the full 10s pre-buffer restart. Called on bassPollingQueue.
    func activateRecoveryStream(handle: DWORD) {
        let elapsed = recoveryStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recoveryStartTime = nil
        print("🔄 FLAC recovery: activating stream \(handle) (downloaded \(String(format:"%.1f", elapsed))s)")

        // Remove and free the exhausted old stream from the pre-mixer.
        let oldHandle = streamHandle
        if oldHandle != 0 {
            BASS_Mixer_ChannelRemove(oldHandle)
            BASS_ChannelStop(oldHandle)
            BASS_StreamFree(oldHandle)
            print("🔄 FLAC recovery: old stream \(oldHandle) freed")
        }

        // Swap in the recovery stream.
        streamHandle = handle

        // Re-register syncs on the new stream handle (old syncs auto-removed when stream was freed).
        setupSyncs(for: handle)

        // Reset metadata dedup so the new stream's first track fires a callback.
        lastFlacTitle = nil
        lastOGGVorbisTitle = nil
        lastIcecastTitle = nil

        // Unmute recovery stream in the pre-mixer, then mute FX output and wait for
        // buffer to fill (same fade-in trigger as initial FLAC play).
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_VOL), 1.0)
        BASS_ChannelSetAttribute(playbackHandle, DWORD(BASS_ATTRIB_VOL), 0)
        flacPendingFadeIn = true

        DispatchQueue.main.async { [weak self] in
            self?.playbackState = .playing
        }
        print("✅ FLAC recovery: stream \(handle) active — fade-in pending buffer fill")
    }

    // MARK: - Stream Restart

    func restartStream() {
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

    // MARK: - Network Resilience

    func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            guard path.status == .satisfied, self.isUserIntendedPlay else { return }
            self.bassPollingQueue.async {
                // Re-check on the serial queue so we don't start multiple restarts
                // if NWPathMonitor fires several times before handles are set.
                guard !self.isStreamActive else { return }
                print("🌐 Network restored — triggering immediate reconnect")
                self.cancelReconnectTimer()
                self.reconnectAttempt = 0
                self.restartStream()
            }
        }
        monitor.start(queue: networkMonitorQueue)
    }

    func scheduleReconnect() {
        guard isUserIntendedPlay else { return }
        guard reconnectAttempt < reconnectMaxAttempts else {
            print("❌ Reconnect giving up after \(reconnectMaxAttempts) attempts (~1 minute)")
            DispatchQueue.main.async {
                self.isReconnecting = false
                self.playbackState = .stopped
            }
            return
        }
        let delay = reconnectRetryInterval
        reconnectAttempt += 1
        print("⏳ Reconnect attempt \(reconnectAttempt)/\(reconnectMaxAttempts) scheduled in \(Int(delay))s")
        DispatchQueue.main.async {
            self.isReconnecting = true
            self.playbackState = .connecting
        }
        cancelReconnectTimer()
        let timer = DispatchSource.makeTimerSource(queue: bassPollingQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isUserIntendedPlay else { return }
            // Skip if a concurrent source (e.g. triggerImmediateReconnect) already
            // created a new stream while this timer was waiting in the queue.
            guard !self.isStreamActive else {
                print("⏩ Reconnect timer fired but stream already active — skipping")
                return
            }
            self.restartStream()
        }
        timer.resume()
        reconnectTimer = timer
    }

    func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Fade In / Fade Out

    func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeGeneration &+= 1
    }

    func startFadeIn(mixer: DWORD) {
        let gen = fadeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.startFadeInOnMainThread(mixer: mixer)
        }
    }

    func startFadeInOnMainThread(mixer: DWORD) {
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

    func startFadeOut(mixer: DWORD, completion: @escaping () -> Void) {
        let gen = fadeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.startFadeOutOnMainThread(mixer: mixer, completion: completion)
        }
    }

    func startFadeOutOnMainThread(mixer: DWORD, completion: @escaping () -> Void) {
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
}
