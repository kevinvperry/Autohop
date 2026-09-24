# Podcast Replay — implementation strategy

<!--
AI CONTEXT — Docs/PODCAST_REPLAY_IMPLEMENTATION_STRATEGY.md
STATUS: IMPLEMENTED BETA IN VERSION 1.7 DEVELOPMENT (12 September 2026).
The implementation record below supersedes proposed engineering shapes and
unresolved recommendations in the original strategy. Device release checks remain.
PURPOSE: Implementation contract for future AI agents. Separate confirmed user
requirements from proposed engineering defaults and unresolved decisions below.
SCOPE: Version 1.7; iOS-family authoring with compatible tvOS queue consumption.
AUTHORITIES: FEATURES.md owns implemented behaviour; PAGES.md owns navigation;
SYNC_DESIGN.md owns current sync authority; VERSION_1.7.md owns future work records.
Do not treat this proposal as evidence that a feature ships. At implementation,
update those authorities, affected source/test AI headers and the Version 1.7
ledger in the same task. Keep historical 1.6/1.6.1 release ledgers closed.
Use Australian English for prose and UI copy. Preserve existing identifiers.
SYNC REQUIREMENT UPDATE: Replay configuration, progress and logical Up Next order
must synchronise across devices using private iCloud when enabled. Local downloads
are not queue authority. Sync is a first-beta requirement, not an optional later phase.
Former brainstorming names: Reactive Feed / Reactivate Feed. Product name is
Podcast Replay; the compact status pill must say Replay.
-->

## Implementation record — 12 September 2026

The feature is now implemented in the Version 1.7 working tree. The original sections below remain the detailed design rationale; they are not evidence that every proposed component, guarantee or future option exists. This record and FEATURES/PAGES/SYNC_DESIGN describe the actual beta implementation.

| Responsibility | Implemented owner |
| --- | --- |
| Configuration, recurrence, filtering, capacity, release journal, merge | `Models/PodcastReplay.swift`, optional `AutoArchiveSettings.replay` |
| Execution, durable reservation flush, downloads, timers and caught-up notification | `App/PodcastReplayCoordinator.swift`, existing auto-download workflow/background drains |
| Persistence, resolution and remote terminal-state reconciliation | `Persistence/SubscriptionStore.swift`, `Models/SyncState.swift` |
| Logical membership, shared Replay pins and TV projection | QueueService, QueueCoordinator, QueueModel, QueueSnapshotEntry |
| Schedule UI, preview and status | PodcastReplayView, SubscriptionSettingsView, PodcastsView, PodcastDetailView, QueueSheetView |
| Regression coverage | `Tests/PodcastReplayTests.swift`, existing queue/sync/completion/Play Instant suites |

Engineering decisions: reuse the existing synced JSON payload and durable auto-download machinery instead of new SQL tables/CloudKit record types. Use a fixed installation owner rather than lease election or automatic failover. Updated 13 September: Daily / Weekdays / Choose Days and multiple release times use a validated calendarSchedule in the stored time zone. Each unique time releases one matching episode per selected day. The old interval field remains decodable for test data, but no legacy interval controls or migration workflow are exposed; the user confirmed there is only one test installation. Count outstanding reservations plus pre-existing unresolved downloads on the scheduling device. Process No Limit in batches of 16 and resume on subsequent reconciliation. Keep release pins shared independently of configuration edits. Re-fetch the available complete RSS catalogue for the picker and final catch-up confirmation; this cannot recover publisher-removed episodes.

The current episode key is the enclosure URL. Matching release records carry a lightweight episode projection; timestamps/order remain deterministic when GUIDs or local UUIDs differ. Device paths and bulky descriptions/chapters are omitted from the synced journal; followers fetch RSS when filter metadata is missing. Resolved outcomes are monotonic within the session, and a new session wins by creation date/UUID. Clock skew, changed publisher enclosure URLs, very large long-lived journals and account-switch behaviour require explicit validation; this is not a server-serialised transaction model.

Existing downloaded episodes remain queued after disable, and unresolved retained releases remain protected from automated eviction. The schedule stops assigning new releases. Changing filters never silently resolves an already assigned reservation; if it becomes excluded before download, the user must change filters, explicitly download it or archive it. Historical completed-state evidence is retained when a Replay file is downloaded, and saved progress before the new reservation is ignored for the new pass.

**Initial implementation validation (12 September):** 75 focused simulator tests passed, including 25 Replay tests; final iOS and tvOS simulator builds, release-configuration guards, AI-header checks and whitespace checks passed. Tests cover schedule boundaries, capacity/refill, filters and unknown duration, DST, history/resume, monotonic merge/upload dirtiness, stale remote events, TV completion projection, queue readiness, manual redownload and no-op scheduler publication. See VERSION_1.7.md for log locations.

**13 September calendar refinement:** 48 focused iOS tests (36 Replay, 12 adaptive) and the tvOS simulator build passed. Added sub-daily slots, chosen weekdays, DST edge cases, shared limit persistence and schedule-edit merge checks. iPhone simulator verified calendar previews and limit mirroring both ways. See the design audit and Version 1.7 ledger for the exact runtime scope.

**Acceptance still requiring devices:** iPhone/iPad/Designed-for-iPad Mac editor and badges at supported sizes; real owner/follower/TV CloudKit propagation with completion, pins, offline edits and reconnect; cold notification actions and permission denial; failed downloads and network-policy transitions; overnight background opportunities/DST; disable during transfer; large catalogues and journal sizes. Do not mark those passed from simulator builds or pure merge tests. Version/build metadata remains at the previously submitted 1.6.1 values until a new build bump is requested.

## Binge Mode refinement — 13 September 2026

User-approved behaviour: Binge Mode appears above Set your pace and hides it when enabled. Seed the selected matching episode immediately (subject to filters and capacity), then prepare one next matching episode after successful playback starts. With Episode Limit 1, allow the started episode plus one upcoming episode. Keep the existing Up Next priority and manual pin order; do not promote the Binge podcast. Larger limits do not imply downloading the entire backlog.

Implementation authority: optional `PodcastReplay.bingeMode`, per-release `startedAt`, and reserveBinge policy. Started evidence is monotonic and reservation-scoped; repeated starts and pre-reservation history cannot create slots. The single most-recently-started unresolved episode is excluded from Binge capacity. Existing unstarted reservations survive mode changes and block further prefetch until started or archived. Failed transfers use the existing retry/outbox safeguards. TV forwards successful-start evidence; the fixed scheduling installation remains responsible for reservation. No automatic owner takeover is added.

Turning Binge off restores the calendar controls; saving scheduled mode uses the next actual future slot rather than accumulating missed slots while binging. Filters, catch-up prompts, normal new-feed suppression, queue priority, manual pins and Play Instant suppression remain in place. Draft mode changes commit on Enable/Save Changes; Episode Limit remains an immediate shared setting.

**Binge validation:** 59 focused iOS tests and final tvOS simulator build passed. Simulator UI verified hiding/restoring cadence and playback-based previews. This is not real-device prefetch/background/CloudKit validation; see VERSION_1.7.md and the design audit for exact scope.

## 1. Objective and product boundaries

Let a listener turn an accessible podcast back catalogue into a personal release
schedule. The listener selects a starting episode, recurrence and first release
time. Autohop then makes successive matching episodes available through the normal
download-first Up Next system, subject to the podcast's existing Episode Limit.

Example: begin at Episode 10, release daily at 4:00 am, and apply a duration filter
strictly greater than 40 minutes. Each due release selects the next matching episode
in chronological order. An excluded episode does not consume a release slot.

Podcast Replay schedules availability. It does not start playback, interrupt
playback, create a public RSS feed, modify publisher release dates, or replace the
Priority Stack. It must not be implemented as a series of Play Next pins.

### Explicitly agreed requirements

| ID | Requirement |
| --- | --- |
| PR-01 | Feature name: Podcast Replay. Compact pill label: Replay. |
| PR-02 | User selects an actual starting episode, release frequency and release time. |
| PR-03 | Apply the podcast's existing Download Feed Filters. Advance to the next matching episode; excluded episodes consume no schedule slots. |
| PR-04 | Use Auto Archive > Episode Limit as Replay capacity. At capacity, pause further releases instead of displacing unplayed episodes. |
| PR-05 | Completion or deliberate manual archive creates capacity. Immediately request overdue eligible downloads when execution/network conditions allow. |
| PR-06 | When several releases are overdue, fill available capacity, bounded by Episode Limit. |
| PR-07 | A failed download retains its place for retry; it is not silently skipped. |
| PR-08 | Disable normal automatic downloads of newly published episodes while Replay is enabled. Explain this clearly. Manual browsing/downloading remains possible. |
| PR-09 | Catch-up requires the latest matching episode to have been played or manually archived, not merely queued/downloaded. |
| PR-10 | On first catching up, notify the user and explicitly offer Keep Schedule or Turn Off Podcast Replay. Keep the same choice available in-app. |
| PR-11 | Dismissal/no response preserves the enabled schedule. Do not repeatedly prompt each time another new episode arrives after Keep Schedule. |
| PR-12 | Keep Schedule applies the chosen schedule to future matching publisher episodes. Turning Replay off restores normal automatic-download rules without downloading the old backlog or removing existing queued episodes. |
| PR-13 | Add Replay alongside existing Subscriptions-list status pills and on the individual Podcast page. It stays visible while enabled, including capacity waits and waiting for new matching episodes. |
| PR-15 | Synchronise Podcast Replay settings, progress and logical Up Next membership/order across supported devices using the same private iCloud account when sync is enabled. Download readiness remains device-local. |
| PR-14 | All future implementation is Version 1.7 work, alongside iOS and tvOS changes. This task creates a strategy only. |

### Proposed defaults, not additional user decisions

- One matching episode per release slot; recurrence initially daily, every N days,
  or selected weekdays. Arbitrary hourly intervals are a later extension.
- Calendar-based local time for “daily at 4:00 am”, rather than exactly 86,400 seconds.
- iOS-family setup/editing; one designated scheduler device; TV consumes released
  phone-authored queue entries and reports completion/archive events.
- No Replay-generated Play Instant interruption.
- No pre-download of unreleased episodes in the first implementation.
- Reuse existing download network/battery/storage policies.
- Protect unresolved Replay episodes from automatic inactivity expiry as well as
  Episode Limit eviction. This interaction needs explicit product confirmation.
- No new analytics, hosted service, public feed or developer account.

See section 14 for decisions that must be settled before implementing dependent work.

## 2. Vocabulary and invariants

Use these terms consistently in code, diagnostics and tests:

- **Replay session:** one enabled configuration anchored to a chosen starting episode.
- **Release slot:** a calendar occurrence with a stable identity and due timestamp.
- **Due:** the slot's timestamp has passed. Due does not mean downloaded or playable.
- **Reservation:** durable assignment of one episode to one slot, consuming capacity.
- **Released:** the reservation has entered the allowed download workflow; it is no
  longer a future catalogue item, but becomes queue-playable only when available.
- **Resolved:** played to completion or explicitly manually archived for this session.
- **Cursor:** last durably assigned catalogue position, not the currently playing item.
- **Frontier:** latest matching accessible episode in the most recent successful feed evaluation.
- **Caught up:** every selected matching episode through the frontier is resolved,
  with no unresolved reservation or unknown eligibility blocking that conclusion.
- **Capacity:** maximum outstanding episodes permitted by the existing Episode Limit.

Mandatory invariants:

1. One slot assigns at most one episode; one episode receives at most one automatic
   reservation per Replay session. Explicit restart creates a new session identity.
2. Cursor movement and reservation insertion are atomic. Never advance on a scan,
   notification, queue render or an uncommitted download request.
3. Queued, downloading, failed and downloaded-but-unresolved reservations occupy
   capacity. The currently playing unresolved Replay episode also occupies capacity.
4. No release occurs before its due time. Queue rendering never advances a schedule.
5. Excluded episodes consume neither capacity nor release slots.
6. Podcast Replay never bypasses Feed Filters for an automatic download.
7. Auto Archive must not evict an unresolved Replay episode just to make room.
8. Explicit user navigation/pins retain their existing meaning.
9. Enabling/disabling Replay does not erase listening history or mark backlog played.
10. Notification delivery is not required for correctness or state transitions.
11. A stale task, old device owner or old configuration revision cannot commit work.
12. New-publisher auto-download and Replay auto-download are mutually exclusive for
    a Replay-enabled podcast. Feed refresh and metadata updates continue normally.
13. Unknown duration under a duration-dependent filter cannot be assumed to pass.
14. Default decode for existing users is Replay disabled; no migration starts downloads.

## 3. Repository integration map

Names marked “proposed” are design suggestions, not current files.

| Existing owner | Current responsibility | Planned integration |
| --- | --- | --- |
| `Models/Subscription.swift` | Subscription, AutoArchiveSettings, EpisodeLimit, DownloadFilterSettings, retention policy | Add backwards-compatible Replay configuration or a linked configuration identity. Reuse filter evaluation and Episode Limit; do not duplicate either setting. |
| `App/FeedRefreshItemWorkflow.swift` | Merge feeds and identify newly discovered automatic candidates | Continue merging; route Replay-enabled podcasts to Replay catalogue reconciliation, suppress the ordinary new-release branch. |
| `App/AutoDownloadIntentWorkflow.swift` | Durable, bounded automatic download intent and revalidation | Recognise an explicit Replay origin/reservation. Do not reject an older Replay episode under newest-arrival eligibility. |
| `Persistence/AutoDownloadIntentStore.swift` | Persist/retry download intent | Carry a backwards-compatible origin and reservation ID, or use a side-table outbox linked to the intent. |
| `App/DownloadCoordinator.swift`, download workflows | Transfer lifecycle and settlement | Report Replay transfer outcomes; preserve existing retry/network policies. |
| `App/AutoArchiveCoordinator.swift` and retention policy | After Playing, inactivity, Episode Limit enforcement | Apply Replay protection before archive mutations; ordinary subscriptions retain existing behaviour. |
| `App/EpisodeCompletionWorkflow.swift`, `App/EpisodeDispositionWorkflow.swift` | Completion and explicit episode dispositions | Emit idempotent Replay resolution only after the underlying disposition is committed; trigger reconciliation outside archive throttling. |
| `Queue/QueueService.swift`, `Queue/QueueModel.swift` | Priority ordering and manual pins | Preserve podcast priority, downloaded-only eligibility and oldest-first order. Explicitly prevent unreleased automatic Replay items from entering queue selection. |
| `App/QueueCoordinator.swift` | Queue projection, invalidation and snapshots | Observe narrow Replay eligibility changes; publish only committed state. No scheduling side effects in queue reads. |
| `Models/QueueSnapshot.swift` | Phone-authored TV queue projection | Publish eligible released items only; extend optional display metadata if TV needs Replay indication. |
| `App/AppStartupWorkflow.swift`, `App/AppState.swift` | Startup/composition and command façade | Construct/connect the new owner without adding business logic to AppState. |
| `App/AppDelegate.swift` and existing background workflow | OS wake windows and lifecycle | Reconcile due work during existing wakes; schedule earliest useful opportunity. |
| `Persistence/AutohopDatabase.swift`, CloudKit mapping/engine | Durable storage and private sync | Persist release ledger/outbox and merge authority safely; do not sync local file paths. |
| `Notifications/NotificationService.swift`, `App/NewEpisodeNotificationWorkflow.swift` | Local notification transport and download-notification policy | Add Replay caught-up category/deep link without treating Replay as a new publisher release. |
| `Views/PodcastsView.swift`, `Views/PodcastDetailView.swift` | Subscription list and individual Podcast page | Add Replay alongside existing pills; detail entry opens the schedule and state explanation. |
| `Views/SubscriptionSettingsView.swift` | Podcast settings and Episode Detail | Add Podcast Replay setup/manage entry and optional “Listen From Here” action. |
| `Views/EpisodeBadges.swift` | Shared status presentation | Reuse visual metrics. Prefer a subscription-mode badge rather than corrupting episode lifecycle status with a fake replay state. |
| `TV/AI_CONTEXT.md` and TV sync/playback owners | Companion authority and outcomes | Consume the authoritative schedule projection, never run an independent release scheduler. |

Observed queue fact: `QueueService` already sorts downloaded unplayed episodes
oldest-published first within each priority-ranked podcast. The implementation
should extend eligibility and stable ordering where needed, not replace the
entire queue algorithm based on a “newest-first” assumption.

Existing Episode Limit values are No Limit, 1, 2, 3, 4, 5 and 10. No Limit has raw
value zero; never interpret it as zero available slots.

## 4. Proposed domain architecture

### Pure policy layer

Proposed `PodcastReplayPolicy` accepts immutable snapshots and returns a plan:

- configuration and revision;
- current time/calendar/time-zone rules;
- ordered accessible catalogue and current filter evaluation;
- outstanding reservations and resolved identities;
- effective Episode Limit and protected manual/current items;
- ownership epoch and feed-evaluation status.

Its output contains due slots, candidate assignments, blocked reasons, next wake
hint and caught-up eligibility. It performs no I/O, playback, notifications or
store mutations. Inject clocks/calendars into tests.

### Coordinator/workflow layer

Proposed `PodcastReplayCoordinator` owns observable per-podcast state and serialises
reconciliation. Proposed `PodcastReplayWorkflow` coordinates persistence and the
existing download/disposition services. A small project may combine these initially
if ownership remains narrow and testable; do not create duplicate mutable sources.

The implementation uses a bounded per-subscription execution gate and re-reads
configuration revision before commit. It must survive actor reentrancy: MainActor
alone does not protect a plan across an awaited transfer/store operation.

### Durable store and transactional outbox

Proposed `PodcastReplayStore`, backed by the established database, stores:

| Record | Suggested fields |
| --- | --- |
| Configuration | schemaVersion, enabled, sessionID, subscription/feed identity, startingEpisodeKey, recurrence, firstReleaseDate, localTime, timeZonePolicy, revision, ownerDeviceID, ownerEpoch |
| Progress | cursor/order key, lastAssignedSlot, nextDueDate projection, successfulCatalogueRevision, caughtUpDecision, promptEventID |
| Reservation | reservationID, sessionID, slotID, episodeKey, catalogueOrderKey, dueAt, configurationRevision, state, outcome, retry metadata |
| Outbox | idempotency key, operation kind, reservation/configuration reference, delivery state |

Use an explicit journal of reservations, not only `lastEpisodeIndex`. An index
cannot survive reordered feeds, retries, crashes or concurrent devices.

Local UI state such as whether the editor is open does not belong in CloudKit.
Queue and status labels are derived from records; do not persist a second queue.

Transactions atomically reserve capacity, assign slots and persist download-outbox
work. The outbox bridges database commit to existing intent insertion. Retry after
crash can re-deliver the same request without creating a second download or slot.

Keep assigned progress separate from completed progress: the cursor may be beyond
several still-unplayed reservations, and that must not imply catch-up.

## 5. Catalogue selection and Feed Filters

### Identity and ordering

- Start from the selected real episode identity, not a displayed ordinal such as 10.
- Prefer the project's canonical feed/enclosure identity and stable GUID reconciliation.
- Sort ascending by publisher date, with a deterministic identity tie-breaker.
- Record stable order keys on reservation. Feed refresh must not reshuffle already
  released episodes or replay items whose publisher title/date changed.
- Episodes without usable dates require a documented fallback order and preview;
  do not rely on dictionary iteration or UUID lexical order as meaningful chronology.
- Show explicit episode numbers when provided, but do not assume numbering is
  unique, continuous or identical to chronological order across seasons.

### Selection sequence

1. Resolve the current feed and starting identity.
2. Build the accessible chronological catalogue from that anchor.
3. Exclude identities already assigned/resolved in this session.
4. Apply the existing Download Feed Filter evaluator.
5. Separate pass, excluded and unknown/incomplete eligibility.
6. Take only enough eligible candidates for due slots and available capacity.
7. Return preview/exclusion explanations without writing progress.

For unknown duration, reuse any existing feed/metadata enrichment first. If it
cannot be established, show “Waiting for episode information”; do not consume a
slot, declare catch-up, or silently download media solely to guess duration without
an explicit policy. This is an implementation decision to confirm in section 14.

### Catalogue changes

Filter changes apply prospectively. Already released episodes remain as they are
unless the user explicitly archives them. Unstarted reservations must be revalidated
before transfer; cancellations need a reversible slot treatment, not lost progress.

Episodes behind the assigned cursor that become newly eligible after a filter edit
should not suddenly be backfilled. Proposed default: apply edits from the current
cursor, with an explicit Restart From Episode action for revisiting earlier items.

If the starting episode disappears, preserve its saved identity/order anchor and
show what is available. Missing assigned media remains an actionable failure;
never equate disappearance with manual archive or catch-up.

Only promise replay of accessible RSS episodes. A podcast advertised as having
500 episodes may expose only 100 in its current feed. Show the accessible range
and unavailable-start explanation; do not scrape gated archives or fabricate URLs.

## 6. Scheduling, capacity and missed slots

### Calendar rules

“Daily at 4:00 am” is a wall-clock calendar recurrence. It is not equivalent to
“every 24 hours” around daylight saving. Store recurrence intent as well as computed
dates; derive occurrences with calendar APIs, never repeated fixed-second addition.

Implemented daylight-saving rules: a nonexistent selected time moves to the next valid
local time on that date; a repeated time fires once, using the first occurrence.
Both are covered by deterministic tests. Travel retains the schedule’s stored time zone. Coincident slots caused by a DST gap collapse into one release. A slot's identity must remain stable despite recomputation.

The user chooses a Start date and one or more release times. The first release is the earliest selected slot on or after that date; unselected days roll forward. Do not silently start
the selected episode during setup. Subsequent slots follow the configured anchor.

### Due-slot debt

Persist unconsumed due occurrences, or a compact equivalent with stable sequence
numbers. Capacity does not move the schedule anchor. If Tuesday's release is blocked
until Tuesday 9:00 am, it remains Tuesday's slot; Wednesday remains 4:00 am.

At a reconciliation, allocate no more than:

`minimum(unconsumed due slots, available capacity, eligible catalogue items)`

For No Limit, use bounded processing batches and resumable work rather than an
unbounded task or in-memory allocation. Batch size is an execution safeguard, not
an undocumented user-facing episode limit.

At the live frontier there may be no candidate for elapsed slots. Proposed policy:
do not accrue unlimited empty-calendar debt after catching up. Wait for the next
matching publisher episode and apply the next applicable schedule occurrence.
This must be confirmed because it affects whether a future burst is released at
once or one episode per new slot.

### Capacity accounting

Count outstanding automatic Replay reservations through completion/manual archive:
reserved, waiting for network, downloading, failed, ready, playing and partially
played. Download completion does not create capacity. Retries reuse reservations.

With limit 1: Monday's episode blocks Tuesday's release until resolved. If resolved
Tuesday morning, immediately request Tuesday's overdue episode; if resolved Monday
afternoon, wait for Tuesday's slot.

With limit 3 and several missed days: fill up to three available places. Do not
make skipped/excluded episodes occupy capacity or create empty daily releases.

Lowering a limit below the existing occupancy pauses new work without deleting
unplayed episodes. Increasing it triggers reconciliation for overdue work. The
same rule applies when changing No Limit to a finite limit.

Manual downloads and pre-existing episodes require a clear policy. Recommended:
count unresolved local/manual items from the same podcast towards the visible limit
when evaluating new automatic Replay capacity; preserve explicit manual overrides,
but display over-capacity and stop new automatic reservations. Confirmation is
required before implementing this broader occupancy rule.

### Immediate refill events

Reconcile after committed completion, manual archive, limit/filter changes, schedule
changes, successful feed merge, startup/foreground and allowed background work.
Do not wait for AutoArchiveCoordinator's 25-minute maintenance gate. Reconciliation
must be coalesced and bounded so bulk archive does not spawn competing planners.

An automatic archive caused by another policy must not masquerade as deliberate
manual resolution. Carry disposition origin explicitly.

## 7. Lifecycle and transitions

Enabled is a durable configuration flag. Waiting/downloading/caught-up are derived
conditions; a capacity wait must not toggle enabled off.

| Event/state | Required transition |
| --- | --- |
| Enable confirmed | Persist new session/anchor, suppress new-release automation, reconcile first due slot. |
| Before release time | Scheduled; no automatic transfer reservation yet. |
| Due + capacity | Reserve atomically, enqueue durable download intent, update derived status. |
| Due + full | Waiting for space; retain due-slot debt. |
| Transfer fails | Needs attention/retry; retain reservation/capacity and episode order. |
| Transfer completes | Ready; notify queue owner, retain capacity. |
| Episode completes/manual archive | Resolve once, free capacity, reconcile overdue work, evaluate catch-up. |
| No eligible next item + unresolved released items | Continue waiting for listening; do not notify caught-up. |
| Frontier resolved + successful complete evaluation | Caught-up decision pending; notification outbox and in-app prompt. |
| Keep Schedule | Persist decision, suppress repeat catch-up prompt for this session, retain schedule. |
| No response | Remain enabled, retain in-app choice; do not repeatedly notify. |
| Turn Off | End session automation safely; resume ordinary future new-release eligibility. |
| Unsubscribe/delete | Cancel pending Replay work, remove badge; preserve appropriate history. |
| Inactive subscription | Proposed: retain enabled configuration and pill, pause new releases until reactivated. |

For a failed first episode with a larger limit, do not silently autoplay later Replay
episodes past that gap. Proposed first beta behaviour: block further automatic release
assignment until retry or explicit Skip/Archive resolves the failed head reservation.
This is stricter than capacity alone and must be confirmed before implementation.

## 8. Integration with existing behaviours

### Feed refresh and ordinary automatic downloads

Continue parsing/merging the feed. Branch only when planning automatic media work.
While Replay is enabled, newly published items join its future catalogue instead
of entering the normal new-release downloader.

At enable, revoke unstarted ordinary automatic intents for that subscription.
Do not silently cancel an explicit manual transfer or active playback. Existing
started/downloaded items require the enable preview described in section 10.
Every queued transfer rechecks origin, current session and configuration revision.

At disable, invalidate pending Replay outbox work and future slots. Preserve already
released/downloaded episodes and user pins. Do not run a generic “download every
eligible old episode” pass. Retain ordinary feed observation history so the next
real publisher arrival, not the existing backlog, drives new automatic downloads.
The stored Play Instant preference may resume for genuine future new releases.

### Queue and priority

Keep subscription priority and manual pins intact. Replay should not jump ahead of
higher-priority podcasts. The ordinary downloaded queue already has chronological
ordering; use stable session/order metadata where feed edits could undermine it.

Scheduled release does not interrupt the current player. An explicit user Play Next
remains an override. A future episode manually downloaded/played is a manual action,
not evidence that all prior Replay episodes are resolved; define its session effect
without jumping the Replay cursor automatically.

### Auto Archive and filters

Episode Limit becomes an admission guard for Replay, not a newest-N eviction rule.
After Playing cleanup still runs normally after completion. Unresolved Replay items
must be protected from conflicting automatic eviction. Document the confirmed
inactivity policy visibly in Podcast settings rather than silently ignoring a rule.

Download Feed Filters govern automatic Replay releases. Manual downloads retain
existing manual/filter semantics. Reuse exact boundary operators and include/exclude
precedence; do not implement a second duration/title rule system.

### Play Instant, notifications and history

Replay intent must carry its origin through download settlement. Do not call
PlayInstantWorkflow.enqueueIfEligible for Replay-origin downloads. Do not present
an old replay as a newly published episode in ordinary notifications.

Intentional replay of an already completed historical episode creates a new Replay
session outcome without erasing accumulated history. Audit existing global terminal
flags, playable eligibility and idempotent Stats outcome keys: a session-local
resolution must not be satisfied by last year's completed flag. This may require a
separate listening-session identity; do not broadly reset historical completion.

## 9. Catch-up notification and decision

Evaluate only against a successfully loaded, current accessible matching catalogue.
A network error, missing metadata, unresolved failure, empty initial result or an
incomplete catalogue fetch cannot establish catch-up.

Require all selected matching episodes through the known frontier to be resolved,
not simply the highest-numbered episode. Explicit manual pins may cause out-of-order
listening, so checking only the last episode is insufficient.

Suggested copy:

> You're caught up with [Podcast Name]
> You've reached the latest episode matching your Feed Filters. Keep your Podcast
> Replay schedule, or return to automatic downloads of new episodes?

Actions: **Keep Schedule** and **Turn Off Podcast Replay**.

Use a unique session/prompt event identity to prevent duplicate notifications after
restart/sync. Persist pending delivery through an outbox and use a stable notification
identifier. Revalidate the session when handling an action; a stale action must not
disable a newly configured Replay session. Open the current Podcast page if stale.

If permission is denied, use the same in-app panel. Do not repeatedly request
notification permission. If a new matching episode appears before the prompt is
answered, remove stale “caught up” wording and present the current state. No response
keeps the schedule; Keep Schedule suppresses future repeated catch-up prompts for
that session. Explicit restart may create a new prompt cycle.

Confirm whether caught-up notices follow the per-podcast episode notification switch
or a distinct opt-in setting. Do not assume the existing switch authorises every new
notification category.

## 10. Interface specification

### Setup and episode selection

Entry points proposed:

- Podcast settings > Podcast Replay.
- Episode Detail > Listen From Here, opening setup with that episode selected.
- Podcast page Replay pill/status panel when already enabled.

Episode picker must support searching the accessible catalogue, chronological order,
release dates, duration and clear filter-match status. It must remain usable for
hundreds of episodes without downloading all media. Selecting a nonmatching anchor
shows the first matching episode and asks the user to confirm the resulting start.

Setup fields: start episode, Start date, Daily / Weekdays / Choose Days, one or more release times, time-zone explanation, an immediately saved Episode Limit picker bound to the existing Auto Archive setting, Feed Filters with navigation to their existing editor, and next-release preview. Remove the device acknowledgement gate and separate section; concise update/sync and fixed-scheduling-device notes remain near Save. Schedule drafts save explicitly; Episode Limit changes save immediately and mirror in Podcast Settings.

Enable explanation:

> Podcast Replay downloads matching episodes from your chosen starting point.
> Automatic downloads of new releases are paused while it's enabled. You can still
> browse and download any episode manually.

Show any pre-existing queued/downloading episodes and the effect on capacity before
confirmation. Do not destructively clear them as an implementation shortcut.

### Replay pill

Add **Replay** alongside current status pills in Subscriptions rows. Do not replace
Played, Queued, Playing, Paused or Inactive. It describes a subscription mode, not
an episode's played state. Reuse shared font, padding, capsule shape and adaptive
metrics; avoid changing the entire row to accommodate the new badge.

Use a replay-arrow or clock-arrow symbol only if available at the deployment target,
with a text label and suitable contrast. Final symbol/tint is a design choice, not
a hard-coded dependency of schedule logic. Colour alone must not convey enabled state.

The list pill remains non-interactive so tapping the row still opens the podcast.
Support wrapping/stacking at narrow widths and large Dynamic Type. Preserve swipe
behaviour and search filtering. Retain the pill while waiting at capacity or waiting
for a future matching episode; remove it only when Replay is disabled.

On the Podcast page, show the same pill and a tappable detail area:

| Condition | Example supporting text |
| --- | --- |
| Scheduled | Next episode: Tomorrow at 4:00 am |
| Due but unable to run/download | Episode due · Waiting for download |
| Capacity reached | Waiting for space · 3 of 3 episodes |
| Downloading | Downloading Episode 14 |
| Failed | Download needs attention · Tap to review |
| Catch-up decision | You're caught up · Review your schedule |
| Keep Schedule accepted | Waiting for the next matching episode |
| Missing episode information | Waiting for episode information |
| Inactive podcast | Replay paused while this podcast is inactive |

Do not imply that a 4:00 am transfer is guaranteed. Distinguish scheduled due time
from actual downloaded availability. Keep keyboard navigation, VoiceOver hints and
Back behaviour consistent across iPhone, iPad and Designed-for-iPad Mac.

## 11. Background execution and reliability

Apple's background task earliestBeginDate is a lower bound, not a guaranteed wake
at a chosen time. Background URLSession scheduling likewise cannot guarantee an
exact start. A local notification is not a reliable mechanism for executing arbitrary
queue/download code at its delivery time.

Implement schedule reconciliation on existing execution opportunities. Persist all
necessary intent before suspension. If the user force-quits or the system grants
no execution window, catch up at the next allowed opportunity without early releases,
duplicates, unbounded bursts or silently lost slots.

Do not keep the process alive through silent audio, polling loops or a hidden timer.
Do not add a server solely to suggest exact timing; even a push would not guarantee
execution. Prefetching can be a later separately designed optimisation requiring a
strict release gate and storage policy.

Official references checked during planning:

- [BGTaskRequest earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)
- [URLSessionTask earliestBeginDate](https://developer.apple.com/documentation/foundation/urlsessiontask/earliestbegindate)

## 12. Cross-device authority, migration and compatibility

### Required shared experience

Cross-device consistency is a confirmed user requirement. It is part of the first
usable beta, not an optional enhancement after single-device shipping. Schedule
settings alone are insufficient: the devices must agree on which episodes have
been released, resolved and ordered in Up Next.

| State | Sync contract |
| --- | --- |
| Replay enabled, starting episode, recurrence, first release, time-zone policy | Shared per-podcast configuration, with atomic revision. |
| Feed Filters and Episode Limit | Reuse existing synced per-podcast settings; reconcile only against a coherent configuration snapshot. |
| Session identity, assigned release slots and cursor | Shared durable progress; a second installation does not restart at the initial episode. |
| Outstanding/resolved Replay episodes | Shared logical reservations; remote completion/manual archive frees logical capacity once. |
| Caught-up state and Keep/Disable choice | Shared session-scoped decision; do not ask again independently on every device. |
| Subscription priority, Play Next/Play Last overrides | Preserve existing sync semantics and reconcile into one canonical logical order. |
| Playback position | Reuse the existing playback-position/history conflict rules; Replay does not introduce another resume store. |
| Download tasks, file paths, byte progress, local readiness | Device-local. Never treat a missing file on another device as an archive, unreleased episode or vacant global capacity slot. |

A notification may already have been delivered on an offline device when another
device answers. Sync the decision, withdraw pending/stale notices where possible,
and make every action idempotent. Do not promise exactly-once visible notification
delivery across disconnected devices.

### Logical queue versus local playability

The existing iOS queue is derived from local downloaded files, while TV consumes
phone-authored projections. That is a material compatibility gap for strict
cross-device Replay order: syncing configuration alone cannot close it.

Introduce or extend an authoritative logical queue projection containing released
identities, stable order/pins, Replay session membership, configuration revision and
queue generation. Each device overlays its own availability on this shared order.
A device without a file displays the episode as waiting for download rather than
silently dropping or promoting it in a way that rewrites the shared queue.

Keep the existing iOS download-first playback policy. A missing local file requires
its normal download flow before playback. Whether automatic advancement waits or
skips locally unavailable items must be explicitly designed; it must not silently
change shared order or mark items completed. TV may stream eligible released media
under its existing policy. No device-local transfer failure may erase another
device's queue item.

Logical capacity is counted once per released unresolved episode across devices,
not once per device download. Local storage limits may defer a follower's download,
but must not allocate an extra release slot or free global Replay capacity.

The queue and matching schedule/progress revisions must be applied coherently.
CloudKit records may arrive separately: retain the last coherent projection and
request missing records rather than combining a new cursor with an old queue.
Tombstones/session IDs prevent a stale device resurrecting a disabled or restarted
Replay configuration. Preserve existing subscription order generations and manual
pin conflict semantics; do not introduce an unrelated last-writer-wins queue.

### Editing and propagation

Users can edit supported Replay settings on iPhone, iPad and Designed-for-iPad Mac.
A designated scheduler is an implementation authority, not a reason to make other
iOS-family devices permanently read-only. Route edits through versioned commands
that the scheduler acknowledges, or an equivalent conflict-safe revision protocol.
Show pending sync when changes have not reached the authority; do not display an
unacknowledged schedule as active on all devices. TV may remain read-only for setup
while still receiving configuration, badges and shared queue state.

Concurrent edits must preserve a coherent schedule, not merge unrelated date/time
fields into an unintended recurrence. Specify deterministic conflict handling and
surface superseded local edits. Reconcile filter and limit changes with the same
configuration generation before reserving further episodes.

When iCloud Sync is disabled, Replay may operate locally with an explicit local-only
status. Enabling sync later requires reconciliation/ownership confirmation; never
union two independently advanced sessions into duplicate release assignments.
When a device is offline, it retains its last known queue and may record local
listening outcomes. Reconcile those outcomes on reconnect without duplication.
Immediate synchronisation cannot be guaranteed while offline or without background
execution; show pending state rather than claiming devices are already aligned.

### Cross-device acceptance scenarios

1. Enable Replay on iPhone; iPad/Mac receive the same configuration and released
   sequence, show Replay, and do not independently reserve another first episode.
2. Release three episodes with limit 3; another device missing all files still
   reports three occupied logical places and the same intended queue order.
3. Finish/archive on TV; owner receives the outcome, releases one overdue episode
   when capacity permits, and publishes one new generation to all devices.
4. Pin an episode Play Next on a supported device; ordering converges without a
   later Replay reconciliation discarding the explicit override.
5. Edit recurrence/filter/limit while another device is offline; reconnect applies
   a coherent revision and never executes stale pending reservations.
6. Disable Replay or answer Keep Schedule on one device; all others converge and
   stale notification actions cannot undo the newer decision.
7. Restore/reinstall or switch accounts; no duplicate owner, copied device identity
   or queue progress from the previous account is adopted.



### One scheduler

Configuration must synchronise across devices. Only the designated scheduler may
assign slots. Use an owner identity and epoch checked before every commit. Private
CloudKit eventual convergence alone does not provide a distributed lock.

First-beta recommendation: one explicitly designated iPhone/iPad/Mac installation
owns releases; other iOS-family devices submit versioned edits while TV may
remain read-only for settings. Releasing authority transfers only deliberately.
A disconnected second device must not take over automatically. Ownership transfer
requires a coordinated current state/epoch update; defer takeover when authority
cannot be established. Do not ship cross-device editing until command acknowledgement and conflict
handling are verified; it is a required beta gate, not an optional post-release task.

TV continues consuming phone-authored queue snapshots. Its manual archive/completion
must be mapped back to the correct session reservation and release capacity when
synced. Local file paths and transfer tasks remain device-local. The plan must handle
TV completion while the owner is offline without duplicate resolution on reconnect.

### Storage migration

Default missing fields to disabled. Introduce additive schema/CloudKit fields with
explicit versions. Preserve existing subscription IDs, filters, Auto Archive values,
notification choices, history and queue pins. Never enable Replay during migration.

Audit import/export and subscription survival backups for new configuration fields.
Decide whether restored progress is read-only until scheduler ownership is reclaimed.
Do not restore a device author identity as permission for two installations to schedule.

Older app versions may ignore Replay configuration and keep downloading new releases
or republish queue state. This is a real rollout hazard. A version-aware capability
strategy and user-facing minimum-version guidance are required before cross-device
beta enablement. Keep the feature disabled on accounts/device combinations where
an old writer can negate its invariants; do not assume optional-field decoding alone
makes mixed-version behaviour safe.

## 13. Phased implementation and acceptance gates

| Phase | Deliverable | Exit condition |
| --- | --- | --- |
| 0: Confirm contract | Resolve section 14, approve UI states and due-slot semantics | No ambiguous capacity, old-history, disable or catch-up rule remains. |
| 1: Pure policies | Catalogue/filter selection, calendar slots, capacity and catch-up evaluation | Deterministic unit tests cover boundary matrix below. No runtime wiring. |
| 2: Durable state | Additive schema, session ledger, reservations/outbox and migration | Crash/retry/import tests demonstrate no lost or duplicated assignment. Disabled by default. |
| 3: Download/archive integration | Explicit Replay origin, suppression of normal automation, retention protection | Existing ordinary-download tests remain green; Replay cannot be evicted or misclassified as Play Instant. |
| 4: Queue and lifecycle | Queue release gating, completion/archive refill, startup/background reconciliation | Limit 1/3 scenarios work end-to-end, preserving pins and active playback. |
| 5: UI and notifications | Setup, previews, Replay pills, state panel, caught-up actions | Device/accessibility walkthrough; permission-denied and stale-action paths verified. |
| 6: Required sync and TV gate | Shared settings/progress/logical queue, owner enforcement, remote edits/outcomes | Two-device offline/reconnect and TV completion tests pass with mixed-version policy. |
| 7: Beta hardening | Diagnostics, controlled opt-in, hardware testing, documentation | Recorded release checklist and no unresolved data-loss/duplicate-release defects. |

Design the shared logical queue and sync schema during Phases 1–2; Phase 6 is
end-to-end verification, not the first point at which sync is considered. Do not
ship a user-facing beta before this gate passes.

Do not implement all phases in one unreviewable change. Each phase must include its
own relevant AI headers, validation evidence and Version 1.7 entry. A partially
implemented phase must remain inaccessible rather than appear as a functioning mode.

### Required regression matrix

- Start before/at/after filter boundary; duration exactly 40 minutes is excluded for
  a strict greater-than-40 filter. Missing duration follows the explicit unknown rule.
- Excluded episode between two eligible episodes consumes no day or capacity.
- Equal publication dates, missing dates, changing GUID/enclosure and feed reordering.
- Limit 1: complete before due, exactly due and after due; archive follows same refill.
- Limit 3: several overdue slots fill only free places; all transfer states count.
- No Limit: large overdue catalogue processed in bounded batches with cancellation.
- Limit decreased below occupancy: no eviction; increased: overdue refill.
- Retry same reservation after network failure, process termination and background expiry.
- Crash before commit, after commit/before intent insertion, and after insertion/before ack.
- Simultaneous completion, feed refresh and background reconciliation.
- Enable/disable or filter edit during an in-flight plan; stale plan cannot commit.
- Ordinary download suppression and manual-download exceptions.
- Replay transfer completion never triggers Play Instant.
- Current playback, explicit Play Next/Play Last and cross-podcast priority unchanged.
- Existing historical completion does not instantly resolve a newly started replay.
- Automatic archive is distinguished from deliberate manual archive.
- Caught-up withheld while any earlier matching reservation remains unresolved.
- Caught-up withheld for failed/incomplete feed loads or no matching starting episode.
- Notification dedupe, denied permission, dismissal, Keep Schedule, stale Disable action.
- New episode arrives while caught-up prompt is pending.
- Turn Off preserves queue/history and does not backfill the old catalogue.
- DST gap/overlap, time-zone travel, clock moved backwards/forwards, leap day.
- Scheduler-owner conflict, stale epoch, offline follower and account switch.
- TV completion/archive produces exactly one resolution after sync.
- Old-version client compatibility and subscription delete/restore.
- Replay pills alongside each existing status at compact/large widths, Dynamic Type,
  VoiceOver, hardware keyboard and pointer; no swipe or row-navigation regression.

Testing must include workflow integration, not only a pure function mirroring its
implementation. Use fake time/calendar, in-memory stores and transfer spies for
policy tests; real-device validation remains necessary for background behaviour.

## 14. Open decisions and recommended resolutions

These are not blockers to drafting this document, but implementation must not invent
answers silently. Bundle them into a short product review before dependent phases.

| Decision | Recommended resolution |
| --- | --- |
| Manual/pre-existing episodes and Episode Limit | Count unresolved same-podcast items for automatic capacity; preserve explicit manual overrides and show over-capacity. Preview existing items at enable. |
| Inactive Auto Archive policy | Protect unresolved Replay reservations, explain the exception; After Playing remains active. |
| Missing duration for active duration filter | Attempt bounded metadata enrichment, then block/explain until resolved or explicitly skipped. |
| Failed head with capacity >1 | Retry/block later automatic assignment for the first beta; allow explicit Skip/Archive. |
| Time-zone travel | Follow local time for daily schedules, with explicit explanation; fixed-zone scheduling can follow later. |
| Empty slots after reaching the frontier | Do not accumulate unlimited debt; future publisher arrivals follow the next schedule slot. |
| Notification preferences | Separate caught-up preference or explicitly document its relationship to the current per-show notification switch. |
| Replaying previously played material | Introduce session-specific unresolved state without deleting history; audit queue/Stats eligibility before choosing storage representation. |
| Pausing versus disabling | Capacity wait is automatic and retains Replay. If a user Pause control is added, specify whether ordinary downloads remain suppressed and how missed slots accumulate. |
| Future episode manually played | Resolve only its own session membership where applicable; never jump over earlier unresolved items. |
| Ownership transfer | Explicit online handover with revision/epoch validation; no automatic offline takeover. |
| Exact recurrence options | Begin with calendar recurrence; confirm whether hourly intervals are required for the beta. |

## 15. Diagnostics, documentation and definition of done

Add bounded, meaningful diagnostics: session/reservation identifiers, eligibility
reason, due slot, capacity/occupancy, filter revision, blocked reason, owner epoch,
retry outcome, queue publication and caught-up event state. Avoid full private feed
URLs, episode descriptions or unbounded catalogue dumps. Use existing local logging;
no telemetry service is implied.

Canonical documentation updates when implemented:

- FEATURES.md: product behaviour, defaults, limits and automation interactions.
- PAGES.md: setup/manage paths, Replay pill and notification destinations.
- DESIGN.md: badge composition, responsive states and accessibility.
- SYNC_DESIGN.md: ownership, conflict rules, schema and older-client behaviour.
- ONBOARDING.md: concise discovery/help copy if onboarding is added.
- TV/AI_CONTEXT.md: queue consumption and remote resolution contract.
- VERSION_1.7.md: implemented phases, tests and outstanding verification.
- Source/test AI headers: local ownership, dependencies and regression invariants.
- project.yml/generated Xcode project: target membership for new files, changed only
  through the existing XcodeGen workflow.

The feature is implementation-complete only when confirmed requirements, durable
restart behaviour, existing-feature regressions, accessible UI, owner-safe sync and
caught-up decisions pass their acceptance gates. Simulator success does not prove
exact background delivery. Release copy must describe intended due times honestly.

The original strategy-only milestone is complete. The implementation record at the top of this document now describes the Version 1.7 beta and remaining release checks. The 13 September visual redesign is recorded in [PODCAST_REPLAY_DESIGN_AUDIT.md](PODCAST_REPLAY_DESIGN_AUDIT.md).
