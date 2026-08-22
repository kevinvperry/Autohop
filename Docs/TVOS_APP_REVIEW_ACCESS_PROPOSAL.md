# Autohop tvOS App Review Access — Phased Resolution Proposal

<!--
AI CONTEXT — Docs/TVOS_APP_REVIEW_ACCESS_PROPOSAL.md

PURPOSE: Canonical, implementation-ready proposal for resolving the App Store
Review rejection of Autohop tvOS Version 1.5 (build 6), submission
58fa2f2b-d022-4d85-8604-fca296177a3d, reviewed 15 August 2026 on tvOS 26.5.
The reviewer reported indefinite loading and could not access the app's
functionality because a clean Apple TV installation had no phone-authored
Autohop library in the reviewer's private iCloud account.

STATUS: IMPLEMENTED IN CODE ON 15 AUGUST 2026 through the automated-build/test
gates: bounded presentation fallback, setup/retry/Discover access, isolated
offline demo, bundled first-party audio/video, ephemeral demo interactions,
Reset/Exit, AI headers and canonical documentation. Physical Apple TV clean-
install/focus/playback validation and inspection of a signed distribution
archive's effective APNs/CloudKit entitlements remain unrecorded in the
repository. Version 1.6 build 13 was submitted on 22 August 2026; do not treat
submission as proof that the rejection is resolved, approved or publicly
released.

INDEPENDENT REVIEW UPDATE: Claude Opus findings were audited against the source
on 15 August 2026. Accepted: launch and review access are distinct requirements;
the demo must ship in Release; fixtures/media should work offline; all bootstrap
stages need bounded ownership. Qualified: the exact stalled await is unproven,
and a source `aps-environment: development` value does not prove the App Store
binary used sandbox APNs because Xcode derives the effective value from the
distribution profile. Inspect the signed Release archive before changing or
closing either finding. See §2.5.

PRIMARY DECISION: Preserve Autohop's private-iCloud companion architecture,
but make a clean Apple TV installation a complete, non-blocking experience.
After a bounded initial sync attempt, show a stable setup/empty state with
Retry, Explore Discover, and Explore Demo Library actions. Demo mode must be
local, deterministic, clearly labelled, fully reversible, review-accessible,
and incapable of writing synthetic data to CloudKit or production statistics.

SYNC AUTHORITY: iPhone remains authoritative for subscriptions, priority
order, subscription settings, and the normal Up Next snapshot. Apple TV remains
a companion client. Demo mode is a presentation/testing environment, not a new
sync authority and not an alternative user account system.

SAFETY BOUNDARY: Never store demo subscriptions, queue snapshots, history,
playback positions, archive state, or listening statistics in the production
SubscriptionStore, AutohopDatabase, CloudKit zone, survival kit, widget data,
or analytics. Never require an App Review username/password: Autohop has no
developer-operated account service and uses each user's private iCloud account.

SCOPE: tvOS application, tvOS tests, App Review notes, and affected project
documentation. iOS runtime behaviour must remain unchanged. Shared types may be
used only where they remain immutable domain values and do not introduce demo
state into shared persistence or sync paths.

CANONICAL RELATED DOCUMENTS:
- TV/AI_CONTEXT.md
- Docs/TVOS_REBUILD_PROPOSAL.md
- Docs/TVAPP_MODEL_DECOMPOSITION_PROPOSAL.md
- SYNC_DESIGN.md
- DESIGN.md
- FEATURES.md
- PAGES.md
- VERSION_1.6.md

AI IMPLEMENTATION RULE: Execute phases in order. Keep the first-launch state
machine, demo data source, demo playback side effects, and App Review copy as
separate concerns. Do not solve review access by weakening iCloud privacy,
shipping hidden credentials, silently seeding a real library, or compiling a
review-only build that differs from the customer binary.
-->

> **Version 1.6 implementation refinement — 15 August 2026:** The ten-second
> actionable deadline applies to clean installs with no durable library
> evidence. A returning Apple TV with survival-kit or cached-projection evidence
> receives a 45-second branded recovery grace across both loading and transient
> empty states, preventing first-time setup from flashing during ordinary iCloud
> catch-up while retaining an eventual actionable recovery path.

## 1. Executive summary

Apple rejected the tvOS submission under Guideline 2.1(a) for two connected
reasons:

1. A clean Apple TV installation appeared to load indefinitely.
2. The reviewer could not access enough functionality to evaluate the app.

Autohop currently assumes that the Apple TV user has already installed the
iPhone app, subscribed to podcasts, and enabled iCloud Sync. That assumption is
valid for the intended companion workflow, but it is not sufficient for a
standalone App Store installation or for App Review's clean-device process.

The existing runtime already attempts to leave the launch state after a short
grace period. However, the subsequent `.empty` screen retains a `ProgressView`
and the message “Still listening for iCloud updates…”. It therefore continues
to communicate unfinished loading. It also blocks access to the normal tab
interface, including Discover and Settings. The reviewer has no Autohop account
credentials to enter because Autohop deliberately has no developer-operated
account system, and their Apple TV is connected to their own private iCloud
account rather than the developer's test library.

The recommended resolution has three layers:

- **Make first launch finite:** use an explicit, bounded state machine and stop
  showing an activity indicator when the initial attempt completes.
- **Make the empty product useful:** allow access to Discover and Settings even
  when no synced library exists, while clearly explaining the iPhone/iCloud
  companion setup.
- **Make full review possible:** provide a built-in local demonstration library
  that exercises the major tvOS flows without credentials or CloudKit data.

This is preferable to supplying a username/password because no such Autohop
account exists. It also preserves the product's privacy promise and gives real
customers a better recovery path when they install Apple TV first, disable
iCloud, use the wrong Apple Account, or encounter a temporary CloudKit delay.

## 2. Evidence and root-cause analysis

### 2.1 Review evidence

- Submission: `58fa2f2b-d022-4d85-8604-fca296177a3d`
- Reviewed version: `1.5 (6)`
- Review hardware: Apple TV
- Review OS: tvOS 26.5
- Network: active
- Observed result: indefinite loading on launch
- Additional requirement: a way to verify features for all account types,
  normally through credentials or an in-app demonstration mode

The network being active does not guarantee that the reviewer's private iCloud
zone contains Autohop subscription records. A clean reviewer account should be
treated as a valid empty input, not an exceptional or indefinitely transitional
condition.

### 2.2 Current code path

The relevant runtime path is:

1. `AutohopTVApp` displays `TVLaunchLoadingView` and creates `TVAppModel`.
2. `TVAppModel.bootstrap()` loads local storage, starts CloudKit, begins a
   targeted library prime, refreshes projections, and applies an initial grace
   period.
3. `refreshLibrary()` publishes `.ready` when library tiles exist or `.empty`
   when they do not.
4. `TVRootView` renders `.empty` as setup guidance plus a persistent spinner and
   “Still listening for iCloud updates…”.

Although `.empty` is technically distinct from `.loading`, its visual language
says the operation is still incomplete. The user cannot enter the main tabs
from that state, so the practical outcome is indistinguishable from a hang.

### 2.3 Product-level root cause

The deeper issue is not merely a missing timeout. The current root model treats
“no synced subscriptions” as a gate that prevents access to the application.
That conflates three different conditions:

- CloudKit is actively attempting its first fetch.
- CloudKit completed, but the private account contains no Autohop library.
- CloudKit is unavailable, disabled, signed out, or temporarily failed.

These conditions require different copy and actions. None should trap the user.

### 2.4 Why credentials are the wrong solution

Autohop does not authenticate against a developer-owned service. Its synced
data resides in the current Apple Account's private iCloud database. Supplying
an arbitrary username and password would either be meaningless or require a new
account/backend architecture that conflicts with Autohop's privacy model.

App Review should instead receive the same production binary as customers,
with a visible demonstration mode that requires no secret gesture, special
build flag, reviewer-only entitlement, or external credential.

### 2.5 Independent reconciliation of the Claude Opus review

An independent source audit was performed after Claude Opus supplied a second
analysis. Its central product conclusion is accepted: repairing launch alone
does not provide App Review with full feature access, and a Release-build demo
path is required. Its recommendation for bundled demonstration media also
strengthens this proposal.

The following claims require qualification:

- **The exact blocking call is not proven.** `completeDeferredLoad()` is an
  unbounded await, but it performs local SQLite reads, payload decoding and a
  sync-projection repair inside a detached task. It does not wait for iCloud.
  On a genuinely fresh installation the database should be empty and this path
  should normally finish quickly. It remains a valid watchdog target, but it
  cannot be named as the review failure without timing logs or reproduction.
- **Survival-kit recovery is another unbounded bootstrap stage, but it should
  not exist on a clean install.** When a kit does exist, its sequential RSS
  materialisation can wait on multiple network requests and is a stronger
  reason not to gate first usable UI on the whole recovery pass.
- **A single timeout race around mutable startup work would be unsafe.** A
  timed-out detached database load cannot be assumed cancelled. Publishing a
  usable root while that task later mutates `SubscriptionStore` could create
  concurrent or out-of-order state changes. The durable design needs staged
  deadlines, explicit task ownership, cancellation/coalescing rules, and a
  single main-actor publication boundary—not merely `race(work, sleep)`.
- **The launch animation does not necessarily become motionless.** The status
  message loop stops after its finite message list, while the waveform animation
  is configured to repeat. The more important defect is unchanged: neither
  animation nor rotating copy is a substitute for a guaranteed transition.
- **The APNs source entitlement is a release-audit item, not proven evidence of
  the submitted binary's entitlement.** `project.yml` and
  `TV/AutohopTV.entitlements` currently specify `aps-environment: development`.
  Apple documents that Xcode sets this entitlement from the active provisioning
  profile and that distribution/TestFlight profiles use `production`. Because
  the App Store also re-signs submitted apps, the source plist alone does not
  prove that Version 1.5 (6) used sandbox APNs. The actual archived/exported app
  signature must be inspected. Hard-coded configuration should still be
  reviewed so generated projects and archives cannot drift.

Apple reference: [APS Environment Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/aps-environment)
states that Xcode derives the value from the provisioning profile, with
development profiles using `development` and distribution/prerelease profiles
using `production`.

The resulting plan therefore keeps Claude's useful watchdog and bundled-demo
recommendations, but treats root-cause attribution and APNs breakage as facts to
verify rather than assumptions.

## 3. Goals, non-goals, and invariants

### 3.1 Goals

1. A clean install must present a usable, focusable decision screen within a
   bounded period even when iCloud returns no records.
2. No completed empty or error state may resemble indefinite loading.
3. Discover and Settings must remain accessible without a synced library.
4. App Review must be able to exercise all representative tvOS functionality.
5. Demo content must be deterministic enough for automated tests and reviewer
   instructions.
6. Demo mode must not modify real user data, sync data, stats, or preferences
   beyond one explicit local “demo active” setting if persistence is desired.
7. Real iCloud data arriving later must be handled safely and predictably.
8. Focus behaviour, Siri Remote navigation, audio playback, video playback,
   dismissal, retry, and exit must work on physical Apple TV.
9. Documentation and App Review notes must accurately describe the final build.

### 3.2 Non-goals

- Creating Autohop user accounts or a developer-hosted sync service.
- Allowing tvOS to author real podcast subscriptions or priority rankings.
- Changing the iPhone onboarding or iCloud authority model.
- Writing demo records into CloudKit so they appear on iPhone.
- Hiding the issue with a longer animation or more rotating loading messages.
- Providing only a demonstration video; Apple explicitly requires interactive
  access to the submitted app.
- Building a different binary exclusively for App Review.
- Redesigning every tvOS screen beyond what the review-access flow requires.

### 3.3 Locked invariants

- Production mode reads and writes only genuine user data.
- Demo mode reads only its own local fixture repository.
- Demo mode side effects terminate at a demo-scoped session/state store.
- Switching modes tears down active playback before changing repositories.
- A real library must never be merged with demo rows.
- Demo artwork and metadata must have a documented usage right or be
  first-party synthetic assets.
- Any remote media used in demo playback must be stable, HTTPS-accessible, and
  lawful to stream in App Review territories; bundled short samples are safer.
- The main interface must visibly identify demo mode on every relevant root
  screen so screenshots and reviewer observations cannot be mistaken for real
  synced data.

## 4. Target experience

### 4.1 State model

Replace ambiguous root gating with explicit states such as:

- `launching`: local construction before the first frame is usable.
- `syncingInitialLibrary`: bounded first CloudKit attempt with progress copy.
- `libraryReady`: genuine synced library available.
- `setupRequired(reason)`: sync attempt completed without a usable library.
- `recoverableFailure(reason)`: iCloud account/network/service problem.
- `demoReady`: isolated demonstration session active.

The exact type names may follow existing architecture, but the semantic
distinctions must remain. A loading state must always have a defined exit
condition. A setup or failure state must never display an indefinite spinner.

### 4.2 Setup-required screen

After the bounded initial attempt, show a stable page with:

- Heading: “Set up Autohop on iPhone”
- Explanation that Apple TV uses the user's private iCloud library
- Three concise setup steps
- Primary action: **Explore Demo Library**
- Secondary action: **Open Discover**
- Secondary action: **Check iCloud Again**
- Tertiary access: **Settings**
- Diagnostic status phrased as a completed fact, for example “No Autohop
  library was found in this iCloud account.”

Do not show a continuously spinning progress indicator. A temporary spinner is
appropriate only while the user-triggered retry is actually running, and the
retry must return to a stable state after its own timeout.

### 4.3 Library-free normal mode

The main tab shell should tolerate an empty real library:

- Home explains that Up Next will appear after iPhone sync and offers Discover.
- Library explains setup and offers Retry/Demo.
- History displays a legitimate empty state.
- Discover remains fully usable for browse-and-play.
- Settings remains fully usable and displays iCloud/account diagnostics.

This improves the real product independently of demo mode and prevents library
membership from being an application-level navigation gate.

### 4.4 Demonstration mode

Demo mode should present a coherent sample account containing:

- at least four shows with varied artwork and priority ranks;
- multiple audio episodes and at least one video episode;
- a populated Up Next order with normal and pinned/play-next examples;
- one partially played item suitable for Continue Listening/Watching;
- finished and archived examples;
- representative history entries;
- episode descriptions, dates, durations, chapters where supported, and
  realistic download/stream availability states;
- enough content to demonstrate Library, episode lists, details, playback,
  queue actions, history, Discover, Settings, focus movement, and empty/error
  messaging.

Demo mode should include a persistent “Demo” badge and an obvious **Exit Demo**
action in Settings. On exit, discard all demo mutations and return to the real
library/setup state.

## 5. Architecture proposal

### 5.1 Separate content source from presentation

Introduce a tvOS-scoped library/session boundary rather than inserting fixtures
into `SubscriptionStore`. For example:

```swift
enum TVContentMode: Equatable {
    case personalLibrary
    case demonstration
}

protocol TVContentSession {
    var mode: TVContentMode { get }
    func library() -> [TVPodcastTileModel]
    func upNext() -> [TVQueueRowModel]
    func history() -> [TVHistoryRowModel]
}
```

The precise protocol should match the decomposed models and avoid a giant data
source. The important rule is dependency direction: views consume projections;
the real adapter projects production stores; the demo adapter projects immutable
fixtures plus ephemeral demo mutations.

### 5.2 Demo fixture repository

Create a tvOS-only repository, preferably under `TV/Demo/`, containing:

- stable identifiers;
- deterministic dates relative to a fixed reference or a controlled clock;
- local artwork assets;
- local short audio/video samples or carefully controlled public fixtures;
- immutable base fixtures;
- a resettable in-memory overlay for play progress, archive and queue actions.

Do not represent demo mode by setting `iCloudSyncEnabled = false` and reusing the
production database. Isolation must be structural, not dependent on every
future caller remembering an `if isDemo` guard.

### 5.3 Side-effect routing

All mutable actions require an explicit mode-aware destination:

- Playback progress → real history store or demo session overlay
- Finished state → real persistence or demo overlay
- Archive → real sync workflow or demo overlay
- Play Next/Unpin → real CloudKit request or demo queue overlay
- Listening stats → real `ListeningStatsStore` or no-op/demo-only counter
- Survival kit → production only
- CloudKit flush → production only

Prefer injecting collaborators over scattering mode checks throughout views.
Tests should fail if a demo session receives a production writer.

### 5.4 Playback media strategy

The safest review fixture uses short, bundled, first-party audio and video files
so the core demonstration does not depend on third-party RSS availability,
geoblocking, redirects, expiring URLs, or licensing ambiguity. Discover can
still demonstrate live network playback separately.

Bundled samples should be long enough to test seek, pause, resume, speed and
progress but small enough to avoid materially increasing the app download.
They must contain no copyrighted podcast material without permission.

### 5.5 Real data arriving during demo

Do not silently replace the current screen. Record that a personal library is
available and offer a non-disruptive action such as “Your iCloud library is
ready — Exit Demo”. Switching must stop demo playback, discard the demo overlay,
refresh production projections, and enter the real tab shell.

## 6. Phased implementation plan

### Phase 0 — Reproduce, instrument, and lock requirements

**Objective:** Establish a repeatable clean-install baseline before changing
behaviour.

Work:

1. Archive the exact Version 1.5 (6) behaviour and rejection text.
2. Test after deleting the app from Apple TV, including local cache and prior
   CloudKit tokens.
3. Test four account states: populated iCloud, empty iCloud, iCloud signed out,
   and temporary network failure.
4. Record timestamps for first frame, local-store completion, sync activation,
   targeted prime completion, and root-state transition.
5. Add stage-level begin/end/timeout diagnostics for deferred database load,
   survival-kit recovery, CloudKit activation and the initial projection.
6. Inspect the entitlements of the archived/exported Release `.app`, not only
   the source plist. Confirm `aps-environment` is `production`, the expected
   iCloud container is present, and the archive uses the tvOS distribution
   profile. Treat any mismatch as a separate release blocker.
7. Add a bounded-state policy test independent of SwiftUI.
8. Define the maximum initial waiting interval. Target 8–12 seconds; never wait
   minutes before presenting actionable UI.

Exit gate:

- The clean-install failure is reproducible or the state-transition logs prove
  why the reviewer perceived it.
- Tests demonstrate that every initial condition reaches a non-loading state
  within the chosen bound.
- The submitted-style Release archive's effective entitlements have been
  captured and verified; source configuration has been corrected if it can
  produce a sandbox APNs claim in distribution.
- No customer-facing behaviour has changed yet.

### Phase 1 — Finite bootstrap and honest setup states

**Objective:** Resolve the apparent indefinite-loading defect independently of
demo mode.

Work:

1. Expand `TVBootstrapCoordinator.State` to distinguish setup-required and
   recoverable failure reasons.
2. Divide bootstrap into locally bounded stages. Do not allow survival-kit RSS
   recovery or CloudKit priming to hold the root UI; launch them as owned,
   observable background work after the minimum safe local projection exists.
3. Give deferred database loading an explicit completion/degradation policy.
   If it cannot be safely cancelled, do not race it with an unowned timeout;
   isolate its result and publish it exactly once on the main actor when valid.
4. Make initial cloud sync a bounded presentation operation; owned background
   sync may continue after the UI becomes usable.
5. Remove the persistent spinner from completed empty states.
6. Add **Check iCloud Again** with a bounded, visibly active retry.
7. Display specific guidance for empty account, iCloud unavailable, signed-out
   account, and temporary fetch failure where APIs expose the distinction.
8. Ensure callbacks can promote setup-required to library-ready when genuine
   records arrive later.
9. Add accessibility labels and deterministic initial focus.

Exit gate:

- Clean install never displays indefinite animation.
- Retry cannot become permanently busy.
- Genuine returning users still reach their library immediately when cached or
  synced data exists.
- Empty, failure and late-arrival paths pass automated state tests.

### Phase 2 — Make the normal shell library-independent

**Objective:** Allow useful navigation without a personal library.

Work:

1. Permit entry to `TVMainTabView` with zero subscriptions.
2. Validate Home, Library, History, Discover and Settings independently.
3. Add contextual setup, retry and demo actions to relevant empty states.
4. Ensure Discover browse-and-play does not accidentally require a library
   subscription or queue snapshot.
5. Verify focus returns correctly after dismissing Discover playback.

Exit gate:

- A clean-install user can enter Discover and Settings.
- Every tab has a stable, helpful empty state.
- No empty collection causes force-unwrap, focus trap or navigation collapse.

### Phase 3 — Build the isolated demo domain

**Objective:** Create deterministic representative content without touching
production persistence.

Work:

1. Add `TV/Demo/` with AI headers documenting the isolation boundary.
2. Define fixture IDs, shows, episodes, queue, history and progress.
3. Add first-party artwork and compact media samples with asset provenance.
4. Implement an in-memory demo mutation store.
5. Implement start/reset/exit lifecycle.
6. Add a visible demo badge to Home, Library, History and Player.
7. Add **Explore Demo Library** to the setup-required screen.

Exit gate:

- Demo starts without network or iCloud.
- Demo content is identical after reset.
- Production database and CloudKit pending-change counts remain unchanged
  throughout a full demo session.
- Exiting demo restores the exact real-library/setup state.
- The demo entry point and fixtures exist in Release builds; no `#if DEBUG`,
  launch argument or reviewer-only build setting controls availability.

### Phase 4 — Route demo interactions safely

**Objective:** Make the demonstration interactive enough for App Review while
proving synthetic actions cannot escape.

Work:

1. Route playback progress and completion to the demo overlay.
2. Route archive, Play Next, pin/unpin and queue changes locally.
3. Suppress production stats writes and CloudKit flushes in demo mode.
4. Support audio and video presentation, pause, seek, speed, resume and exit.
5. Provide intentional examples for Continue Listening/Watching and history.
6. Ensure external Discover playback is clearly separate from fixture playback.

Exit gate:

- Reviewer walkthrough can exercise every advertised major tvOS capability.
- Production writers are unreachable by construction or guarded by tested
  injected no-op/demo collaborators.
- Playback transitions and Remote focus pass on physical Apple TV.

### Phase 5 — Review UX and diagnostic hardening

**Objective:** Make the path obvious without private instructions or guesswork.

Work:

1. Put **Explore Demo Library** in the primary focus position on the no-library
   screen while keeping genuine setup equally clear.
2. Add a concise explanation that demo changes are local and temporary.
3. Add **Exit Demo** and **Reset Demo** in Settings.
4. Add a visible iCloud status and last-check result in personal-library mode.
5. Log state transitions using stable event names without user content.
6. Confirm no analytics or tracking is introduced.
7. Review copy at television distance and with VoiceOver.

Exit gate:

- A person unfamiliar with Autohop can enter demo mode within one remote click
  after reading the screen.
- No secret gesture or review-only instruction is required.
- Diagnostics identify the state without exposing private library content.

### Phase 6 — Automated and physical-device validation

**Objective:** Prevent recurrence and prove release quality.

Automated matrix:

- bootstrap policy reaches stable setup state within deadline;
- populated cached library takes the fast path;
- empty CloudKit result selects setup-required;
- account unavailable selects recoverable failure;
- retry transitions busy → result and cannot remain busy;
- late real data promotes setup-required to ready;
- demo fixture integrity and stable IDs;
- demo reset restores baseline;
- demo playback writes only to demo overlay;
- demo archive/queue changes never call production sync;
- exiting demo tears down playback and clears mutations;
- all root states expose a focusable primary action.
- a simulated non-returning local-load stage cannot keep root state loading;
- a late local-load result cannot overwrite a newer ready/demo state;
- generated Release settings and archive inspection enforce production APNs.

Physical Apple TV matrix:

1. Delete and reinstall on an empty iCloud account.
2. Launch with network available but no Autohop records.
3. Launch signed out of iCloud where feasible.
4. Launch offline, then restore connectivity and retry.
5. Enter demo and traverse every tab.
6. Play, seek, pause, change speed and finish demo audio.
7. Present and dismiss demo video fullscreen.
8. Perform queue and archive actions, then reset demo.
9. Exit demo and verify no synthetic data appears on iPhone.
10. Enable iPhone sync and verify late real data replaces setup state safely.
11. Relaunch with a populated real library.
12. Test tvOS 26.5 and the current supported/latest tvOS releases.
13. Inspect the Release archive's effective entitlements and confirm production
    APNs plus the intended private CloudKit container before upload.

Exit gate:

- All automated tests pass.
- All physical-device scenarios pass without focus traps, indefinite loading,
  crashes, synthetic sync or stale mode state.
- Release build, not only Debug, is tested after clean installation.

### Phase 7 — Documentation and resubmission

**Objective:** Give App Review a precise, reproducible path and keep project
knowledge synchronized.

Required project updates:

- `VERSION_1.6.md`: rejection, root cause, implementation phases completed,
  test evidence and resubmission build.
- `FEATURES.md`: library-free Discover and demonstration mode, accurately
  labelled as tvOS-specific.
- `PAGES.md`: setup-required screen, demo badge, reset/exit paths, and empty tab
  states.
- `DESIGN.md`: finite loading, completed-state visual language, focus order,
  demo labelling and ten-foot copy rules.
- `SYNC_DESIGN.md`: explicit statement that demo data cannot enter CloudKit.
- `TV/AI_CONTEXT.md`: mode boundary and prohibited dependencies.
- Website Apple TV guide and in-app support content if customer-visible setup
  behaviour changes.

Suggested App Review notes:

> Autohop for Apple TV normally displays the user's private podcast library
> synced from Autohop on iPhone through their own iCloud account. No Autohop
> username or password exists. To review the app without an existing iPhone
> library, launch the app and select “Explore Demo Library” on the setup screen.
> This opens a local demonstration containing sample Home, Up Next, Library,
> History, audio playback and video playback data. Demo actions remain local and
> do not write to iCloud. Choose Settings → Exit Demo at any time. Discover and
> Settings are also available without demo mode.

The final notes must use the exact labels and navigation present in the shipped
binary. Include setup steps for genuine iPhone sync, but do not make those steps
a prerequisite for review.

Exit gate:

- App Review notes have been verified word-for-word against the Release build.
- Screenshots and metadata do not imply demo data is a real user account.
- Version/build numbers are incremented and the clean archive is uploaded.
- The resubmitted binary is the same production binary customers receive.

## 7. Testability and dependency seams

To keep this work maintainable, introduce narrowly scoped seams:

- A clock/sleeper for bounded bootstrap tests.
- An account/sync-status provider for empty, unavailable and failure cases.
- A content-mode/session owner with one observable source of truth.
- Production and demo action sinks for playback, queue, archive and history.
- A demo fixture validator that checks unique IDs, valid media URLs/assets,
  required audio/video coverage and referential integrity.

Avoid UI tests as the sole proof. State-transition and side-effect-isolation
tests should be headless where practical, while focus and AV presentation still
require tvOS UI/physical-device validation.

## 8. Failure handling requirements

| Condition | Stable user-facing result | Available actions |
|---|---|---|
| Empty private iCloud zone | Setup required | Demo, Discover, Retry, Settings |
| iCloud signed out/unavailable | iCloud unavailable | Demo, Discover, Settings, Retry |
| Temporary CloudKit/network error | Could not check library | Retry, Demo, Discover, Settings |
| Sync still running after deadline | Setup screen; background work continues | Retry/status, Demo, Discover, Settings |
| Real data arrives on setup screen | Personal library available | Open library |
| Real data arrives during demo | Non-disruptive ready notice | Exit demo and open library |
| Demo fixture/media failure | Bounded error with Retry/Back | Retry, return to demo Home |
| Mode switch during playback | Stop/close player before switch | Continue in destination mode |

No row in this table may resolve to an unbounded spinner or blank screen.

## 9. Privacy, security, and content requirements

- Demo mode must require no personal data, login or analytics consent.
- Do not log episode titles, feed URLs, Apple Account identifiers, CloudKit
  record payloads or reviewer behaviour.
- Do not ship real customer/library data as fixtures.
- Do not include private developer iCloud containers, tokens or credentials.
- Keep App Transport Security intact; do not weaken it for sample media.
- Document ownership/licence for every bundled demo asset.
- Ensure demo content is appropriate in all App Store territories where the app
  is available.
- Demo mode must not make privacy-policy claims inaccurate.

## 10. Release risks and mitigations

### Risk: demo checks leak across production paths

Mitigation: inject separate action sinks and repositories; test that production
writers are never invoked. Do not rely on view-level `if isDemo` checks.

### Risk: demo scope becomes a second full application

Mitigation: reuse the same presentation models and views, but provide a compact
fixture repository and ephemeral mutation overlay. Do not duplicate screens.

### Risk: bundled media increases binary size

Mitigation: use short, efficiently encoded first-party samples and measure the
archive-size impact before the release gate.

### Risk: reviewer still cannot find demo mode

Mitigation: make it the initial primary focus on the completed setup screen and
repeat the exact path in App Review notes.

### Risk: real users enter demo accidentally

Mitigation: label it clearly, keep personal setup instructions visible, display
a persistent Demo badge, and provide immediate Exit Demo.

### Risk: real iCloud data arrives while demo is active

Mitigation: never merge; show a non-disruptive readiness notice and switch only
after explicit user action.

## 11. Definition of done

This issue is resolved only when all statements below are true:

1. A Release clean install with no Autohop iCloud records leaves loading within
   the documented bound.
2. The completed empty state contains no indefinite activity indicator.
3. Discover and Settings work without a personal library.
4. Demo mode is visible, deterministic, interactive and clearly labelled.
5. Demo mode covers representative Home, Up Next, Library, History, audio and
   video playback functionality.
6. Automated tests prove demo writes cannot reach production persistence,
   CloudKit or listening statistics.
7. Physical Apple TV validation passes the full Phase 6 matrix.
8. All affected code files contain accurate AI context headers.
9. All canonical project documents are updated.
10. App Review notes match the submitted Release binary.
11. A clean-install resubmission has been archived and uploaded with a new build
    number.

## 12. Recommended implementation order

The shortest safe path is:

1. Complete Phase 0 evidence and tests.
2. Ship the finite setup state from Phase 1.
3. Unlock library-free Discover/Settings in Phase 2.
4. Build the isolated fixture/session boundary in Phase 3.
5. Route and test interactive demo side effects in Phase 4.
6. Perform review UX, accessibility and diagnostic refinement in Phase 5.
7. Run automated and physical-device release gates in Phase 6.
8. Update documentation and resubmit through Phase 7.

Do not skip directly to fixture insertion. Without the state-machine and
side-effect boundaries, a fast demo implementation could contaminate private
iCloud data—the opposite of Autohop's product promise and a more serious defect
than the original rejection.
