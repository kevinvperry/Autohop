// AI CONTEXT — Tests/SilenceGapAccountingTests.swift
// Headless unit tests for SilenceGapAccounting, the pure net-removed-frame
// accounting behind the Trim Silence "time saved" stat (ASSESSMENT.md B2).
// SilenceDetector itself is app-target-only (real-time AVAudioPCMBuffer), but it
// delegates the gap-size/re-insert DECISION to SilenceGapAccounting, so the figure
// that lands in Stats (and on the website) can be verified here without audio.
// Key invariants: a short gap that gets re-inserted reports 0 net removed; a
// significant gap reports exactly the dropped frames net of the kept join buffers.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class SilenceGapAccountingTests: XCTestCase {

    // A gap shorter than the minimum is re-inserted wholesale → nothing removed.
    // This is the case the old per-buffer delta over-counted (it credited every
    // accumulated buffer as saved and never deducted the re-inserts).
    func testShortGapRemovesNothing() {
        let accounting = SilenceGapAccounting(amount: .medium) // minGap 16, reinsert 12
        let shortGap = Array(repeating: 4096, count: 10)       // 10 < 16 → too short
        XCTAssertFalse(accounting.isSignificant(gapBufferCount: shortGap.count))
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: shortGap), 0)
    }

    // A significant gap removes every frame except the kept join buffers.
    func testSignificantGapRemovesNetFrames() {
        let accounting = SilenceGapAccounting(amount: .medium) // minGap 16, reinsert 12 → keep 13
        let gap = Array(repeating: 4096, count: 40)            // 40 >= 16 → significant
        XCTAssertTrue(accounting.isSignificant(gapBufferCount: gap.count))
        XCTAssertEqual(accounting.reinsertCount(gapBufferCount: gap.count), 13)
        // keep = min(12 + 1, 40) = 13 buffers re-inserted; 27 dropped.
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: gap), (40 - 13) * 4096)
    }

    // High amount keeps a single faded join buffer (buffersToReinsert == 0).
    func testHighAmountKeepsOneJoinBuffer() {
        let accounting = SilenceGapAccounting(amount: .high)   // minGap 4, reinsert 0 → keep 1
        XCTAssertEqual(accounting.reinsertCount(gapBufferCount: 10), 1)
        let gap = Array(repeating: 4096, count: 10)
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: gap), (10 - 1) * 4096)
    }

    // Variable-length buffers (e.g. a short trailing read) are summed exactly,
    // not assumed uniform.
    func testVariableLengthBuffersSummedExactly() {
        let accounting = SilenceGapAccounting(amount: .high)   // keep 1
        let gap = [4096, 4096, 4096, 4096, 1000]               // 5 >= 4 → significant
        // Keep leading 1 (4096); remove the rest: 4096 + 4096 + 4096 + 1000.
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: gap), 4096 + 4096 + 4096 + 1000)
    }

    // A gap exactly at the threshold is significant and trims.
    func testGapAtThresholdIsSignificant() {
        let accounting = SilenceGapAccounting(amount: .high)   // minGap 4, keep 1
        XCTAssertTrue(accounting.isSignificant(gapBufferCount: 4))
        let gap = Array(repeating: 4096, count: 4)
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: gap), 3 * 4096)
    }

    // One buffer below the threshold is the boundary that must NOT trim.
    func testGapJustBelowThresholdRemovesNothing() {
        let accounting = SilenceGapAccounting(amount: .high)   // minGap 4
        let gap = Array(repeating: 4096, count: 3)             // 3 < 4
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: gap), 0)
    }

    // An empty gap removes nothing and never traps.
    func testEmptyGapRemovesNothing() {
        let accounting = SilenceGapAccounting(amount: .low)
        XCTAssertEqual(accounting.framesRemoved(gapFrameLengths: []), 0)
    }
}
