import Foundation
#if os(macOS)
import Bass
import BassMix
#endif

// MARK: - Metadata Polling & Publishing

extension BASSRadioPlayer {

    // MARK: - Polling Lifecycle

    func startMetadataPolling() {
        stopMetadataPolling()
        bassPollingQueue.async { [weak self] in self?.pollMetadata() }
        metadataTimer = Timer.scheduledTimer(withTimeInterval: metaPollInterval, repeats: true) { [weak self] _ in
            self?.bassPollingQueue.async { self?.pollMetadata() }
        }
        startStatePolling()
    }

    func stopMetadataPolling() {
        metadataTimer?.invalidate()
        metadataTimer = nil
        stopStatePolling()
    }

    func startStatePolling() {
        stopStatePolling()
        stateTimer = Timer.scheduledTimer(withTimeInterval: statePollInterval, repeats: true) { [weak self] _ in
            self?.bassPollingQueue.async { self?.checkStreamStatus() }
        }
    }

    func stopStatePolling() {
        stateTimer?.invalidate()
        stateTimer = nil
    }

    // MARK: - Metadata Polling

    func pollMetadata() {
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

    // MARK: - Stream Status Polling

    func checkStreamStatus() {
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

    // MARK: - Icecast JSON Metadata

    func fetchIcecastMetadata() {
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

    func handleFlacTitleChange(shortTitle: String) {
        if lastFlacTitle != shortTitle {
            print("📋  FLAC TITLE changed: '\(lastFlacTitle ?? "(none)")' -> '\(shortTitle)'")
            lastFlacTitle = shortTitle
            publishTitle(shortTitle)
            fetchIcecastMetadata()
        }
    }

    // MARK: - Parsing Helpers

    func parseICYTitle(_ raw: String) -> String? {
        if let start = raw.range(of: "StreamTitle='"),
           let end   = raw[start.upperBound...].range(of: "';") {
            let title = String(raw[start.upperBound..<end.lowerBound])
            return title.isEmpty ? nil : title
        }
        return nil
    }

    func extractVorbisTitle(_ ptr: UnsafePointer<CChar>) -> String? {
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

    func publishTitle(_ title: String) {
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
