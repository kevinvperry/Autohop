> **SUPERSEDED — historical record only.** Current canonical assessment: `ASSESSMENT_2026-08-30.md`, which corrects several figures stated here (notably the 219 fixed-font count, now measured at 263, and the aps-environment framing).

# Autohop Whole-Project Assessment — Independent Pass — 2026-07-24

<!--
AI CONTEXT — ASSESSMENT_2026-07-24.md
Independent, source-grounded, point-in-time engineering/product/UI/sync/security
assessment of the Autohop iOS + tvOS codebase and the kevmarl-site public pages.
Produced by re-deriving findings from the CURRENT working tree, not from prior
Claude memories or the previously committed assessment. Every claim below is
anchored to a symbol or file:line verified at review time; RE-LOCATE and RE-READ
before acting on any recommendation — code moves.

AUTHORITY BOUNDARIES (do not restate behaviour here as truth):
- FEATURES.md owns behaviour/defaults. PAGES.md owns visible names/navigation.
- DESIGN.md owns visual patterns. SYNC_DESIGN.md owns CloudKit semantics.
- VERSION_1.4.md owns the post-1.3 implementation ledger.
- Internal `Queue*` symbols are intentional legacy names; the visible page is
  "Up Next".

SUPERSEDES the prior 2026-07-24 assessment committed at 938163c (recoverable via
git). This pass CONFIRMS the bulk of that report against code and adds hard
quantification, verified file:line evidence, one near-divergence that verification
resolved (host circuit breaker DOES exist), and a single unifying frame: the
logs 15–17 background remediation is CODE-COMPLETE but DEVICE-UNVERIFIED.

FINAL AUDIT 2026-07-25:
- Claude's corrective response was independently checked against both repositories.
- The required website icon is now tracked (`kevmarl-site` commit `51a7f5f`);
  the website is clean, reproducible, deployed, and serves the corrected Web3Forms
  CSP from commit `c380755`.
- All 12 user-facing DESIGN.md references to the old Queue page name are now
  "Up Next" (`0fc7a55`); internal `Queue*` symbols and the "Queued" state remain.
- SettingsView.swift and SubscriptionSettingsView.swift received the previously
  missing line-by-line copy audit. App, in-app Support, website Support, and
  FEATURES now agree after the two verbatim Auto Archive footer quotations were
  corrected (`0896d02`).
- AI CONTEXT verification proves file-level Swift marker coverage and targeted
  accuracy in recently changed subsystems. It does not prove that every comment
  in every subsystem remains complete; context quality is a continuing review
  obligation, not a one-time binary gate.
-->

## 1. Executive summary

Autohop is a mature, unusually well-instrumented, download-first podcast player.
The architecture is materially stronger than legacy reports imply: AppState is
decomposed into domain coordinators/workflows, feed selection/parsing/downloads
have bounded recovery paths, background scheduling avoids the moving-horizon
replacement defect, and nearly every file carries a machine-oriented AI CONTEXT
header. The codebase is clean: 1 TODO/FIXME across non-test source, no deprecated
UIKit window/keyWindow/unarchive APIs, no embedded secret, ad tracker, or
behavioural-analytics SDK found.

**The single most important finding is a status, not a defect.** Every remediation
that the diagnostic logs 15–17 recommended is now implemented in the working tree
— feed-selection fairness, phase-aware download deadlines, per-host + cross-host
circuit breakers, generation-safe watchdog cancellation, per-item parse memory
caps, and a parse-memory quarantine. **None of it has been verified on a physical
device under battery.** The logs that motivated the work all predate the code that
implements it (log 17 export = build 4, 08:34 AEST; the remediation is now
committed at and after `938163c`). The correct next action is a device matrix, not
more speculative background-policy tuning.

Remaining genuine risks are trade-offs and polish, not emergencies: a global ATS
exception for legacy HTTP feeds, development APNs entitlements that must be
release-gated, whole-list LWW sync records that cannot merge concurrent reorders,
high UI reliance on fixed font sizes/geometry (a Dynamic-Type accessibility gap),
and public copy that must never promise fixed background intervals.

Checked-in shipping config is **iPhone 1.3 build 4**. The tree also contains
implemented 1.4 work plus development-gated tvOS, Autohop Pro, and Relay code.
Docs and website must keep distinguishing "implemented in source" from "shipping".

## 2. Scope and method

Static review of the current working tree (216 Swift files, ~69k LOC), plists,
entitlements, privacy manifest, StoreKit config, and the kevmarl-site pages.
Findings are anchored to verified symbols/lines. This pass did **not** run the app
or capture device traces; iOS owns background launch timing and no static review
can measure real energy/scheduling. Every "landed" claim below means "present and
read in source", explicitly **not** "validated in behaviour".

The final audit additionally inspected the repository/commit state, rebuilt-source
requirements, remaining visible Queue terminology, and all user-facing copy and
bindings in `SettingsView.swift` and `SubscriptionSettingsView.swift`. Exact UI
counts are scope-sensitive: the **219** fixed-font count below covers `Views/`;
the current whole-project equivalent is **223** after including App, TV, Widgets,
and CarPlay. Neither number is a substitute for runtime accessibility testing.

## 3. Logs 15–17 remediation — verification status (CODE-COMPLETE, DEVICE-UNVERIFIED)

| Log finding | Fix in tree | Evidence | On-device verified |
|---|---|---|---|
| Feed-selection starvation (oldest deferred waited 45 min) | Fairness reservation: ≥8 min deferred → reserve 1 slot within the hard ceiling, ≥20 min → 2 | `FeedRefreshCycleWorkflow.swift:1137-1161` (`fairnessReservation`) + `:529-558` wiring into `FeedRefreshBudgeting` | ❌ |
| 60 s first-byte deadline too aggressive backgrounded | Phase-aware: 60 s foreground, **240 s** background, anchored to task create/resume | `DownloadManager.swift:131-132`, header `:38-41` | ❌ |
| No host circuit breaker (pdst.fm 36, Akamai 37 cancels) | Per-host: 2 terminal fails/10 min → host opens 15 min; cross-host: 3 failing hosts → global 5 min; success clears; manual bypasses | `DownloadCoordinator.swift:325-363` | ❌ |
| Watchdog double-cancel race (cancelled a completed transfer) | Generation-safe: one terminal decision per task generation; per-attempt absolute deadline work items; post-`getAllTasks` recheck | `DownloadManager.swift:109-115` (`firstByteDeadlineWorkItems`, `watchdogEvaluationInFlight`, `watchdogCancellationClaimedTaskIDs`) | ❌ |
| Retry-exhaustion resurrection | Durable per-episode cooldown (900 s), survives feed cycles; manual bypass only | `DownloadCoordinator.swift:192-238`; log 17 already showed it holding (min restart +15.8 min) | ⚠️ partially (log 17) |
| Parse memory bomb (3 MB feed → +477 MB) | Per-element char caps (description 64 KB, ordinary 8 KB) + truncation + per-item autorelease + 50-episode abort | `RSSParser.swift:250-251, 354-381, 420, 423-425` | ❌ |
| Parse memory as jetsam risk | Parse-memory quarantine (6 h → 12 h escalation) skips high-growth feeds from auto-refresh | `FeedRefreshCycleWorkflow.swift:490-512`; `Models/Subscription.swift` `parseQuarantineUntil` | ❌ |
| BGAppRefresh cancelled a manual cycle (log 17 #4) | Deadline handler detaches when it does not own the active cycle, or when foreground/audio owns it | `FeedRefreshCycleWorkflow.swift:255-304` (`cancelIfOwnedByBackgroundTask`) | ❌ |
| Moving-horizon BGAppRefresh replacement | Pending request replaced only if ≥60 s materially earlier | `BackgroundTaskCoordinator.swift:101-108` (`shouldReplacePendingAppRefresh`) — log 16/17 confirmed (73–176 skips / few schedules) | ✅ |
| BGProcessing zero-wake | Outcome-paced + persisted eligibility; requires external power + network | `BackgroundTaskCoordinator.swift:285-343` | ✅ (log 16 03:08 run) |

**Implication:** do not describe any of the ❌ rows as "fixed" in release notes,
website, or docs until a battery capture confirms them. The prior assessment's
P1 ("physical-device validation remains essential") is the correct top priority;
this table is the concrete checklist for it.

### 3.1 Two nuances a future model must not miss

- **Fairness applies only to `backgroundAudioAlive`.** The hard-slot reservation
  (`:1142` guard) is scoped to the audio-poll path. A real BGAppRefresh wake uses
  `protectedStates`/`minimumProtectedSelections` (`refreshForBackground`,
  `:159-185`) and the follow-up batch relies on `deferredScoreBoost` in the
  Release Radar score — not the hard reservation. This asymmetry is intentional
  but means the log-17 starvation fix does not transfer verbatim to BGAppRefresh;
  verify both paths.
- **Quarantine may now be near-redundant.** With the real per-element caps in
  `RSSParser` (`:250-251`), the feeds that previously tripped the quarantine
  (This Week in Tech: 3 MB → +477 MB) should no longer allocate hundreds of MB.
  If a device capture shows the quarantine still firing, the caps are insufficient;
  if it never fires, consider softening the 12 h escalation so a transiently
  heavy feed is not frozen out of auto-refresh for half a day. Do not remove the
  quarantine — keep it as the safety net — but instrument whether it still earns
  its place.

## 4. Background-task subsystem (priority review)

**Scheduling (`BackgroundTaskCoordinator.swift`)** is sound. Moving-horizon defect
resolved (`:101-108`). BGProcessing is outcome-paced (`processingDelay` `:285-309`:
initial 12 h, completed-work 18 h, no-work 8 h, expiry 2→24 h exponential) with
positive-only jitter and a persisted `nextEligibleDate` so relaunches cannot reset
the clock. `requiresExternalPower`/`requiresNetworkConnectivity` are both set
(`:338-339`). The 11-hour BGAppRefresh gap in log 17 is **iOS budget throttling on
battery, not an app defect** — the app kept a single pending request correctly and
iOS simply granted no window. No code change can force this; the mitigation is the
background-audio poll path, which log 17 confirmed alive (104 screen-closed cycles).

**Adaptive budget (`backgroundAudioBudget` `:924-993`)** is well-designed: base
audio limits expand to 8/10 feeds for an aging/large backlog **only** when not in
Low Power Mode, thermal state < serious, and footprint < 300 MB; and shrink under
Low Power (4/6), thermal serious/critical (3/5, 2/3), constrained/cellular/expensive
network (4/6), and ≥100 MB active downloads (4/6). This is the right shape.

**Residual gaps / recommendations (background):**
1. **Device matrix is the gate** — unplugged audio, locked screen, Wi-Fi/cellular
   handoff, Low Power, thermal, overnight charging, large backlog. Report per
   execution context: feed age, selected/deferred, material changes, transfer
   start/complete, footprint, battery delta.
2. **Add CI fixtures** for the parser (3–10 MB malformed, 10k-item, huge
   `content:encoded`, entity-heavy) asserting retained-char caps, episode-limit
   abort, quarantine persistence, and conditional-request reuse.
3. **Add watchdog stress tests** for delegate delivery after simulated process
   suspension — protect "one terminal decision per task generation" and the
   post-`getAllTasks` recheck from regression.
4. **Harden interruption recovery** (log 17, 13:19: `engine.restartFailed` ×3 →
   `app.willTerminate`). `PlaybackEngine.swift` received +155 lines in the
   snapshot; verify the Core-Audio `-50`/interruption-resume path rebuilds the
   session+graph through one serialized recovery and cannot wedge into termination.

## 5. Efficiency & performance

- **P-A (Medium): oversized source units.** `Models/Subscription.swift` (3,199),
  `Views/PlayerView.swift` (2,490), `Playback/PlaybackEngine.swift` (2,270),
  `Persistence/SubscriptionStore.swift` (2,152), `Views/StatsView.swift` (1,609),
  `Persistence/CloudSyncEngine.swift` (1,477). Comments are excellent but size
  inflates merge/compile/regression surface. Recommend behaviour-preserving
  extractions only (render subviews from state owners; Codable-by-domain
  extensions; audio route/graph helpers behind tested protocols). Do **not**
  re-aggregate coordinators back into AppState.
- **P-B (Low): notification coalescing is correctly used** — background feed cycles
  wrap mutations in one `begin/endChangeNotificationCoalescing` transaction
  (`FeedRefreshCycleWorkflow.swift:641-648`) and CKSyncEngine fetch bursts do the
  same (`CloudSyncEngine.swift` header). This is a real prior-fix; keep it.
- **P-C (Low): deprecated Accelerate call.** Prior assessment flags `cblas_scopy`
  in `PlaybackEngine.swift` as deprecated since iOS 16.4. Compiles; frame counts
  far below 32-bit limits. Maintenance debt only; migrate behind an audio
  regression test, not urgently.

## 6. Reliability & correctness

- **R1 (Medium): whole-list LWW sync records cannot merge concurrent edits.**
  Subscription order (`subscription-order:current`) and the Up Next snapshot are
  intentionally atomic whole-record LWW by `updatedAt`
  (`CloudKitSyncMapping.swift:170, 211`). Two devices reordering concurrently:
  one entire generation wins, the other's reorder is lost. Correct for coherence,
  wrong for merge. Keep deterministic timestamp tie-break; document precisely in
  Support; only consider an operation-log/CRDT for order if concurrent editing
  becomes common (with tombstones + bounded compaction).
- **R2 (Medium): "all settings sync" is false.** Episode state, per-podcast
  settings, subscriptions, order, history, position, Stats, Up Next roam; global
  AppSettings, network prefs, onboarding state, and learned Release Radar
  observations are device-local. Defensible, but keep the explicit matrix in
  SYNC_DESIGN + Support and never claim total sync.
- **R3 (Low): multiple-scene declaration vs singleton services.** If the plist
  declares multi-window while playback/downloads are process singletons, either
  test two windows with defined ownership or disable multi-window. Verify the
  plist state before acting.

## 7. Cross-device sync

Engine is well-built: opt-in (`iCloudSyncEnabled`), two-lane push (fast =
user actions immediate; slow = history/stats debounced ~60 s), type-namespaced
record names to prevent shared-zone collisions, and coalesced fetch apply
(`CloudSyncEngine.swift` header). tvOS is structurally read-only for subscription
state — `pushesSubscriptionState: false` is a hard one-way rule set at the TV
composition root (`TV/App/AutohopTVApp.swift:444-456`), satisfying the explicit
"TV must not alter phone subscriptions" constraint. **Improvement opportunities:**
(a) resolve R1 whole-list merge if two-device reordering is real for users;
(b) classify any future global setting as roamable vs device-specific rather than
syncing the whole AppSettings blob; (c) a per-episode event/tombstone model would
make historic played/archived sets a clean cross-device merge (currently union
risks blocking removals, LWW risks losing concurrent adds).

## 8. Security & privacy

- **S1 (Medium/High trade-off): global ATS exception.** `Info.plist`
  `NSAllowsArbitraryLoads = true` permits clear-text HTTP for legacy feeds/media.
  Necessary for the long tail of HTTP RSS, but broadens attack surface. Recommend:
  prefer HTTPS; warn visibly before adding an HTTP feed; never send credentials/
  tokens over HTTP; reject URL user-info; consider blocking loopback/link-local/
  private-network hosts unless the user confirms a local feed; keep Relay/CloudKit/
  Apple HTTPS-only; re-justify the global exception each release.
- **S2 (High for release): development APNs entitlement.** `Autohop.entitlements`
  has `aps-environment = development`. Signing may override for distribution, but
  an archive slip would silently break production push. Add a release/CI check that
  inspects **signed** entitlements and fails if the App Store artifact is not
  `production`.
- **S3 (Medium): Relay JWS verification is a decode-only placeholder** (per source
  header). Feature gates prevent production use — correct control. Never enable
  Pro/Relay in production until the server verifies the full Apple cert chain,
  bundle/product/environment, signed date, revocation/expiry, and transaction
  status; rate-limit registration.
- **S4 (Low): diagnostics remain behaviourally sensitive even when redacted** —
  feed hosts + titles + timing reveal listening habits; exports leave the sandbox
  on explicit user action. Keep titles bounded, maintain redaction tests, warn
  before sharing.

## 9. Design, UI, layout consistency, accessibility (quantified)

- **U1 (Medium): Dynamic Type is the biggest UI gap.** **219** fixed
  `.font(.system(size:))` call sites and **121** fixed `.frame(width/height:)` in
  `Views/`. Fixed point sizes do not scale with the user's text setting and can
  truncate titles, metadata pills, settings copy, and Stats labels at accessibility
  sizes. Recommend semantic fonts for body/settings text, `@ScaledMetric` for
  deliberate geometry, multiline labels, and testing the two largest Dynamic Type
  categories + Bold Text + Increased Contrast. Preserve 44 pt hit targets.
- **U2 (Medium): accessibility-label coverage is thin.** Only **21 of 39** view
  files reference `accessibilityLabel/Hint/dynamicTypeSize/accessibilityElement`.
  The mini-player is well-labelled (`RootView.swift`), but audit VoiceOver reading
  order across Player panels, Up Next, Priority, Settings, and Podcast Settings.
- **U3 (Medium): no code-level design-token abstraction found.** Zero references to
  a central theme/`DesignSystem` in `Views/` vs **31** inline `Color(red:/hex:/sRGB)`
  literals — colours appear defined at call sites (verify whether asset-catalog
  named colours are used elsewhere). Combined with three visual systems (iOS 17–25
  dark cards, iOS 26 glass, tvOS focus), this risks per-page shade/spacing drift.
  Recommend consolidating colour into named tokens and adding reference snapshots
  for Player/Priority/Up Next/Settings on iOS 17 + 26 and focused/unfocused tvOS.
- **U4 (Medium): Settings density.** Global and per-podcast Settings are coherent
  but long (mixed runtime controls, defaults, storage, contact, hidden diagnostics).
  Keep labels/defaults; consider stable subpages (Playback Defaults,
  Automation/Background, Data/Sync); frequently-changed controls up top, destructive
  actions last.
- **U5 (Low): page naming converged on "Up Next".** Internal `QueueSheetView`,
  `QueueSnapshot`, DB keys, and log events stay valid; future user-facing IDs /
  a11y labels / deep links should use `up-next`.

## 10. tvOS assessment

tvOS is a **companion**, not parity. `TV/Views/` ships 8 surfaces (Home, Library,
Queue/Up Next, Player, Search, EpisodeList, MainTab, + Theme/Artwork) — no Stats,
Discover depth, Downloads, or dense per-podcast configuration, which is correct
(a TV is a poor place to configure rules). Read-only subscription-state sync is
enforced structurally (`AutohopTVApp.swift:456`). Recommend: document an explicit
tvOS support matrix (browse/search/play/resume/Up Next/transport on TV;
configuration on iPhone) and verify empty / signed-out / CloudKit-unavailable /
stale-snapshot states before any TV release. Keep tvOS in sync with every iOS
design/fix change in the same pass (standing project rule).

## 11. Stale / outdated code

Very clean. **1** TODO/FIXME/HACK in non-test source; no `UIApplication.shared.windows`,
`keyWindow`, or `NSKeyedUnarchiver.unarchiveObject`; vDSP/`withUnsafeBytes` uses are
correct, not deprecated. Only genuine debt: the `cblas_scopy` Accelerate call (P-C)
and the large-file regression surface (P-A). No dead-module or abandoned-feature
smell found in the read sample.

## 12. Confirmations of, and divergences from, the prior committed assessment

- **Confirmed against code:** ATS exception (S1), development APNs (S2), Relay
  placeholder (S3), whole-list LWW (R1), device-local settings/learning (R2),
  Settings density (U1/prior U1), Dynamic Type risk (prior U2 — now quantified at
  219/121), three-visual-system consistency (prior U3), tvOS companion status
  (prior U5), oversized files (prior P2), moving-horizon + BGProcessing pacing.
- **Near-divergence resolved by verification:** prior P4 asserts "durable episode/
  **host** cooldowns". An initial grep suggested only per-episode cooldown; direct
  read of `DownloadCoordinator.swift:325-363` **confirms** the per-host +
  cross-host breaker exists. Prior report is correct; flag logged so future models
  do not "correct" it away.
- **Added by this pass:** the unified CODE-COMPLETE / DEVICE-UNVERIFIED status
  table (§3); hard UI quantification (§9); the fairness-scope asymmetry and
  quarantine-redundancy nuances (§3.1).
- **Final audit closures (2026-07-25):** the website's previously untracked,
  build-required `icon.png` is committed and a tracked-source rebuild is
  reproducible; the live CSP permits `api.web3forms.com`; all user-facing
  DESIGN.md Queue-page references now say Up Next; and the complete global/
  per-podcast Settings copy audit found no app-code defect. The only discovered
  drift was two FEATURES quotations that claimed to reproduce the Auto Archive
  footer verbatim; those quotations now match the app and Support mirrors.
- **Important qualification retained:** every Swift file contains an AI CONTEXT
  marker, but marker presence is only file-level coverage. It does not establish
  that every algorithm, ownership boundary, configuration file, build script, or
  future edit is adequately explained. Treat comment accuracy as a review
  discipline and require context updates in the same change as behavioural edits.

## 13. Final recommendations

### 13.1 Required before claiming the background remediation is verified

1. **Run the physical-device background/energy matrix.** Use every ❌ row in §3
   as an explicit assertion. Include long unplugged locked-screen audio, screen-off
   periods with and without playback, Wi-Fi↔cellular changes, Low Power Mode,
   thermal pressure, failing media hosts, a large backlog, malformed feeds, and a
   charging overnight control. Compare feed age, fairness selections, selected/
   deferred work, material updates, transfer attempts/completions, cancellation
   generations, CPU, memory, jetsam/MetricKit evidence, and battery delta by
   execution context.
2. **Require more than one representative capture.** One successful night proves
   only that session. Use at least a normal listening day and a deliberately
   adverse session before changing a §3 row from ❌ to ✅.
3. **Do not retune the four-minute background-audio policy from anecdotes.** First
   verify that fairness, phase-aware deadlines, circuit breakers, parser bounds,
   and BGTask ownership work together. Retune only from measured freshness,
   battery, CPU, radio, and backlog-age evidence.

### 13.2 Required before the next public release

4. **Keep the new regression suite mandatory.** The 25 July suite now covers
   pathological parser bounds, watchdog final-cancel races, cooldown escalation,
   host/session circuit behavior, fairness thresholds, and BGTask ownership.
   Preserve the shared SwiftPM execution and Xcode-only build-for-testing CI jobs.
   Device suspension, delegate delivery after process relaunch, and physical-memory
   peaks remain integration/device assertions rather than deterministic unit tests.
5. **Use the new release security gate for every upload.**
   `Scripts/validate-release.sh --configuration-only` now protects Pro/Relay/tvOS
   source gates in CI. Before upload, run it with `--archive` against the exact
   distribution `.xcarchive`; it fails unless the signed app has production APNs
   and no tvOS app is embedded. Keep Pro/Relay disabled until the server performs
   complete Apple JWS/certificate-chain, bundle, product, environment, date,
   revocation, and transaction-state validation.
6. **Complete an accessibility release pass.** The measured **219** fixed
   `.font(.system(size:))` sites in `Views/` (**223** whole project) are the largest
   UI risk. Prioritise Settings, Podcast Settings, Player metadata, Up Next,
   Priority, Stats, widgets, CarPlay, and tvOS. Use semantic fonts or
   `@ScaledMetric`, multiline text, ≥44 pt targets, VoiceOver order/labels, Bold
   Text, Button Shapes, Increased Contrast, and the two largest Dynamic Type sizes.
7. **Harden HTTP-feed handling without silently breaking legitimate legacy feeds.**
   Prefer HTTPS, warn clearly before subscribing to HTTP, reject credential-bearing
   URLs, never transmit secrets over clear text, and adopt an explicit policy for
   loopback/link-local/private-network destinations. Retain the broad ATS exception
   only while real compatibility evidence justifies it.
8. **Keep source, app copy, Support, website, and generated Worker atomic.** Any
   behavioural or naming change must update FEATURES/PAGES/DESIGN/SYNC_DESIGN/
   VERSION_1.4 as applicable, both Settings surfaces, Support mirrors, website
   pages, AI CONTEXT, and generated artifacts in the same change. Build the website
   from tracked files and verify the live CSP/contact path after deployment.

### 13.3 Planned engineering improvements, not release blockers

9. **Decide whether concurrent list editing warrants a new sync model.** Preserve
   current deterministic whole-record LWW for Priority and Up Next unless real
   multi-device conflicts justify an operation log with tombstones and bounded
   compaction. Keep the sync matrix explicit; do not sync the whole AppSettings
   blob indiscriminately.
10. **Extract large source units incrementally behind tests.** Separate rendering
    subviews, model-domain extensions, audio route/graph helpers, and tvOS
    CloudKit/materialisation responsibilities without creating parallel state
    ownership or rebuilding AppState as a monolith.
11. **Modernise the deprecated Accelerate call in an isolated audio change.** Move
    from the deprecated `cblas_scopy` interface, then regression-test mono
    duplication, route changes, Trim Silence, Vocal Boost, interruptions, and
    resume on physical devices.
12. **Treat AI CONTEXT as maintained architecture metadata.** File-level marker
    coverage is complete; quality is not permanently “done.” Review ownership,
    invariants, lifecycle, concurrency, persistence, security boundaries, and
    failure behaviour whenever a subsystem changes. Extend the same standard to
    project/configuration/build assets where comments are supported.

### 13.4 Closed findings — do not reopen without new evidence

- Website source reproducibility (`icon.png`) and the Web3Forms CSP regression.
- Visible Queue-page naming in DESIGN.md; **Up Next** is canonical while internal
  `Queue*` symbols and the `Queued` state remain valid.
- Global and per-podcast Settings-copy consistency, including Auto Archive footer
  quotations and the 30-minute Inactive Episodes option.
- Moving-horizon scheduling replacement and the exercised BGProcessing path.
- Presence/wiring of the logs 15–17 remediation. Its runtime status remains
  device-unverified exactly as shown in §3.
- Deterministic regression coverage for parser bounds, watchdog cancellation
  races, retry cooldowns, circuit breakers, fairness thresholds, and BGTask
  ownership; retain these tests as release gates.
- Configuration and archive-time release validation for disabled Pro/Relay/tvOS
  features and signed production APNs.

## 14. Release gate

Before the next public build:
- confirm both repositories begin clean and all required/generated website assets
  can be reproduced from tracked source;
- clean-generate the project (`xcodegen generate`) and build iOS + tvOS schemes;
- run the full test suite, the §13.2 regression fixtures, and website generator/
  syntax checks;
- inspect **signed production** entitlements and the privacy manifest;
- run `Scripts/validate-release.sh --archive <exact-upload.xcarchive>`;
- exercise: fresh install, existing-user upgrade, OPML import, first subscription,
  iCloud off→on, two-device order/Up-Next conflict, HTTP + HTTPS feed, locked-screen
  audio, **unplugged background refresh (§3 matrix)**, large malformed feed,
  interruption→resume, CarPlay, widget actions;
- verify Dynamic Type/VoiceOver/contrast and tvOS focus/empty/error states;
- reconcile app copy, website, Support, privacy, AI CONTEXT, and canonical documents
  against the exact release feature gates;
- deploy the website only from its committed reproducible source, then verify live
  headers, `/llms.txt`, icon routes, and a Web3Forms contact submission;
- bump MARKETING_VERSION/build only once release scope is fixed.
