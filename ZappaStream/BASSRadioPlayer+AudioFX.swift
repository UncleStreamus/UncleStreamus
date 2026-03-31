import Foundation
#if os(macOS)
import Bass
import BassFX
import BassMix
#endif

// MARK: - Audio Effects & DSP

extension BASSRadioPlayer {

    // MARK: - Apply Effects Pipeline

    func applyEffects(to handle: DWORD, clickGuardOn cgHandle: DWORD? = nil) {
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

                        // Frequency-dependent side-channel scaling (400 Hz and 3.5 kHz crossovers).
                        // Three bands with different widening amounts when slider is right of centre:
                        //   Low  (<400 Hz):       0.5× boost — bass stays centred and tight
                        //   Mid  (400 Hz–3.5 kHz): 0.5× boost — body/presence matches low treatment
                        //   High (>3.5 kHz):       full boost — air/brightness fully widened
                        // For narrowing (coeff ≤ 1): low collapses fastest (coeff²), mid in between,
                        //   high slowest (coeff). All reach 0 (mono) at coeff=0 and 1 at coeff=1.
                        let S_low  = player.lowPassFilterSide(S)
                        let S_aboveLow = S - S_low
                        let S_mid  = player.lowPassFilterSideMid(S_aboveLow)
                        let S_high = S_aboveLow - S_mid
                        let lowFreqCoeff: Float = coeff <= 1.0 ? coeff * coeff               : 1.0 + (coeff - 1.0) * 0.5
                        let midFreqCoeff: Float = coeff <= 1.0 ? (coeff + coeff * coeff) * 0.5 : 1.0 + (coeff - 1.0) * 0.5
                        L = M + S_low * lowFreqCoeff + S_mid * midFreqCoeff + S_high * coeff
                        R = M - S_low * lowFreqCoeff - S_mid * midFreqCoeff - S_high * coeff

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
                let samples = buffer.assumingMemoryBound(to: Float.self)
                let count = Int(length) / MemoryLayout<Float>.size

                // --- MP3 post-gate scan: watches for late detectable splices ---
                // Runs ONLY after the initial gate has completed (cgFadeBuffersRemaining == 0).
                // Uses second-difference spike detection: d2 = |s[i] - 2·s[i-1] + s[i-2]|.
                // Normal music: spike (max d2 / rms) ≤ ~2. MDCT artifact: spike >> 4.
                // On detection, arms a second gate. On timeout (with smart extension during silence),
                // exits with no gate.
                if p.cgMP3ScanActive && p.cgFadeBuffersRemaining == 0 {
                    let now = ProcessInfo.processInfo.systemUptime
                    let elapsed = (now - p.cgSyncTime) * 1000  // ms since SYNC

                    // --- Compute metrics first (needed for smart expiry check) ---
                    let frames = count / 2
                    var maxD2: Float = 0
                    var sumSq: Float = 0
                    // Track cross-buffer d2: include boundary between this buffer and the previous
                    // one. Splices at buffer boundaries have zero within-buffer signature but a
                    // large cross-buffer discontinuity — missed if we start the loop at i=4.
                    var prevL  = p.cgScanPrevL
                    var prev2L = p.cgScanPrevPrevL
                    for i in stride(from: 0, to: count, by: 2) {
                        let s  = samples[i]
                        let d2 = abs(s - 2 * prevL + prev2L)
                        if d2 > maxD2 { maxD2 = d2 }
                        sumSq += s * s
                        prev2L = prevL
                        prevL  = s
                    }
                    // Save last two L-channel samples for next buffer's cross-buffer d2
                    p.cgScanPrevL     = count >= 4 ? samples[count - 2] : prevL
                    p.cgScanPrevPrevL = count >= 4 ? samples[count - 4] : prev2L
                    let rms   = sqrt(sumSq / Float(frames))
                    let spike = rms > 0.005 ? maxD2 / rms : 0

                    // Read EMAs before update so checks compare current values to past baseline.
                    let ema    = p.cgMP3ScanEMA
                    let rmsEMA = p.cgMP3ScanRMSEMA
                    p.cgMP3ScanEMA    = 0.3 * spike + 0.7 * ema
                    p.cgMP3ScanRMSEMA = 0.3 * rms   + 0.7 * rmsEMA

                    // Sustained-spike counter: resets to 0 on any buffer with spike ≤ 1.0.
                    let spikeCount = p.cgMP3SpikeCount
                    if spike > 1.0 { p.cgMP3SpikeCount += 1 } else { p.cgMP3SpikeCount = 0 }

                    // --- Expiry check (after metrics so smart extension can use updated rmsEMA) ---
                    if now >= p.cgMP3ScanEnd {
                        // Smart extension: if we're still in near-silence (inter-track gap), keep
                        // watching. rmsEMA < 0.003 means no audible signal for several buffers.
                        // Cap at 5000ms total to avoid scanning forever if stream goes quiet.
                        let updatedRMSEMA = p.cgMP3ScanRMSEMA
                        if updatedRMSEMA < 0.003 && elapsed < 5000 {
                            p.cgMP3ScanEnd = now + 0.2   // extend by 200ms and keep watching
                        } else {
                            p.cgMP3ScanActive = false
                            print("🛡️  MP3 scan expired — \(String(format: "%.0f", elapsed))ms rmsEMA=\(String(format: "%.4f", updatedRMSEMA))")
                            return
                        }
                    }

                    // --- Log only when there's something to see ---
                    if spike > 0 || rms > 0.003 {
                        print("🛡️  MP3 scan — \(String(format: "%.0f", elapsed))ms: spike=\(String(format: "%.1f", spike)) ema=\(String(format: "%.2f", ema)) rms=\(String(format: "%.3f", rms)) rmsEMA=\(String(format: "%.3f", rmsEMA)) sc=\(spikeCount)")
                    }

                    // --- Detectors ---
                    // Absolute: large MDCT artifacts (spike > 7.3 observed for "Young Sophisticate").
                    // Relative: moderate local outlier (e.g. spike=2.0 vs EMA=0.4 baseline → ratio 5×).
                    //   Primed EMA=1.0 prevents false trigger before baseline stabilises (~5 buffers).
                    // RMS jump: low-freq splice energy invisible to D2 (e.g. Montana: rms 0.055→0.137).
                    //   rmsEMA guard (>0.02) prevents false trigger on near-silence.
                    // Sustained: 3+ consecutive buffers with spike > 1.0 — catches gradual MDCT residual
                    //   in near-silence (e.g. IEB ending → Audience Tuning: both near-silent at splice).
                    // SilenceOnset: inter-track silence followed by new track starting abruptly
                    //   (e.g. Inca Outro → Call Any Vegetable: rmsEMA ~0 for 1200ms then new track).
                    //   rmsEMA < 0.003 confirms preceding silence; rms > 0.015 is the new track onset.
                    let isAbsolute     = spike > 4.0
                    // Guard lowered to 0.2 (from 0.3): once EMA has settled to signal baseline,
                    // a late splice (at T > 600ms) can stand out at 3× even with small absolute values.
                    let isRelative     = ema > 0.2 && spike > 3.0 * ema
                    let isRMSJump      = rmsEMA > 0.02 && rms > 2.0 * rmsEMA
                    let isSustained    = spikeCount >= 2 && spike > 1.0
                    let isSilenceOnset = rmsEMA < 0.003 && rms > 0.015
                    if isAbsolute || isRelative || isRMSJump || isSustained || isSilenceOnset {
                        // Keep scan active: it pauses while the gate runs (cgFadeBuffersRemaining > 0)
                        // and resumes after, catching any artifact that slips past the re-triggered gate.
                        // Re-prime EMAs and counters to avoid an immediate double-trigger.
                        p.cgMP3ScanEMA    = 1.0
                        p.cgMP3ScanRMSEMA = 1.0
                        p.cgMP3SpikeCount = 0
                        p.cgMP3ScanEnd    = max(p.cgMP3ScanEnd, now + 0.3)
                        p.cgFadeBuffersRemaining = p.cgSilenceBufferCount + p.cgFadeBufferCount
                        let reason: String
                        if isAbsolute        { reason = "absolute" }
                        else if isRelative   { reason = "relative (\(String(format: "%.1f", spike)) > 3×\(String(format: "%.2f", ema)))" }
                        else if isRMSJump    { reason = "rmsJump (\(String(format: "%.3f", rms)) > 2×\(String(format: "%.3f", rmsEMA)))" }
                        else if isSustained  { reason = "sustained (\(spikeCount+1) bufs spike>\(String(format: "%.1f", spike)))" }
                        else                 { reason = "silenceOnset (rmsEMA=\(String(format: "%.4f", rmsEMA)) rms=\(String(format: "%.3f", rms)))" }
                        print("🛡️  MP3 late splice at \(String(format: "%.0f", elapsed))ms \(reason) → gate \(p.cgFadeBuffersRemaining) bufs")
                        // Fall through to gate below.
                    } else {
                        return  // pass through
                    }
                }

                // --- OGG/FLAC/MP3 click guard: buffer-count envelope ---
                // MP3: runs for the immediate 60ms gate AND any secondary scan-detected gate.
                guard p.cgFadeBuffersRemaining > 0 else { return }

                let frames = count / 2
                let remaining = p.cgFadeBuffersRemaining
                p.cgFadeBuffersRemaining -= 1
                let n = p.cgFadeBufferCount

                if remaining > n {
                    if remaining == n + p.cgSilenceBufferCount {
                        if p.cgMP3ScanActive {
                            // MP3: smooth fade-out 1→0 (prevents gate-onset click when gate
                            // starts during active audio — the artifact may be mid-buffer).
                            // Using cubic smoothstep inverted: gain = 1 − t²(3−2t).
                            for i in stride(from: 0, to: count - 1, by: 2) {
                                let tFwd = Float(i / 2) / Float(frames)
                                let gain = 1.0 - tFwd * tFwd * (3.0 - 2.0 * tFwd)
                                samples[i] *= gain; samples[i + 1] *= gain
                            }
                        } else {
                            // OGG/FLAC: hard-zero the entire buffer. The click is at the bitstream
                            // boundary which can be at sample 0 of this buffer; a smooth fade-out
                            // starts at gain=1.0 and would pass the artifact through at full amplitude.
                            for i in 0 ..< count { samples[i] = 0 }
                        }
                    } else {
                        // Subsequent silence buffers: hard zero to suppress any artifact.
                        for i in 0 ..< count { samples[i] = 0 }
                    }
                } else {
                    // Cubic smoothstep fade-in: t²(3−2t) — zero derivative at both ends,
                    // avoiding the abrupt-onset "burst" feeling of a linear ramp.
                    let posInFade = n - remaining
                    for i in stride(from: 0, to: count - 1, by: 2) {
                        let t = min((Float(posInFade) + Float(i / 2) / Float(frames)) / Float(n), 1.0)
                        let gain = t * t * (3.0 - 2.0 * t)
                        samples[i]     *= gain
                        samples[i + 1] *= gain
                    }
                    // Last fade-in buffer: seed cross-buffer d2 state so the first scan buffer
                    // computes an accurate d2 at the gate→scan boundary.
                    if remaining == 1 && p.cgMP3ScanActive && count >= 4 {
                        p.cgScanPrevL     = samples[count - 2]
                        p.cgScanPrevPrevL = samples[count - 4]
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
    func attachRecordingDSP() {
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

    // MARK: - EQ

    func applyLowShelf(gain: Float) {
        guard eqLowFX != 0 else { return }
        var p = BASS_BFX_BQF()
        p.lFilter  = Int32(BASS_BFX_BQF_LOWSHELF)
        p.fCenter  = 120
        p.fGain    = gain
        p.fS       = 0.7
        p.lChannel = -1
        BASS_FXSetParameters(eqLowFX, &p)
    }

    func applyMidPeak(gain: Float) {
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

    func applyHighShelf(gain: Float) {
        guard eqHighFX != 0 else { return }
        var p = BASS_BFX_BQF()
        p.lFilter  = Int32(BASS_BFX_BQF_HIGHSHELF)
        p.fCenter  = 7500
        p.fGain    = gain
        p.fS       = 0.7
        p.lChannel = -1
        BASS_FXSetParameters(eqHighFX, &p)
    }

    // MARK: - Compressor

    func applyCompressorParams() {
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
    func applyCompressorPassthrough() {
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
    func applyCompressorBlend(_ blend: Float) {
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
    func applyEQAtCurrentBlend() {
        applyLowShelf(gain:  eqLowGain  * eqBlend)
        applyMidPeak(gain:   eqMidGain  * eqBlend)
        applyHighShelf(gain: eqHighGain * eqBlend)
    }

    /// Start the FX ramp timer if it isn't already running.
    /// The timer fires at ~120 Hz and moves blends toward their goals in ~83ms.
    func startFXRampIfNeeded() {
        guard fxRampTimer == nil else { return }
        fxRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.fxRampTick()
        }
    }

    func fxRampTick() {
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

    // MARK: - Audio DSP Helpers

    /// Simple 1st-order low-pass filter for 400 Hz crossover (44.1 kHz sampling).
    /// Maintains state internally; call once per sample. Used for mono center channel.
    func lowPassFilter400Hz(_ input: Float) -> Float {
        let output = centerSpreadLPFAlpha * input + (1.0 - centerSpreadLPFAlpha) * centerSpreadLPFState
        centerSpreadLPFState = output
        return output
    }

    /// Same 400 Hz low-pass filter for the stereo side channel (S = (L−R)/2).
    /// Separate state from the center-spread filter to avoid cross-contamination.
    func lowPassFilterSide(_ input: Float) -> Float {
        let output = centerSpreadLPFAlpha * input + (1.0 - centerSpreadLPFAlpha) * sideChannelLPFState
        sideChannelLPFState = output
        return output
    }

    /// 3.5 kHz low-pass filter applied to the above-400Hz side signal to extract the mid band.
    /// Input is the output of the 400 Hz high-pass (S_aboveLow), so this yields 400 Hz–3.5 kHz.
    func lowPassFilterSideMid(_ input: Float) -> Float {
        let output = sideChannelMidLPFAlpha * input + (1.0 - sideChannelMidLPFAlpha) * sideChannelMidLPFState
        sideChannelMidLPFState = output
        return output
    }
}
