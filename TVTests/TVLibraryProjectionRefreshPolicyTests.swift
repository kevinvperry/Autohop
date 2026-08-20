import XCTest
import AutohopCore
@testable import AutohopTV

// AI CONTEXT — Guards the O(1) Library refresh gate. An unchanged freshness
// poll must skip the full Subscription/episode graph; real store mutations and
// survival-kit materialisation changes must still rebuild it.
final class TVLibraryProjectionRefreshPolicyTests: XCTestCase {
    func testUnchangedRevisionSkipsFullLibraryProjection() {
        XCTAssertFalse(TVLibraryProjectionRefreshPolicy.shouldRebuild(
            lastRevision: 42, currentRevision: 42, explicitlyInvalidated: false
        ))
    }

    func testChangedRevisionRebuildsLibraryProjection() {
        XCTAssertTrue(TVLibraryProjectionRefreshPolicy.shouldRebuild(
            lastRevision: 42, currentRevision: 43, explicitlyInvalidated: false
        ))
    }

    func testInitialAndExplicitInvalidationRebuild() {
        XCTAssertTrue(TVLibraryProjectionRefreshPolicy.shouldRebuild(
            lastRevision: nil, currentRevision: 0, explicitlyInvalidated: false
        ))
        XCTAssertTrue(TVLibraryProjectionRefreshPolicy.shouldRebuild(
            lastRevision: 42, currentRevision: 42, explicitlyInvalidated: true
        ))
    }

    @MainActor
    func testAuthoredStoreMutationAdvancesProjectionRevision() {
        let store = SubscriptionStore.inMemory()
        let initialRevision = store.projectionRevision
        let feedURL = URL(string: "https://example.com/revision.xml")!
        let feed = ParsedFeed(
            title: "Revision Show", author: nil, artworkURL: nil,
            latestEpisode: nil, episodes: []
        )

        _ = store.materialize(
            parsedFeed: feed, feedURL: feedURL,
            subscriptionID: UUID(), priorityRank: 1
        )

        XCTAssertGreaterThan(store.projectionRevision, initialRevision)
    }
}
