import Combine
import CloudKit
import Foundation
import AutohopCore

// AI CONTEXT — Launch/bootstrap workflow. Extracted from TVAppModel without changing
// product policy; this extension is tvOS-only and coordinated through focused
// observable state owners defined in TVAppFeatureModels.swift.

extension TVAppModel {
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Keep the branded launch experience informative while the real store,
        // queue and history projections are assembled. The task is cancelled
        // as soon as bootstrap publishes a usable root state.
        let launchMessageTask = Task { [weak self] in
            await self?.waitForFirstSyncWithAnimatedStatus()
        }
        defer { launchMessageTask.cancel() }

        // Finish the deferred store load FIRST (off-main decode — see init's
        // note); everything below reads store.subscriptions.
        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        await subscriptionStore.completeDeferredLoad()
        AppLogger.shared.info("tv.perf", "Deferred store load finished", metadata: [
            "stage": "storeLoad",
            "ms": String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000),
            "subscriptions": "\(subscriptionStore.subscriptions.count)"
        ], alwaysPersist: true)

        if let kit = survivalKitStore.load() {
            await rebuildMissingSubscriptions(from: kit)
        }
        // ONE-SHOT REPAIR (2026-07-11) — MUST run before startCloudSync(): a TV
        // database rebuilt from the survival kit before the materialize
        // clean-seed fix holds fully-dirty DEFAULT-settings projections for
        // every subscription; engine activation queues dirty state, so starting
        // sync first would re-push the defaults and re-clobber the phone's real
        // settings (the exact damage Kevin reported). Safe on TV because the TV
        // never authors subscription settings — see the method's header.
        let repairFlag = "com.autohop.tv.cleanDefaultProjectionDirt.v1"
        if !UserDefaults.standard.bool(forKey: repairFlag) {
            let cleaned = subscriptionStore.markAllPendingSubscriptionProjectionsClean()
            UserDefaults.standard.set(true, forKey: repairFlag)
            if cleaned > 0 {
                AppLogger.shared.warning("sync.tvProjectionDirtRepaired", "Cleared pre-fix dirty subscription projections that would have pushed default settings", metadata: [
                    "count": "\(cleaned)"
                ], alwaysPersist: true)
            }
        }
        startCloudSync()
        observeStoreForKitWrites()
        startForegroundFreshnessPolling()

        // Prime the library DIRECTLY (targeted zone queries) rather than
        // waiting for CKSyncEngine's cold-start delta stream — Kevin's
        // real-device findings were a ~5-min "No Library Yet" blank AND the Up
        // Next queue cycling stale episodes for ~10 min. This fetches every
        // subscription record (kicking off feed materialisation immediately)
        // and the Up Next queue snapshot the moment the engine activates. Runs
        // in the background (retries until activation) so it never blocks the
        // launch path.
        Task { await primeLibraryFromCloudSoon(reason: "launch") }

        // Fast path: the survival-kit rebuild (or a database that already
        // survived from a previous launch) may already have real content —
        // don't make a returning device sit through the first-sync wait.
        refreshLibrary()
        // A returning device normally becomes ready immediately. A true first
        // install gets a short iCloud grace while the launch carousel explains
        // what is happening, then an actionable empty/offline state while
        // CloudKit continues progressively in the background.
        guard rootState != .ready else { return }
        rootState = .loading
        statusText = "Connecting to your iCloud library…"
        try? await Task.sleep(for: .seconds(8))
        refreshLibrary()
    }

    /// Shown IN ORDER (not shuffled) so the informative ones about what's
    /// actually happening come first, then Autohop feature highlights, with
    /// family-friendly dad jokes sprinkled throughout for relief. Normal
    /// bootstrap exits after only a couple of messages; the longer rotation is
    /// retained for an exceptional survival-kit rebuild without looking frozen.
    static var firstSyncWaitMessages: [String] { [
        // — What's actually happening (process, in rough order) —
        "Connecting to your iCloud library…",
        "Asking iCloud for your podcasts — the first sync fetches everything, so it takes a few minutes…",
        "Your subscriptions arrive first, then each show's episode list…",
        "Why don't podcasts ever get lost? They always follow the feed.",
        "Downloading your show list from iCloud — it only takes this long the first time…",
        "Played and archived episodes are matched up next, so your progress carries over…",
        "I asked iCloud to hurry up. It said it needed a moment to sync in.",
        "Episode artwork and details are filled in from each show's RSS feed…",
        "Your Priority Stack order comes across too — shows appear in YOUR order…",
        "What's a podcast's favourite exercise? The feed-lift.",
        "Listening positions sync as well, so you can resume right where you left off…",
        "Your Up Next queue syncs from your iPhone — same episodes, same order…",
        "Why did the episode go to school? To get a little more well-listened.",
        // — Feature highlights (the Autohop tour) —
        "Autohop's Priority Stack plays your favourite shows first, automatically…",
        "On iPhone, new episodes download themselves — Up Next is always ready to play…",
        "What do you call a queue that builds itself? Up Next. We checked — it's very modest about it.",
        "Release Radar learns each show's schedule and checks feeds right when new episodes drop…",
        "Trim Silence on iPhone skips the quiet gaps — hours saved without missing a word…",
        "Vocal Boost lifts voices above the background music, great for noisy rooms…",
        "Why did the silence get trimmed? It didn't have anything to say for itself.",
        "Sleep Schedule can ask 'still listening?' at night and rewind to where you dozed off…",
        "The Stats page tracks your listening streaks, top shows, and total time saved…",
        "Chapters are supported too — skip straight to the segment you want…",
        "What's a podcast host's favourite dinner? Anything with good seasoning… and a mid-roll.",
        "Download Filters can skip trailers and short episodes automatically…",
        "Autohop works in the car too — the full queue is on CarPlay…",
        "Shared Listening slows things down evenly so everyone in the room can follow along…",
        "Why don't podcast apps tell secrets? Too many listeners.",
        "Everything syncs through YOUR private iCloud — no accounts, no servers, no tracking…",
        "Episodes played here mark as played on your iPhone too — one library, everywhere…",
        // — Reassurance (the long-tail wait) —
        "Still syncing — larger libraries take a little longer, but it's all on the way…",
        "What did the Apple TV say to the iPhone? 'You're breaking up… but your podcasts aren't.'",
        "Nearly there — the first sync is always the slowest; launches after this are instant…",
        "Your queue, positions, and played history are all coming across…",
        "Why was the podcast app so calm? Everything was under subscription.",
        "Apple's iCloud sets the pace on a first sync — Autohop grabs everything the moment it lands…",
        "Once this finishes, this Apple TV stays in step with your iPhone automatically…",
        "How does a podcast say goodbye? 'Thanks for listening — see you next episode!'",
        "Hang tight — good things come to those who sync…",
        "Fetching the last few shows now…",
        "What's the loading screen's favourite song? 'The Waiting' — it's a deep cut.",
        "Almost done — your library is nearly all here…"
    ] }

    /// Rotates friendly, factual messages on the branded launch screen while
    /// bootstrap is building the first usable Home projection.
    func waitForFirstSyncWithAnimatedStatus() async {
        var messageIndex = 0
        for _ in 0..<Self.firstSyncWaitMessages.count {
            guard !Task.isCancelled, rootState == .loading else { return }
            statusText = Self.firstSyncWaitMessages[messageIndex % Self.firstSyncWaitMessages.count]
            messageIndex += 1
            try? await Task.sleep(for: .seconds(7))
        }
    }

}
