// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Portions of this file are derived from Pocket Casts for iOS
// (https://github.com/Automattic/pocket-casts-ios), © Automattic, Inc.
// Used under the Mozilla Public License, v. 2.0.
//
// Specifically, the gap-size thresholds and re-insert counts are ported from
// AudioReadTask.swift in the Pocket Casts iOS project. The implementation has
// been restructured into a pure Swift value type, but the tuning parameters
// originate from Pocket Casts.

import Foundation

// AI CONTEXT — Models/SilenceGapAccounting.swift  (LICENSE: MPL-2.0, see header)
// Pure, buffer-independent accounting for the Trim Silence feature. SilenceDetector
// (Playback/, app-target-only, real-time audio) owns the RMS gap DETECTION but
// delegates the "how much did this gap actually remove?" DECISION here so the same
// logic can be unit-tested headlessly in AutohopCore. Given a TrimSilenceAmount and
// the per-buffer frame lengths of a detected silent gap, this reports how many
// leading buffers SilenceDetector re-inserts at the join (the kept fade-out frames)
// and the NET frames removed once those re-inserts are deducted.
//
// WHY THIS EXISTS (ASSESSMENT.md B2): PlaybackEngine previously inferred saved time
// from a per-buffer (input − output) delta, which could only ever add — so the
// frames re-inserted when a gap is too short, or the join buffers kept for a real
// gap, were never deducted and the Stats "Trim Silence" / lifetime "time saved"
// totals (also surfaced on the website) were systematically inflated. The detector
// now reports the value computed here instead.
//
// Tuning constants (min gap size, re-insert counts) are ported verbatim from
// Pocket Casts AudioReadTask.swift and MUST NOT be retuned casually — they are
// perceptually validated values and are the single source of truth shared with
// SilenceDetector.

/// Pure accounting for how many frames a silent gap actually removes, net of the
/// buffers `SilenceDetector` re-inserts at the join. Mirrors `SilenceDetector.endGap`
/// exactly so it can be unit-tested without real-time audio buffers.
public struct SilenceGapAccounting {

    /// Minimum number of consecutive silent buffers before a gap is trimmed.
    /// A shorter gap is re-inserted wholesale and removes nothing.
    public let minGapSizeInBuffers: Int

    /// How many silent buffers are kept at the join point (the last gets a fade-out).
    public let buffersToReinsert: Int

    public init(amount: TrimSilenceAmount) {
        switch amount {
        case .off:
            minGapSizeInBuffers = 0
            buffersToReinsert = 0
        case .low:
            minGapSizeInBuffers = 20
            buffersToReinsert = 14
        case .medium:
            minGapSizeInBuffers = 16
            buffersToReinsert = 12
        case .high:
            minGapSizeInBuffers = 4
            buffersToReinsert = 0
        }
    }

    /// Whether a gap of `gapBufferCount` buffers is long enough to trim.
    public func isSignificant(gapBufferCount: Int) -> Bool {
        gapBufferCount >= minGapSizeInBuffers
    }

    /// Number of leading gap buffers re-inserted at the join when a significant gap
    /// ends. The last one is faded out for a smooth join (the `+1` matches
    /// `SilenceDetector.endGap`).
    public func reinsertCount(gapBufferCount: Int) -> Int {
        min(buffersToReinsert + 1, gapBufferCount)
    }

    /// Net frames removed when a gap with the given per-buffer frame lengths ends.
    /// A too-short gap is re-inserted wholesale → 0. A significant gap removes every
    /// frame except the `reinsertCount` leading buffers kept at the join. The buffer
    /// that resumes audio is real content, not part of the gap, so it never counts.
    public func framesRemoved(gapFrameLengths: [Int]) -> Int {
        guard isSignificant(gapBufferCount: gapFrameLengths.count) else { return 0 }
        let keep = reinsertCount(gapBufferCount: gapFrameLengths.count)
        let total = gapFrameLengths.reduce(0, +)
        let reinserted = gapFrameLengths.prefix(keep).reduce(0, +)
        return max(0, total - reinserted)
    }
}
