# Autohop — New User Onboarding: Implementation Plan

<!--
AI CONTEXT — ONBOARDING_PLAN.md
Phased, code-grounded build plan for the onboarding strategy in ONBOARDING.md.
Includes the final UI copy deck (§Copy Deck) — every string is drafted here so
implementation is copy-complete. Each phase lists files touched, steps, copy,
and acceptance criteria. Grounded in the real launch architecture: RootView owns
navigationPath + the PlayerView-as-permanent-root; AppSettings holds first-run
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
  `isFirstRunNoSubscriptions` / `checkFirstSubscriptionMilestone()` (wired into the
  existing `subscriptionStore.objectWillChange` sink); bootstrap reconciliation marks
  existing users onboarded; `.autohopFirstSubscription` notification declared.
- ✅ **Phase 1** — empty `PlayerView` state (no-subs → Find shows; subscribed-but-
  downloading variant); rich `PodcastsView` empty state (Find shows + working OPML
  import via `fileImporter`); warmer `QueueSheetView` + Listening History empty copy.
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
- ✅ **Phase 5** — `Views/CoachMark.swift` (`OnboardingTip` + `CoachMarkOverlay`);
  AppState `requestTip`/`dismissActiveTip` (one-at-a-time, seen flags, ≤3/session);
  triggers in `PodcastsView` (priorityStack), `PodcastDetailView` (swipeActions),
  `PlayerView` (playerPanels + speed). Overlay mounted in `RootView` behind sheets.
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

**1c. Empty Queue (`Views/QueueSheetView.swift`)** — `EMPTY_QUEUE_TITLE` / `_BODY`.

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

**4c. Post-first-play speed nudge (light).** After the first episode *starts*, queue a
single coach mark (Phase 5) about playback speed — Autohop's defining control:
`TIP_SPEED_TITLE` / `_BODY`. Not before first play.

**Acceptance:** note shows at most once; first-play flag flips reliably; speed tip is the
only thing introduced at first play (no feature pile-on).

---

## Phase 5 — Coach-mark / tip system (P1)

**Goal:** a small reusable, non-annoying tip system (strategy §6).

**Files:** new `Views/CoachMark.swift` (a reusable purple-accented card matching
`Blocks-Support` / settings cards) + a tiny `TipCenter` in `AppState` that enforces
"one visible at a time", reads/writes `tip.<key>.seen` in `UserDefaults`, and caps the
first session at ≤3.

**Tips (each fires on first arrival at its surface / first relevant event):**
| Key | Surface / trigger | Copy keys |
|---|---|---|
| `priorityStack` | First time `PodcastsView` shows with ≥1 sub | `TIP_PRIORITY_TITLE` / `_BODY` |
| `swipeActions` | First episode-list / Queue view | `TIP_SWIPE_TITLE` / `_BODY` |
| `playerPanels` | First time the Player has an episode | `TIP_PANELS_TITLE` / `_BODY` |
| `speed` | After first play (Phase 4c) | `TIP_SPEED_TITLE` / `_BODY` |

Rules: one at a time; "Got it" dismisses + sets seen; outside-tap dismisses; everything a
tip teaches is also permanently in Menu → Support. Power-feature tips (Sleep Schedule,
Trim Silence, Shared Listening) are spread across later sessions, not first-run.

**Acceptance:** never more than one visible; never re-shows after "Got it"; ≤3 in session 1;
all dismissible; no blocking modality.

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

### Empty Queue / Downloads / History / Stats (Phase 1c/1d)
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
- `TIP_PANELS_BODY` — "Swipe across to see episode details and chapters. Everything stays in one place while you listen."
- `TIP_SPEED_TITLE` — "Find your speed"
- `TIP_SPEED_BODY` — "Tap the sound controls to set your speed and trim silences. Each show remembers its own settings."
- `TIP_GOT_IT` — "Got it"

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
