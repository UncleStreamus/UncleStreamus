//
//  BASSRadioPlayerLogic.swift
//  UncleStreamus
//
//  Pure, BASS-free decision logic extracted from BASSRadioPlayer and its
//  extensions. These functions were previously inline in checkStreamStatus(),
//  scheduleReconnect(), restartStream() and updateDVRBufferSize() — places that
//  can't be unit-tested directly because they touch the BASS C API and live
//  audio hardware. The predicates and arithmetic, however, are pure: given a few
//  scalar inputs they return a decision. They live here so there is a single,
//  testable source of truth, mirroring the ContentViewShared.swift pattern.
//
//  Nothing here imports BASS or mutates state — the BASSRadioPlayer methods keep
//  their thin shells (read BASS values in, apply side effects out) and call into
//  these for every branch decision. Behavior is unchanged.
//

import Foundation

enum BASSRadioPlayerLogic {

    // MARK: - Playback State Mapping

    /// Maps a raw `BASS_ChannelIsActive` status to the app's `PlaybackState`.
    /// BASS status values: 0 = stopped, 1 = playing, 3 = stalled; anything else
    /// (paused / paused-device) is treated as still connecting.
    static func playbackState(forActiveStatus status: UInt32) -> PlaybackState {
        switch Int32(status) {
        case 1:  return .playing
        case 3:  return .stalled
        case 0:  return .stopped
        default: return .connecting
        }
    }

    // MARK: - Auto-Restart Predicates

    /// AAC buffer-underrun signal: BASS still reports PLAYING but the download
    /// buffer has fully drained after we'd already decoded a meaningful amount.
    /// `bufferedBytes == 0` after `positionBytes > 100 KB` reliably means the
    /// network feed died mid-stream. (The caller separately bails if a reconnect
    /// is already in flight.)
    static func isAACUnderrun(statusIsPlaying: Bool,
                              bufferedBytes: UInt64,
                              positionBytes: UInt64) -> Bool {
        statusIsPlaying
            && bufferedBytes == 0
            && positionBytes > 100_000
    }

    /// Outcome of the decode-position staleness check: catches network loss where
    /// BASS keeps the stream PLAYING but the decode position stops advancing (the
    /// canonical AAC + AudioToolbox "can't decode this packet" loop).
    enum PositionStaleness: Equatable {
        case advanced  // position moved; caller should record (positionBytes, now)
        case stale     // frozen past the threshold; trigger a restart
        case holding   // not advanced yet, but not stale either
    }

    /// Decides whether the decode position has gone stale.
    /// - `stallThreshold`: seconds of no advance before declaring a stall (4s =
    ///   2× the state-poll interval; AAC's tiny pre-mixer buffer freezes within a
    ///   fraction of a second on network loss, so two missed polls is safe).
    static func positionStaleness(positionBytes: UInt64,
                                  lastKnownBytes: UInt64,
                                  lastAdvanceTime: TimeInterval,
                                  now: TimeInterval,
                                  stallThreshold: TimeInterval,
                                  isReconnecting: Bool) -> PositionStaleness {
        if positionBytes > lastKnownBytes {
            return .advanced
        }
        if lastKnownBytes > 0,
           lastAdvanceTime > 0,
           now - lastAdvanceTime > stallThreshold,
           !isReconnecting {
            return .stale
        }
        return .holding
    }

    // MARK: - FLAC Buffer Health

    /// Download-buffer fill (0–100) at which a FLAC recovery stream has rebuffered
    /// enough to unpause (mirrors the ~10s initial-connect wait).
    static let flacRebufferThresholdPct: Double = 40

    /// True once the FLAC recovery stream's download buffer has refilled enough to
    /// resume decoding.
    static func flacRebufferComplete(downloadPct: Double,
                                     threshold: Double = flacRebufferThresholdPct) -> Bool {
        downloadPct >= threshold
    }

    /// Proactive FLAC recovery: pre-create a backup stream when the download buffer
    /// drops below 10% while disconnected and no recovery is already underway.
    /// Normal dlBuf sits at 17–20%, so <10% reliably signals genuine network loss.
    static func shouldStartFlacProactiveRecovery(downloadPct: Double,
                                                 isConnected: Bool,
                                                 isAttemptingRecovery: Bool,
                                                 hasRecoveryStream: Bool,
                                                 isRebuffering: Bool) -> Bool {
        downloadPct >= 0
            && downloadPct < 10
            && !isConnected
            && !isAttemptingRecovery
            && !hasRecoveryStream
            && !isRebuffering
    }

    // MARK: - Reconnect Backoff

    /// Graduated connect timeout (ms) by attempt number:
    ///   attempt 0 → 10s (first try; network may just be flaky)
    ///   attempt 1 → 5s  (path just reported satisfied + first retry)
    ///   attempt 2+ → 3s (fast-fail to burn through the budget quickly)
    static func reconnectConnectTimeoutMs(attempt: Int) -> UInt32 {
        switch attempt {
        case 0:  return 10_000
        case 1:  return 5_000
        default: return 3_000
        }
    }

    /// Whether the reconnect loop has exhausted its budget and should give up
    /// (transition to `.stopped`).
    static func shouldGiveUpReconnect(attempt: Int, maxAttempts: Int) -> Bool {
        attempt >= maxAttempts
    }

    // MARK: - DVR Buffer Resize

    /// What to do when the user changes the DVR buffer-size preference.
    enum DVRBufferResize: Equatable {
        case recreate          // live: tear down and rebuild the ring at the new size
        case applyImmediately  // paused/playing but new window still covers everything recorded
        case deferToGoLive     // shrinking would truncate playable content; wait until next go-live
    }

    /// Decides how to apply a DVR buffer-size change.
    /// - `recordedSeconds`: how much is currently behind the live edge (`behindLiveSeconds`).
    static func dvrBufferResize(isLive: Bool,
                                newMaxSeconds: Double,
                                recordedSeconds: Double) -> DVRBufferResize {
        if isLive {
            return .recreate
        }
        if newMaxSeconds >= recordedSeconds {
            return .applyImmediately
        }
        return .deferToGoLive
    }
}
