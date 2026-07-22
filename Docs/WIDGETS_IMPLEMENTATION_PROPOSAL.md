# Autohop — Home Screen Widgets Implementation Proposal

> **AI CONTEXT — Visual implementation update (2026-07-21):** Home Screen
> widget families now use an opaque textured dark-charcoal glass surface rather
> than pure black. iOS 26+ adds native Liquid Glass sheen. Playback controls use
> a host-safe tinted glass-style gradient on every OS because native glass
> can suppress an App Intent Toggle label in WidgetKit. iOS 17–25 use a stable
> background gradient/stroke fallback. Lock Screen
> accessories deliberately retain system-owned backgrounds and tint behavior.

<!--
AI CONTEXT — Docs/WIDGETS_IMPLEMENTATION_PROPOSAL.md

PURPOSE:
Authoritative, staged, AI-executable proposal for Autohop's iOS Home Screen /
Lock Screen widgets ("Now Playing & Up Next"). Written 2026-07-20 as the
consolidation of THREE converged assessments: a Claude review of the local
Pocket Casts clone, a Codex review of Pocket Casts at GitHub commit 67d40466
(plus the live Autohop tree), and two cross-review rounds in which each
assessment audited the other. Every factual claim below about Pocket Casts was
verified against the local clone (~/Developer/GitHub/pocket-casts-ios,
checked out at a55cf050, 2026-06-05); every claim about Autohop was verified
against the live working tree post-AppState-decomposition (stages 0–14
complete — see APPSTATE_DECOMPOSITION_PROPOSAL.md).

STATUS: STAGES 1–4, 6, AND 7 IMPLEMENTED 2026-07-20; PHYSICAL-DEVICE
LISTENING/LOCKED/STANDBY/DURABILITY GATES PENDING. STAGE 5 DEFERRED BY KEVIN.
Kevin gives a per-stage "go"; an
executing model implements ONE stage, stops at its gate, and records the outcome
in this file's execution ledger, following the decomposition doc's convention.
Do not combine stages into one edit pass.

EXECUTION RULES FOR A FUTURE MODEL:
- Read this file, DESIGN.md ("Apple TV Patterns" shows the house doc style for
  platform additions), APPSTATE_DECOMPOSITION_PROPOSAL.md (coordinator
  boundaries this feature must respect), and the AI CONTEXT headers of
  App/QueueCoordinator.swift, App/PlaybackCoordinator.swift,
  App/AppRoutingCoordinator.swift, App/AppCompositionRoot.swift before writing
  any code.
- The widget extension NEVER links AutohopCore, never opens the GRDB database,
  and never performs artwork networking. These are invariants, not defaults.
- Kevin compiles and runs builds himself (never run xcodebuild). New files →
  update project.yml → `xcodegen generate`.
- Clean-room rule: Pocket Casts is MPL-2.0. This feature reuses its
  ARCHITECTURE as design inspiration only. If any file ends up a genuine port,
  it gets the MPL header and joins NOTICE + AcknowledgementsView per
  reference practice in this repo. Target outcome: zero ported files; one
  "design inspiration" line added to NOTICE at Stage 7.
-->

## 1. Product summary

One adaptive, clean-room **"Now Playing & Up Next"** WidgetKit extension:

| Family | Content |
|---|---|
| `systemSmall` | Artwork, episode title (2 lines), remaining time, interactive play/pause |
| `systemMedium` | Current episode (~half width) + next episode compact row; play controls on both; Up Next count |
| `systemLarge` | Current-episode hero band (artwork · title · podcast · remaining · large play/pause) + four following queue rows (artwork · title · duration · play button) + "Up Next" label with full queue count |
| `accessoryCircular` | Up Next count + stack glyph |
| `accessoryRectangular` | Next episode title + podcast name (privacy-sensitive) |

Product invariants:
- **Downloaded-only play buttons.** Everything rendered with a play control is
  already on-device and immediately playable — Autohop's core promise. An
  undownloaded episode may never carry a play button (navigation only).
- **Play/pause and play-this-episode are interactive App Intents** (no app
  foregrounding). Ships in the initial release — this is *parity* with Pocket
  Casts (verified: their rows use `Toggle(isOn:intent: PlayEpisodeIntent(...))`,
  an `AudioPlaybackIntent` with `openAppWhenRun = false`), not a later polish.
- **Deep links are for navigation only** (row text → episode, header → player,
  empty state → Discover).
- Dark, purple-accented, consistent with DESIGN.md episode-row geometry. No
  Pocket Casts visual styling, strings, or artwork.

Empty-state ladder (in order; stop at first satisfiable):
1. Current episode + Up Next.
2. Up Next with no current episode.
3. Recently downloaded playable episodes (if temporarily absent from the queue
   projection).
4. No downloaded episode → Discover call-to-action (navigation only).
5. NEVER an undownloaded episode with a play button.

Deferred to a SECOND release (Stage 5, separate widgets — do not blend into Up
Next's meaning): "Fresh from Your Shows" discovery, Listening Stats /
Time Saved, Auto Archive activity, configurable podcast widget. An iOS 18
Control Center control is a separate feature that may reuse the playback
intent but is not part of this proposal's scope.

## 2. Pocket Casts reference map (verified in the local clone)

| What | Where | Verdict |
|---|---|---|
| Widget bundle (7 widgets) | `WidgetExtension/PocketCastsWidgetBundle.swift` | Reference for bundle shape; Autohop ships ONE adaptive design + accessories |
| App-side publisher | `podcasts/WidgetHelper.swift` — NotificationCenter observers → JSON `[CommonUpNextItem]` into App Group UserDefaults → `WidgetCenter` reloads | Adopt the publish/render split; REPLACE broad NotificationCenter observation with narrow coordinator publishers |
| Shared item model | `podcasts/CommonUpNextItem.swift` (uuid, title, podcast, color, duration, imageUrl, isPlaying) | Adopt the compact-display-model idea; Autohop's is richer + versioned (§4) |
| Family artwork limits | `WidgetExtension/Up Next/UpNextProvider.swift` (`context.family.imageCount` → 1/2/5) | Adopt |
| Artwork loading | `WidgetExtension/Data/WidgetEpisode.swift` `loadImageData()` — SYNCHRONOUS `Data(contentsOf:)`; remote CDN URL for normal podcasts (`ServerHelper.image(...)` in WidgetHelper), App Group file only for user-file episodes | DO NOT ADOPT the remote fetch. Autohop pre-renders ALL visible thumbnails app-side (§5) — a deliberate improvement |
| Interactive playback | `podcasts/PlayEpisodeIntent.swift` (`AudioPlaybackIntent`, `openAppWhenRun = false`; toggle if current, else load-and-play) + the dual-target trick: `AppPlayEpisodeIntentExtension.swift` (real behavior, app target) / `WidgetPlayEpisodeIntentExtension.swift` (compile-only stub, widget target) | Adopt the pattern AND the `Toggle(isOn:intent:)` control (optimistic state flip before the intent completes) |
| Navigation links | `pktc://widget-episode/<uuid>`, `pktc://discover?source=widget`, `.widgetURL(...)` | Adopt the shape with a validated parser (§6) |
| Empty-state fallback | Top-filter episodes when queue empty (`publishTopFilterInfo`) | Adopt the *idea*; Autohop's ladder is §1 |
| Timeline policy | Single-entry timelines, app-driven reloads | Adopt, with dedupe + targeted kinds (§7) |

Corrections ledger (why this doc exists in this exact form): the first Claude
assessment wrongly called PC's play buttons deep-link-only and wrongly
described App Group thumbnails as PC's general artwork mechanism; both were
corrected by Codex review and re-verified in the clone. Codex's report
correctly anticipated the completed AppState decomposition. All three
documents now agree; there are no open disagreements.

## 3. Prerequisites Autohop lacks today (verified)

1. **App Group** — none exists. Add `group.com.kevinperry.autohop` to the iOS
   app + widget extension entitlements and project.yml. KEVIN MANUAL STEP:
   register the group in the Apple Developer portal / Xcode Signing &
   Capabilities (same class of step as the CarPlay entitlement).
2. **URL scheme** — none exists. Register `autohop://` (CFBundleURLTypes via
   project.yml `info` block) + `onOpenURL` in AutohopApp.
3. **Widget extension target** — new `AutohopWidgets` target
   (`com.kevinperry.autohop.widgets`) in project.yml, sources under a new
   `Widgets/` directory, WidgetKit + AppIntents frameworks, its own
   entitlements file with only the App Group. tvOS untouched.

## 4. Data contract: the widget display snapshot

The CloudKit `QueueSnapshot` is NOT reused (different responsibility: ordered
cross-device identities vs device-local presentation; it carries no podcast
name, artwork, duration, remaining time, or playing state). A separate,
versioned, device-local file:

- `widget-snapshot.json`, written ATOMICALLY into the App Group container.
- `WidgetArtwork/` directory beside it for thumbnails.

Snapshot contents (shared model file compiled into BOTH targets — a small
`Widgets/Shared/WidgetSnapshot.swift`, never AutohopCore):
- `schemaVersion: Int`
- `generatedAt: Date`
- `upNextTotalCount: Int`
- `isPlaying: Bool`
- Up to **5** display episodes, each: stable identity
  (`subscriptionID` + `PlaybackPositionStore.key(for:)` — NEVER `Episode.id`,
  it regenerates on feed refresh), episode title, podcast title, duration,
  remaining seconds (static — see §7), `isCurrent`, thumbnail filename,
  optional video/explicit flags.

MUST NOT contain: audio URLs, local media paths, CloudKit record IDs, relay
credentials, tokens, or full Episode/Subscription objects. Display-only.

File protection: after-first-unlock, so Lock Screen widgets render post-reboot
once the device has been unlocked.

## 5. Publisher: `WidgetSnapshotCoordinator`

New coordinator owned/constructed by `AppCompositionRoot` (never a new
AppState responsibility — respect the decomposition):

- Observes NARROW publishers only: `QueueCoordinator.$episodes` /
  `$upNextEpisode`, `PlaybackCoordinator.$currentEpisode` / `$isPlaying`,
  download-completion and archive events, artwork-availability. Explicitly NOT
  `AppState.objectWillChange`, NOT the 0.5 s playback tick, NOT raw
  `SubscriptionStore` mutations.
- Publication triggers: current-episode change; play/pause/completion; queue
  composition or order change; episode download finished; episode archived or
  removed; relevant artwork became available; startup restore finished; app
  backgrounded (final checkpoint).
- Debounced briefly; DEDUPED by hashing the visible snapshot and skipping
  equivalent publications; reloads only the affected widget kind.
- Thumbnails: resolve episode artwork → subscription artwork fallback; render
  via the existing `ArtworkImageCache` pipeline to ~200–300 px compressed
  JPEGs; write to `WidgetArtwork/`; publish filenames only; garbage-collect
  files not referenced by the current snapshot (keep at most one previous
  generation); waveform placeholder asset when artwork is unavailable.
- Diagnostics: log `widget.published` (reason, episode count, dedupe result,
  duration ms) and `widget.publishSkipped` (dedupe hash hit) — the same
  greppable discipline as `sync.queued`, so a future overnight-log review can
  prove this isn't storming (relay lesson, 2026-07-11).

## 6. Interactivity and navigation

**Playback — App Intents (Stage 3, part of the initial usable feature):**
- `PlayAutohopEpisodeIntent: AudioPlaybackIntent`, `openAppWhenRun = false`,
  parameterized by the stable identity from §4. Dual-target placeholder
  pattern as in PC (real `perform()` extension in the app target; compile-only
  stub in the widget target).
- Semantics: identity == current episode → toggle play/pause. Otherwise →
  immediate "Play Now" of that (downloaded) episode; deliberate user selection
  cancels any pending Play Instant restoration.
- The handler is a small `WidgetPlaybackIntentHandler` that revalidates the
  identity against the live store AT PERFORM TIME and delegates to
  `PlaybackTransportWorkflow` (cold-launch bridge via
  `AppState.sharedOrBootstrap()`; policy stays in the typed workflow — never a
  second player, never direct DB access from the intent).
- Stale/archived/no-longer-downloaded → fail SAFELY: no playback, republish
  the snapshot so the widget corrects itself; treat as navigate-not-play where
  a UI response is possible.
- Widget controls use `Toggle(isOn:intent:)` for play/pause state so the
  glyph flips optimistically.

**Navigation — validated deep links:**
- Routes: `autohop://player`, `autohop://up-next`,
  `autohop://episode/<subscription-id>/<encoded-episode-key>`,
  `autohop://discover` (append `?source=widget` for attribution logging).
- A dedicated parser validates scheme/host/identity shape and emits typed
  `AppRouteCommand`s through `AppRoutingCoordinator` (add cases as needed,
  e.g. `.openUpNext`, `.openEpisode(...)`); malformed/unknown URLs are
  rejected and logged, never partially handled.

## 7. Update & performance policy

- Never reload per playback tick; never simulate a live countdown/scrubber via
  timeline reloads. Remaining time is a static value refreshed on meaningful
  playback events (speed/Trim Silence make predicted countdowns wrong anyway).
- Single-entry timelines; app-driven `WidgetCenter` reloads, targeted by kind.
- ≤5 visible episodes; artwork loaded per `context.family` count (1/2/5).
- No networking, no GRDB, no AutohopCore, no full domain models in the
  extension.
- Memory: no numeric cap is documented as a guarantee (system-managed, varies
  by OS/device). Policy instead: the artifact limits above + measure peak
  extension memory on Kevin's real devices at Stage 7; ANY extension
  termination during timeline rendering is a release blocker.

## 8. Privacy & security

- App Group content is display-only (§4 exclusion list).
- Every playback request revalidated in-app; widget identity is a claim, not
  proof.
- Lock Screen episode titles marked privacy-sensitive (system redaction).
- Thumbnails/snapshot removed when episodes leave the snapshot; no third-party
  requests from the extension (artwork servers never see widget traffic).
- Eventually disclose local widget caching in the privacy policy
  (support-page mirror rule applies: SupportContent.swift + website
  support.html together).

## 9. Implementation stages (each gated on Kevin's go + build)

**Stage 1 — Foundation.** App Group registration (KEVIN: portal/Xcode step) +
entitlements; `AutohopWidgets` target in project.yml + xcodegen; shared
versioned snapshot model + atomic App Group storage + thumbnail directory;
static placeholder layouts for all five families. GATE: Kevin builds; widgets
install and render placeholders.

**Stage 2 — Read-only live widget.** `WidgetSnapshotCoordinator` on the
composition root; narrow observation, debounce, dedupe hash, diagnostics keys;
thumbnail rendering + GC; real small/medium/large layouts; empty-state ladder;
stale-state handling (snapshot older than N hours renders a neutral "open
Autohop" state rather than wrong data). GATE: widgets track queue/playback
correctly through a real listening session; `widget.published` cadence sane in
a diagnostic log.

**Stage 3 — Interactivity + routing.** The App Intent (dual-target), handler
revalidation, Play Now semantics, post-action republish; URL scheme + parser +
`AppRouteCommand` additions; row/header/empty-state links. GATE: play/pause
and play-other-row work from the Home Screen without foregrounding; stale
selections fail safely; all four routes navigate correctly.

**Stage 4 — Lock Screen + StandBy.** Replace Stage 1's registered static
`accessoryCircular` + `accessoryRectangular` placeholders with live snapshot
content; add privacy redaction, tinted/accented rendering modes,
locked-device/first-unlock testing, and the StandBy check. GATE: Kevin's
overnight real-device pass.

**Stage 5 — Discovery/stats widgets (separate release).** Scope deferred; do
not start without a fresh product decision.

**Stage 6 — Perf & durability pass.** Corrupt-snapshot recovery, missing
artwork, archived-while-displayed, large queues, background downloads,
reboot/first-unlock, reload-frequency audit from a real overnight log, device
memory measurement.

**Stage 7 — Docs & release.** DESIGN.md (widget patterns section), FEATURES.md,
PAGES.md, README.md, project_autohop.md, SupportContent.swift + support.html
mirror, privacy copy, NOTICE design-inspiration line, VERSION doc for the
release that ships it. Update this file's ledger.

## 10. Execution ledger

| Stage | Status | Date | Notes |
|---|---|---|---|
| 1 | Complete; install/render validation continues with Stage 2 | 2026-07-20 | Added App Group declarations for app + extension, `AutohopWidgets` XcodeGen target, versioned shared snapshot model, atomic App Group storage and thumbnail directory, static placeholders for all five families, and isolated storage/contract characterization tests. `xcodegen generate`, plist/project inspection, and standalone iOS extension type-check completed. Kevin confirmed Developer Portal association of `group.com.kevinperry.autohop` with both `com.kevinperry.autohop` and `com.kevinperry.autohop.widgets` on 2026-07-20. |
| 2 | Implementation complete; Kevin build/device gate pending | 2026-07-20 | Added root-owned `WidgetSnapshotCoordinator`, narrow queue/playback/presentation triggers, cancellation-safe coalescing, stable-identity projection, downloaded-only fallback, app-side bounded JPEG preparation, atomic snapshot publication, current-plus-previous artwork retention, visible-state hash deduplication, targeted WidgetKit reloads, and greppable publication diagnostics. Home Screen small/medium/large now render live, family-bounded local artwork with explicit empty, 24-hour stale, and unreadable recovery states; accessory families remain static for Stage 4. Test composition roots disable App Group publication by default. Storage characterization now covers thumbnail lifecycle and stale policy. `xcodegen`, plist, extension type-check, and source checks completed; Kevin must build/install and confirm live refresh on-device before Stage 3 authorization. |
| 3 | Implementation complete; device gate pending | 2026-07-20 | Added shared `PlayAutohopEpisodeIntent` with target-specific execution witnesses, live-store stable-identity revalidation, downloaded-only toggle/Play Now delegation to existing transport, post-action republish, and intent diagnostics. Registered `autohop://`; added strict parser and typed routes for Player, Up Next, Episode Detail, and Discover; wired links and optimistic Toggle controls into Home Screen families. Stale selections and malformed routes fail safely. Parser/security tests added. |
| 4 | Implementation complete; locked-device/StandBy gate pending | 2026-07-20 | Replaced accessory placeholders with live circular Up Next count and rectangular current/next metadata. Rectangular title/podcast text is privacy-sensitive; accessories use accentable system rendering, omit artwork, and link through validated routes. Overnight locked-device and StandBy appearance checks remain physical-device gates. |
| 5 | Deferred by product decision | 2026-07-20 | Discovery/Stats widget concepts intentionally skipped. They require a fresh later product decision and are not advertised as shipped. |
| 6 | Code hardening complete; real-device audit pending | 2026-07-21 | Added corrupt-snapshot removal, 1 MB thumbnail read ceiling, mapped local reads, 24-hour stale behavior, bounded 1/2/5 artwork loading, current-plus-previous thumbnail GC, stable dedupe across regenerated episode UUIDs, archived/downloaded-state revalidation, cancellation-safe publication, test-root isolation, and greppable publish/intent/route diagnostics. BGAppRefresh/BGProcessing now suppress projection/artwork/write/reload work, accumulate reason tokens, and resume one coalesced publication only under foreground/active-audio execution; `background.wakeSummary` reports how many widget events were deferred. Automated storage, parser, and background-wake summary characterizations cover corruption, path traversal, oversized keys, reserved-character identity, artwork lifecycle, and diagnostic counter settlement. A real overnight reload-frequency log, first-unlock/reboot pass, background-download observation, and device extension-memory measurement remain required because they cannot be proven by source tests. |
| 7 | Documentation complete; website deployment separate | 2026-07-20 | Updated DESIGN.md, FEATURES.md, PAGES.md, README.md, project_autohop.md, VERSION_1.4.md, SupportContent.swift and its support.html mirror, privacy.html local App Group disclosure, NOTICE design-inspiration credit, and in-app Acknowledgements. All claims describe the implemented adaptive widget; Stage 5 concepts remain deferred. Website files are updated in the existing dirty sibling repository but were not deployed as part of this code stage. |
