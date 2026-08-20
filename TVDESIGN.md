# Autohop Apple TV Design System

<!--
AI CONTEXT — Canonical implemented tvOS design and focus contract from rebuild
Phase 5 (26 July 2026). Do not copy iPhone spacing or add bespoke glass layers.
Update this document whenever a TV screen, focus rule, loading state, artwork
size, or navigation contract changes.
-->

## Progressive data states

The TV renders compact cached Library and Up Next projections immediately. A
network refresh updates those values without replacing the navigation tree.
Podcast detail pages request at most 25 episodes and cancel work when dismissed.
“Syncing…” is never used as an indefinite row state: unresolved legacy queue
entries say that episode details are loading, while the page-level status states
whether data is current, cached, updating, unavailable or failed.

## Product hierarchy

Home prioritises Continue Listening/Watching, followed by a compact Up Next
shelf. Up Next is the authoritative phone-authored ordered queue. Library is a
secondary browsing surface. Search is browse-only; subscriptions are managed on
iPhone. Settings exposes truthful sync state and redacted diagnostics.

Dynamic Top Shelf extends that hierarchy onto the Home Screen: live Currently
Playing/Watching owns the first slot, idle Continue content is its fallback,
and Up Next follows in exact order. The featured identity is deduplicated from
the queue even when it originally falls below the ten-item cap. Both Select and
Play/Pause start or resume exact-identity playback. The extension reads a
bounded prebuilt snapshot; the containing app owns all network and image work,
commits immutable artwork before atomically replacing the manifest, and reuses
prepared artwork after a failed publication attempt.

## Layout and typography

- Primary safe-content guides: 80 points horizontal and 60 points vertical.
- Use semantic system typography. Page title: `largeTitle.bold`; section title:
  `title2.semibold`; primary row/title: `headline`; metadata: `subheadline` or
  `caption` with secondary/tertiary styling.
- Episode titles use at most two lines. Podcast titles use one line where space
  is constrained. Focus must never change card dimensions or surrounding layout.
- Lists use stable IDs and lazy containers. Views render immutable display
  models rather than traversing full subscription graphs during focus updates.
- Up Next metadata mirrors iOS: a partially played episode shows remaining time
  and an untouched episode shows total runtime. Synced positions enter the
  immutable row projection in one bounded read, never from the view.
- Tall Settings content relies on automatic focus-driven scrolling. Nearby
  read-only health rows are deliberate focus stops, preventing jumps between
  actionable controls separated by several screens.

## Materials and artwork

- Content and artwork remain opaque and dominant. Standard button/card focus
  effects supply platform appearance.
- Custom material is reserved for hierarchy, not every list row. Ordinary rows
  use a quiet opaque fill to avoid stacked blur/compositing cost.
- Queue artwork decodes to 360 px, library/shelf artwork to approximately
  520 px, detail artwork to 440 px, and the audio-player hero to 1200 px.
- Discover uses separate bounded tiers: 240 px compact results, 440/560/640 px
  shelf cards and 720 px detail artwork. These are decoded pixel targets, not
  source-image layout points; all remain owned by `TVArtworkLoader`.
- The shared decoded artwork cache is capped at 48 MB / 80 images and is purged
  when the app backgrounds or receives memory pressure.

## Focus contract

- Every collection uses stable cross-sync identity. Up Next uses `episodeKey`;
  Library uses subscription UUID.
- Initial focus is the first actionable content item. Disabled legacy rows may
  show while their single podcast feed is enriched, but cannot trap focus.
- Live queue generations preserve IDs. If the focused item disappears, focus
  falls to the next row at that position, then the previous row, then the tab.
- Player dismissal returns to the originating card through the unchanged tab
  view. Video uses the system player and Back dismisses it once.
- Sidebar navigation, directional navigation, Play/Pause and Back are the only
  required primary controls. No touch or swipe assumptions are permitted.
- Avoid timers that replace view trees while the user navigates. Background
  projection updates publish only when Equatable display models change.

## Loading and sync language

- `Up to date`: the newest accepted cached generation was fetched.
- `Updating from iPhone…`: a targeted queue fetch/retry is active.
- `Cached · updated …`: cached data remains usable after bounded recovery.
- `iCloud unavailable` and `Update failed — try again` are explicit failures.
- Legacy Version 1 queue rows say `Loading episode details…`; a bounded,
  per-podcast fetch enriches only those rows. Never leave the indefinite and
  ambiguous label `Syncing…`.

## Diagnostic operations

- Full Diagnostic Export is an asynchronous Settings operation: focus and
  scrolling remain responsive, the button immediately changes to a progress
  label, and repeat activation is disabled until completion.
- Log stitching, privacy redaction and file writing run at utility priority,
  never on the main actor. Completion records duration and output size without
  exposing episode or account identity.
- Invisible CloudKit projection requests are coalesced while the scene is
  inactive and produce one scheduled refresh when focus returns to the app.
- Top Shelf artwork dimensions are pixel contracts, not UIKit point sizes. The
  renderer always uses scale 1; separate 404×608 and 808×1216 outputs provide
  the four-across poster layout without inheriting the television's screen scale.

## Accessibility

- Preserve system focus effects, Reduce Motion and Increase Contrast behaviour.
- Icon-only actions require labels. Metadata reading order follows visual order.
- Video playback uses `AVPlayerViewController` for system transport, subtitles,
  audio tracks and Siri Remote behaviour.
