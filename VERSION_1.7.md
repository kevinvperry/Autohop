# Autohop Version 1.7 — Change Ledger

<!--
AI CONTEXT — VERSION_1.7.md
Canonical running ledger for every future app, behaviour, design, diagnostic,
documentation, website and user-visible change after Version 1.6.1 was confirmed
approved and live on 8 September 2026. Update this ledger and appropriate project
documents/AI headers in the same task, including small fixes. Record implemented
work with validation and limitations; do not present proposals as completed.
VERSION_1.6.1.md is closed. Its earlier development label was also 1.7, but its
entries shipped under 1.6.1 and must not be copied here as new 1.7 features.
Keep iOS-family and tvOS submission/approval status independent. TV 1.6.1 (1)
was submitted for approval, user-confirmed 8 September 2026. All subsequent
iOS and tvOS code updates share this Version 1.7 ledger; TV 1.6.1 scope is closed.
-->

## Release status

- **Development:** Open; started 8 September 2026 after the 1.6.1 release confirmation.
- **Submission:** Not submitted.
- **Approval:** Not approved.
- **Release:** Not released.
- **Build configuration:** No version/build-setting change requested by this documentation transition.

## Completed changes

### tvOS submission confirmed — 8 September 2026

- User confirmed tvOS 1.6.1 (1) submitted for approval; approval remains pending.
- Closed its submitted scope and updated release records and AI context.
- All future iOS and tvOS code changes are documented together here as Version 1.7.
- Kept submitted build settings intact. Documentation/AI-header-only update;
  whitespace checks passed.


### tvOS 1.6.1 build 1 preparation — 8 September 2026

- At the user’s request, prepared a separate tvOS 1.6.1 (1) candidate to match
  the public iOS marketing version. App and Top Shelf updated through XcodeGen;
  iOS app/widget remain 1.6.1 (17). This entry documents preparation, not a 1.7 binary.
- Created description, promotional text, keywords, What’s New and review notes in
  [the TV submission package](Docs/AppStore/tvOS-1.6.1/SUBMISSION.md).
- Recorded screenshot evidence of tvOS 1.6 (15) Ready for Distribution, superseding
  old build-13/latest-submission assumptions. Exact build-15 provenance remains unknown.
- Configuration/AI-header validation, metadata lengths and Release TV simulator
  build pass. Built app/Top Shelf versions verified as 1.6.1 (1). Remaining
  hardware/archive checks are tracked in the package.
- At preparation time the assistant did not upload or submit. The user
  subsequently confirmed submission; see the status entry above.


### Release-ledger transition — 8 September 2026

- Recorded user confirmation that 1.6.1 is approved and live; closed its ledger.
- Opened this ledger for all future changes and updated documentation/AI context pointers.
- Preserved historical 1.6.1 release material and the separate tvOS status.
- Validation: checked ledger references and diff whitespace. Documentation-only change.

No new app implementation changes recorded yet.

## Startup splash coverage — 12 September 2026

The desktop command host now fills the window’s container safe areas. Its nested
UIKit hosting view still supplies safe-area insets to page content, while the
launch animation’s existing edge-to-edge purple background can cover the status
bar and home-indicator regions. Keyboard avoidance is preserved by ignoring only
container safe areas. Keep this boundary when changing responder-host layout;
adding ignoresSafeArea solely inside the splash cannot expand a constrained host.

Validation: iOS Debug simulator build and diff whitespace checks passed.
Visual confirmation on a device remains outstanding.

## Episode Detail podcast link — 12 September 2026

The show title beneath the episode title is now a tinted, underlined navigation
link at its intrinsic text height with an accessibility hint. It opens the
existing Podcast page to subscribe or browse other episodes. Browse-only search
results retain preview/feed loading and Subscribe behaviour; real subscriptions
retain their stored identity. Opening the link does not subscribe automatically.
Native navigation preserves Back to the episode and its existing mini-player.

Validation: iOS Debug simulator build and diff whitespace checks passed.
Discover search → Episode Detail → Podcast page still needs a visual walkthrough.

### Show-title spacing follow-up — 12 September 2026

User confirmed podcast navigation works. Removed the link’s 44-point minimum
height to significantly reduce the space above and below the show title.
Retained six-point header spacing, text wrapping, styling and navigation.
Validation: inspected the targeted modifier change; diff whitespace checks pass.

## Play Instant return priority — 12 September 2026

Protect the final two minutes (inclusive) before and after the warning. Completing
an Instant episode restores the saved interrupted episode directly, before Play
Next. Pending Instant arrivals are released to normal queue order to prevent an
immediate repeat interruption. Pausing active Instant playback preserves its
return point; cancelling a warning or selecting another episode still cancels it.
Unavailable return media retains the existing normal-queue fallback; fired sleep
timers still stop playback. Update boundary tests and current feature copy.

Validation: all 10 focused PlayInstantPolicyTests and EpisodeCompletionWorkflowTests
passed, including the inclusive two-minute boundary and Instant-versus-normal
completion dispatch. Diff whitespace checks passed. Live audio-route interruption
and resume on a device remain to be verified.

## Podcast Replay strategy — 12 September 2026

Created [the detailed implementation strategy](Docs/PODCAST_REPLAY_IMPLEMENTATION_STRATEGY.md)
from the agreed brainstorming requirements. Defines starting-episode selection,
scheduled matching releases, Episode Limit admission, overdue refill on completion
or manual archive, suppression of normal new-release downloads, caught-up decisions
and Replay status pills. Maps proposed ownership to existing download, queue, filter,
archive, sync and notification code; specifies durable reservations, scheduling
limits, phased acceptance gates and regression coverage. Separates approved product
requirements from engineering recommendations and open decisions. README indexes
the proposal; its AI context explicitly prohibits treating planned work as shipped.
Validation: checked referenced source paths and diff whitespace. Documentation only;
no runtime code, settings, build numbers or release metadata changed.

### Podcast Replay cross-device requirement — 12 September 2026

Expanded the proposal to make synced settings, Replay progress and logical Up Next
order mandatory for the beta. Distinguished shared release/capacity state from local
download readiness; specified coherent revisions, remote edits, TV outcomes,
notification decisions, offline limits and cross-device acceptance scenarios.
Identified the current locally downloaded iOS queue as an integration gap rather
than claiming existing sync already meets the proposed contract. Documentation only.

## Podcast Replay implementation — 12 September 2026

- Added Podcast Replay to Podcast Settings and a **Listen From Here** entry on Episode Detail. The editor retrieves the available full RSS catalogue, supports episode search/selection, previews matching episodes and saves a first/next date/time with an every-1–30-calendar-days recurrence. Existing Feed Filters and Episode Limit remain their authoritative settings.
- Implemented due-slot reservations, chronological filtering, paused-at-capacity behaviour, bounded No Limit catch-up, immediate reconciliation after resolution/settings changes, durable retry identity and protection against automatic eviction. Unknown duration stops at the affected candidate rather than blocking earlier known episodes. Normal newly published auto-downloads are suppressed while enabled; manual actions remain available.
- Added additive **Replay** status pills on Subscriptions and the Podcast page, the schedule-management link, mini-player coverage in the editor, and waiting/downloading/retry explanations in Up Next.
- Implemented a single scheduling installation with a device-only Keychain identity. The existing synced AutoArchiveSettings payload carries configuration, release journal, outcomes and per-release pin edits. Configuration LWW and monotonic journal merges are separate, and newly merged information remains dirty for upload. Legacy decode is disabled and absent remote data cannot wipe Replay.
- Preserved logical Replay queue order before media downloads and refreshed local readiness without requiring ID changes. Queue snapshots carry optional session identity. Apple TV retains its read-only schedule role and syncs completion/archive through the existing episode-state channel. New-pass playback ignores pre-reservation resume progress; old terminal history cannot resolve a new reservation.
- Added fresh-feed confirmation before catch-up, permission-aware caught-up notification actions and the persistent in-app Keep Schedule / Turn Off choice. Normal new-episode notifications and Play Instant are suppressed for Replay transfers, including an in-flight completion after disable. Existing downloaded episodes survive disable.
- Updated source/test AI headers and FEATURES, PAGES, DESIGN, SYNC_DESIGN, README and the strategy's implementation record. Preserved the submitted iOS/widget 1.6.1 (17) and tvOS/Top Shelf 1.6.1 (1) build metadata; this work belongs to Version 1.7 development.

Validation: **75 focused iOS simulator tests passed with zero failures**, including 25 Podcast Replay policy/store tests and existing queue, subscription-sync, sync-state, Play Instant and completion regressions. Final iOS and Apple TV simulator builds passed. Release configuration, tvOS AI-header, new Replay AI-header and `git diff --check` checks passed. Xcode project regenerated from project.yml. Logs: `/tmp/replay-tests-final.log`, `/tmp/replay-ios-final.log`, `/tmp/replay-tv-final.log` and `/tmp/replay-release-guards.log`. These are simulator/configuration checks, not signing/archive, real CloudKit delivery or physical-device acceptance.

Release checks still open: real owner/follower/TV private-iCloud propagation, offline edits/reconnect, cold notification actions, background scheduling on physical devices, Mac/iPad/iPhone visual acceptance, publisher URL changes and large/long-lived journals. The beta uses a fixed owner and user-confirmed updated clients; automatic owner failover, capability negotiation and a TV schedule editor are not implemented. See the implementation record in `Docs/PODCAST_REPLAY_IMPLEMENTATION_STRATEGY.md` for these explicit boundaries. No submission or upload was performed.

## Podcast Replay design audit and guided setup — 13 September 2026

- Promoted Podcast Replay into its own Podcast Settings section immediately above Download Feed Filters, with setup/manage copy and its own iPad/Mac sidebar shortcut. Updated both native Form section mappings, including conditional Chapters and the two Playback sections.
- Rebuilt the page around the existing dark glass cards, purple controls/icons, adaptive Form sizing, circular Back control and mini-player conventions. Added a podcast introduction and numbered starting-point, pace and episode-preview cards, with brief explanations for each section.
- Added Daily / 2 days / Weekly / Custom presets using the existing 1–30-day policy, separate date/time controls, a schedule summary and planned episode dates. Date controls and preview explicitly use the schedule's stored time zone.
- Added a searchable starting-episode page with full-row selection, release dates, selected checkmarks and mini-player coverage. The draft appears before RSS refresh completes and is not overwritten by a late fetch. Feed Filters now opens directly from the rules card.
- Clarified capacity, caught-up notifications, the scheduling device and single-device acknowledgement. Added a prominent purple Enable/Save action and disabled-state guidance; moved the red Turn Off action and consequence explanation to the bottom.
- Completed the section-by-section audit in `Docs/PODCAST_REPLAY_DESIGN_AUDIT.md`; updated FEATURES, DESIGN, PAGES, README, strategy status and affected AI headers. Existing scheduling/queue behaviour and submitted build numbers remain unchanged.

Validation: final iOS simulator build passed; 37 focused tests passed (25 Replay, 12 adaptive layout). iPhone 17 Pro Max/iOS 26.5 inspection covered section placement, card appearance, purple toggles, Feed Filters navigation/back, enabling the action through draft acknowledgement, catalogue search and selection. The review caught a saturated hero with low-contrast secondary text; the final design uses dark glass and a purple accent border, verified in a final simulator inspection with the mini-player visible. Physical Mac/iPad, VoiceOver, maximum Dynamic Type, active/caught-up and older-iOS fallback visual checks remain open. No Replay schedule was enabled for the visual review. See `/tmp/replay-design-tests.log` and `/tmp/replay-design-final-build.log`.

## Podcast Replay calendar scheduling and simpler controls — 13 September 2026

- Replaced interval controls with **Daily / Weekdays / Choose Days**. Choose Days exposes selectable weekday buttons; users must retain at least one day. **Add another time** supports multiple episodes per selected day, one per unique time, with removable extra rows and duplicate-time guidance.
- Added a shared, validated calendar schedule containing weekday numbers and minutes after midnight. The first release rolls forward from Start date to the first selected slot; subsequent slots preserve the stored time zone through daylight saving. Repeated times release once; coincident DST-gap slots collapse. Feed Filters, capacity waits and overdue refill still apply to each slot.
- Updated previews and synced scheduling configuration. Cadence edits retain the new configuration's cursor when merged with old-cadence progress, while reservation/outcome journals still converge. Saving unchanged schedule controls preserves live nextDue. No legacy-interval UI or migration workflow is exposed, following the user's confirmation that there is only one test installation.
- Made **Episode Limit** editable directly in Replay using the existing synced Auto Archive field. Changes save immediately and appear on both pages; reducing the limit does not evict protected Replay episodes.
- Removed the separate device section and mandatory acknowledgement. Short update/sync and scheduling-device notes remain beside Enable/Save; automatic owner failover and capability negotiation remain outside this change.
- Updated source/test AI headers, FEATURES, DESIGN, PAGES, README, SYNC_DESIGN, implementation strategy and design audit. Submitted iOS/widget and tvOS build metadata is unchanged.

Validation: **48 focused iOS simulator tests passed** (36 Replay + 12 adaptive); iOS test build and tvOS simulator build passed. Simulator checks verified Weekdays roll-forward, two release times, Tuesday/Thursday preview sequencing and Episode Limit mirroring in both directions. The test limit was restored; no Replay schedule was enabled. Physical-device CloudKit/background execution, iPad/Mac, VoiceOver and maximum Dynamic Type checks remain open. Logs: `/tmp/replay-calendar-tests.log`, `/tmp/replay-calendar-tv-build.log`. No upload or submission performed.

## Podcast Replay Binge Mode — 13 September 2026

- Added a **Binge Mode** glass card and purple toggle above Set your pace. When enabled in the draft, pace controls are hidden and the preview describes playback-triggered preparation. Turning it off restores the retained calendar controls. Enable/Save Changes commits the mode.
- Binge seeds one matching episode immediately when capacity permits, reusing an already downloaded/queued starting episode. A successful start or resume records a durable reservation-scoped event and prepares one unstarted successor. Repeated starts/resumes cannot download the backlog. Feed Filters, unknown-duration holds, retry protection and inactive-podcast restrictions remain effective.
- User-confirmed capacity rule: Episode Limit 1 allows the single most-recently-started unresolved episode plus one upcoming episode. Other outstanding or existing downloads still use capacity. No Limit still prefetches only one unstarted successor. Existing scheduled reservations survive mode changes; unstarted ones must start or be archived before more are prepared.
- **Existing Up Next priority and manual Play Next/Play Last order remain unchanged**, as explicitly requested. Binge never promotes its podcast, starts playback automatically or triggers Play Instant.
- Added optional synced Binge configuration and monotonic per-release startedAt evidence. iOS playback start/resume and remote EpisodeSyncState playing events supply it. TV now authors playing/start evidence only after engine success and can forward resume evidence for an adopted Replay episode; the fixed scheduling installation alone reserves successors. Pre-reservation history and unrelated episodes cannot trigger prefetch.
- Returning to scheduled mode uses the next real calendar slot instead of replaying time-based debt accumulated while binging. Updated affected AI headers, FEATURES, DESIGN, PAGES, README, SYNC_DESIGN, TV/AI_CONTEXT, implementation strategy and design audit. Build/version metadata remains unchanged.

Validation: **59 focused iOS simulator tests passed** (47 Replay, 4 completion, 8 QueueModel), including prefetch idempotence, limit 1, filter/metadata gates, already-downloaded starting episodes, start-event merges, stale history, payload round trips and unchanged queue priority/pins. iOS test build and final tvOS simulator build passed. iPhone 17 Pro Max/iOS 26.5 visual inspection confirmed Binge placement, purple styling, hidden/restored pace controls with retained values, updated preview and mini-player layout. No Replay mode was committed and no audio was played during visual inspection. Physical-device playback-to-download timing, background execution, real CloudKit/TV propagation, iPad/Mac and accessibility acceptance remain open. Logs: `/tmp/replay-binge-tests-final.log`, `/tmp/replay-binge-tv-build.log`. `git diff --check` passed. No upload or submission performed.

## Download Feed Filters guided design — 13 September 2026

- Rebuilt DownloadFiltersView with the Podcast Replay visual language: dark glass cards, purple controls/icons, adaptive Form sizing, shared spacing, contextual mini-player and existing onboarding.
- Added a podcast-specific introduction and clear immediate-save/manual-download/Replay explanations. Length, title and description groups hide their editors when switched off while preserving saved rules.
- Split crowded length controls into separate comparison and 1–300-minute rows. Added inset rule panels, plain-language rule summaries, descriptive text-field labels, blank-term guidance and visible Remove Rule buttons. All existing rule types, multiple rules and Include/Exclude options remain available.
- Moved All/Any into “How your rules work together” with concrete examples and explicit Exclude precedence. No filter evaluator, storage, sync schema, auto-download or queue policy changed.
- Improved read-only preview with match/skip counts, readable outcome/reason labels, empty/error/loading copy and live re-evaluation of current settings. Cached Episode values avoid stale rules captured before a network request. Show five rows initially with Show All / Show Fewer for the complete result set.
- Updated the view AI header, FEATURES, PAGES, DESIGN, README and `Docs/DOWNLOAD_FEED_FILTERS_DESIGN_AUDIT.md`. Build metadata remains unchanged.

Validation: **24 focused iOS simulator tests passed** (20 subscription-sync and 4 Replay filter regressions). Final iOS simulator build and `git diff --check` passed. iPhone 17 Pro Max/iOS 26.5 visual checks covered page cards, disabled-group disclosure, adding a length rule, its controls/summary, preview fetching, match counts and live recalculation from 48 matches/2 skipped to 50 matches/0 skipped when the rule group was disabled. All test filter groups were left off; the simulator retains the disabled 40-minute example rule. Physical iPad/Mac, VoiceOver, maximum Dynamic Type, keyboard and every text-rule interaction remain device/UI acceptance checks. Logs: `/tmp/feed-filter-design-tests.log`, `/tmp/feed-filter-design-final-build.log`. No upload or submission performed.

### Download Feed Filters default audit — 13 September 2026

- Confirmed the production default already sets title, duration and description filtering off. New subscriptions and older payloads without filter settings use this default; the editor reads the saved per-feed value without enabling it on appearance.
- Preserved all existing on/off settings and saved rules, including enabled groups with no rules. No bulk reset or migration: existing enabled values cannot safely be classified as accidental defaults.
- Added regression coverage for new/legacy defaults and local-persistence/CloudKit round trips of both enabled and disabled title filters, with and without rules. Added the invariant to the model and test AI headers.
- User-reported enabled state remains to be distinguished from previously saved settings; no runtime default change was necessary in the inspected source.

Validation: all 22 SubscriptionSyncTests passed on the iOS simulator, including the new default/preservation cases; `git diff --check` passed. No existing user settings were rewritten.

### Text-rule input visibility — 13 September 2026

The reported black bar is the editable phrase field. Explicit plain text-field styling, white semibold text, intrinsic vertical sizing and a minimum 44-point input height now prevent a compressed or low-contrast field inside the nested Form card. A subtle purple border and “Words or phrase” label identify the editable value. Shorter group explanations and removal of the duplicate rule sentence reduce clutter. Both title and description editors share the fix; saved terms and matching behaviour are unchanged. Long phrases can grow to six visible lines and scroll within the field.

Validation: iOS simulator build succeeded and whitespace checks passed. This follow-up has not yet been visually verified on a running device or simulator; confirm phrase visibility and editing with the reported “The Breakers” rule.

### Settings clarity — Version 1.7, 13 September 2026

Audited all Main Settings and Individual Subscription Settings sections. Shortened explanations, split multi-control footers into labelled paragraphs, clarified global defaults versus existing podcast settings, and added brief RSS/OPML guidance. Existing controls, bindings, section order, sidebar IDs and safeguards remain intact. See `Docs/SETTINGS_CLARITY_AUDIT.md` for the full section-by-section review and validation limits.

Validation: final iOS simulator build and whitespace checks passed. Runtime visual, Dynamic Type and VoiceOver checks remain outstanding for this copy pass.

### Manual RSS entry — Version 1.7, 13 September 2026

Add RSS Feed now uses Podcast Replay-style glass cards with a guided link/preview/subscribe flow, clear URL entry, expandable RSS help, artwork preview and novice-friendly error guidance. Technical episode links remain expandable. Editing a link clears its previous preview; surrounding whitespace is trimmed. Existing subscription saving, navigation and mini-player remain. Build passed; runtime device checks remain outstanding. See `Docs/ADD_RSS_FEED_DESIGN_AUDIT.md`.

### Preview button visibility follow-up

Preview Podcast is hidden for empty or whitespace-only input, appears after typing or pasting a link, and remains visible with its progress indicator during loading. Clearing the field hides it again. Existing URL validation is retained.

### Support content audit — 13 September 2026

Completed a source/content comparison of the in-app guide, local website guide sources and six live support-related pages. Confirmed obsolete navigation/control instructions, unpublished local website content and missing Version 1.7 Replay/Binge guidance. Full findings, platform/release matrix and remediation sequence are in `Docs/SUPPORT_CONTENT_AUDIT_2026-09-13.md`. Audit only: no support copy changed, no website deployment, no device walkthrough or claim that published content is now synchronised.

### Support audit corrections — 13 September 2026

Updated in-app guidance for Subscriptions navigation/search, category charts, mini-player return, Downloads controls, two-minute Play Instant protection, notification recaps, OPML scope, sync caveats and device coverage. Added Version 1.7 Replay/Binge and guided RSS instructions. Added `Scripts/export_support_website.py` to generate all 23 web guide sections from the app content, preserving release notices and legacy audio anchors. Website source updates also cover TV setup/Top Shelf, related terminology, support reporting and shared app-guide navigation.

Validation: iOS simulator build succeeded; website worker generation succeeded; exporter repeatability and guide anchors/unique IDs passed. No device walkthrough, browser visual/accessibility validation or production deployment performed. Existing unrelated website changes prevent treating the complete generated worker as a support-only release.

### Website publication — 13 September 2026

User authorised publication of all website updates. Rebuilt and deployed the complete kevmarl-site bundle with Wrangler. Deployment version: `b4bf9f23-2777-478c-981a-5a82923a5c86`. Fresh public-domain requests verified the new support guide, TV recovery section, contact guidance and Intelligence content; privacy and Priority pages also returned successfully. An initial unversioned request returned old cached content; cache-busted public requests served the new deployment. No browser visual or authenticated stats workflow test was performed.

### Diagnostic recording improvements — 13 September 2026

Added recording-session correlation, bounded change-driven state summaries, logger write-health export metadata, off-main iOS export/read work with error feedback, and expanded TV export snapshots captured before stitching. Added TV queue source/model/Home counters, badge transitions, per-subscription recovery timings and AVPlayer waiting/error metadata. Existing Radar/background/download/sync event coverage retained. See `Docs/DIAGNOSTIC_RECORDING_1.7.md` for interpretation and explicit limits. No change to the underlying sync or queue policy.

Validation: final iOS build/test run passed all nine LogRedactionTests; final tvOS simulator build and whitespace checks passed. Physical-device logging and the unresolved Up Next incident remain to be verified.

### TV startup recovery and persistence repair — 13 September 2026

Restored TV library/stat storage to Library/Caches/Autohop, reusing the existing database in place rather than attempting unsupported Application Support writes or copying SQLite sidecars. Deferred database-open errors are now logged explicitly. Caches remains purgeable; this does not promise permanent local storage.

Bootstrap starts CloudKit and its observers before launching survival-kit RSS recovery asynchronously. Existing dirty-default repair still runs before sync activation; materialisation retains its clean-seed/remote-settings adoption rules. Recovery skips already-restored or remotely unsubscribed entries, schedules progressive library refresh, and checks whether the identity actually materialised before reporting success. No iCloud data deletion or forced re-upload was added.

Validation: tvOS simulator build and targeted TVAppDecompositionTests/TVLibraryProjectionRefreshPolicyTests passed, including cache database reopen persistence. Whitespace checks passed. Physical Apple TV validation is still required: install over the existing app, confirm immediate sync activation, populated playable Up Next and persistence across a relaunch. No physical-device success is claimed.


### Sleep Schedule page refresh — 20 September 2026

<!-- AI CONTEXT — Presentation-only refresh; preserve existing settings and
playback contracts. Docs/SLEEP_SCHEDULE_DESIGN_AUDIT.md owns validation evidence. -->

Sleep Schedule now matches Feed Filters and Podcast Replay with dark glass cards,
purple controls, clear setup guidance, a saved-schedule summary and expandable
help. All existing intervals, End of Episode, daytime/overnight/all-day windows,
immediate saving, notification opt-in, onboarding and mini-player remain.
The explanation now correctly describes a chime over continuing playback before
an unanswered check-in fades out and rewinds. See
[the design audit](Docs/SLEEP_SCHEDULE_DESIGN_AUDIT.md) for scope and validation.

### iOS 27 navigation repair — 20 September 2026

<!-- AI CONTEXT — Shared Back compatibility; preserve nearest-parent dismissal
and distinguish pushed destinations from Player modal navigation roots. -->

Discover and 17 other destination implementations use the shared Back policy:
native Back on iOS 27+, branded Back on older systems, explicit dismiss for modal
Podcast Detail/Settings roots. Existing native-only pages and Subscriptions' Menu
remain unchanged. The source audit covered all app navigation/presentation surfaces.
Five hosted tests passed on each of iOS 26.5 and 27 (26 destination/presentation
variants per runtime); Discover screenshots show one Back control. Physical-device
interaction, swipe gestures and populated-library coverage remain unverified.
See [navigation audit](Docs/IOS27_NAVIGATION_BACK_AUDIT.md).

### Session documentation reconciliation — 20 September 2026

Added/updated AI context for the shared Back owner, all migrated view files,
Player modal-route caller and hosted tests; expanded Sleep Schedule's purpose,
collaborators and preservation constraints. Corrected the obsolete custom-toolbar
example and grouped Sleep Schedule references in living documents. Updated the
project brief and audit index. Documentation/comment-only reconciliation; prior
runtime results remain the evidence, with no new device or release claims.

Sleep Schedule validation: simulator build and four-state hosted rendering,
navigation and settings-preservation checks passed on iOS 26.5, iOS 27 and iPadOS
26.5, including accessibility text size. Physical overnight audio, VoiceOver and
notification delivery remain unverified; see its design audit.

## Diagnostic reliability repairs — 20 September 2026

<!-- AI CONTEXT — Keep this contract aligned with source headers and the repair record. -->

Playback resume retires stale buffer waits; Pause cancels pending recovery; EOF
uses consistent completion and render health reflects actual callbacks. Auto
Archive reads live pin IDs without repeated catalogue scans. Download completion
awaits ordered off-main stats-file persistence. First active-runtime fallback is
prompt; later retries stay bounded. Sync settings reactions are deduplicated,
foreign subscription identities remain protected, and diagnostic exports additionally
pseudonymise personal route names/arbitrary GUIDs. MetricKit disk-write reports now
carry byte counts and bounded stacks. Titles/timestamps remain diagnostic context.
See [implementation and validation](Docs/DIAGNOSTIC_REPAIRS_2026-09-20.md).

Validation: 95 focused tests passed on iOS 27. On iOS 26.5, 94 passed and one
existing lifecycle timing test passed on isolated rerun after initially failing.
Final logging/sync checks passed all 32 tests on both runtimes; the shared core
build passed. Physical Bluetooth transitions and long-running disk/energy impact
remain unverified.


## Mini-player bottom backing — 20 September 2026

<!-- AI CONTEXT — Shared safe-area ownership. One background includes material, tint and glass;
never restore a fixed-height offset patch or change playback hit targets. -->

The shared persistent mini-player now extends one purple glass background into
the bottom container safe area. Material, tint and glass cover the full height,
preventing a material-only colour band below the progress strip. This replaces the
64-point offset patch that could be clipped below the progress strip, exposing
page rows (reported on Stats). The same surface serves all shared mini-player
call sites, including Subscriptions' direct inset. Controls, progress height,
return-to-Player behaviour and page inset sizing are unchanged. See
[the mini-player audit](Docs/MINI_PLAYER_AUDIT_2026-09-06.md) for validation.

Build and hosted page/sheet checks passed on iOS 27 and iOS 26.5 simulators;
all four screenshots were visually inspected. Physical-device validation remains
outstanding.
