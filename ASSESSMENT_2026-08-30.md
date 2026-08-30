# Autohop — Whole-Project Assessment, 30 August 2026

<!--
AI CONTEXT — ASSESSMENT_2026-08-30.md
CANONICAL assessment. Supersedes ASSESSMENT_2026-07-24.md, ASSESSMENT.md, and
every DEEP_SCAN_*.md as the current statement of open issues.

Scope of this pass: iOS + tvOS PRODUCTION source (223 Swift files, 74,736 LOC;
the whole repo including tests is 295 files / 87,375 LOC — an earlier draft of
this header mixed the two populations), all settings
surfaces, the onboarding system, project/build configuration, the kevmarl.com
website, and the project documentation set.

Method: read against the WORKING TREE at commit 9e8b68f
(branch feature/version-1.6-responsive-package-2, clean tree). Every claim below
was re-derived from current source. Where this report contradicts an earlier
assessment or a memory note, THIS document is correct — several previously
recorded figures had drifted (see §12).

Verification vocabulary used throughout:
  VERIFIED    — read directly in current source; file:line given.
  MEASURED    — produced by a counting command over current source.
  RISK        — a real hazard whose runtime impact is not proven here.
  NOT VERIFIED — requires a physical device or signed archive to confirm.

Authoring constraint for this pass: Kevin authorised documentation and
comment-only edits. NO functional code change and NO website change was made.
Everything in §1–§11 is a proposal awaiting his approval unless marked APPLIED.
-->

## 1. Executive summary

The codebase is in strong health. There are zero `TODO`, `FIXME`, `try!`, or
`fatalError` sites in production source; AI CONTEXT header coverage is 223/223
files; the AppState decomposition (Stages 0–14) is genuinely complete; and the
security posture of the parsing, sharing, and deep-link surfaces is better than
most shipping podcast clients. The prior assessment's structural findings have
largely been closed.

What remains is a small number of **defects that are invisible from the code
they live in** — they only appear when two correct-looking components are
composed. The four highest-value findings are all of this kind:

| # | Finding | Severity | Status |
|---|---|---|---|
| **B1** | Four of eleven onboarding coach marks never render on their primary navigation path | High | VERIFIED |
| **S1** | iOS has no Release entitlements file for production APNs; tvOS does | Medium | VERIFIED (impact NOT VERIFIED) |
| **D1** | Dynamic Type: ~89 hard-literal text sizes in `Views/`; no Dynamic Type input anywhere in the adaptive metrics system | Medium | MEASURED (restated — see §14) |
| **P1** | 7 views hold unused `AppState` dependencies | Low (cleanup) | VERIFIED — original severity **refuted**, see §14 |

One website inaccuracy is confirmed (**W1**: Auto Archive interval stated as 30
minutes; the app and code both say 25), and the app↔website Support mirror has
drifted on three features.

---

## 2. Efficiency and performance

### P1 — Unused `AppState` dependencies *(VERIFIED as unused; performance mechanism REFUTED)*

> **Correction, 30 Aug 2026.** This was first filed as a medium-severity
> performance finding ("re-renders on every global publish"). **That mechanism is
> wrong.** `App/AppState.swift:46` conforms to `ObservableObject` but declares
> **zero `@Published` properties** and never forwards `objectWillChange`
> (verified: `grep -c '@Published' App/AppState.swift` → 0). There are no AppState
> publications, so these declarations cause no re-renders. Downgraded to
> dependency cleanup. The decomposition invariant is not violated — it is
> *upheld*, which is exactly why the declarations are inert.

Seven views declare `@EnvironmentObject private var appState: AppState` and never
reference it:

| File | Line |
|---|---|
| `Views/CoachMark.swift` | 98 |
| `Views/DiscoverView.swift` | 69 |
| `Views/NotificationSettingsView.swift` | 23 |
| `Views/TopEpisodesView.swift` | 30 |
| `Views/TopPodcastsView.swift` | 40 |
| `Views/WelcomeView.swift` | 22 |
| `Views/AddFeedView.swift` | 8 |

Removing them is still worth doing, for the reasons that survive:
- They are dead dependencies that misdescribe each view's actual coupling.
- **They make the view crash if `AppState` is ever absent from the environment.** This is not hypothetical: `Views/PlayerView.swift:57-60` documents that the iOS-on-Mac presentation host can form a separate modal subtree where a missing inherited object terminates the process immediately. Every unused declaration is a needless instance of that failure mode.
- They add friction to SwiftUI previews and to any future extraction of these views.

Severity: **low, cleanup**. Not a performance fix.

### P2 — `StatsView.downloadFilterSkippedEpisodeIDs` scans the whole library per body pass *(VERIFIED — comment APPLIED)*

`Views/StatsView.swift:663` is a **computed property with no caching**, evaluated
inside `driftingShowsSection` on every StatsView body evaluation. It walks every
episode of every subscription and calls
`DownloadFilterSettings.evaluation(for:)` per episode. `evaluation` rebuilds its
`activeRules` array on each call (`Models/Subscription.swift:3343`), so the rule
set is reconstructed **per episode** rather than once per show.

On a 4,000-episode library that is 4,000 iterations plus a `Set<UUID>`
construction on the main actor, repeated whenever the range selector changes or
the store publishes.

Mitigating fact: most users have no filters enabled, so `activeRules` returns
empty after three boolean checks and the dominant cost is iteration, not rule
evaluation. This is why it has not been felt as a hang.

**Recommendation (cheap, low-risk):**
1. Skip whole subscriptions via the existing `downloadFilterSettings.hasActiveFilters` before touching their episodes.
2. Hoist the result into `@State`, recomputed against `SubscriptionStore`'s existing O(1) mutation token rather than per body.

Do **not** relax the `.notDownloaded` guard — that is correctness (a manual
download must remain valid engagement evidence), not performance.

### P3 — `SettingsView` storage section flattens the library on every Form render *(VERIFIED — comment APPLIED)*

`Views/SettingsView.swift:701` runs
`subscriptions.flatMap(\.episodes).filter { $0.downloadState == .downloaded }`
inside the Section builder. Because `settingsForm` is one `Form`, this executes
on every body pass of the whole page — every toggle tap, every store publish —
not only when the Storage section is visible.

Note the asymmetry already present in the same section: the *byte* total is
correctly computed off-main via `Task.detached` into `@State`
(`Views/SettingsView.swift:729-734`), while the *count* is computed synchronously
on the main actor. **Recommendation:** count with `reduce(0)` instead of
materialising two arrays, or cache alongside `totalDownloadedBytes`.

### P4 — Discover hero timer: unstable publisher + off-screen ticking *(VERIFIED — comment APPLIED)*

`Views/DiscoverView.swift:91` declares
`Timer.publish(every: 5, on: .main, in: .common).autoconnect()` as a plain `let`
on a View **struct**. Two consequences:

1. A fresh publisher is constructed every time SwiftUI re-initialises
   `DiscoverView`; `.onReceive` then re-subscribes to the new instance and tears
   down the old. Moving it to `@State` makes the subscription stable.
2. It runs on `.common` and drives `withAnimation` state mutations at
   `Views/DiscoverView.swift:432` and `:582`. While DiscoverView remains in the
   hierarchy but is not the visible page, those animated re-renders continue
   until the process suspends.

Today Discover is a pushed `AppRoute` destination, so it is normally torn down —
impact is currently low. **This becomes a real battery cost the moment Discover
is kept alive off-screen** (tabs, iPad sidebar, split view), which is precisely
the direction `Docs/RESPONSIVE_LAYOUT_PROPOSAL.md` points. Gate the advance on
visibility rather than lengthening the period.

### P5 — Settings reaction fan-out is broader than necessary *(VERIFIED)*

`App/AppRuntimeWorkflow.swift:437-452` subscribes to the entire `$appSettings`
struct and, on **any** change, runs `syncDiagnosticLogging()`,
`syncSleepScheduleConfig()`, and `syncCoordinator.syncEnabledChanged(...)`.

So adjusting "Skip forward" or "Download over WiFi" triggers a sync-enablement
reconciliation and a sleep-schedule reconfiguration. The downstream calls appear
idempotent, so this is waste rather than a defect — but it compounds with the
350 ms trim-control coalescing, where each committed trim edit runs the full
chain. **Recommendation:** compare the specific fields (`diagnosticLoggingEnabled`,
sleep-schedule fields, `iCloudSyncEnabled`) and dispatch only what changed.

---

## 3. Bugs and poorly implemented code

### B1 — Four coach marks never render on their primary path *(VERIFIED — HIGHEST VALUE)*

**Mechanism.** `CoachMarkOverlay()` is mounted at `Views/RootView.swift:476`
inside `rootContent`'s `ZStack`. UIKit draws a presented `.sheet` **above** the
entire presenting hierarchy, including that ZStack. Therefore a page that both
(a) attaches `.onboardingTip(_:)` and (b) is reached inside a presented sheet has
its tip rendered behind the sheet.

**Affected surfaces.** These four attach tips but are `NavigationLink`
destinations of `MenuSheetView`, which `PodcastsView` presents as a `.sheet`:

| Tip | Attach site | Menu destination |
|---|---|---|
| `.stats` | `Views/StatsView.swift:65` | `Views/MenuSheetView.swift:66` |
| `.sleepSchedule` | `Views/SleepScheduleView.swift:48` | `Views/MenuSheetView.swift:73` |
| `.downloads` | `Views/DownloadsView.swift:57` | `Views/MenuSheetView.swift:87` |
| `.settings` | `Views/SettingsView.swift:165` | `Views/MenuSheetView.swift:94` |

Only `Views/QueueSheetView.swift:305` mirrors the overlay with
`.overlay { CoachMarkOverlay() }`. The contract is stated correctly in
`Views/RootView.swift:45` ("A system sheet that owns a tip mirrors
CoachMarkOverlay above its sheet content") — it is simply not honoured by four
of the five sheet-hosted tips.

**Severity is higher than "a tip is invisible."** `OnboardingCoordinator.requestTip`
guards on `activeTip == nil` and caps presentation at `maxTipsPerSession = 3`
(`App/OnboardingCoordinator.swift:118-126`). An invisible tip therefore:
- **blocks every other tip** for as long as its page is on screen, and
- **consumes one of the three per-session slots**.

A new user who opens Menu → Settings, then Menu → Downloads, then Menu → Stats
has silently exhausted the entire first-session tip budget having seen nothing.

**Why it survived the 29 August audit.** `.stats` and `.sleepSchedule` *also*
exist as root `AppRoute` destinations (`Views/RootView.swift:447` and `:449`,
reached via a Listening Recap notification and the Player's sleep indicator
pill). On those paths the same tips render correctly. The defect is
path-dependent, so a tester who reaches Stats from a recap notification sees the
tip work.

**Recommended fix (smallest correct change).** Add
`.overlay { CoachMarkOverlay() }` to the four views, matching `QueueSheetView`.
**Better structural fix:** have `MenuSheetView` mirror the overlay once on its
own `NavigationStack` content, so every current and future Menu destination is
covered by construction rather than by remembering.

**Applied in this pass (documentation only):** the contract and the live
violation are now recorded in `Views/CoachMark.swift`, `FEATURES.md` §18, and
`Docs/ONBOARDING_AUDIT_2026-08-29.md`.

### B2 — Sidebar shortcut mapping is a hand-maintained positional index *(VERIFIED — comment APPLIED)*

`Views/SettingsView.swift:formSection(for:)` returns raw **positional indexes**
into `settingsForm`'s Section list, consumed by `FormSectionScrollController`
(`Views/AdaptiveLayout.swift:548`), which scrolls by section index.

The mapping is currently **correct**, including the subtle part: `defaultPlaybackSection`
emits *two* Sections (Default Playback + Default Episode Trim), which is why the
table jumps 4 → 7. But adding, removing, splitting, or reordering any Section
silently misroutes every shortcut below it, and the compiler cannot catch it.

This is a latent regression trap rather than a present bug. A guard comment
enumerating the full index table has been added.

### B3 — `shortcutHeader` tracks the *last* header to appear *(VERIFIED)*

`Views/SettingsView.swift:shortcutHeader` sets `activeShortcut` in `.onAppear`
with no matching `.onDisappear`. In a lazy `Form`, headers fire `onAppear` as
they scroll into view, so `activeShortcut` becomes the **bottom-most** header
that has appeared — the sidebar highlight runs ahead of what the user is reading,
and scrolling up does not correct it until a header re-enters from the top.

Low severity, iPad/Mac only. **Recommendation:** track visible section bounds, or
clear on `onDisappear` and pick the topmost remaining.

### B4 — Failed remote materialisation drops the state entirely *(VERIFIED)*

`App/SyncCoordinator.swift:materializeRemoteSubscription` calls
`subscriptionStore.applyRemoteSubscriptionState(state)` on both success paths but
**not** in the `catch`. If the feed fetch fails (offline, feed 500), the remote
subscription's settings are discarded for that pass with only an error log. There
is no retry queue; recovery depends on a later full fetch re-delivering the
record. **Recommendation:** apply the remote state even when hydration fails, or
record the pending materialisation for retry on connectivity.

### B5 — Unresolvable companion Play Next requests re-warn forever *(VERIFIED)*

`App/SyncCoordinator.swift:applyRemoteQueueCommand` returns `false` without
recording the request ID when the episode cannot be resolved. If the episode is
permanently gone (archived, feed rotated it out), every subsequent sync logs
`sync.playNextUnresolved` again with `alwaysPersist: true`. **Recommendation:**
age out unresolvable requests after a bounded number of attempts or a TTL.

---

## 4. Cross-device sync

### S1 — iOS production APNs depends on a manual pre-upload step; tvOS does not *(VERIFIED — comment APPLIED)*

The iOS target ships a single entitlements file with
`aps-environment: development` (`Autohop.entitlements`, `project.yml:266`),
relying on Xcode rewriting it during distribution signing. The **tvOS target
explicitly rejects that assumption**, pinning a separate
`TV/AutohopTV.Release.entitlements` with `aps-environment: production` per
configuration (`project.yml:400-403`), with the comment: *"Release has a separate
distribution entitlement file so an App Store archive cannot claim the sandbox
environment even if source generation/signing drifts."*

Both comments cannot be right. iOS is the target still taking the risk.

**Correction to an over-strong initial reading.** There *is* a guard:
`Scripts/validate-release.sh --archive <path>` reads the **signed** entitlements
from the `.xcarchive` and hard-fails unless `aps-environment == production`.
So this is not an unguarded shipping defect.

**The residual risk is narrower than "unguarded", and narrower than an earlier
draft of this section claimed.** Two things reduce it:
1. `--archive` hard-fails on a non-production signed archive, if run.
2. **The source entitlements file is not the sole determinant.** Distribution
   provisioning and signing participate in producing the effective entitlement in
   the shipped binary. Source inspection alone therefore **cannot** establish
   that any shipped iOS archive carried a sandbox APNs entitlement, and this
   report does not claim it did.

What is left is a real but modest hardening gap: CI
(`.github/workflows/release-guards.yml`) runs only `--configuration-only`, which
prints *"Archive APNs check not run"* and exits 0, because an unsigned checkout
has no signed entitlements to inspect. So the explicit in-repo assertion of
production APNs depends on a human running one command before upload.

**Why it matters if it ever slips.** CKSyncEngine depends on silent pushes. A
sandbox-token build receives no production CloudKit pushes, and cross-device sync
degrades to the foreground prime at `App/AppRuntimeWorkflow.swift:206-211` — a
change made on Apple TV or a second iPhone appears only when the user next
foregrounds the app. **It fails silently: no error, no log, just latency.** That
failure mode is indistinguishable from "sync is a bit slow," which is why it
could persist unnoticed.

**Recommendation.** Mirror tvOS: add `Autohop.Release.entitlements` with
`aps-environment: production` and set `CODE_SIGN_ENTITLEMENTS` per configuration.
The manual archive check then becomes a confirmation rather than the sole
defence. *(NOT VERIFIED: whether any shipped build has actually carried a sandbox
token — that requires inspecting a real distribution archive.)*

### S2 — Global app settings do not sync at all *(VERIFIED)*

`SYNC_DESIGN.md` confirms there is **no global settings record type**. Skip
durations, launch screen, Auto Archive defaults, default playback preference,
diagnostics, and download network toggles are per-device by design.

For the stated target user (10–30+ subscriptions, multiple devices) this is real
friction: a user who tunes skip-back to 30s and sets "Open at launch → Player"
must repeat it on every device. **Recommendation:** consider a narrow
`AppSettings` subset record (launch screen, skip durations, default playback
preference, Auto Archive defaults) with field-level LWW. Deliberately exclude
device-scoped values (diagnostics toggles, download network permissions, badge)
— `SYNC_DESIGN.md` §13.3 already warns against syncing the blob indiscriminately,
and that warning remains correct.

### S3 — Whole-list LWW loses concurrent Priority Stack edits *(known, unchanged)*

Documented at `SYNC_DESIGN.md:53`. Reordering on two devices while both are
offline discards one ordering entirely rather than merging. Correct for v1 and
deterministic. Revisit only with evidence of real multi-device conflicts;
`SYNC_DESIGN.md` §13.3's guidance to prefer determinism over a speculative
operation log still holds.

### S4 — Download Filters use struct-level LWW *(VERIFIED)*

`SYNC_DESIGN.md:71` — the whole `DownloadFilterSettings` blob is one LWW unit.
Editing a title rule on iPhone and a duration rule on iPad concurrently loses
one edit silently. Low frequency; worth documenting in the app's Feed Filters
copy rather than re-engineering.

### S5 — tvOS one-way authority is correct; keep it *(VERIFIED)*

`TV/Sync/TVAppModel+Sync.swift:21-30` documents `pushesSubscriptionState: false`
as a hard rule following the purge-rebuild damage incident. The engine
structurally refuses to queue SubscriptionState records under `.tvCompanion`
capability. **This is well-designed and should not be relaxed.** The accepted
consequence — subscribe-on-TV stays local to the TV — is correctly documented.

---

## 5. Security

Overall posture is **strong**. Findings are hardening, not exploitable defects.

**Confirmed good (do not regress):**
- `App/WidgetDeepLinkParser.swift` — strict allow-list parser; rejects credentials, ports, fragments, extra path components, oversized keys. Exemplary.
- `Models/ShareContent.swift` — `ShareURLResolver` structurally cannot leak a media enclosure or private RSS address (the enclosure is not a parameter). Rejects loopback/link-local/RFC1918 hosts and sensitive query names. Exemplary.
- `Views/CachedArtworkImage.swift` — validates responses (2xx, `image/*`, ≤5 MB), negative-caches failures, bounds disk at 250 MB / 90 days.
- Feed/search/chart sessions use `URLSessionConfiguration.ephemeral` — no cookie or credential persistence.
- No `try!`, `fatalError`, or force-unwrap crash surface in production source.

### S6 — Blanket ATS exception remains *(VERIFIED, unchanged since prior assessment)*

`Info.plist` sets `NSAllowsArbitraryLoads = true` globally. This is genuinely
hard to avoid for an app that fetches arbitrary publisher-supplied feed and media
URLs — a per-domain exception list is impossible for user-supplied feeds.

The exception is broader than the need, however: it also permits cleartext for
the iTunes Search API, the charts API, and artwork, all of which are HTTPS in
practice. **Recommendation (unchanged from prior assessment, still open):**
- Prefer HTTPS and upgrade `http://` feed URLs where the host supports it.
- Warn clearly before subscribing to a cleartext feed.
- Reject credential-bearing feed URLs at entry (`Feeds/PodcastSearch.swift:256` already rejects some).
- Add `NSAllowsLocalNetworking: false` and document the exception for App Review.

### S7 — Diagnostic log field set could be itemised *(NARROWED 30 Aug 2026)*

> **Correction.** An earlier draft said the privacy policy did not adequately
> cover the diagnostic log. It does: `privacy.html` lists *"Diagnostic log
> (optional, off by default) — Local text file (Application Support) — Never
> shared; viewable and shareable only by you"* in its storage table. Existence,
> default-off state, and non-transmission are all correctly disclosed.

The remaining, much smaller opportunity: the policy does not enumerate *what the
log captures* — feed hosts, episode titles, device model, battery level, thermal
state, and CPU (`Logging/ResourceMonitor.swift`). Since the user can export and
share it, itemising the fields would let them make an informed choice about
sharing. Optional improvement, not a gap.

### S8 — APNs registration undisclosed *(WITHDRAWN — this finding was WRONG)*

> **Retracted in full.** The claim was that `privacy.html` does not disclose the
> APNs registration performed at `App/AppDelegate.swift:161`. **It does, clearly
> and accurately**, under "Notifications":
>
> > *"iCloud may use Apple's own silent CloudKit push mechanism to wake sync;
> > Autohop does not operate an APNs provider server or send marketing push
> > notifications."*
>
> That is a correct and appropriately specific disclosure. The finding was
> produced by keyword-counting the page rather than reading its prose — a
> methodology failure noted in §14. **No action required.**

---

## 6. Design, UI, and layout consistency

### D1 — Dynamic Type is the largest accessibility gap *(MEASURED — restated 30 Aug 2026)*

> **Correction.** This was first filed as "263 fixed font sizes, regressed from
> July's 219." **The regression conclusion is withdrawn.** A raw count of
> `.system(size:` is not a count of fixed *text* styles, and comparing two raw
> counts across the responsive-layout work does not establish a regression.

Properly classified, the 263 occurrences in `Views/` break down as:

| Category | Count | Assessment |
|---|---|---|
| Computed from `metrics.*` (adaptive layout) | **107** | Not literals. Introduced deliberately by the large-screen responsive work. |
| Hard literal, sizing **Text/Label** | **89** | ← **the actual Dynamic Type finding** |
| Hard literal, sizing an **SF Symbol** | 66 | Lesser issue; symbols should still scale with text |
| Unclassified | 1 | `Views/PodcastShareSheet.swift:165` |

So the headline number is **~89**, not 263, and the growth since July is mostly
*more responsive code existing*, not more fixed text.

**However — one finding survives intact and is arguably broader than the raw
count suggested.** The adaptive metrics system is driven **only by container
width**: `AdaptiveEditorialMetrics.init(containerWidth:)`
(`Views/AdaptiveLayout.swift:87-91`) takes no other input, and `AdaptiveLayout.swift`
contains **zero** references to `dynamicTypeSize`, `UIFontMetrics`, or
`ScaledMetric` (verified by grep). Those 107 computed sizes therefore respond to
*screen size* but **not to the user's text-size setting**. A user at AX5 gets the
same point size as a user at default on the same device.

Net position: **all 263 sites are Dynamic-Type-insensitive**, but only ~89 are
the crude literal-text problem worth fixing first. The remaining `@ScaledMetric`
count is genuinely 2, both at `Views/StatsView.swift:209-210`.

**Recommendation.** Two separable pieces of work:
1. Convert the ~89 literal text sites to semantic fonts or `@ScaledMetric(relativeTo:)`. Start with `Views/PlayerView.swift` (highest user contact).
2. **Feed Dynamic Type into `AdaptiveEditorialMetrics`** so the responsive scale composes with text scale instead of overriding it. This is the higher-leverage change and should be designed before (1) is done wholesale, or (1) will be redone.

Add a CI guard on the *literal-text* count specifically, not the raw
`.system(size:` count — the raw count is not a quality signal.

### D2 — VoiceOver coverage is thin *(MEASURED)*

~55 accessibility modifiers across 40 view files. `PlayerView` (19) and a handful
of others carry nearly all of them; `StatsView` and `SettingsView` have **1
each**, and `DownloadsView`, `SleepScheduleView`, `QueueSheetView`, and the chart
pages have almost none. Custom controls are the concern: the Player's custom
Up Next swipe rows (`Views/PlayerView.swift`, deliberately not native
`swipeActions`) and the custom `EpisodeTrimControlRow` capsule stepper are
invisible-by-default to VoiceOver and need explicit labels, values, and
adjustable traits.

### D3 — Volume Adjustment has no global default *(VERIFIED — consistency gap)*

`PlaybackControlsCard` supports Volume Adjustment behind `showsVolumeAdjustment`.
`Views/SubscriptionSettingsView.swift:489` passes `true`; `Views/SettingsView.swift`
(Default Playback) does not pass it at all. Every other audio control — Speed,
Trim Silence, Vocal Boost, Mono Audio, start/end skip — has a global default that
seeds new subscriptions. Volume Adjustment alone must be set per-podcast, forever.

This is a genuine consistency gap in the "Default Playback" promise. **Either**
add `defaultVolumeAdjustment` to `AppSettings.defaultPlaybackPreference`, **or**
state in the Default Playback footer that Volume Adjustment is intentionally
per-podcast because it corrects an individual show's mastering. The second is
defensible and cheaper — but the current silence is not.

### D4 — Playback footer copy is asymmetric *(VERIFIED)*

- Global Default Playback footer (`Views/SettingsView.swift`) explains **Mono Audio**, Vocal Boost, Trim Silence — but not Volume Adjustment (correctly, it is absent there).
- Per-podcast Playback footer (`Views/SubscriptionSettingsView.swift:436`) explains Volume Adjustment, Vocal Boost, Trim Silence — but **omits Mono Audio**, even though the control is present in that card.

**Recommendation:** add one Mono Audio sentence to the per-podcast footer,
reusing the global wording verbatim so the two stay diff-able.

### D5 — Settings surfaces are otherwise strongly consistent *(VERIFIED — positive)*

Both settings pages share `SettingsRowLabel`, `PlaybackControlsCard`,
`EpisodeTrimControlRow`, the purple glyph treatment, the iOS 26 "defined glass"
vs iOS 17–25 flat-card split, and 48 pt section spacing. Footer copy is unusually
thorough and accurate. The `EpisodeTrimControlRow` alignment contract
(duration rendered inside the `Label` title slot so both lines share one leading
edge at every Dynamic Type size) is documented and correct. This is a
well-maintained design system.

---

## 7. Stale and outdated code

### T1 — Stale `Relay` references in AI CONTEXT headers *(VERIFIED — FIXED in this pass)*

The Cloudflare Relay and Autohop Pro prototypes were removed (`README.md`
confirms), and there are **zero** `relay` identifiers in executable code. Five
comment sites still described Relay as live architecture:

| File | Was |
|---|---|
| `App/FeedRefreshCycleWorkflow.swift:8` | "…and Relay-targeted cycle requests" |
| `App/FeedRefreshCycleWorkflow.swift:22` | "Relay-targeted work may request one follow-up…" |
| `App/AppLifecycleCoordinator.swift:22` | "…does not implement playback, feeds, downloads, sync, Relay…" |
| `Views/SettingsView.swift:46` | "…never implies Relay or Pro availability when those gates are off" |
| `TV/Sync/TVForegroundSyncPolicy.swift:5` | "CloudKit change notifications and **Relay nudges** remain the primary fast path" |

The last was the most harmful: it told a future model that a relay exists *and*
that push is a guaranteed fast path — the exact assumption **S1** shows is
unproven. All five have been corrected; the tvOS one now states that push is
best-effort and that the foreground poll is the only convergence guarantee.

### T2 — Empty `Relay/` and `Store/` directories *(VERIFIED — do not delete blindly)*

Both directories are empty leftovers. **However**, `Scripts/validate-release.sh`
greps them by path to assert retired Pro/Relay code has not returned. Deleting
them without updating that script degrades the guard. **Recommendation:** remove
the directories and the corresponding paths from the script in one change, or
leave both as-is. Do not do half.

### T3 — Superseded documents should be marked, not deleted *(VERIFIED)*

`DEEP_SCAN_2026-06-23.md`, `DEEP_SCAN_2026-06-26.md`, `DEEP_SCAN_2026-06-28.md`,
`ASSESSMENT.md`, `APPSTATE_DECOMPOSITION_BASELINE.md`, and
`APPSTATE_DECOMPOSITION_PROPOSAL.md` describe completed or superseded states.
They retain historical value but currently carry no marker saying they are not
current — the exact condition that produces stale-memory errors in future AI
sessions. **Recommendation:** add a one-line `> SUPERSEDED by
ASSESSMENT_2026-08-30.md` banner at the top of each.

---

## 8. Onboarding accuracy

Beyond **B1** (the material defect), the onboarding system is accurate and
recently audited. Specific checks:

- **Tip copy vs. app reality** — all eleven `OnboardingTip` messages
  (`Views/CoachMark.swift:47-71`) were checked against current behaviour. All
  accurate. `.settings` correctly describes Release Radar as *learned* scheduling
  rather than a fixed polling promise; `.downloads` correctly states downloads
  are device-local; `.feedFilters` correctly states Exclude always wins.
- **Session-cap semantics** — the 3-per-session cap counts *presented* tips,
  including ones cancelled by navigation. Intentional anti-overload behaviour,
  but it interacts badly with **B1** (invisible tips still burn slots). Now
  documented at `App/OnboardingCoordinator.swift`.
- **Coverage gaps that are defensible** — Listening History, Search, and ordinary
  detail pages have no tips. Correct; they use established patterns.
- **Not taught anywhere** — the **Widgets** feature has no coach mark and no
  first-run mention, despite being a v1.4 headline. It is documented in Menu →
  Support only. Reasonable (widgets are configured outside the app), but worth a
  deliberate decision rather than an omission.

---

## 9. Website review *(report only — no changes made)*

### W1 — Confirmed factual error: Auto Archive interval *(VERIFIED)*

`support.html` states Auto Archive *"Runs automatically at most every 30
minutes."* The code says **25 minutes**
(`App/AutoArchiveCoordinator.swift:55` — `interval: TimeInterval = 25 * 60`), and
both in-app settings footers say 25 minutes. **The website is wrong. Fix to 25.**

### W2 — Feature page omits four marketable features *(VERIFIED)*

`autohop.html` lists 20 features. Zero mentions of:

| Missing | Why it matters |
|---|---|
| **CarPlay** | An Apple-approved entitlement, a full in-app Support topic, and a top purchase driver for a driving-heavy listening audience |
| **Home / Lock Screen Widgets** | The v1.4 headline feature; interactive, small/medium/large + StandBy accessories |
| **Listening Recaps** | Weekly/monthly/yearly opt-in recap notifications |
| **Play Instant** | A genuinely distinctive feature no mainstream competitor has |

Also absent as named features: Volume Adjustment, Mono Audio, and Up Next
(only partially covered by "Play Next / Play Last").

**Recommended ordering**, most marketable first (Kevin's stated criterion):

1. Priority Stack *(the core differentiator — correctly already first)*
2. Download First
3. Trim Silence
4. Vocal Boost
5. **CarPlay** *(new)*
6. Release Radar
7. iCloud Sync
8. **Widgets** *(new)*
9. Apple TV *(currently only on `tvos.html`)*
10. Sleep Schedule
11. **Play Instant** *(new)*
12. Per-Podcast Playback *(fold in Volume Adjustment + Mono Audio)*
13. Auto-Archive
14. Stats → then Download Feed Filters, Chapters, Discover, Find Podcasts, Video, Sleep Timer, Shared Listening, Listening History, **Recaps**, OPML.

Rationale for the moves: Trim Silence and Vocal Boost are the audio-quality
promises in the product vision's Core Design Goal #2 and should outrank a
power-user filtering feature; CarPlay/Widgets/Apple TV are ecosystem-reach
signals that convert browsers and are currently invisible.

### W3 — App ↔ website Support mirror has drifted *(VERIFIED)*

Topic lists match exactly (20 topics, same order) — the structural mirror holds.
Body content has drifted:

| Feature | `Views/SupportContent.swift` | `support.html` |
|---|---|---|
| Play Instant | 4 mentions | **0** |
| Listening Recaps | 1 | **0** |
| Volume Adjustment | 1 | **0** |
| Mac | 0 | 6 |

Neither source documents: Review in Apple Podcasts (added 29 Aug), Starter Packs,
coach marks / Quick Tips, or the iPad/Mac responsive layouts. The website was
last edited 15 August; the app has changed substantially since.

### W4 — Privacy policy: two genuine omissions (two earlier claims retracted) *(CORRECTED)*

> **Retraction.** An earlier draft listed four gaps. Two were wrong — the policy
> *does* disclose silent CloudKit push (see **S8**) and *does* disclose the
> diagnostic log (see **S7**). Both were keyword-count errors on my part.

The two that survive scrutiny:
- **CarPlay** — 0 mentions. Autohop reads the library while the device is locked via after-first-unlock file protection. Worth one sentence.
- **TestFlight** — 0 mentions. Linked directly from Settings → Contact; joining shares the user's data with Apple under Apple's terms.

Everything the policy currently states is accurate. `privacy.html` is in better
shape than the first draft of this report implied.

### W5 — Intelligence page is honest but incomplete *(VERIFIED — positive)*

**Verified good:** zero visible "AI" or "machine learning" claims in the rendered
text (all 31 `AI` matches were inside HTML comments). For a page titled
*Intelligence*, resisting the AI-washing temptation is a real integrity win.
**Preserve this.**

Missing, and genuinely marketable because they are *true*: adaptation to battery
mode, thermal state, and network conditions; deferred-feed fairness; per-host and
cross-host circuit breakers; conditional-request (ETag/304) efficiency. The page
also excludes Auto Archive, Play Instant, and Download Feed Filters, which are
arguably the app's most "intelligent" behaviours.

### W6 — AI headers and SEO are in good shape *(CORRECTED — 9 pages, not 8)*

The repository contains **nine** HTML pages, not eight as first stated. Eight are
public; all eight carry an AI CONTEXT block, a `meta description`, and JSON-LD
(`support.html` 23 AI blocks, `privacy.html` 12, `intelligence.html` 11;
`autohop.html` carries 2 JSON-LD blocks).

The ninth, `stats.html`, has **no** `meta description` and **no** JSON-LD — and
**this is correct, not a gap.** It is the private App Store Connect dashboard: it
carries `noindex`/`robots` directives and is password-gated. Adding SEO metadata
or structured data to it would be a mistake. It does still carry 3 AI CONTEXT
blocks, which is appropriate for maintainer/AI comprehension.

Suggested increments for the public pages only: add `FAQPage` JSON-LD to
`support.html` (high SEO value for Q&A-shaped content), and `SoftwareApplication`
structured data to `tvos.html` to match `autohop.html`.

---

## 10. tvOS

No new defects found. The tvOS codebase (66 files, 9,513 LOC) is disciplined:

- One-way sync authority is structurally enforced, not merely conventional (**S5**).
- `TVHangWatchdog` mirrors the iOS `MainThreadWatchdog` design.
- Fixed-viewport typography means Dynamic Type (**D1**) does not apply.
- `Scripts/validate-tvos-release.sh` (12 KB) is a substantially more thorough release gate than the iOS equivalent — the iOS script would benefit from the same treatment.
- Retry/backoff sleeps are bounded and reasoned, with no unbounded polling loops.

The `TVForegroundSyncPolicy` comment correction (**T1**) is the only tvOS change
in this pass.

---

## 11. Prioritised recommendations

**Do before the next release:**
1. **B1** — mirror `CoachMarkOverlay` in `MenuSheetView` (one change covers all four tips). *Highest value-to-effort ratio in this report.*
2. **W1** — correct 30 → 25 minutes on `support.html`.
3. **S1** — add `Autohop.Release.entitlements`; make the APNs guarantee structural.
4. **W2/W3** — add CarPlay, Widgets, Play Instant, Recaps to the feature page; re-sync the Support mirror.

**Do soon:**
5. **D1** — design Dynamic Type into `AdaptiveEditorialMetrics` first, then convert the ~89 literal text sites starting at PlayerView. Guard the *literal-text* count in CI, not the raw `.system(size:` count.
6. **D3/D4** — resolve the Volume Adjustment asymmetry and the Mono Audio footer omission.
7. **W4/W5** — add CarPlay + TestFlight to the privacy policy; expand the Intelligence page with true capabilities.
8. **P1** — delete 7 unused `AppState` declarations (crash-surface cleanup, not performance).

**Backlog:**
9. **P2/P3/P5** — caching and reaction-fan-out cleanups.
10. **S2** — decide on a narrow synced-settings subset.
11. **B3/B4/B5**, **T2/T3** — small correctness and hygiene items.
12. **D2** — VoiceOver pass on custom controls.

---

## 12. Corrections to previously recorded state

Recorded here explicitly, because these are the figures most likely to be carried
forward incorrectly by a future session:

| Previously recorded | Actual, 30 Aug 2026 |
|---|---|
| 219 fixed fonts in `Views/` | Raw count is now 263, but **the raw count is not a quality metric** and no regression is demonstrated. Properly classified: **~89** literal text sizes, 66 literal SF-Symbol sizes, 107 width-computed. See **D1**. |
| "aps-environment = dev" as an unguarded open item | Guarded at archive time by `Scripts/validate-release.sh --archive`; the real gap is that the guard is **manual and not in CI** |
| Coach marks cover 11 surfaces | 11 **declared**; **7 render on all paths, 4 do not** |
| `ASSESSMENT_2026-07-24.md` is canonical | Superseded by this document |
| Relay described as removed | Removed from code, but **5 comment sites still described it as live** (now fixed) |

## 13. Changes applied in this pass

Comment-only and documentation-only. **No functional code and no website file was
modified.** Every edited Swift file passes `swiftc -parse`; `project.yml` parses
as valid YAML and `Scripts/validate-release.sh --configuration-only` passes.

| File | Change |
|---|---|
| `App/FeedRefreshCycleWorkflow.swift` | Removed 2 stale Relay claims |
| `App/AppLifecycleCoordinator.swift` | Removed stale Relay claim |
| `Views/SettingsView.swift` | Removed stale Relay/Pro claim; added index-map hazard guard (**B2**); added storage-scan cost note (**P3**) |
| `TV/Sync/TVForegroundSyncPolicy.swift` | Removed Relay claim; push now documented as best-effort |
| `Views/CoachMark.swift` | Documented the sheet-hosting contract and the live **B1** violation |
| `App/OnboardingCoordinator.swift` | Documented session-cap semantics |
| `Views/StatsView.swift` | Documented **P2** cost and safe optimisations |
| `Views/DiscoverView.swift` | Documented **P4** publisher-stability and off-screen ticking |
| `project.yml` | Documented **S1**, the existing archive guard, and the tvOS contradiction |
| `FEATURES.md` | §18 corrected: declared vs rendered coach-mark coverage |
| `Docs/ONBOARDING_AUDIT_2026-08-29.md` | Correction appended; four rows marked ⚠️ |

---

## 14. External audit of this report (30 August 2026)

Kevin commissioned an independent review of this document against the same
commit. It found four material problems. **All four were re-verified from source
and all four were upheld.** Corrections are applied in place above; nothing was
quietly edited away.

| Challenge | Outcome | Evidence |
|---|---|---|
| **P1's mechanism is false** — AppState has no `@Published` and never forwards `objectWillChange`, so there are no publications to re-render on | **Upheld.** `grep -c '@Published' App/AppState.swift` → **0**. Finding downgraded from Medium performance to Low cleanup; the crash-surface rationale is what survives. | §2 P1 |
| **D1 overstated** — 263 is a raw syntax count, not 263 fixed text styles; the 219→263 comparison does not prove regression | **Upheld.** Classified: 107 computed from `metrics.*`, 89 literal text, 66 literal SF Symbols. Regression claim withdrawn. *Added in response:* `AdaptiveEditorialMetrics` takes **only** `containerWidth` and `AdaptiveLayout.swift` has zero Dynamic Type references — so all 263 remain text-size-insensitive, which makes the underlying accessibility concern broader than either framing. | §6 D1 |
| **S1 overstated** — distribution provisioning/signing also participates; source inspection cannot prove a shipped archive used sandbox APNs | **Upheld.** "Rests entirely on a human" was too strong and is rewritten. The report never claimed a shipped build was defective, but the framing implied more certainty than the evidence carries. | §5 S1 |
| **Website privacy claims wrong** — the policy *does* disclose silent CloudKit push and *does* disclose the diagnostic log | **Upheld, and these were outright errors.** S8 is fully withdrawn; S7 narrowed to "itemise the captured fields." | §5 S7/S8, §9 W4 |

Two further corrections accepted:
- **Scope figures mixed populations.** "223 files, ~86k LOC" was wrong: 223 files is production-only (**74,736** LOC); 87,375 LOC is all 295 files including tests. Header corrected.
- **Nine HTML pages, not eight.** Corrected — with the added finding that `stats.html`'s lack of SEO metadata is *correct* (it is `noindex` and password-gated), so it is not a gap to fix.

One point of partial disagreement, recorded for the next reader: the audit
classifies **P4** (Discover timer) as "latent risk, not a current defect." That is
right, and it is what §2 P4 already says ("impact is currently low"). No change.

### Root cause of the errors

Three of the four failures share one cause: **counting instead of reading.** The
privacy errors came from `grep -c` on keywords rather than reading the prose; the
D1 error came from treating a syntax count as a semantic measurement. The
AppState error came from assuming a mechanism (`ObservableObject` ⇒ publishes)
rather than verifying it — a one-line grep would have caught it, and that grep is
now in the table above.

Counting is good for *finding candidates* and bad for *drawing conclusions*.
Findings in this report that came from reading code paths (**B1**, **B4**,
**B5**, **D3/D4**, **S5**, **T1**) held up without exception; findings that came
from counting are exactly the ones that failed. A future model using this
document should apply that filter to its own method.
