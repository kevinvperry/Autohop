# Autohop — Future Versions

A running list of goals and ideas for versions *after* the v1 App Store launch.
Items here are deliberately **out of scope for v1** — parked so they aren't lost.

**How this list works:** add ideas as they come up, keep each entry short with a
one-line rationale, and note when something graduates into an active version.
Group by theme as the list grows.

**Status legend:** 💡 idea · 🔜 planned for next version · 🏗️ in progress · ✅ shipped (move to a release note)

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
