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
// read loop. Stateless API surface: feed each AVAudioPCMBuffer to process(),
// receive back buffers to schedule (silent runs collapsed, with fade-out/
// fade-in joins) plus a count of trimmed frames (PlaybackEngine converts to
// seconds for the Stats "Trim Silence" time-saved category). Tuning constants
// (minRMS per level, min gap sizes, re-insert counts, last-5-seconds guard,
// overflow cap) are ported verbatim from Pocket Casts AudioReadTask.swift and
// MUST NOT be retuned casually — they are perceptually validated values.
// RMS is computed with Accelerate vDSP_rmsqv.

/// Detects and removes silent gaps from a stream of audio buffers.
///
/// The core algorithm is ported from Pocket Casts' AudioReadTask (MPL-2.0).
/// Call `process(buffer:currentFrame:totalFrames:sampleRate:)` for each buffer read from
/// AVAudioFile, then call `flush()` after reaching end-of-file to drain any trailing gap.
struct SilenceDetector {

    let amount: TrimSilenceAmount

    // MARK: - Tuning constants (matching Pocket Casts values)

    private var minRMS: Float {
        switch amount {
        case .off:    return 0
        case .low:    return 0.0055
        case .medium: return 0.00511
        case .high:   return 0.005
        }
    }

    /// Minimum number of consecutive silent buffers before a gap is trimmed.
    private var minGapSizeInBuffers: Int {
        switch amount {
        case .off:    return 0
        case .low:    return 20
        case .medium: return 16
        case .high:   return 4
        }
    }

    /// How many silent buffers to keep at the join point (fade-out applied to the last one).
    private var buffersToReinsert: Int {
        switch amount {
        case .off, .high: return 0
        case .low:        return 14
        case .medium:     return 12
        }
    }

    // MARK: - Init

    init(amount: TrimSilenceAmount) {
        self.amount = amount
    }

    // MARK: - State

    private var inGap = false
    private var gapBuffers: [AVAudioPCMBuffer] = []
    private let maxGapBuffers = 1000   // safety cap — prevents unbounded memory growth

    // MARK: - Public API

    /// Process one buffer. Returns the buffers that should be scheduled for playback.
    /// May return an empty array (silence being accumulated) or multiple buffers (gap just ended).
    mutating func process(
        buffer: AVAudioPCMBuffer,
        currentFrame: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition,
        sampleRate: Double
    ) -> [AVAudioPCMBuffer] {
        guard amount != .off else { return [buffer] }

        // Never trim the last 5 seconds — preserve natural endings.
        let secondsRemaining = Double(totalFrames - currentFrame) / sampleRate
        if secondsRemaining <= 5 {
            if inGap {
                // Flush accumulated gap so audio doesn't drop out near the end.
                let saved = gapBuffers
                gapBuffers = []
                inGap = false
                return saved + [buffer]
            }
            return [buffer]
        }

        let rms = calculateRMS(buffer)

        if rms > minRMS && !inGap {
            // Normal audio, not in any gap.
            return [buffer]

        } else if inGap && (rms > minRMS || gapBuffers.count >= maxGapBuffers) {
            // Gap ended (audio resumed, or safety cap hit).
            return endGap(resumingWith: buffer)

        } else if rms <= minRMS && !inGap {
            // Start of a gap.
            inGap = true
            gapBuffers = [buffer]
            return []

        } else {
            // Still inside a gap.
            gapBuffers.append(buffer)
            return []
        }
    }

    /// Flush any buffers that were accumulated in a gap at end-of-file.
    /// Always call this after the read loop exits due to EOF.
    mutating func flush() -> [AVAudioPCMBuffer] {
        guard inGap, !gapBuffers.isEmpty else { return [] }
        let saved = gapBuffers
        gapBuffers = []
        inGap = false
        return saved
    }

    // MARK: - Private

    private mutating func endGap(resumingWith newBuffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        let saved = gapBuffers
        gapBuffers = []
        inGap = false

        if saved.count < minGapSizeInBuffers {
            // Gap was too short to be meaningful — re-insert all buffered frames.
            return saved + [newBuffer]
        }

        // Gap was significant — keep only `buffersToReinsert` frames with a fade-out,
        // then fade the new audio back in for a smooth join.
        var result: [AVAudioPCMBuffer] = []
        let reinsertCount = min(buffersToReinsert + 1, saved.count)
        let channelCount = newBuffer.format.channelCount

        for i in 0..<reinsertCount {
            if i == reinsertCount - 1 {
                applyFade(to: saved[i], fadeIn: false, channelCount: channelCount)  // fade out
            }
            result.append(saved[i])
        }

        applyFade(to: newBuffer, fadeIn: true, channelCount: channelCount)  // fade in
        result.append(newBuffer)
        return result
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
