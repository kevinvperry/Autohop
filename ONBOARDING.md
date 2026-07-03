# Autohop — New User Onboarding Strategy

<!--
AI CONTEXT — ONBOARDING.md
Strategy + spec for the first-run / new-user experience. Defines the onboarding
mental model, the phased flow, empty-state specs per screen, the coach-mark/tip
system, re-entry logic, and a prioritised rollout. Grounded in the real launch
architecture (RootView's PlayerView-as-permanent-root + AppRoute navigationPath)
and existing first-launch migration flags in AppState. When any onboarding
behaviour ships, reflect it in FEATURES.md (add a "First-Run Experience" section),
the in-app Support guide (SupportContent.swift → "Getting Started"), and the
website support page. Power-feature intros referenced here that aren't yet built
belong in FUTURE_VERSIONS.md.
-->

**Status:** ✅ **IMPLEMENTED** (built 2026-06-19; verified against code 2026-06-26). This
file is the original *strategy/rationale*; the as-built implementation and its phase
breakdown live in `ONBOARDING_PLAN.md`, and the canonical feature description is
**FEATURES.md §18** (Welcome carousel, launch routing, Starter Packs, Getting-Started
checklist, "You're all set" first-subscribe card, coach marks, empty states). Visual specs
are in DESIGN.md "Onboarding — First-Run Components"; screens are registered in PAGES.md.
Drafted 2026-06-19.

---

## 1. The core problem

A first-time user installs Autohop, opens it, and lands on the **empty Player**
(`PlayerView` is the permanent `NavigationStack` root — see `Views/RootView.swift`).
There is no queue, no subscriptions, no obvious "what do I do now". Discover is one
or two taps away behind the `+` button or the hamburger Menu.

But the empty player is only the *symptom*. The deeper problem is that **Autohop's
mental model is unusual and invisible**:

> You don't browse-and-tap-play episode by episode. You **subscribe** to shows, rank
> them, and Autohop **auto-builds a download-first queue** that walks your Priority
> Stack and **just plays** — like a personal radio station for your shows.

Three things about that model trip up newcomers, and onboarding must teach all three:

1. **Priority Stack = the engine, not just a list.** Subscribing isn't bookmarking;
   it feeds an automatic queue. This is the single most important concept.
2. **Download-first, no streaming.** Autohop only plays files already on device
   (`§7 Downloads`). A user from a streaming app will tap play and wonder why there's
   a wait. This needs proactive explanation, once.
3. **Aggressive-by-design lifecycle.** Defaults like Episode Limit = 1 and Auto
   Archive "After Playing" (`§10.4`) keep storage lean, but to a newcomer episodes
   can seem to "vanish". The fresh-subscription backlog exemption already softens
   this; onboarding should still set the expectation.

**Design goal:** get a new user from install → first subscription → first audio in
their ears, with the Priority Stack model understood, in under ~60 seconds, without
forcing anything or asking for permissions up front.

---

## 2. Design principles

These constrain every idea below.

1. **Teach the model, don't just fill the screen.** The win isn't "show Discover",
   it's "user understands subscribe = auto-queue".
2. **Never force playback or permissions.** No autoplaying audio into a silent room,
   no notification/tracking prompts at launch. (The app already correctly defers
   notification permission until opt-in — `§14`. Hold that line.)
3. **Empty states are the cheapest, highest-leverage fix.** Every screen a new user
   can reach while empty must point forward. This is P0 and mostly free.
4. **Progressive disclosure.** Basics first (subscribe → play). The power features —
   Sleep Schedule, Vocal Boost, Trim Silence, Shared Listening, Chapters filter —
   are introduced contextually *after* the basics land, never crammed into first run.
5. **Skippable and quiet.** Any welcome flow is dismissible in one tap. Coach marks
   appear one at a time, remember dismissal, and never block.
6. **Lean on what already exists.** Browse subscriptions, the fresh-subscription
   backlog exemption, the latest-episode principle, and the Support guide are already
   built — onboarding should orchestrate them, not reinvent them.

---

## 3. Evaluation of the three proposed ideas

### Idea 1 — Open in Discover until the first subscription ✅ (refine)

**Verdict: do it, but route to a Welcome step first, not cold into the charts.**

Dropping a brand-new user straight into the Discover charts is better than the empty
player, but the charts are dense (Top-8 hero + 10 genre rails + 2 country spotlights,
`§2.6`) and they explain *nothing* about how Autohop works. The user still doesn't
know that tapping subscribe builds a queue.

Recommended: on first launch with **zero real subscriptions**, show a short **Welcome**
screen (§4, Phase 0) whose primary button drops them into Discover. After they have
≥1 real (non-browse) subscription, launch returns to normal.

**Implementation:** in `RootView`, seed `navigationPath` at launch based on
`subscriptionStore`'s real-subscription count.
- 0 real subs → present Welcome, then push `[.podcasts, .discover]`.
- ≥1 real sub → current behaviour (Player root; Subscriptions one back).
Gate "real" on `browseDate == nil` so invisible browse/preview subs (`§2.4`) don't
count as "they've subscribed". Track completion with a `hasCompletedWelcome` flag in
`AppSettings`/UserDefaults, mirroring the existing first-launch migration flags
(`playbackSpeed160Migrated`, etc.) in `AppState`.

**Don't fight the user:** if they manually navigate to the Player, let them stay. The
launch routing is a *default*, not a cage.

### Idea 2 — First subscribe auto-downloads + auto-plays latest ✅ download / ⚠️ play

**Verdict: auto-download yes (already aligned with the latest-episode principle).
Auto-*play* — don't blast audio; cue it up and make "Play" a one-tap, irresistible
moment.**

Why not literal autoplay:
- **The download-first constraint makes autoplay awkward.** You can't play until the
  file is on device (`§7`). On first subscribe that's a several-second silent wait —
  autoplay would mean "I tapped subscribe and… nothing, then suddenly audio." Bad.
- **Consent / context.** The user may be on a train with no headphones, or just
  exploring. Audio erupting from a subscribe tap is a classic dark-pattern feel.

Recommended instead — the **"You're all set" moment**:
1. On the user's *first ever* real subscribe, immediately auto-download the latest
   episode (this already happens on subscribe; just make it explicit and visible).
2. Show a celebratory confirmation (haptic + the queue animating to life) that
   teaches the model in one line: *"Nice — Autohop is downloading the latest episode
   of [Show]. When it's ready it'll start your queue."*
3. Surface an oversized **Play latest** button. If the user taps it before download
   finishes, show progress and start the instant it lands.
4. *Optional delight:* if the app is still foregrounded and showing this card when the
   download completes, offer a one-tap auto-start (or a 3-2-1 "starting…" the user can
   cancel). This gets you 90% of the magic of autoplay with none of the ambush.

This converts the first subscribe into the "aha" — the queue visibly comes alive and
audio is one deliberate tap away.

### Idea 3 — Pop-up instruction cards / coach marks ✅ (use sparingly)

**Verdict: yes, but contextual, one-at-a-time, dismissible, and tied to first arrival
at each screen — not a wall of tooltips on day one.**

Good coach-mark targets (each fires the *first* time the user reaches that surface):
- **Priority Stack** (`PodcastsView`): "This is your Priority Stack. Autohop plays the
  newest episode from each show, top to bottom. Drag to reorder." (Most important one.)
- **Swipe actions** (episode rows / Queue): a one-time hint that rows swipe for Play
  Next / Play Last / Archive.
- **Player**: a one-time hint that the player has three swipeable panels (Now Playing /
  Details / Chapters).

Rules: one card visible at a time; "Got it" dismisses; each has its own
`UserDefaults` seen-flag; never more than ~3 in the whole first session; all reachable
again any time via Menu → Support. See §6 for the system spec.

---

## 4. The phased onboarding flow

### Phase 0 — Welcome (first launch, 0 real subscriptions)

A short, skippable value-prop screen (2–3 panels max, or one strong screen). It must
land the mental model, not just look pretty.

- **Panel 1 — the promise:** "Subscribe to your shows. Autohop downloads the latest,
  builds Up Next, and just plays — like radio for your podcasts."
- **Panel 2 — (optional) the differentiators in one line:** trim silence, smart speed,
  sleep schedule, shared listening — "less faff, more listening."
- **Primary CTA:** **Find shows** → Discover.
- **Secondary CTA:** **Import from another app** → OPML import (§5-D). Critical for
  switchers from Apple Podcasts / Pocket Casts / Overcast.
- **Tertiary:** **Skip** → Subscriptions (with its guiding empty state, §5-B).

Set `hasCompletedWelcome = true` on any exit so it never reappears.

### Phase 1 — First subscription

- User picks a show in Discover/Search → Podcast Detail (`§2.2`).
- They tap **Subscribe**. Fire the **"You're all set" moment** (Idea 2 refined).
- Auto-download the latest episode; show the queue populating.
- Coach mark on first arrival at the Priority Stack (§3, Idea 3).

### Phase 2 — First play

- The big **Play latest** affordance starts audio (one tap; waits on download if
  needed with visible progress).
- **First-download education** (one time): when the very first episode is downloading,
  show a single quiet note — *"Autohop downloads episodes so they play instantly and
  work offline."* — so the wait is understood, not mysterious.
- After the first episode *starts*, a contextual tip about playback speed (the player's
  defining feature) is reasonable. Not before.

### Phase 3 — Habit / power features (later sessions)

Introduce one differentiator at a time, triggered by relevant moments:
- After first **completed** episode → tip: set your speed / try Trim Silence.
- After **3+ subscriptions** → tip: drag to reorder your Priority Stack.
- First launch **inside evening hours** with playback → tip: Sleep Schedule.
- Speed/processing changes → the relevant settings already live in Audio Controls.

This is where the "Getting Started checklist" (§5-H) can quietly track momentum.

### Re-entry logic (don't reset to empty)

If a user subscribed but never played, the **next launch should not dump them on the
empty player.** Route to the Subscriptions/Priority Stack (or the Player already cued
with their queued episode) so the path to first-play is one tap, every time, until
they've actually listened.

---

## 5. Additional ideas (beyond the three proposed)

**A. Real empty states on every reachable screen (P0, cheapest win).**
Today the empty Player shows nothing actionable. Every surface a new user can hit
while empty needs a forward pointer:
- *Player empty:* "Nothing queued yet" + **Find shows** button → Discover.
- *Subscriptions empty:* a friendly explainer of the Priority Stack + **Find shows**
  and **Import subscriptions** buttons.
- *Queue empty:* "Your queue fills automatically as you subscribe and download."
- *Downloads empty / History empty / Stats empty:* one-line "what shows up here".
Use the existing `ContentUnavailableView` pattern already used in Search (`§2.1`).

**B. Starter packs / curated bundles (high impact on cold-start).**
A blank library is the real friction, and the charts make the user do all the work.
Offer category bundles — News, Comedy, True Crime, Tech, Sports — each a one-tap
"subscribe to a starter set". Dramatically lowers effort and immediately demonstrates
the Priority Stack with several shows. Source from a curated list or chart data; reuse
the OPML/subscribe plumbing. (Likely a FUTURE_VERSIONS candidate; high ROI.)

**C. Prominent OPML import for switchers (P1).**
OPML import already exists but is buried in Settings → Subscriptions (`§13`). Surface
it in Welcome (§4) and the Subscriptions empty state. The whole target market is people
leaving Apple Podcasts / Pocket Casts / Overcast — let them bring their library in 30
seconds and the app is instantly full and useful.

**D. Proactive download-first education (P1).**
Covered in Phase 2 — one quiet, one-time note so "why isn't it playing instantly"
never becomes a confused 1-star review.

**E. Set-expectations on the lean defaults (P2).**
Episode Limit = 1 + Auto Archive "After Playing" are deliberate (`§10.4`) and the
fresh-subscription backlog exemption already prevents a day-one massacre. Still, a
single line somewhere ("Autohop keeps the latest episode and tidies the rest — change
this per show in Settings") prevents "my episodes disappeared" surprise.

**F. Bundled "Welcome to Autohop" demo episode (consider).**
Because playback is download-first, the player is empty and untouchable until something
downloads. Shipping a tiny pre-bundled audio clip (a 60–90s "here's how Autohop works")
lets a brand-new user *immediately* experience the player — try speed, skip, scrubber,
chapters — before they've subscribed to anything. It doubles as a friendly intro. Nice
delight; evaluate cost/clutter. (FUTURE_VERSIONS candidate.)

**G. Getting-Started checklist / momentum nudge (P2).**
A lightweight, dismissible checklist: ① Subscribe to a show ② Play an episode ③ Set
your speed ④ Reorder your Priority Stack. Gives a sense of progress and surfaces the
next step. Keep it subtle and permanently dismissible.

**H. First-subscribe micro-delight (P1, pairs with Idea 2).**
Haptic + the queue animating to life the moment the first show is added. Reinforces
"it just works" viscerally. Cheap, memorable.

**I. Hold the line on permissions (already correct — keep).**
No notification/ATT/anything prompts at launch. Notification permission stays deferred
to opt-in (`§14`). This is a real differentiator in feel; document it as intentional.

---

## 6. Coach-mark / tip system spec

A small reusable system rather than ad-hoc popovers.

- **One at a time.** Never stack. A queue ensures at most one is visible.
- **Per-tip seen flag** in `UserDefaults` (e.g. `tip.priorityStack.seen`). Once seen,
  never auto-shown again.
- **Trigger = first arrival** at the relevant surface (or first relevant event), not a
  timer and not launch.
- **Dismiss** with an explicit "Got it"; tapping outside also dismisses.
- **Budget:** ≤ 3 in the first session. Power-feature tips spread across later sessions.
- **Always re-findable:** every concept a tip teaches also lives in Menu → Support
  (`§16`) so nothing is lost by dismissing.
- **Style:** matches the dark design system (DESIGN.md) — purple-accented card,
  consistent with `Blocks-Support` / settings cards.

---

## 7. Where this touches the code

- **Launch routing:** `Views/RootView.swift` — seed `navigationPath` from real-sub
  count; present Welcome over the stack when `!hasCompletedWelcome && realSubCount == 0`.
- **First-run flags:** `App/AppState.swift` / `AppSettings` — add `hasCompletedWelcome`,
  per-tip seen flags, `hasPlayedFirstEpisode`. Follow the existing one-shot
  first-launch migration pattern already in `AppState`.
- **Real vs browse subs:** count subscriptions with `browseDate == nil` (`§2.4`,
  Appendix) so previews never count as onboarding completion.
- **First-subscribe hook:** `SubscriptionStore` add path (where new subs snapshot
  default playback prefs) is the natural place to detect "first ever real sub" and fire
  the "You're all set" moment + ensure latest-episode auto-download.
- **Empty states:** `PlayerView`, `PodcastsView`, `QueueSheetView`, `DownloadsView`,
  history/stats views — `ContentUnavailableView`-style, reusing the Search pattern.
- **Welcome screen:** new view, presented from `RootView`.

---

## 8. Prioritised rollout

**P0 — ship first (cheap, high leverage, no new concepts):**
- Empty states on every new-user-reachable screen (§5-A).
- Launch routing: 0 real subs → Discover (with at least a minimal Welcome) (Idea 1).
- Re-entry logic so a subscribed-but-never-played user never sees the empty player (§4).

**P1 — the "aha" + switcher conversion:**
- First-subscribe "You're all set" moment: auto-download latest + cue + one-tap Play +
  micro-delight (Idea 2 refined, §5-H).
- Prominent OPML import for switchers in Welcome + empty state (§5-C).
- One-time download-first education note (§5-D).
- Priority Stack + swipe-actions coach marks (Idea 3, §6).

**P2 — polish / depth (largely FUTURE_VERSIONS):**
- Welcome value-prop carousel with differentiators (§4 Phase 0).
- Starter packs / curated bundles (§5-B).
- Getting-Started checklist (§5-G).
- Bundled demo episode (§5-F).
- Lean-defaults expectation-setting line (§5-E).
- Progressive power-feature tips: speed, trim silence, sleep schedule (§4 Phase 3).

---

## 9. Success criteria

- % of new installs that reach **first subscription** (target the dominant drop-off).
- % that reach **first audio playing**.
- Time from install → first play.
- % of switchers using **OPML import**.
- Retention: day-1 / day-7 of users who completed vs skipped onboarding.

(Stats are on-device and private — `§12` — so any measurement must respect that stance;
prefer local funnel counters over any off-device analytics, consistent with the privacy
footer "Your listening stats never leave this device.")

---

## 10. Keep in sync when this ships

Per the project's source-of-truth discipline:
- **FEATURES.md** — add a "First-Run Experience" section.
- **SupportContent.swift** (in-app Getting Started) **and** website `support.html` — the
  two must stay mirrored.
- **FUTURE_VERSIONS.md** — park P2 items not in the immediate build there.
- **PAGES.md** — register the Welcome screen if added.
