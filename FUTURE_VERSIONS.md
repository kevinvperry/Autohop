# Autohop — Future Versions

A running list of goals and ideas for versions *after* the v1 App Store launch.
Items here are deliberately **out of scope for v1** — parked so they aren't lost.

**How this list works:** add ideas as they come up, keep each entry short with a
one-line rationale, and note when something graduates into an active version.
Group by theme as the list grows.

**Status legend:** 💡 idea · 🔜 planned for next version · 🏗️ in progress · ✅ shipped (move to a release note)

---

## Onboarding

*(The first-run experience — Welcome carousel, launch routing, empty states,
first-subscribe card, coach marks, starter packs, getting-started checklist — shipped;
see ONBOARDING_PLAN.md. This is the one deferred piece.)*

- 💡 **Bundled "Welcome to Autohop" demo episode** — a tiny pre-loaded audio clip so a
  brand-new user can try the player (speed, skip, scrubber, chapters) *before* anything
  downloads, since playback is download-first. Deferred from Phase 7: needs a real audio
  asset plus special playback-engine handling for a non-downloaded local bundle file
  (and care not to pollute the Priority Stack / stats with a synthetic subscription).

---

## Polish

- 💡 **iOS 18 Dark + Tinted icon variants** — a nice-to-have polish (the icon shows
  differently in dark/tinted home screens). Apple does **not** require them; if you
  don't provide them, iOS auto-generates a tinted version. Skipped for v1; add in a
  later update for the extra polish.

---

## Share Sheet

*(Tier 1 — capture episode `<link>` + share it — and Tier 2 — `LPLinkMetadata`
rich preview — shipped in v1. These are the remaining tiers.)*

- 💡 **Tier 3 — formatted text blurb for plain-text share targets** (Notes, email,
  SMS): e.g. "Episode — Podcast · 14 Jun 2026 · 1h 19m / Shared via Autohop" plus the
  link. Build from existing title / podcast name / `publishedAt` / `durationSeconds`.
- 💡 **Tier 4 — show episode duration on the share card** itself (e.g. "· 1h 19m"
  next to the date). `durationSeconds` is already available; card currently shows date only.
- 💡 **Niche — Podcasting 2.0 share enrichment** (`<podcast:transcript>`,
  `<podcast:funding>`, `<podcast:chapters>`) — e.g. a "support the show" link. Low
  priority, inconsistently present in feeds.

---

## Ideas parked from v1 scope

*(Items intentionally deferred during the App Store submission roadmap — see
`APPSTORE_ROADMAP.md`.)*

- 💡 **iPad layout + iPad screenshots** — v1 is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`).
  A proper iPad layout is a future-version effort.
- 💡 **Apple Silicon Mac availability** — left off for v1 (untested on Mac); enable in
  App Store Connect once the experience has been validated on macOS.
- 💡 **Screenshot polish** — Shared Listening shown ON, Subscriptions captured from #1,
  a Stats *heatmap* variant, and benefit-first caption overlays.

---

## Competitive gaps (vs. Apple Podcasts, Overcast, Pocket Casts)

*From a June 2026 feature comparison against the three key competitors. On feature
count Autohop wins, but it has structural gaps that decide whether a new user keeps
the app. Ordered roughly by how much each one caps the addressable market.*

### Tier 1 — market-capping gaps (the ones that actually lose users)

- 🔜 **Opt-in iCloud sync across devices — TOP PRIORITY for next version.** Biggest
  single competitive liability today: lose the phone, lose everything (history,
  position, stats; only OPML survives). Apple and Pocket Casts sync seamlessly; for
  many users this is the sole reason they won't switch. Implemented as **opt-in
  CloudKit sync** so the on-device privacy stance ("your stats never leave this
  device") is preserved as the default — sync is a user choice, off until enabled.
  Scope to settle when planning: which data syncs (subscriptions + priority order,
  playback position, listening history, stats, per-podcast settings), conflict
  resolution across devices, and how the privacy copy is reworded once sync exists.
- 💡 **Streaming / instant play (no download wait)** — currently download-only. Real
  reliability/offline benefit, but every competitor lets you tap an episode and hear
  it now. New users feel the wait as friction before they read the rationale.
  Consider a "stream while downloading" / play-from-partial-download path so the
  download-first architecture stays intact.
- 💡 **Cross-platform reach (Android / web / desktop / CarPlay-watch)** — iOS-only
  caps the market hard (Pocket Casts is everywhere). Overcast is also iOS-only so
  Autohop isn't uniquely crippled, but the moment a user has an Android phone, work
  PC, or car head unit, Autohop is invisible. Huge effort; park as a long-term
  strategic question, not a v2 item. Near-term cheaper win: solid **CarPlay** support
  if not already complete.

### Tier 2 — competitive parity / polish

- 💡 **Recommendations / curation in Discover** — current Discover is iTunes/Apple
  chart feeds, exactly what everyone else has. It matches, doesn't win. Add personal
  recommendations, "because you listen to…", or editorial curation to differentiate.
- 💡 **Richer queue/playlist flexibility** — priority-stack auto-queue is a genuine
  strength, but offer optional manual playlists / smart filters (à la Overcast
  playlists, Pocket Casts filters) for users who want more control than the stack.

### Lean into the wins (marketing + product, not gaps)

*These are where Autohop already beats the field — protect and promote them, and
keep extending the lead rather than chasing parity everywhere.*

- 💡 **Sleep Schedule** (recurring window + "are you still listening?" rewind) — a
  genuinely novel feature no competitor has. Lead marketing with it: position Autohop
  as "the best-sounding, most automated podcast player on iPhone for people who fall
  asleep listening."
- 💡 **Audio processing depth** (4-level Vocal Boost, 3-level Trim Silence) — matches
  or beats Pocket Casts/Overcast, buries Apple (no silence trim or volume boost in
  2026). Keep as a headline differentiator.
- 💡 **One-tap shared/group speed override** and **priority-stack + auto-archive
  automation** — small but unique; nobody else has the one-tap group override.
- 💡 **Website comparison table** — build a tightened ~8-row version showing only the
  rows where Autohop clearly wins or ties, for kevmarl.com (don't claim raw
  "more features than Pocket Casts" — claim the lean-back/audio-quality angle).
