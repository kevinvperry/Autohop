// AI CONTEXT — Tests/SubscriptionSurvivalKitTests.swift. Headless tests for the
// tvOS purge-recovery survival kit (proposal T2): capture excludes browse
// previews and orders by priority, identity round-trips through UserDefaults
// (the subscriptionID is what keeps synced records applicable after a rebuild),
// and the identity-preserving SubscriptionStore.materialize path recreates a
// subscription with the SAME id + rank and full episode catalog, no-oping when
// the id already exists. Also covers the 2026-07-04 priority-rank-corruption
// fix: out-of-order remote materialization (CloudKit delivery order != phone
// rank order) must still converge on the true relative Priority Stack order —
// see resortByCurrentPriorityRank in SubscriptionStore.swift for the bug.
import XCTest
#if AUTOHOP_SPM
@testable import AutohopCore
#else
@testable import Autohop
#endif

@MainActor
final class SubscriptionSurvivalKitTests: XCTestCase {

    private func makeSubscription(title: String, rank: Int, browse: Bool = false) -> Subscription {
        var sub = Subscription(
            id: UUID(),
            feedURL: URL(string: "https://f.com/\(title)")!,
            title: title,
            priorityRank: rank
        )
        if browse { sub.browseDate = Date() }
        return sub
    }

    func testCaptureExcludesBrowsePreviewsAndOrdersByRank() {
        let kit = SubscriptionSurvivalKit.capture(
            from: [
                makeSubscription(title: "second", rank: 2),
                makeSubscription(title: "preview", rank: 3, browse: true),
                makeSubscription(title: "first", rank: 1)
            ],
            iCloudSyncEnabled: true
        )

        XCTAssertEqual(kit.entries.map(\.title), ["first", "second"])
        XCTAssertTrue(kit.iCloudSyncEnabled)
    }

    func testKitRoundTripsThroughUserDefaultsPreservingIdentity() throws {
        let suite = "survival-kit-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let sub = makeSubscription(title: "Show", rank: 1)
        let store = SurvivalKitStore(defaults: defaults)
        store.save(SubscriptionSurvivalKit.capture(from: [sub], iCloudSyncEnabled: false))

        let loaded = try XCTUnwrap(SurvivalKitStore(defaults: defaults).load())
        XCTAssertEqual(loaded.entries.first?.subscriptionID, sub.id)
        XCTAssertEqual(loaded.entries.first?.feedURL, sub.feedURL)
        XCTAssertFalse(loaded.iCloudSyncEnabled)
    }

    func testMaterializePreservesIdentityRankAndCatalog() throws {
        let store = SubscriptionStore.inMemory()
        let preservedID = UUID()
        let feedURL = URL(string: "https://f.com/rebuilt")!

        func makeParsedEpisode(guid: String, title: String, url: String) -> ParsedEpisode {
            ParsedEpisode(
                guid: guid, title: title, description: nil, subtitle: nil,
                author: nil, publishedAt: nil, durationSeconds: nil,
                audioURL: URL(string: url)!, artworkURL: nil, fileSizeBytes: nil,
                isExplicit: nil, chapters: [], externalChaptersURL: nil
            )
        }
        let newest = makeParsedEpisode(guid: "e2", title: "Newest", url: "https://e.com/2.mp3")
        let older = makeParsedEpisode(guid: "e1", title: "Older", url: "https://e.com/1.mp3")
        let parsed = ParsedFeed(
            title: "Rebuilt Show", author: "Author", artworkURL: nil,
            latestEpisode: newest, episodes: [newest, older]
        )

        let rebuilt = store.materialize(
            parsedFeed: parsed,
            feedURL: feedURL,
            subscriptionID: preservedID,
            priorityRank: 1
        )

        XCTAssertEqual(rebuilt.id, preservedID, "Synced records key on this UUID — it must survive the rebuild")
        XCTAssertEqual(rebuilt.title, "Rebuilt Show")
        XCTAssertEqual(rebuilt.episodes.map { $0.guid }, ["e2", "e1"])
        XCTAssertEqual(rebuilt.latestEpisode?.guid, "e2")
        XCTAssertEqual(store.subscription(id: preservedID)?.priorityRank, 1)

        // Rebuilding again is a no-op returning the existing subscription.
        let again = store.materialize(parsedFeed: parsed, feedURL: feedURL, subscriptionID: preservedID)
        XCTAssertEqual(again.id, preservedID)
        XCTAssertEqual(store.subscriptions.filter { $0.feedURL == feedURL }.count, 1)
    }

    /// Reproduces the exact bug found via real-device tvOS testing
    /// (2026-07-04): a fresh device receiving several subscriptions from
    /// CloudKit in ARBITRARY delivery order (not priority order) must still
    /// end up with the phone's true relative Priority Stack order — not
    /// "whatever order they happened to arrive in." This is what TVAppModel's
    /// materializeRemoteSubscription does per-subscription: materialize (no
    /// rank yet) then applyRemoteSubscriptionState (sets the true synced
    /// rank). Before the fix, the second call's normalizePriorityOrder()
    /// clobbered every subscription's rank to its current array position,
    /// destroying the very value just set the moment the NEXT subscription
    /// materialized.
    func testOutOfOrderRemoteMaterializationPreservesTruePriorityOrder() async throws {
        let store = SubscriptionStore.inMemory()

        // Phone's true order: First(1), Second(2), Third(3). CloudKit
        // delivers them to this fresh device in a DIFFERENT order.
        let firstID = UUID(), secondID = UUID(), thirdID = UUID()
        func materializeAndApply(id: UUID, title: String, rank: Int, feedURLPath: String) async throws {
            let feedURL = URL(string: "https://f.com/\(feedURLPath)")!
            let episode = ParsedEpisode(
                guid: "g", title: "Ep", description: nil, subtitle: nil,
                author: nil, publishedAt: nil, durationSeconds: nil,
                audioURL: URL(string: "https://e.com/\(feedURLPath).mp3")!,
                artworkURL: nil, fileSizeBytes: nil, isExplicit: nil,
                chapters: [], externalChaptersURL: nil
            )
            let parsed = ParsedFeed(title: title, author: nil, artworkURL: nil, latestEpisode: episode, episodes: [episode])
            // Mirrors TVAppModel.materializeRemoteSubscription: materialize
            // first (rank unknown), then apply the synced state carrying the
            // TRUE rank — arrival order here is deliberately NOT rank order.
            // flushPendingSaves() between the two: SubscriptionStore.save()
            // persists asynchronously on a background queue, and
            // applyRemoteSubscriptionState's baseline read
            // (database.subscriptionSyncState) needs materialize's freshly-
            // seeded projection row to have actually landed first — the real
            // TVAppModel flow always has a real async gap here (a network
            // feed fetch); this closes the same gap deterministically in a test.
            _ = store.materialize(parsedFeed: parsed, feedURL: feedURL, subscriptionID: id)
            await store.flushPendingSaves()
            let state = SubscriptionSyncState(
                subscription: Subscription(id: id, feedURL: feedURL, title: title, priorityRank: rank),
                dirtyAt: Date()
            )
            store.applyRemoteSubscriptionState(state)
            await store.flushPendingSaves()
        }

        // Arrival order: Third, First, Second — scrambled relative to rank.
        try await materializeAndApply(id: thirdID, title: "Third", rank: 3, feedURLPath: "third")
        try await materializeAndApply(id: firstID, title: "First", rank: 1, feedURLPath: "first")
        try await materializeAndApply(id: secondID, title: "Second", rank: 2, feedURLPath: "second")

        let orderedTitles = store.subscriptions
            .sorted { $0.priorityRank < $1.priorityRank }
            .map(\.title)
        XCTAssertEqual(orderedTitles, ["First", "Second", "Third"], "True synced rank order must survive arbitrary CloudKit delivery order")
    }

    /// Reproduces the second real-device bug (2026-07-04): Up Next full of
    /// episodes already played/archived on iPhone. An `EpisodeSyncState`
    /// record can arrive (and get stashed as a clean projection) BEFORE the
    /// subscription that owns it has materialized — CloudKit doesn't
    /// guarantee episode records arrive after their parent subscription.
    /// `materialize` must self-heal from that stashed projection, exactly
    /// like `updateEpisodes` already does for the iPhone feed-refresh path.
    func testMaterializeSelfHealsFromEpisodeStateStashedBeforeSubscriptionExisted() throws {
        let store = SubscriptionStore.inMemory()
        let subscriptionID = UUID()
        let feedURL = URL(string: "https://f.com/show")!

        // The EpisodeState record arrives first — episode doesn't exist
        // locally yet, so this hits applyRemoteEpisodeState's stash branch.
        let episode = Episode(
            subscriptionID: subscriptionID, guid: "ep1", title: "Old Episode",
            audioURL: URL(string: "https://e.com/1.mp3")!
        )
        var remoteState = EpisodeSyncState(episode: episode, subscriptionID: subscriptionID)
        remoteState.playedState = .archived
        remoteState.wasCompleted = true
        _ = store.applyRemoteEpisodeState(remoteState)

        // Now the subscription itself materializes, bringing that episode in.
        let parsedEpisode = ParsedEpisode(
            guid: "ep1", title: "Old Episode", description: nil, subtitle: nil,
            author: nil, publishedAt: nil, durationSeconds: nil,
            audioURL: URL(string: "https://e.com/1.mp3")!, artworkURL: nil,
            fileSizeBytes: nil, isExplicit: nil, chapters: [], externalChaptersURL: nil
        )
        let parsed = ParsedFeed(title: "Show", author: nil, artworkURL: nil, latestEpisode: parsedEpisode, episodes: [parsedEpisode])
        let rebuilt = store.materialize(parsedFeed: parsed, feedURL: feedURL, subscriptionID: subscriptionID)

        let healedEpisode = try XCTUnwrap(rebuilt.episodes.first)
        XCTAssertEqual(healedEpisode.playedState, .archived, "The stashed EpisodeState must be applied, not left at the RSS default of .unplayed")
        XCTAssertTrue(healedEpisode.wasCompleted)
        XCTAssertEqual(healedEpisode.downloadState, .notDownloaded)

        // And QueueModel.streamableQueue must therefore exclude it.
        XCTAssertTrue(QueueModel.streamableQueue(from: [rebuilt]).isEmpty)
    }
}
