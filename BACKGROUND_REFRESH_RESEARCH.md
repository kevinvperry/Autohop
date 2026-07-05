# Autohop — Background Refresh: Research & Code Audit (2026-06-24)

> **Audience: AI models + the developer.** This document is the reference for why
> background feed refresh is unreliable on iOS, what the platform actually permits,
> the modern (Swift 5.9+/iOS 17, Swift-6-concurrency-ready) implementation pattern,
> and a concrete audit of Autohop's current code against that pattern. It is
> research + analysis only — **no behaviour was changed.** Sourced from Apple's
> BackgroundTasks docs, WWDC "Background Execution Demystified" (2020) and "Finish
> tasks in the background" (2025), and corroborating practitioner sources (links at
> the end).
>
> **Revised 2026-06-24** after an independent code review (Codex): corrected the Low
> Power Mode claim (it *is* read, diagnostically), softened the ≤100 KB and
> earliest-begin-date items, and added nuance to the silent-push row. The central
> finding (poller stands down in the background) was confirmed unchanged. See §6.

---

## 0. Plain-English summary

> **✅ STATUS (2026-06-24, device-verified):** Both Tier 1 fixes are **resolved** — the
> poller now refreshes feeds during background audio playback (audit #8/#9), and
> Settings → Release Radar warns when Background App Refresh is off (audit #10). The
> remaining Tier 2/3 items are optional. The sections below keep the original analysis
> for context.
>
> **Also fixed since:** the `BGProcessingTask` overnight catch-up (Tier 2 #3), and a
> log-driven robustness fix (from the Wed→Thu overnight log) where an expiring BGTask
> cancelled a refresh cycle a live foreground/audio context still owned. The cancel is
> now `cancelRefreshCycleIfBackgroundOnly`, and the behavioural decisions (this + the
> poller guard) use the real `isAppForeground` (UIApplication state) instead of the
> cached `isSceneActive`, which can be stale-`true` on a background relaunch.

iOS does **not** let an app refresh on a fixed background schedule. `BGAppRefreshTask`
is a *hint*; the system decides if and when it runs, mostly based on **how often and
how regularly the user opens the app**, and it suppresses it entirely if the user has
**force-quit** the app or turned **Background App Refresh** off. So "feeds don't
update in the background" is largely Apple working as designed — no scheduling code
will make it reliable.

The one window an app *fully controls* is **while audio is playing**: with the
`audio` background mode, the app stays alive and unthrottled during playback. For a
podcast player this is the best, most reliable refresh window — and **Autohop now uses
it** (the poller runs on `isSceneActive || isPlaying`, refreshing feeds and queuing
downloads while the user listens). This was the highest-leverage fix and the most
likely cause of the original frustration — now resolved (audit #8/#9).

---

## 1. The reality: `BGAppRefreshTask` is best-effort, never guaranteed

- Apple engineer, verbatim: *"if you expect that the app refresh mechanism will grant
  you background execution time, say, every 15 minutes, you'll be disappointed."*
- WWDC: *"It is entirely up to the system to decide when background tasks will be
  executed, and if at all."*
- **iOS 26 tightened this further** — the platform is more aggressive about
  suppressing background work; "you cannot count on background execution time every
  15 minutes."
- Practitioner consensus: **treat background refresh as supplementary**, never as the
  primary content-update path.

## 2. Factors that govern whether `BGAppRefreshTask` fires (ranked by real-world impact)

1. **System ML prediction of when the user opens the app** — the dominant factor.
   *"the device uses machine learning to figure out when you are most likely to use
   the app, then it refreshes right before it expects you to use it."* Rarely/
   irregularly opened apps get refreshed rarely.
2. **Force-quit suppresses everything.** If the user swipes the app away in the App
   Switcher, iOS suppresses `BGAppRefreshTask`, background-`URLSession` relaunches,
   **and** silent pushes until the next *manual* launch. Habitual force-quitters get
   zero off-app updates.
3. **Background App Refresh setting** (Settings → General → Background App Refresh,
   and per-app) must be ON.
4. **Low Power Mode** suppresses background execution.
5. **Energy + cellular-data budgets**, depleted across the day. Guidance: keep each
   refresh **under ~30 s and ~100 KB**.
6. **Device state** — low battery, thermal pressure.

## 3. The mechanisms, and what each is genuinely for

| Mechanism | Reliability | Best for | Notes |
|---|---|---|---|
| `BGAppRefreshTask` | Low / opportunistic | Short "catch up before the user opens" | ≤30 s, ≤100 KB; 1 refresh-task max scheduled |
| **Background audio keep-alive** | **High — while playing** | App is *fully alive & unthrottled* during background audio | Best window for a podcast app; no BGTask budget |
| Background `URLSession` | High (system-managed) | Downloads that finish / relaunch the app when suspended | `isDiscretionary=false` for user-relevant work |
| `BGProcessingTask` | Low-moderate, minutes of runtime | Charger + Wi-Fi overnight catch-up | Needs its own identifier + capability |
| Silent / background push | **Highest** | Server says "new episode now" | Push plumbing **exists** (`remote-notification` is declared for CloudKit sync), but there is **no feed-watching server**, so it can't signal new episodes |
| `BGContinuedProcessingTask` (iOS 26) | High but **user-initiated only** | A task the *user* starts (button tap) that finishes after backgrounding | Cannot power *automatic* refresh |

## 4. The podcast-specific insight (highest leverage)

Because the app holds the `audio` background mode, **whenever audio is playing the
process is alive and not subject to BGTask budgets** — a normal run loop. A repeating
timer can refresh every due feed and queue downloads during playback. Podcast users
listen regularly, so this window covers a large share of "new episode arrived" moments
**reliably and entirely within the app's control** — unlike `BGAppRefreshTask`.

> ✅ **Implemented 2026-06-24** — `startForegroundPolling()` now runs on
> `isSceneActive || isPlaying`, so this window is in use. See §6 audit #8.

## 5. Modern implementation pattern (Swift 5.9+/iOS 17, Swift-6-concurrency-ready)

The current recommended shape uses structured concurrency: an async `Task` for the
work, cooperative cancellation via the `expirationHandler`, and `Sendable` types.

```swift
BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
    guard let task = task as? BGAppRefreshTask else { return }

    // 1. Reschedule the NEXT request immediately — a fired request is not reused.
    scheduleNextAppRefresh()

    // 2. Structured async work.
    let work = Task {
        let didRun = await refreshDueFeeds()       // checks Task.isCancelled internally
        // 3. "Nothing due" is still success — reporting failure deprioritises wakes.
        task.setTaskCompleted(success: true)
    }

    // 4. Cooperative cancellation when the system reclaims the time.
    task.expirationHandler = {
        work.cancel()                              // Task.isCancelled flips → loops exit
        task.setTaskCompleted(success: false)
    }
}
```

Modern-standards checklist:
- **Structured concurrency** (`Task { await … }`) not completion-handler pyramids.
- **Cooperative cancellation**: long loops check `Task.isCancelled` and bail; the
  `expirationHandler` calls `work.cancel()`. Prefer checking `Task.isCancelled` over
  `try Task.checkCancellation()` when you need to checkpoint/clean up.
- **`Sendable` value types** for anything crossing task/actor boundaries (Swift 6).
- **`@MainActor` isolation** for shared mutable model state; hop to it explicitly.
- **Conditional GET** (ETag / Last-Modified) keeps each refresh far under the 100 KB
  budget — re-validation is essentially free (`304 Not Modified`).
- **Detect the user's settings**: read `UIApplication.shared.backgroundRefreshStatus`
  (`.available` / `.denied` / `.restricted`) and `ProcessInfo.processInfo.isLowPowerModeEnabled`
  to explain to the user why off-app updates may be paused.

---

## 6. Autohop audit — current code vs. the checklist

> Files: `App/AppDelegate.swift`, `App/BackgroundTaskCoordinator.swift`,
> `App/AppState.swift`. Anchors are approximate — re-locate by symbol.

| # | Checklist item | Status | Evidence |
|---|---|---|---|
| 1 | Register handler before `didFinishLaunching` returns | ✅ | `AppDelegate.registerBackgroundTasks()` called from `didFinishLaunching` (`AppDelegate.swift:32,77`) |
| 2 | Reschedule next request at **start** of handler | ✅ | `BackgroundTaskCoordinator.scheduleAppRefresh()` first line of `handleFeedRefresh` (`AppDelegate.swift:96`) |
| 3 | Modern async work + cooperative cancellation | ✅ | `let work = Task { await … }` + `expirationHandler { work.cancel(); setTaskCompleted(false) }` (`AppDelegate.swift:98-118`); `performRefreshCycle` checks `Task.isCancelled` and checkpoints the backlog |
| 4 | `setTaskCompleted(success: true)` even for "nothing due" | ✅ | `AppDelegate.swift:104-106` + the documented rationale |
| 5 | `earliestBeginDate` = soonest due feed, 15-min floor | ✅ (two-step) | The handler first submits a **generic 15-min** request (`scheduleAppRefresh()` no-arg, `AppDelegate.swift:96`) as a safety net, then the cycle **replaces** it with the due-feed date (`scheduleBackgroundRefreshForNextDueFeed()` → `scheduleAppRefresh(earliestBeginDate:)`, `AppState.swift:3194`). Net pending request = the due date once the cycle finishes; the 15-min one only persists if the cycle is killed first. |
| 6 | Stay near the ~100 KB data budget | ⚠️ partial | Conditional GET (`FeedService.refreshIfModified`, ETag/Last-Modified) makes an **unchanged** feed ≈ 0 bytes (`304`). A **changed** feed still returns a full body (capped at `episodeLimit` 50 items, **not by size**), so the ~100 KB guideline is **helped but not code-enforced**. |
| 7 | Background `URLSession` for downloads (survives suspend, relaunches app) | ✅ | `DownloadManager` background session + `handleEventsForBackgroundURLSession` (`AppDelegate.swift:61`) |
| 8 | **Refresh during background audio (the reliable window)** | ✅ **RESOLVED 2026-06-24** | `startForegroundPolling()` now guards on `isSceneActive || isPlaying`, so it refreshes due feeds and queues downloads while the user listens with the app backgrounded; it only stands down when the process is truly idle/suspended. |
| 9 | `backgroundAudioAlive` context actually used | ✅ **RESOLVED 2026-06-24** | Now reachable: when the poller runs with `!isSceneActive` (background audio), `refreshDueSubscriptions` labels the cycle `.backgroundAudioAlive`. |
| 10 | Detect `backgroundRefreshStatus` / Low Power Mode and inform the user | ✅ **RESOLVED 2026-06-24** | `UIApplication.backgroundRefreshStatus` is now read in `SettingsView` and surfaced as a warning row + "Open iOS Settings" link in the Release Radar section (re-checked on `scenePhase`). Low Power Mode is still only logged diagnostically (`ResourceMonitor.swift:222`), not surfaced — minor/optional. |
| 11 | Guard against double `setTaskCompleted` | ⚠️ minor | `work` calls `setTaskCompleted(true)` and `expirationHandler` calls `setTaskCompleted(false)`; a late expiration after completion would double-call. iOS tolerates it, but a `hasCompleted` flag would be tidier. |

**Net (updated 2026-06-24):** the BGTask plumbing was already textbook-correct; the
gap was **#8/#9**, now **fixed** — the poller refreshes during background audio
playback, so feeds update and new episodes download reliably while the user listens
(app alive). The fully-suspended *not-listening* case still relies on best-effort
`BGAppRefreshTask` — and Tier 1 #2 (detect/educate via a Settings → Release Radar
warning) is now done too, so a user who has Background App Refresh off is told why.

## 7. Prioritised recommendations (for a later change — not yet applied)

**Tier 1 — in the app's control, high impact**
1. ✅ **DONE (2026-06-24) — Refresh during background audio.** `startForegroundPolling()`
   now guards on `isSceneActive || isPlaying`, so `refreshDueSubscriptions()` runs
   (labelled `.backgroundAudioAlive`) while the user listens with the app backgrounded.
   Existing budget/backoff unchanged; gated on `isPlaying` so a truly-idle suspended
   process isn't involved.
2. ✅ **DONE (2026-06-24) — Detect + educate.** Settings → Release Radar now shows a
   warning row + "Open iOS Settings" deep link when `UIApplication.backgroundRefreshStatus
   != .available` (re-checked on `scenePhase`), explaining that off-app checks are paused
   and that force-quitting the app also stops them (`SettingsView.swift`). A more
   prominent home-screen surface remains optional.

**Tier 2 — worth considering, mild tradeoffs**
3. ✅ **DONE (2026-06-24) — `BGProcessingTask` overnight catch-up.** `com.autohop.feedprocessing`
   (gated on `requiresExternalPower` + `requiresNetworkConnectivity`) runs
   `refreshSubscriptionsForProcessing()` — an **uncapped** due-feed sweep that drains the
   deferred backlog and retries backed-off feeds. `processing` background mode re-added to
   Info.plist; App Review notes (APPSTORE_ROADMAP Appendix 2) updated to declare/justify it.
4. Add a `hasCompleted` guard around the two `setTaskCompleted` calls (#11).

**Tier 3 — nuclear option**
5. **Server-driven silent push** is the only *truly* reliable trigger, but it requires
   backend infrastructure and conflicts with the no-server/private stance. Avoid unless
   Tier 1–2 prove insufficient.

**Skip:** `BGContinuedProcessingTask` (iOS 26) — requires an explicit user tap, so it
cannot power automatic refresh; only useful for a user-initiated "Refresh & download".

## 8. Testing background tasks (deterministic)

Pause in the debugger, then in LLDB force a launch / expiration:
```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.autohop.feedrefresh"]
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.autohop.feedrefresh"]
```
This is the only way to exercise the handler on demand; real wakes are non-deterministic.

---

## 9. Diagnosing wake behaviour from the diagnostic log

Three log signals answer "why didn't background refresh run?" without a debugger:

- **`app.launch`** (emitted at `didFinishLaunching`) — `launchState=background` means iOS
  cold-launched the app itself (a BGTask/push wake): the system IS willing to wake it.
  `launchState=foreground` on *every* start, never `background`, is the signature of a
  **terminated / user-force-quit app** — iOS never runs BGTasks for a force-quit app, so
  it only ever comes back because the user reopened it. `backgroundRefreshStatus` on the
  same line reports the OS permission (`available` / `denied` / `restricted`).
- **`background.launch` / `background.processingLaunch`** — logged as the *first* line of
  each BGTask handler. Their **absence** across a session means iOS never fired the task
  (not an app failure). Both now carry `backgroundRefreshStatus` too.
- **`background.schedule`** — a successful `submit()`; since `submit()` throws
  `.notPermitted` when Background App Refresh is off, a `background.schedule` with no
  paired `background.notPermitted` implies the permission is on. Confirm against the
  explicit `backgroundRefreshStatus` label (also stamped into the Release Radar export
  header).

Worked example (2026-07-01 log): activity only 03:24–03:43 then a **cold launch** at
07:47 (`app.bootstrap`, `autoArchive.start reason=app.startup`) — the process was
terminated in between. Zero `background.launch` lines in the 4-hour gap ⇒ iOS never ran
the scheduled task. Every refresh that day was `trigger=foregroundTimer` with the app
open. Root cause was app termination, not a code/config fault (registration, Info.plist
identifiers, and scheduling were all correct).

> **Export must cover the night, or §9 is unusable (fixed 2026-07-06).** The signals
> above only help if they're *in the exported file*. `AppLogger` rotates the log to a
> single `.previous.log` segment when the current file hits the cap; the share/export
> path used to read the current segment only. A long background-audio session logs
> densely enough to rotate mid-session, so a morning-after export could contain just the
> post-rotation tail (observed: a 2-minute export at 04:25 while the overnight data sat
> unread in `.previous.log`) — hiding the very `app.launch` / `background.launch` markers
> this section depends on. Three changes fixed it: (1) the export now stitches
> `.previous.log` + current (`AppLogger.combinedContents`); (2) the cap went 1 MB → 5 MB;
> (3) routine `resources.snapshot` writes are throttled to 45 s while the scene is
> inactive (`ResourceMonitor.minimumBackgroundSnapshotInterval`), the biggest single
> byte source during background playback. Net: a full night of falling-asleep-to-audio
> now fits the two retained segments instead of rotating away in ~30 min.

## 10. Sources

- Apple — [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler),
  [BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask),
  [Using background tasks to update your app](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)
- WWDC 2020 — [Background Execution Demystified](https://wwdcnotes.com/documentation/wwdcnotes/wwdc20-10063-background-execution-demystified/)
- WWDC 2025 — [Finish tasks in the background (BGContinuedProcessingTask)](https://developer.apple.com/videos/play/wwdc2025/227/)
- Mert Bulan — [Don't rely on BGAppRefreshTask for your app's business logic](https://mertbulan.com/programming/dont-rely-on-bgapprefreshtask-for-your-apps-business-logic)
- Uy Nguyen — [Best practice: iOS background processing](https://uynguyen.github.io/2020/09/26/Best-practice-iOS-background-processing-Background-App-Refresh-Task/)
- Andy Ibanez — [Common Reasons for Background Tasks to Fail in iOS](https://www.andyibanez.com/posts/common-reasons-background-tasks-fail-ios/)
- Swift with Majid — [Background tasks in SwiftUI](https://swiftwithmajid.com/2022/07/06/background-tasks-in-swiftui/)
- Tanaschita — [Task cancellation and lifetimes in Swift concurrency](https://tanaschita.com/swift-async-tasks-cancellation/)
