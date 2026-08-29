# Autohop Onboarding Audit — 29 August 2026

<!--
AI CONTEXT — Docs/ONBOARDING_AUDIT_2026-08-29.md
Implementation audit of the iOS-family first-run experience after the 2026-08-29
coach-mark redesign. This records shipped behavior, not a proposal. Keep the
coverage table aligned with Views/CoachMark.swift and FEATURES.md section 18.
-->

## Outcome

The first-run Welcome, Starter Packs, first-subscription card, download-first
note, checklist and forward-pointing empty states remain accurate. The coach-mark
layer was the material defect: it used app-like dark/purple styling, had a quiet
text dismissal, knew nothing about the page that requested it, and covered only
five features. A tip could therefore remain visible after its page disappeared.

The repaired system uses a white card with black text, a 48-point black close
button and a full-width black confirmation button. Each requesting view owns its
tip through `onboardingTip(_:when:)`; `onDisappear` cancels that tip without
marking it seen. Explicit close actions alone persist the seen flag.

The follow-up visual audit found two dedicated onboarding surfaces outside the
coach-mark renderer: the Subscriptions **Getting Started** checklist and the
first-subscription **You're all set** sheet. Both now use the same white/black,
high-contrast language and 48-point close control. The Discover Starter Packs
nudge is white/black as well; Starter Pack result cards remain ordinary content
cards because they are selectable podcast bundles rather than advice.

Subscriptions never presents its checklist and Priority Stack coach mark
together. The checklist contains the reorder lesson, so showing it marks that
redundant coach mark seen. Discover likewise defers its general coach mark while
the zero-subscription Starter Packs nudge is visible. Welcome remains a distinct
full-screen purple introduction rather than a floating advice card.

## Current contextual coverage

| Surface | Tip teaches | Eligibility |
|---|---|---|
| Discover | charts, countries/categories, search and preview-before-subscribe | first arrival after the zero-subscription Starter Packs nudge no longer applies |
| Subscriptions | automatic Priority Stack order and manual reordering | at least one visible subscription and no Getting Started checklist |
| Podcast Detail | Play Next, Play Last and Archive swipe actions | after at least one real subscription |
| Player | Playing/Details/Chapters panels plus speed, Trim Silence, Vocal Boost and Shared Listening | an episode is loaded |
| Up Next | automatic queue construction, swipes and pinned overrides | first sheet arrival |
| Stats | this/last periods, Lifetime and expandable Top Show detail | first page arrival |
| Downloads | active, device-local and recently archived downloads | first page arrival |
| Sleep Schedule | prompt/fade/rewind behavior | first page arrival |
| Settings | Auto Archive, learned Release Radar and private iCloud Sync | first page arrival |
| Podcast Settings | per-show playback/download rules, Play Instant and Auto Archive | first page arrival |
| Download Feed Filters | automatic-only scope, Include/Exclude precedence, All/Any matching and Preview Matches | first filter-page arrival |

Listening History, Search results and ordinary detail pages use clear established
list/navigation patterns and do not receive cards solely to increase the count.
Welcome and the first-subscription milestone remain dedicated onboarding surfaces,
not coach marks. Tips remain one-at-a-time, one-time after explicit dismissal and
capped at three per process session to prevent first-session overload.

## Accuracy decisions

- Up Next is described as downloaded episodes ordered from Priority Stack, with
  pins overriding automatic order.
- Downloads are explicitly device-local; iCloud does not sync media files.
- Stats describes current/previous calendar periods and expandable Top Shows.
- Settings describes Release Radar as learned scheduling, not a manual polling
  promise, and iCloud Sync as private library/listening-state sync.
- Player audio guidance includes Shared Listening and current processing controls.
- Play Instant is presented only in per-podcast automation context.
- Download Feed Filters explicitly distinguishes automatic downloads from manual
  actions, explains that Exclude matches always win, and directs users to preview
  the current feed before depending on a rule set.
