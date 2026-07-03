// AI CONTEXT — Tests/SyncPushCoalescingTests.swift. Headless tests for the
// slow-lane push coalescing policy (CloudSyncEngine.shouldDeferSlowLane): during
// playback, history/stats-only dirt defers to the ~60 s slow-lane debounce
// instead of producing a 1–2-record CloudKit push per store change (2026-07-03
// log review: 8 pushes in ~2 min); fast-lane dirt (episode user-state,
// subscriptions) pushes immediately and piggybacks any slow rows; explicit
// flushes (activation / sign-in / lifecycle checkpoints / debounce expiry)
// never defer. The debounce timer itself needs a live CKSyncEngine and is
// device-verified — only the pure lane policy is unit-tested here.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

final class SyncPushCoalescingTests: XCTestCase {

    func testSlowLaneOnlyDirtDefersWhenCoalescing() {
        XCTAssertTrue(CloudSyncEngine.shouldDeferSlowLane(.coalesce, fastCount: 0, slowCount: 2))
    }

    func testFastLaneDirtPushesImmediatelyAndPiggybacksSlowLane() {
        // A CloudKit push is going out for the fast lane anyway, so deferring
        // the slow rows would only cost a second request later.
        XCTAssertFalse(CloudSyncEngine.shouldDeferSlowLane(.coalesce, fastCount: 1, slowCount: 2))
    }

    func testFastLaneOnlyDirtPushesImmediately() {
        XCTAssertFalse(CloudSyncEngine.shouldDeferSlowLane(.coalesce, fastCount: 3, slowCount: 0))
    }

    func testNothingPendingDoesNotDefer() {
        // No dirt at all: the queue pass just returns; scheduling a timer here
        // would produce a guaranteed-empty flush later.
        XCTAssertFalse(CloudSyncEngine.shouldDeferSlowLane(.coalesce, fastCount: 0, slowCount: 0))
    }

    func testLifecycleFlushNeverDefers() {
        XCTAssertFalse(CloudSyncEngine.shouldDeferSlowLane(
            .flush(reason: "playback.pause"), fastCount: 0, slowCount: 3
        ))
    }

    func testDebounceExpiryFlushNeverDefers() {
        XCTAssertFalse(CloudSyncEngine.shouldDeferSlowLane(
            .flush(reason: "slowLaneDebounce"), fastCount: 0, slowCount: 1
        ))
    }

    func testSlowLaneDebounceIsMuchLongerThanFastStoreDebounce() {
        // The fast lane rides the 1 s store debounce (observeStoreChanges); the
        // slow lane only earns its keep if it batches a playback session's
        // stats/history churn into on the order of one push per minute.
        XCTAssertGreaterThanOrEqual(CloudSyncEngine.slowLaneDebounceSeconds, 30)
    }
}
