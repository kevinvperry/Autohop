import SwiftUI
import Combine
import CloudKit
import Observation
import AutohopCore

// AI CONTEXT — TV/App/AutohopTVApp.swift
// tvOS Phase 1 (Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md §6): app entry point,
// TVAppModel composition root, and the purge-resilient bootstrap (T2). This
// target consumes AutohopCore as a LIBRARY (import AutohopCore) — it must
// never compile iOS sources or reach for AppState; TVAppModel is deliberately
// the anti-AppState (@Observable, a few hundred lines max, composed from
// Phase 0 domain objects).
// BOOTSTRAP (T2): the GRDB store lives in Caches (purgeable!). Cold start:
// read the survival kit (durable UserDefaults: subscription IDs + feed URLs +
// ranks) → refetch each missing feed → SubscriptionStore.materialize with the
// PRESERVED subscriptionID (identity is what keeps synced records applicable)
// → start CloudSyncEngine (its own account check aborts gracefully without
// iCloud) → remote SubscriptionState records for unknown podcasts arrive via
// onSubscriptionNeedsMaterialization and build the library on first-ever
// launch. The kit is rewritten (debounced) on every store change.
// ROOT STATE: loading → ready | empty (PC RootView shape, minus auth).
// `ready` shows the Home/Discover/Subscriptions/History/Settings TabView
// (TVMainTabView); Home
// owns the complete Up Next queue presentation.
// FIRST-SYNC WAIT (fixed 2026-07-04, found on Kevin's real Apple TV): a
// device with no prior CloudKit change token does a full historical fetch of
// the whole private zone, which can legitimately take MINUTES (observed ~4
// on a fresh install) — Apple's fetch speed, not something this app
// controls. `bootstrap()` keeps `rootState == .loading` (animated spinner +
// rotating status text, see waitForFirstSyncWithAnimatedStatus) for a long
// grace window instead of flipping to the static `.empty` screen almost
// immediately, which is what silently happened before (refreshLibrary() was
// called BEFORE the old short wait even started, so the wait's own status
// text updates were never visible). `.empty` itself now also carries a
// small persistent spinner — it is never a dead end: the debounced
// `observeStoreForKitWrites` sink keeps refreshing in the background and
// will flip to `.ready` automatically whenever CloudKit actually delivers
// something, no matter which screen happens to be showing at the time.
// No Simulator debug bypass anymore (removed 2026-07-04 once real-hardware
// testing worked) — see git history if one is ever needed again.
// NOTE: librarySubscriptions is an Observation-tracked mirror of the store's
// library (SubscriptionStore is ObservableObject; its @Published changes are
// NOT tracked by @Observable views — always read the mirror in TV views).
// 2026-07-11 (Kevin's real-device round 5): Latest shelf REMOVED (latestEpisodes
// deleted — Up Next is the point of the TV Home); Continue Listening reworked to
// render from the synced history entry itself (see computeContinueListening);
// prime order flipped to queue/history-first; TV now records listening stats
// (listeningStatsStore) so TV consumption lands on the iPhone's Stats page;
// animated splash (TVLaunchLoadingView) replaces the bare loading spinner.
// PHASE 2 (§7): upNextItems/upNextEpisodes/continueListening and
// the subscription(id:) lookup were originally derived from librarySubscriptions
// on EVERY ACCESS (assumed cheap at "dozens of subscriptions" — the library grew
// to 113, matching the iPhone, invalidating that; PERF FIX 2026-07-10, found
// investigating a reported memory/CPU bug, see refreshLibrary()'s own note).
// They're now cached: recomputed ONCE per refreshLibrary() call (real data
// changes) via recomputeDerivedState(), read back as plain O(1) stored state —
// same pattern as the iPhone's cachedDownloadedQueue, this file just didn't need
// it until the library grew. The former per-foreground all-library RSS sweep
// has now been deleted; only bounded row/detail recovery may fetch feeds.

@main
struct AutohopTVApp: App {
    // LAZY MODEL (2026-07-11, Kevin's round 6: "no splash, just a blank page
    // for ~15 s"): TVAppModel's init synchronously loads the whole GRDB store
    // (113 subscriptions × episodes decoded on the main actor). As a `@State
    // = TVAppModel()` default it ran BEFORE SwiftUI could draw the first
    // frame, so the window sat on the bare background colour until the load
    // finished — the splash never had a chance to appear. Now the splash
    // renders first and the model is created one frame later in .task.
    // ROUND 7 (2026-07-11, "the start up animation does not have any
    // movement — just a static image"): creating the model later wasn't
    // enough — the synchronous decode then froze the main actor WHILE the
    // splash was up, and SwiftUI animations are main-thread driven, so the
    // splash showed but its bars never moved. The store now defers the
    // decode (SubscriptionStore deferred-load init) and bootstrap() runs it
    // off-main via completeDeferredLoad(), keeping the main actor free so
    // the splash actually animates.
    @State private var model: TVAppModel?
    // AI CONTEXT — Presentation watchdog only. It never cancels or races the
    // mutable bootstrap task. Clean installs expose setup/demo after ten
    // seconds; durable returning-library evidence receives a separate 45-second
    // branded recovery grace while the one bootstrap may still publish ready.
    @State private var launchDeadlineReached = false
    @State private var returningRecoveryDeadlineReached = false
    @State private var pendingRouteCoordinator = TVPendingRouteCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    // CKSyncEngine uses the app delegate's remote-notification registration
    // to receive private-iCloud change notifications while the app is installed.
    @UIApplicationDelegateAdaptor(TVAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    TVRootView(
                        model: model,
                        launchDeadlineReached: launchDeadlineReached,
                        returningRecoveryDeadlineReached: returningRecoveryDeadlineReached,
                        pendingRouteCoordinator: pendingRouteCoordinator
                    )
                } else {
                    TVLaunchLoadingView(statusText: "Loading your library…")
                }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { pendingRouteCoordinator.accept($0) }
            .task {
                guard model == nil else { return }
                // Give the splash one rendered frame before the heavy
                // synchronous store load begins.
                try? await Task.sleep(for: .milliseconds(50))
                let created = TVAppModel()
                model = created
                Task { @MainActor in
                    try? await Task.sleep(for: TVLaunchAccessPolicy.firstUsableScreenDeadline)
                    guard created.bootstrapCoordinator.isLoading else { return }
                    launchDeadlineReached = true
                    AppLogger.shared.warning(
                        "tv.bootstrap.presentationDeadline",
                        "Bootstrap exceeded the first-usable-screen deadline; setup actions exposed while work continues",
                        alwaysPersist: true
                    )
                }
                Task { @MainActor in
                    try? await Task.sleep(for: TVLaunchAccessPolicy.returningLibraryRecoveryDeadline)
                    guard created.bootstrapCoordinator.isLoading,
                          created.hasReturningLibraryEvidence
                    else { return }
                    returningRecoveryDeadlineReached = true
                    AppLogger.shared.warning(
                        "tv.bootstrap.returningRecoveryDeadline",
                        "Returning library evidence remained unavailable after extended recovery grace",
                        alwaysPersist: true
                    )
                }
                await created.bootstrap()
            }
            .onChange(of: scenePhase) { _, phase in
                TVHangWatchdog.shared.setSceneActive(phase == .active)
                guard let model else { return }
                model.isSceneActive = (phase == .active)
                // Returning to the foreground: re-prime the library + queue
                // snapshot directly so the Library and Up Next reflect any
                // phone-side changes (new subscriptions, reordered queue)
                // made while the TV app was backgrounded, without waiting
                // for the change stream to drain.
                if phase == .active {
                    Task { await model.primeLibraryFromCloudSoon(reason: "foreground") }
                } else if phase == .background {
                    // Leaving the foreground: persist + force-push the
                    // current position so it reaches the phone promptly.
                    model.handleBackgrounded()
                    TVArtworkLoader.shared.trimForMemoryPressure()
                }
            }
        }
    }
}
