import Foundation
#if os(macOS)
import Bass
import BassMix
#endif

// MARK: - DVR Ring Buffer Playback (macOS only)

extension BASSRadioPlayer {

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

        // Register the pause segment as protected so the ring buffer stops cleanly before
        // overwriting it. When the ring fills, onBufferFull fires handleDVRBufferFull on main.
        if let buffer = streamBuffer {
            let segDur      = buffer.segmentDuration
            let maxSegs     = buffer.maxSegments
            let pauseSegIdx = Int(dvrPauseTimestamp / segDur) % maxSegs
            let maxSecs     = Double(maxSegs) * segDur
            buffer.setStopBeforeSegment(index: pauseSegIdx) { [weak self] in
                guard let self, self.dvrState == .paused else { return }
                self.handleDVRBufferFull(maxSecs: maxSecs)
            }
        }

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
        // Buffer was full: if the 15-min window has expired, go live; otherwise play the buffer.
        if dvrBufferFull && dvrBufferFullExpired { goLive(); return }
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

        // If the buffer filled (stream was paused to stop network activity), clean up the
        // WAV files and recreate StreamBuffer so DVR recording restarts immediately from live.
        let wasBufferFull = dvrBufferFull
        if dvrBufferFull {
            dvrBufferFull = false
            dvrBufferFullExpired = false
            dvrBufferExpiryTimer?.invalidate()
            dvrBufferExpiryTimer = nil
            streamBuffer?.cleanup()       // delete the preserved WAV segment files
            let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
            streamBuffer = StreamBuffer(maxMinutes: dvrMins > 0 ? dvrMins : 15)
            streamBuffer?.start()
        }

        // FLAC always restarts from scratch. Non-FLAC also restarts when the live stream was
        // paused (buffer-full): the paused channel has no usable download buffer, so a fresh
        // connect is identical to a normal play-from-stopped experience.
        if activeFormat == "FLAC" || wasBufferFull {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartStream() }
            print("📡 DVR → LIVE (full restart)")
            return
        }

        // Normal DVR unpause (stream was never paused): unmute with a fade-in.
        bassPollingQueue.async { [weak self] in self?.pollMetadata() }
        if preMixerHandle != 0 {
            cancelFade()                       // cancel any DVR stream ch-vol fade; advance generation
            startFadeIn(mixer: preMixerHandle) // fade live source ch-vol from 0→1
        }
        print("📡 DVR → LIVE")
    }

    // MARK: - DVR Private Helpers

    /// Called when the recording ring buffer has been completely filled.
    /// Stops recording (flushing and closing segment files) but keeps the WAV files on disk
    /// so the user can play back the full buffer within a 15-minute window.
    /// After that window the UI reverts to a "live" appearance and pressing play goes live.
    func handleDVRBufferFull(maxSecs: Double) {
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        // Freeze at actual playable content from the pause point. bufferedDuration is now
        // a clean segment boundary (overshoot removed by StreamBuffer). dvrPauseTimestamp
        // may be nonzero if the user paused partway into the first recorded segment, giving
        // slightly less than maxSecs; this avoids a jump when the behind timer restarts on play.
        behindLiveSeconds = max(0, maxSecs - dvrPauseTimestamp)
        dvrBufferFull = true
        streamBuffer?.stop()          // idempotent: StreamBuffer already stopped itself via stopBeforeSegmentIndex
        // Stop metadata + state polling (includes FLAC health check) — no longer needed.
        stopMetadataPolling()
        // Pause the live download channel for all formats to stop network activity.
        // goLive() will do a full stream restart (restartStream()) when wasBufferFull is true.
        #if os(macOS)
        if streamHandle != 0 {
            BASS_ChannelPause(streamHandle)
        }
        #endif
        // Start a 15-minute window during which the user can press play to watch the buffer.
        dvrBufferExpiryTimer?.invalidate()
        dvrBufferExpiryTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
            guard let self, self.dvrBufferFull else { return }
            DispatchQueue.main.async { self.dvrBufferFullExpired = true }
            print("📼 DVR buffer playback window expired — next play press will go live")
        }
        print("📼 DVR buffer full (\(Int(maxSecs / 60)) min) — recording stopped; 15-min playback window open")
    }

    func startBehindTimer() {
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
                // Buffer-full is signalled by StreamBuffer.setStopBeforeSegment callback —
                // not detected here, so we just update the display.
                let behind = max(0, buffer.bufferedDuration - self.dvrPauseTimestamp)
                self.behindLiveSeconds = behind
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
    func registerDVREndSync(on stream: DWORD) {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        BASS_ChannelSetSync(stream, DWORD(BASS_SYNC_END | BASS_SYNC_MIXTIME), 0, { _, ch, _, user in
            guard let user = user else { return }
            let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
            player.handleDVRStreamEndMixtime(oldStream: ch)
        }, userData)
    }

    /// Pre-create the stream for segment (dvrCurrentSegNum + 1) so it is ready to add
    /// to the mixer instantly when the current segment ends.  Must be called on main thread.
    func preloadDVRNextSegment() {
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
    func handleDVRStreamEndMixtime(oldStream: DWORD) {
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
    func partialRestartLiveChannel() {
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
    func publishDVRMetadata() {
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
    func startDVRMetadataPolling() {
        dvrMetadataTimer?.invalidate()
        publishDVRMetadata()   // immediate update on resume
        dvrMetadataTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.dvrState == .playing else { return }
            self.publishDVRMetadata()
        }
    }
}
