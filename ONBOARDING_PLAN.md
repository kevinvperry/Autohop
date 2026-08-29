# Autohop — New User Onboarding: Implementation Plan

<!--
AI CONTEXT — ONBOARDING_PLAN.md
Phased, code-grounded build plan for the onboarding strategy in ONBOARDING.md.
Includes the final UI copy deck (§Copy Deck) — every string is drafted here so
implementation is copy-complete. Each phase lists files touched, steps, copy,
and acceptance criteria. Grounded in the real launch architecture: RootView owns
the local NavigationPath. Decomposition Stage 5 moved real-subscription
counting, reconciliation, first-subscription coalescing, tip policy, and toast
state to App/OnboardingCoordinator.swift. Typed presentation output flows
through App/AppRoutingCoordinator.swift; AppState names below are compatibility
façades or historical implementation notes. PlayerView remains the permanent
root. AppSettings holds first-run
flags following the existing *Migrated flag pattern (Models/AppSettings.swift,
applied in AppState.swift ~L747); subscribe paths are SubscriptionStore.add()
and activateAndMoveToTop(); PodcastsView already uses ContentUnavailableView.
When a phase ships, update FEATURES.md (First-Run Experience), SupportContent.swift
+ website support.html (Getting Started), and PAGES.md (Welcome screen).
-->

**Companion to:** [`ONBOARDING.md`](ONBOARDING.md) (strategy & rationale).
**Status:** Phases 0–7 implemented 2026-06-19 (demo episode deferred — needs a real audio asset).

### Build progress
- ✅ **Phase 0** — `AppSettings` first-run flags (`hasCompletedWelcome`,
  `hasSubscribedFirstShow`, `hasPlayedFirstEpisode`, `hasSeenDownloadFirstNote`,
  `dismissedGettingStarted`); `AppState.realSubscriptionCount` /
  `isFirstRunNoSubscriptions` / OnboardingCoordinator milestone output (wired into the
  existing `subscriptionStore.objectWillChange` sink); bootstrap reconciliation marks
  existing users onboarded; `.autohopFirstSubscription` notification declared.
- ✅ **Phase 1** — empty `PlayerView` state (no-subs → Find shows; subscribed-but-
  downloading variant); rich `PodcastsView` empty state (Find shows + working OPML
  import via `fileImporter`); warmer Up Next + Listening History empty copy.
- ✅ **Phase 2** — launch routing in `RootView` (first-run → Welcome fullScreenCover;
  post-onboarding → the user's **Open at launch** preference, §15.0 / `AppSettings.launchScreen`
  — Player / Subscriptions / Discover. This superseded the original "subscribed-but-never-played
  → Subscriptions" re-entry rule); new
  `Views/WelcomeView.swift` (Find shows / Import / Skip); `hasPlayedFirstEpisode` set in
  `startPlayback` (Phase 4b brought forward so the re-entry rule clears). Registered in
  PAGES.md + FEATURES.md §18; `xcodegen generate` run.
- ✅ **Phase 3** — `Views/FirstSubscribeCard.swift`, presented by `RootView` on
  `.autohopFirstSubscription`: success haptic, ensures latest episode downloads
  (`downloadLatestEpisode`), live progress, **Play latest** (plays now or arms a wait
  that auto-starts on download completion → returns to Player), **Add more shows**
  (dismiss). FEATURES.md §18 updated; `xcodegen generate` run.
- ✅ **Phase 4** — one-time download-first note in `FirstSubscribeCard`
  (`hasSeenDownloadFirstNote`); 4b first-play flag done in Phase 2.
- ✅ **Phase 5** — `Views/CoachMark.swift` (`OnboardingTip` + `CoachMarkOverlay`),
  redesigned 2026-08-29 as high-contrast page-scoped guidance. Ten triggers cover
  Discover, Priority Stack, Podcast Detail actions, Player panels/audio, Up Next,
  Stats, Downloads, Sleep Schedule, Settings and per-podcast automation.
  Navigation cancels the owning page's card without marking it seen; Up Next
  mirrors the overlay inside its system sheet.
- ✅ **Phase 6** — Discover first-run starter-packs banner (shown only while
  `realSubscriptionCount == 0`); import success toast (`AppState.onboardingToast` →
  RootView overlay) from the Welcome + empty-state import paths.
- ✅ **Phase 7** — `AppState.subscribeToFeedURLs`; `Views/StarterPacksView.swift`
  (chart-derived genre packs, option 1); 3-panel `WelcomeView` carousel;
  `Views/GettingStartedChecklist.swift` (subscribe/play/reorder + lean-defaults footer
  note; reorder signal in `PodcastsView.onMove`); `sleepSchedule` power coach mark.
  **Deferred:** bundled demo episode — needs a real audio asset and special
  playback-engine handling for a non-downloaded local file; shipping a stub would be
  worse than its absence. Tracked in FUTURE_VERSIONS.md when picked up.

**All onboarding phases (0–7) are implemented apart from the deferred demo episode.**

---

## How this is sequenced

Seven phases, each independently shippable and each leaving the app in a better
state than before. Phases 0–2 are P0 (do first), 3–6 are P1, 7 is P2 / FUTURE_VERSIONS.

| Phase | Theme | Priority | Depends on |
|---|---|---|---|
| 0 | Foundations: first-run state & flags | P0 | — |
| 1 | Empty states everywhere | P0 | 0 |
| 2 | Launch routing + Welcome screen | P0/P1 | 0 |
| 3 | First-subscribe "You're all set" moment | P1 | 0 |
| 4 | Download-first education + first play | P1 | 0, 3 |
| 5 | Coach-mark / tip system | P1 | 0 |
| 6 | OPML import surfacing | P1 | 1, 2 |
| 7 | Depth: carousel, starter packs, checklist, demo, power tips | P2 | 2, 3, 5 |

All user-visible strings are consolidated in the **Copy Deck** at the end so they
can be localised in one pass; each phase references them by key (e.g. `WELCOME_TITLE`).

---

## Phase 0 — Foundations: first-run state & flags

**Goal:** add the persisted first-run state the rest of the work reads. No visible change.

**Files:**
- `Models/AppSettings.swift` — add flags (follow the exact existing pattern used by
  `playbackSpeed160Migrated` et al.: stored property, `Self.default` value, `CodingKeys`
  case, memberwise-init param + assignment, and `decodeIfPresent(...) ?? default` in the
  decoder so existing users decode cleanly).
- `App/AppState.swift` — derived helpers + the first-subscribe detection hook.

**New `AppSettings` fields (all default `false`):**
| Field | Meaning |
|---|---|
| `hasCompletedWelcome` | User has passed (or skipped) the Welcome screen. |
| `hasSubscribedFirstShow` | The user's first ever real (non-browse) subscription has happened. |
| `hasPlayedFirstEpisode` | First audio has actually started at least once. |
| `hasSeenDownloadFirstNote` | The one-time "downloads so it plays offline" note has shown. |
| `dismissedGettingStarted` | Getting-Started checklist permanently dismissed (Phase 7). |

Coach-mark "seen" flags (Phase 5) live in `UserDefaults` under `tip.*` keys, not in
`AppSettings`, so they stay lightweight and don't sync across devices (a tip seen on
iPhone needn't be suppressed on a fresh iPad — but keep that call simple; `UserDefaults`
is fine and per-device by default).

**Derived helpers on `AppState`:**
```swift
/// Real (non-browse) subscriptions only — browse/preview subs have browseDate != nil.
var realSubscriptionCount: Int {
    subscriptionStore.subscriptions.filter { $0.browseDate == nil }.count
}
var isFirstRunNoSubscriptions: Bool {
    !settingsStore.appSettings.hasCompletedWelcome && realSubscriptionCount == 0
}
```

**First-subscribe detection hook:** the two real-subscribe entry points are
`SubscriptionStore.add(parsedFeed:feedURL:)` and `activateAndMoveToTop(subscriptionID:)`
(see `Views/PodcastDetailView.swift:756 subscribe()`, plus `AddFeedView` and OPML import).
Rather than touch every call site, add a single observation in `AppState`: when
`realSubscriptionCount` transitions `0 → ≥1` and `!hasSubscribedFirstShow`, fire
`onFirstSubscription(_ subscription:)` which (a) sets `hasSubscribedFirstShow = true`,
(b) ensures the latest episode is downloading, (c) posts `.autohopFirstSubscription`
for the UI (Phase 3). Note: OPML bulk-import should set `hasSubscribedFirstShow = true`
**silently** (no "You're all set" card for a 40-show import — that moment is for the
deliberate single first subscribe).

**Acceptance:** existing installs decode with no data loss; flags persist across relaunch;
`realSubscriptionCount` ignores browse subs; hook fires exactly once.

---

## Phase 1 — Empty states everywhere (P0, cheapest leverage)

**Goal:** every screen a new user can reach while empty points forward. Uses the
`ContentUnavailableView` pattern already in `PodcastsView`.

**1a. Empty Player (`Views/PlayerView.swift`)** — the headline fix.
When `appState.currentPlayerEpisode == nil` **and** `appState.downloadedQueue.isEmpty`,
replace the placeholder-artwork now-playing panel with a centered empty state:
- Waveform/radio glyph (matches launch art), `EMPTY_PLAYER_TITLE`, `EMPTY_PLAYER_BODY`,
  primary button `EMPTY_PLAYER_CTA` → posts `.autohopOpenDiscover`.
- If `realSubscriptionCount > 0` but queue empty (subscribed, nothing downloaded yet),
  show the *downloading* variant instead: `EMPTY_PLAYER_DOWNLOADING_TITLE` /
  `_BODY` with a secondary `EMPTY_PLAYER_SECONDARY` → Subscriptions.

**1b. Empty Subscriptions (`Views/PodcastsView.swift`)** — upgrade the current terse state.
Replace the existing `ContentUnavailableView("No Podcasts", … "Tap + to search…")`
with a richer custom empty state that teaches the model and offers two actions:
- Title `EMPTY_SUBS_TITLE`, body `EMPTY_SUBS_BODY`, primary `EMPTY_SUBS_CTA_FIND`
  (→ Discover), secondary `EMPTY_SUBS_CTA_IMPORT` (→ OPML import, Phase 6).

**1c. Empty Up Next (`Views/QueueSheetView.swift`)** — `EMPTY_QUEUE_TITLE` / `_BODY`.

**1d. Empty Downloads / History / Stats** — light one-liners only:
`EMPTY_DOWNLOADS_BODY`, `EMPTY_HISTORY_BODY`, `EMPTY_STATS_BODY`. (Stats/History likely
already have placeholders; align copy, don't over-build.)

**Acceptance:** no reachable empty screen is a dead end; every primary CTA lands somewhere
that advances the user; copy matches the dark design system (DESIGN.md cards/accent).

---

## Phase 2 — Launch routing + Welcome screen (P0 routing / P1 polish)

**Goal:** a brand-new user lands somewhere that teaches and points to content, not the
empty player; returning users are unaffected; subscribed-but-never-played users never
get dumped on the empty player.

**2a. Launch routing (`Views/RootView.swift`).**
At launch (after the splash), decide the initial `navigationPath`:
- `isFirstRunNoSubscriptions` → present **Welcome** as a full-screen cover over the
  stack. Its primary CTA sets `hasCompletedWelcome = true` and routes (Find shows →
  push `[.podcasts, .discover]`; Import → OPML; Skip → push `[.podcasts]`).
- Else if `realSubscriptionCount > 0 && !hasPlayedFirstEpisode` → **re-entry rule:** push
  `[.podcasts]` so they open on the Priority Stack (one tap from first play), not the
  empty player.
- Else → current behaviour (Player root).
Routing is a *default*: never trap the user — manual navigation to the Player always works.

**2b. Welcome screen (new `Views/WelcomeView.swift`).**
For P0 this can be a single strong screen (not yet the multi-panel carousel — that's
Phase 7). Layout: the existing launch waveform motif, `WELCOME_TITLE`, `WELCOME_BODY`,
then three stacked buttons: `WELCOME_CTA_FIND` (primary, purple), `WELCOME_CTA_IMPORT`
(secondary), `WELCOME_CTA_SKIP` (tertiary text button). Register in PAGES.md.

**Acceptance:** first launch shows Welcome once; after completion it never reappears;
switching CTAs route correctly; returning users with subscriptions skip Welcome; the
re-entry rule holds until `hasPlayedFirstEpisode`.

---

## Phase 3 — First-subscribe "You're all set" moment (P1)

**Goal:** turn the first deliberate subscribe into the "aha" — the queue visibly comes
alive, the latest episode auto-downloads, and Play is one irresistible tap away. (Refined
Idea 2 from the strategy: auto-download yes, no ambush autoplay.)

**Files:** `App/AppState.swift` (hook from Phase 0), a new `Views/FirstSubscribeCard.swift`
sheet/overlay, presented from `RootView` on `.autohopFirstSubscription`.

**Behaviour:**
1. Hook fires (Phase 0) → ensure latest episode of the new show is downloading.
2. Present `FirstSubscribeCard` (a celebratory bottom card; light haptic
   `UINotificationFeedbackGenerator(.success)`): artwork of the show, `FIRST_SUB_TITLE`,
   `FIRST_SUB_BODY` (interpolates the show name), and a live download-progress row.
3. Primary button `FIRST_SUB_CTA_PLAY` — oversized **Play latest**. If the file isn't
   ready it shows `FIRST_SUB_PLAY_PROGRESS` and auto-starts the instant the download lands.
4. Secondary `FIRST_SUB_CTA_MORE` → back to Discover ("Add more shows").
5. *Optional delight:* if the card is still on-screen when the download completes, swap
   the button to a 3-2-1 `FIRST_SUB_AUTOSTART` countdown the user can cancel, then start.

**Edge cases:** OPML bulk import does **not** trigger this card (Phase 0 silent path).
If the user dismisses the card, the queue is still populated and the empty-player CTA
(Phase 1) still guides them.

**Acceptance:** fires only on the first deliberate single subscribe; never autoplays
without the file ready; latest episode is downloading within the hook; haptic + queue
animation present; dismiss is safe.

---

## Phase 4 — Download-first education + first play (P1)

**Goal:** the download-first model never reads as "broken / why won't it play".

**4a. One-time download note.** The first time any episode is downloading and
`!hasSeenDownloadFirstNote`, show a single quiet inline note (in `FirstSubscribeCard`
and/or the downloading empty-player variant): `DOWNLOAD_FIRST_NOTE`. Set the flag.

**4b. First-play flag.** When playback first transitions to playing,
set `hasPlayedFirstEpisode = true` (clears the Phase 2 re-entry rule).

**4c. Post-first-play Player nudge (light).** Once an episode is loaded, offer the
single Player coach mark (Phase 5) covering its panels and sound controls. It
includes speed, Trim Silence, Vocal Boost and Shared Listening without stacking
separate cards. Not before playback is available.

**Acceptance:** note shows at most once; first-play flag flips reliably; one combined
Player tip is the only coach card introduced at first play.

---

## Phase 5 — Coach-mark / tip system (P1)

**Goal:** a small reusable, unmistakable and navigation-safe tip system (strategy §6).

**Files:** `Views/CoachMark.swift` (a reusable white/black card deliberately unlike
ordinary Autohop UI) + `OnboardingCoordinator`, which enforces one visible card,
reads/writes `tip.<key>.seen`, owns page-navigation cancellation and caps a process
session at ≤3 distinct presented tips.

**Tips (each fires on first arrival at its surface / first relevant event):**
| Key | Surface / trigger | Copy keys |
|---|---|---|
| `discover` | First Discover arrival | charts, country/category browsing, search and previews |
| `priorityStack` | `PodcastsView` with ≥1 show | automatic order and reordering |
| `swipeActions` | Subscribed Podcast Detail | episode quick actions |
| `playerPanels` | Player with an episode | panels, processing controls and Shared Listening |
| `upNext` | First Up Next arrival | automatic order, swipes and pins |
| `stats` | First Stats arrival | periods and expandable show detail |
| `downloads` | First Downloads arrival | transfers, device storage and archive lifecycle |
| `sleepSchedule` | First Sleep Schedule arrival | prompt/fade/rewind behavior |
| `settings` | First Settings arrival | Auto Archive, Release Radar and iCloud Sync |
| `subscriptionAutomation` | First Podcast Settings arrival | per-show rules, Play Instant and Auto Archive |
| `feedFilters` | First Download Feed Filters arrival | automatic-only scope, Include/Exclude precedence, All/Any and Preview Matches |

Rules: one at a time; the prominent ✕ or full-width confirmation dismisses + sets
seen; navigating away cancels without setting seen; everything taught is also
permanently in Menu → Support. The ≤3/session budget spreads coverage naturally.

**Acceptance:** never more than one visible; never re-shows after explicit close;
never survives its owning page; ≤3 explicitly dismissed in session 1; all controls
remain reachable with large Dynamic Type. Dedicated first-run cards use the same
white/black treatment. Getting Started supersedes Priority Stack, and the zero-
subscription Starter Packs nudge supersedes the Discover coach mark, so those
surfaces never overlap.

---

## Phase 6 — OPML import surfacing for switchers (P1)

**Goal:** the whole target market is leaving Apple Podcasts / Pocket Casts / Overcast —
let them refill instantly. Import already exists (`§13`, Settings → Subscriptions) but is
buried.

**Steps:** wire the existing OPML import flow to the new entry points added above:
- Welcome `WELCOME_CTA_IMPORT` (Phase 2).
- Subscriptions empty state `EMPTY_SUBS_CTA_IMPORT` (Phase 1b).
- Optionally a one-line hint in Discover for first-run users: `IMPORT_HINT`.
On successful import, set `hasSubscribedFirstShow = true` silently (no first-subscribe
card), show a confirmation toast `IMPORT_DONE` (interpolates count), and route to the
Priority Stack so the now-full library is the payoff.

**Acceptance:** import reachable in ≤1 tap from Welcome and the empty Subscriptions state;
no first-subscribe card on bulk import; success toast + lands on a populated Priority Stack.

---

## Phase 7 — Depth (P2 / mostly FUTURE_VERSIONS)

Park these in `FUTURE_VERSIONS.md`; build after P0/P1 prove out.

- **Welcome carousel** — promote the single Welcome (Phase 2b) to 2–3 swipeable panels
  with the differentiators: `WELCOME_P2_*`, `WELCOME_P3_*` copy below.
- **Starter packs / curated bundles** — `STARTER_*` copy; one-tap subscribe to a curated
  set per category, reusing the subscribe/OPML plumbing.
- **Getting-Started checklist** — dismissible momentum card: `CHECKLIST_*` copy; reads the
  Phase 0/4 flags for completion state.
- **Bundled demo episode** — a tiny pre-loaded "Welcome to Autohop" clip so the player is
  playable before any download; `DEMO_*` copy.
- **Lean-defaults expectation line** — `DEFAULTS_NOTE` surfaced once near first auto-archive.
- **Progressive power-feature tips** — Sleep Schedule / Trim Silence / Shared Listening,
  triggered contextually in later sessions.

---

## Copy Deck

> Voice: warm, plain, confident, second person. Short. No jargon ("Priority Stack" is the
> one term we teach). Australian/UK spelling to match the app. `{show}` / `{count}` are
> interpolation slots.

### Welcome (Phase 2 / 7)
- `WELCOME_TITLE` — **"Welcome to Autohop"**
- `WELCOME_BODY` — "Subscribe to your shows and Autohop does the rest — it downloads the latest episodes, builds Up Next, and just plays. Like radio, but only your podcasts."
- `WELCOME_CTA_FIND` — "Find shows"
- `WELCOME_CTA_IMPORT` — "Import from another app"
- `WELCOME_CTA_SKIP` — "I'll explore on my own"
- *(Carousel, Phase 7)*
  - `WELCOME_P2_TITLE` — "Listen your way"
  - `WELCOME_P2_BODY` — "Speed things up, trim the silences, and boost voices so every word is clear — automatically, on every episode."
  - `WELCOME_P3_TITLE` — "Made for real life"
  - `WELCOME_P3_BODY` — "A sleep schedule that fades out when you nod off, and one-tap shared listening for the car. Set it once and forget it."

### Empty Player (Phase 1a)
- `EMPTY_PLAYER_TITLE` — "Nothing playing yet"
- `EMPTY_PLAYER_BODY` — "Subscribe to a show and Autohop fills your queue automatically. Your latest episodes land here, ready to play."
- `EMPTY_PLAYER_CTA` — "Find shows"
- `EMPTY_PLAYER_DOWNLOADING_TITLE` — "Getting your first episode"
- `EMPTY_PLAYER_DOWNLOADING_BODY` — "Autohop is downloading the latest episode so it plays instantly and works offline. This only takes a moment."
- `EMPTY_PLAYER_SECONDARY` — "View subscriptions"

### Empty Subscriptions (Phase 1b)
- `EMPTY_SUBS_TITLE` — "Your Priority Stack is empty"
- `EMPTY_SUBS_BODY` — "Add the shows you love. Autohop plays the newest episode from each, top to bottom — drag to set the order once you've subscribed."
- `EMPTY_SUBS_CTA_FIND` — "Find shows"
- `EMPTY_SUBS_CTA_IMPORT` — "Import subscriptions"

### Empty Up Next / Downloads / History / Stats (Phase 1c/1d)
- `EMPTY_QUEUE_TITLE` — "Up Next builds itself"
- `EMPTY_QUEUE_BODY` — "As you subscribe and episodes download, they line up here in priority order — newest first, ready to play."
- `EMPTY_DOWNLOADS_BODY` — "Downloaded episodes appear here. Autohop keeps your queue stocked automatically in the background."
- `EMPTY_HISTORY_BODY` — "Episodes you've listened to will show up here, newest first."
- `EMPTY_STATS_BODY` — "Start listening and Autohop will track your time, your streak, and how much time you've saved."

### First subscribe (Phase 3)
- `FIRST_SUB_TITLE` — "You're all set 🎧"
- `FIRST_SUB_BODY` — "Autohop is downloading the latest episode of {show}. When it's ready it'll start Up Next — no tapping play, episode after episode."
- `FIRST_SUB_CTA_PLAY` — "Play latest"
- `FIRST_SUB_PLAY_PROGRESS` — "Downloading… we'll start the moment it's ready"
- `FIRST_SUB_AUTOSTART` — "Starting in {count}…"
- `FIRST_SUB_CTA_MORE` — "Add more shows"

### Download-first education (Phase 4)
- `DOWNLOAD_FIRST_NOTE` — "Autohop downloads episodes before playing, so they start instantly and work offline — even with no signal."

### Coach marks (Phase 5)
- `TIP_PRIORITY_TITLE` — "This is your Priority Stack"
- `TIP_PRIORITY_BODY` — "Autohop plays the newest episode from each show, top to bottom. Tap Reorder and drag to set what comes first."
- `TIP_SWIPE_TITLE` — "Swipe for quick actions"
- `TIP_SWIPE_BODY` — "Swipe any episode to Play Next or Play Last, or to Archive it. No menus needed."
- `TIP_PANELS_TITLE` — "Three swipes, one player"
- `TIP_PANELS_BODY` — "Swipe between Playing, Details and Chapters. Sound Controls sets speed, Trim Silence, Vocal Boost and Shared Listening; each show remembers its own choices."
- `TIP_GOT_IT` — "Got it — close tip"

### OPML import (Phase 6)
- `IMPORT_HINT` — "Coming from another app? Import your subscriptions in seconds."
- `IMPORT_DONE` — "Imported {count} shows — welcome aboard."

### Starter packs (Phase 7)
- `STARTER_TITLE` — "Not sure where to start?"
- `STARTER_BODY` — "Pick a few and we'll set you up instantly. You can change anything later."
- `STARTER_CTA` — "Add these shows"

### Getting-Started checklist (Phase 7)
- `CHECKLIST_TITLE` — "Getting started"
- `CHECKLIST_1` — "Subscribe to your first show"
- `CHECKLIST_2` — "Play an episode"
- `CHECKLIST_3` — "Set your listening speed"
- `CHECKLIST_4` — "Reorder your Priority Stack"
- `CHECKLIST_DISMISS` — "Dismiss"

### Demo episode (Phase 7)
- `DEMO_TITLE` — "Welcome to Autohop"
- `DEMO_BODY` — "A quick tour you can listen to right now — try changing the speed and skipping ahead."

### Lean defaults (Phase 7)
- `DEFAULTS_NOTE` — "Autohop keeps the latest episode and tidies up older ones to save space. Change this per show in its settings."

---

## Cross-doc sync checklist (run when each phase ships)
- **FEATURES.md** — add/extend a "First-Run Experience" section.
- **SupportContent.swift** + website **support.html** — mirror any new "Getting Started"
  guidance (the two must stay in lockstep).
- **PAGES.md** — register `WelcomeView` (and any new sheet).
- **FUTURE_VERSIONS.md** — park Phase 7 items not in the immediate build.
