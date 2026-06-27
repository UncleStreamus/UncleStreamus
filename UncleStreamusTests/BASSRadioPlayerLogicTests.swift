#if os(macOS)
import XCTest
@testable import UncleStreamus

/// Tests for the pure decision logic extracted out of BASSRadioPlayer's
/// hardware-bound methods (checkStreamStatus, scheduleReconnect, restartStream,
/// updateDVRBufferSize). See BASSRadioPlayerLogic.swift.
final class BASSRadioPlayerLogicTests: XCTestCase {

    // MARK: - playbackState(forActiveStatus:)

    func testPlaybackState_playing() {
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 1), .playing)
    }

    func testPlaybackState_stalled() {
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 3), .stalled)
    }

    func testPlaybackState_stopped() {
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 0), .stopped)
    }

    func testPlaybackState_pausedOrOther_treatedAsConnecting() {
        // 2 = BASS_ACTIVE_PAUSED, 4 = BASS_ACTIVE_PAUSED_DEVICE — both map to connecting.
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 2), .connecting)
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 4), .connecting)
    }

    // MARK: - isAACUnderrun

    func testAACUnderrun_true_whenDrainedAfterProgress() {
        XCTAssertTrue(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: true, bufferedBytes: 0, positionBytes: 150_000))
    }

    func testAACUnderrun_false_whenBufferHasData() {
        XCTAssertFalse(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: true, bufferedBytes: 4096, positionBytes: 150_000))
    }

    func testAACUnderrun_false_beforeMeaningfulProgress() {
        // At/under the 100 KB threshold this is start-up, not an underrun.
        XCTAssertFalse(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: true, bufferedBytes: 0, positionBytes: 100_000))
    }

    func testAACUnderrun_false_whenNotPlaying() {
        XCTAssertFalse(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: false, bufferedBytes: 0, positionBytes: 150_000))
    }

    // MARK: - positionStaleness

    func testStaleness_advanced_whenPositionMoves() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 200, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 100, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .advanced)
    }

    func testStaleness_stale_whenFrozenPastThreshold() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 15, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .stale)
    }

    func testStaleness_holding_whenFrozenWithinThreshold() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 12, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .holding)
    }

    func testStaleness_holding_atExactThreshold() {
        // Strictly greater-than: exactly at threshold is not yet stale.
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 14, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .holding)
    }

    func testStaleness_holding_whenNoBaselineYet() {
        // lastKnownBytes == 0 means we have no advance baseline; never declare stale.
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 0, lastKnownBytes: 0, lastAdvanceTime: 0,
            now: 999, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .holding)
    }

    func testStaleness_holding_whenReconnecting() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 100, stallThreshold: 4, isReconnecting: true)
        XCTAssertEqual(r, .holding)
    }

    // MARK: - FLAC buffer health

    func testFlacRebufferComplete_atThreshold() {
        XCTAssertTrue(BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: 40))
        XCTAssertTrue(BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: 55))
    }

    func testFlacRebufferComplete_belowThreshold() {
        XCTAssertFalse(BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: 39.9))
    }

    func testFlacProactiveRecovery_true_whenDrainingAndDisconnected() {
        XCTAssertTrue(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 8, isConnected: false, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenHealthy() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 18, isConnected: true, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenStillConnected() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 5, isConnected: true, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenAlreadyRecovering() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 5, isConnected: false, isAttemptingRecovery: true,
            hasRecoveryStream: false, isRebuffering: false))
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 5, isConnected: false, isAttemptingRecovery: false,
            hasRecoveryStream: true, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenDownloadPctUnknown() {
        // dlPct < 0 is the "not measurable" sentinel; never act on it.
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: -1, isConnected: false, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    // MARK: - reconnect backoff

    func testReconnectTimeout_graduatedByAttempt() {
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 0), 10_000)
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 1), 5_000)
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 2), 3_000)
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 9), 3_000)
    }

    func testGiveUpReconnect_atAndBeyondBudget() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: 11, maxAttempts: 12))
        XCTAssertTrue(BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: 12, maxAttempts: 12))
        XCTAssertTrue(BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: 13, maxAttempts: 12))
    }

    // MARK: - DVR buffer resize

    func testDVRResize_liveRecreates() {
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: true, newMaxSeconds: 600, recordedSeconds: 1200),
            .recreate)
    }

    func testDVRResize_growApplyImmediately() {
        // New window (20 min) still covers everything recorded (10 min).
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: false, newMaxSeconds: 1200, recordedSeconds: 600),
            .applyImmediately)
    }

    func testDVRResize_shrinkBelowRecordedDefers() {
        // New window (5 min) would truncate the 10 min already recorded.
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: false, newMaxSeconds: 300, recordedSeconds: 600),
            .deferToGoLive)
    }

    func testDVRResize_exactFitAppliesImmediately() {
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: false, newMaxSeconds: 600, recordedSeconds: 600),
            .applyImmediately)
    }
}
#endif
