// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Portions of this file are derived from Pocket Casts for iOS
// (https://github.com/Automattic/pocket-casts-ios), © Automattic, Inc.
// Used under the Mozilla Public License, v. 2.0.
//
// Specifically, the silence-detection algorithm — including the RMS threshold
// constants, gap-size thresholds, re-insert counts, last-5-seconds guard, safety
// cap, and fade-in/fade-out join logic — is ported from AudioReadTask.swift in the
// Pocket Casts iOS project. The implementation has been restructured into a Swift
// value-type struct and adapted to the Autohop buffer pipeline, but the algorithm
// and its tuning parameters originate from Pocket Casts.

import Accelerate
import AVFoundation

// AI CONTEXT — Playback/SilenceDetector.swift  (LICENSE: MPL-2.0, see header)
// Value-type silence trimmer used ONLY by PlaybackEngine's engine-path buffer
// read loop. Feed each AVAudioPCMBuffer to process(); receive back a ProcessResult
// holding the buffers to schedule (silent runs collapsed, with fade-out/fade-in
// joins) PLUS framesRemoved — the NET frames actually trimmed by THIS call, which
// PlaybackEngine converts to seconds for the Stats "Trim Silence" time-saved
// category. framesRemoved is 0 while a gap is still being accumulated and when a
// gap turns out too short (re-inserted wholesale); for a significant gap it is the
// dropped frames net of the kept join buffers. The gap-size threshold / re-insert
// DECISION (and that net-removed count) is delegated to the pure, headlessly
// testable SilenceGapAccounting (Models/) so the Stats figure can be unit-tested
// without real-time audio — see ASSESSMENT.md B2, which fixed an over-count that
// arose from inferring saved time from per-buffer input/output deltas.
// minRMS (per level) and the last-5-seconds guard / overflow cap stay here; like
// the SilenceGapAccounting constants they are ported verbatim from Pocket Casts
// AudioReadTask.swift and MUST NOT be retuned casually. RMS uses vDSP_rmsqv.

/// Detects and removes silent gaps from a stream of audio buffers.
///
/// The core algorithm is ported from Pocket Casts' AudioReadTask (MPL-2.0).
/// Call `process(buffer:currentFrame:totalFrames:sampleRate:)` for each buffer read from
/// AVAudioFile, then call `flush()` after reaching end-of-file to drain any trailing gap.
struct SilenceDetector {

    /// The buffers to schedule for playback plus the NET frames removed by this call.
    /// `framesRemoved` is 0 while a gap is still accumulating, 0 for a too-short gap
    /// re-inserted wholesale, and the dropped frames (net of the kept join buffers)
    /// for a significant gap. PlaybackEngine sums it into the "Trim Silence" stat.
    struct ProcessResult {
        var buffers: [AVAudioPCMBuffer]
        var framesRemoved: AVAudioFrameCount
    }

    let amount: TrimSilenceAmount

    /// Pure gap-size / re-insert decision shared with the headless unit tests
    /// (single source of truth for minGapSizeInBuffers and buffersToReinsert).
    private let accounting: SilenceGapAccounting

    // MARK: - Tuning constants (matching Pocket Casts values)

    private var minRMS: Float {
        switch amount {
        case .off:    return 0
        case .low:    return 0.0055
        case .medium: return 0.00511
        case .high:   return 0.005
        }
    }

    // MARK: - Init

    init(amount: TrimSilenceAmount) {
        self.amount = amount
        self.accounting = SilenceGapAccounting(amount: amount)
    }

    // MARK: - State

    private var inGap = false
    private var gapBuffers: [AVAudioPCMBuffer] = []
    private let maxGapBuffers = 1000   // safety cap — prevents unbounded memory growth

    // MARK: - Public API

    /// Process one buffer. Returns the buffers that should be scheduled for playback
    /// plus the net frames removed by this call (see `ProcessResult`). `buffers` may be
    /// empty (silence being accumulated) or hold multiple buffers (gap just ended).
    mutating func process(
        buffer: AVAudioPCMBuffer,
        currentFrame: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition,
        sampleRate: Double
    ) -> ProcessResult {
        guard amount != .off else { return ProcessResult(buffers: [buffer], framesRemoved: 0) }

        // Never trim the last 5 seconds — preserve natural endings.
        let secondsRemaining = Double(totalFrames - currentFrame) / sampleRate
        if secondsRemaining <= 5 {
            if inGap {
                // Flush accumulated gap so audio doesn't drop out near the end.
                // Everything is re-emitted, so nothing is removed.
                let saved = gapBuffers
                gapBuffers = []
                inGap = false
                return ProcessResult(buffers: saved + [buffer], framesRemoved: 0)
            }
            return ProcessResult(buffers: [buffer], framesRemoved: 0)
        }

        let rms = calculateRMS(buffer)

        if rms > minRMS && !inGap {
            // Normal audio, not in any gap.
            return ProcessResult(buffers: [buffer], framesRemoved: 0)

        } else if inGap && (rms > minRMS || gapBuffers.count >= maxGapBuffers) {
            // Gap ended (audio resumed, or safety cap hit).
            return endGap(resumingWith: buffer)

        } else if rms <= minRMS && !inGap {
            // Start of a gap. Nothing is removed until we know how long the gap runs.
            inGap = true
            gapBuffers = [buffer]
            return ProcessResult(buffers: [], framesRemoved: 0)

        } else {
            // Still inside a gap — keep accumulating, removal is decided on endGap.
            gapBuffers.append(buffer)
            return ProcessResult(buffers: [], framesRemoved: 0)
        }
    }

    /// Flush any buffers that were accumulated in a gap at end-of-file.
    /// Always call this after the read loop exits due to EOF. The trailing gap is
    /// re-emitted verbatim (no trim near the end), so `framesRemoved` is 0.
    mutating func flush() -> ProcessResult {
        guard inGap, !gapBuffers.isEmpty else { return ProcessResult(buffers: [], framesRemoved: 0) }
        let saved = gapBuffers
        gapBuffers = []
        inGap = false
        return ProcessResult(buffers: saved, framesRemoved: 0)
    }

    // MARK: - Private

    private mutating func endGap(resumingWith newBuffer: AVAudioPCMBuffer) -> ProcessResult {
        let saved = gapBuffers
        gapBuffers = []
        inGap = false

        if !accounting.isSignificant(gapBufferCount: saved.count) {
            // Gap was too short to be meaningful — re-insert all buffered frames.
            // Nothing is removed.
            return ProcessResult(buffers: saved + [newBuffer], framesRemoved: 0)
        }

        // Gap was significant — keep only `buffersToReinsert` frames with a fade-out,
        // then fade the new audio back in for a smooth join. The frames in the dropped
        // buffers (everything past the kept join buffers) are what we actually removed;
        // SilenceGapAccounting computes that exact count from the same decision.
        var result: [AVAudioPCMBuffer] = []
        let reinsertCount = accounting.reinsertCount(gapBufferCount: saved.count)
        let channelCount = newBuffer.format.channelCount

        for i in 0..<reinsertCount {
            if i == reinsertCount - 1 {
                applyFade(to: saved[i], fadeIn: false, channelCount: channelCount)  // fade out
            }
            result.append(saved[i])
        }

        applyFade(to: newBuffer, fadeIn: true, channelCount: channelCount)  // fade in
        result.append(newBuffer)

        let framesRemoved = accounting.framesRemoved(gapFrameLengths: saved.map { Int($0.frameLength) })
        return ProcessResult(buffers: result, framesRemoved: AVAudioFrameCount(framesRemoved))
    }

    // MARK: - DSP helpers

    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = vDSP_Length(buffer.frameLength)

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, n)

        if buffer.format.channelCount > 1 {
            var rms2: Float = 0
            vDSP_rmsqv(channelData[1], 1, &rms2, n)
            rms = (rms + rms2) / 2
        }

        return rms
    }

    /// Apply a linear fade-in or fade-out to all channels of `buffer` in-place.
    private func applyFade(to buffer: AVAudioPCMBuffer, fadeIn: Bool, channelCount: AVAudioChannelCount) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = vDSP_Length(buffer.frameLength)
        var ramp = [Float](repeating: 0, count: Int(n))
        if fadeIn {
            vDSP_vgen([0.0], [1.0], &ramp, 1, n)
        } else {
            vDSP_vgen([1.0], [0.0], &ramp, 1, n)
        }
        for c in 0..<Int(channelCount) {
            vDSP_vmul(channelData[c], 1, ramp, 1, channelData[c], 1, n)
        }
    }
}
