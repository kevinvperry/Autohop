# Apple TV Discover — Phased Implementation Proposal

<!--
AI CONTEXT — Docs/TVOS_DISCOVER_IMPLEMENTATION_PROPOSAL.md
PURPOSE: Canonical implementation plan for a browse-and-play Discover experience
in the Autohop tvOS app. It translates the current iPhone Discover editorial
decisions into a focus-first television interface without permitting Apple TV
to create, remove or alter subscriptions.
STATUS: PROPOSAL ONLY. A phase becomes complete only after its code, tests,
diagnostics, documentation and physical-device acceptance checks are finished.
NON-NEGOTIABLE AUTHORITY RULE: iPhone remains the sole subscription and priority
author. tvOS Discover may fetch public catalogue/feed data and start transient
playback, but must not create browse subscriptions, write SubscriptionState,
change SubscriptionOrder, add Discover episodes to Up Next, or emit subscription
commands through CloudKit.
SOURCE OF TRUTH: Current code in Views/DiscoverView.swift,
Views/PodcastSearchView.swift, Feeds/PodcastCharts.swift,
Feeds/PodcastSearch.swift, TV/Views, TV/Playback and TV/Navigation.
-->

## 1. Outcome

Add a first-class **Discover** destination to the Apple TV app that feels like
the current iPhone Discover page while respecting television interaction and
the existing cross-device ownership model.

Users will be able to:

- browse Apple Podcasts charts and editorial groupings;
- browse categories using their selected storefront;
- search shows and episodes;
- open a read-only show page;
- read episode descriptions;
- stream an episode immediately through the existing tvOS player;
- return reliably to the same Discover shelf, item and scroll position.

Users will **not** be able to subscribe, unsubscribe, alter podcast priority,
change per-show settings, pin a catalogue episode, add a catalogue episode to
Up Next, archive an unowned catalogue episode, or otherwise mutate the iPhone-
authored library from Discover.

## 2. Product principles

### 2.1 iPhone and Apple TV should feel related, not identical

Retain the iPhone content hierarchy and brand language:

- **Top Episodes**;
- **New & Notable** when at least three credible results exist;
- **Top Podcasts** for the selected storefront;
- international Top Podcast spotlights that do not duplicate the selected
  storefront;
- the same 19 Apple category decisions and storefront-localised names;
- separate **Shows** and **Episodes** in search;
- conservative publisher/creator naming from exact author metadata only.

Adapt presentation for the television:

- use horizontally scrolling shelves and large focusable cards;
- do not auto-advance focused hero cards;
- avoid the iPhone's dense vertical 19-rail feed on initial load;
- preserve focus and shelf position when results update;
- place primary playback behind one predictable Select action;
- use standard long-press menus only for secondary read-only actions such as
  Episode Description.

### 2.2 Discover is a transient catalogue, not a second library

The iPhone preview flow creates a hidden 30-day browse subscription so its
existing podcast page can behave like an owned show. That mechanism must not be
used on Apple TV because it would violate the chosen authoring boundary.

tvOS instead receives immutable catalogue models, keeps bounded caches under
`Caches/Autohop`, and converts only the selected episode into a transient
`Episode` playback request. Nothing is persisted as a `Subscription`.

### 2.3 Existing playback remains the only playback path

Discover must call the same `TVPlaybackCoordinator`, `TVPlaybackModel` and
`StreamingPlaybackEngine` used by Home, Library and History. It must not create
a second `AVPlayer`, player sheet, resume store, speed owner or media-kind
classifier.

## 3. Scope

### Included in the first complete release

1. Discover tab and route hierarchy.
2. Device/storefront-correct Apple charts.
3. Top Episodes, Top Podcasts, New & Notable and category shelves.
4. Dedicated category and chart result pages.
5. Search with separate Shows and Episodes.
6. Read-only show detail and episode detail pages.
7. Direct audio/video streaming.
8. Full episode description access.
9. Loading, empty, offline and retry states.
10. Artwork downsampling, bounded caching and focus restoration.
11. Diagnostics and regression tests.

### Explicitly excluded

- Subscribe and Unsubscribe controls.
- Priority, notification, auto-download or archive settings.
- OPML and RSS URL entry.
- Starter Pack subscription actions.
- Adding a Discover result to Up Next or Play Next.
- CloudKit subscription commands or a new CloudKit record type.
- Host/guest inference. Publisher/creator grouping remains conservative.
- Downloading catalogue episodes for offline playback in the first release.

## 4. Proposed information architecture

### 4.1 Main navigation

Replace the current standalone **Search** tab with **Discover**. Search becomes
the first control within Discover and uses tvOS's native searchable treatment.
This prevents two overlapping catalogue destinations and keeps the sidebar
concise:

1. Home
2. Library
3. Discover
4. History
5. Settings

Up Next is already integrated into Home in the current tvOS shell; this
proposal does not remove a dedicated Queue/Up Next tab as part of Discover.
Likewise, the existing Diagnostics destination is already presented to users as
Settings. The only tab replacement here is **Search → Discover**.

The router gains a dedicated Discover path so nested chart, category, show and
episode pages survive tab changes without resetting.

### 4.2 Discover landing page

Recommended initial order:

1. Search control.
2. Top Episodes hero shelf (8 items).
3. Category chips or compact category shelf.
4. New & Notable shelf, only with at least 3 results.
5. Top Podcasts — selected storefront.
6. First eager category group.
7. International spotlight A.
8. Remaining categories loaded progressively.
9. International spotlight B near the end.

The iPhone 4/5/5/5 editorial cadence remains a content-order reference, but the
TV renderer may group shelves into focus-stable batches rather than reproducing
phone spacing literally.

### 4.3 Child pages

- **Top Episodes:** ranked Top 50, using a television list with artwork, episode
  title, show, publish date and duration where available.
- **Top Podcasts:** ranked Top 50 for the selected storefront.
- **Category:** Top 100 for the existing 19 categories, progressively rendered.
- **Show Detail:** large artwork/header, publisher, category, description and a
  bounded recent episode list. No subscription button.
- **Episode Detail:** title, show, publication date, duration, artwork, full
  description and **Play**.
- **Publisher/Creator results:** read-only list of shows sharing exact cleaned
  author metadata; no inferred people.

## 5. Data architecture

### 5.1 Reuse from `AutohopCore`

- A narrow public chart-provider facade over the existing internal
  `PodcastChartsService` and chart DTOs. `PodcastCharts.swift` already compiles
  inside `AutohopCore`, but its chart models, service and iPhone
  `DiscoverViewModel` are deliberately `internal` and therefore cannot yet be
  imported by the separate `AutohopTV` module. Do not publicise the phone view
  model wholesale and do not duplicate its networking.
- `PodcastSearchService`, including correct storefront handling and independent
  show/episode requests. Unlike charts, the required search providers and
  result DTOs are already public to tvOS.
- `PodcastCreatorGrouping` exact-author rules.
- `EpisodeFeedLoader` for a bounded recent-episode preview.
- `RSSParser`, podcast User-Agent and existing network safeguards.
- `TVArtworkImage` and its purgeable, downsampled artwork pipeline.

### 5.2 Add TV-specific catalogue ownership

Create focused types rather than extending `TVAppModel`:

- `TVDiscoverModel` — observable page state and selected storefront.
- `TVDiscoverRepository` — charts/search/feed-preview orchestration.
- `TVDiscoverCache` — bounded disk/memory catalogue cache in Caches.
- `TVDiscoverRoute` — typed chart/category/show/episode destinations.
- `TVDiscoverShow` and `TVDiscoverEpisode` — immutable presentation models.
- `TVDiscoverPlaybackFactory` — creates the RSS-backed transient `Episode` and
  explicit Discover playback context, then hands both to `TVEpisodeResolver`;
  it must not become an independent identity/reconstruction boundary.

`TVAppModel` supplies only the established playback entry point and shared
dependencies. Discover's transient state must not be folded back into the root
application model.

### 5.3 Show resolution

Chart entries provide Apple collection identity but not always sufficient feed
metadata. Resolve a show through the existing Apple Lookup response to obtain
the public RSS feed URL, then load a bounded episode preview.

Resolution rules:

1. Deduplicate concurrent lookups by Apple collection ID.
2. Cache successful feed resolution for 12 hours.
3. Apply a short failure cooldown rather than hammering a bad result.
4. Show an honest **Feed unavailable** state when no public feed exists.
5. Never insert the resolved show into `SubscriptionStore`.

### 5.4 Episode reconciliation

When an Apple episode result opens:

1. Resolve its parent show's public feed.
2. Match by GUID when Apple supplies a usable GUID.
3. Otherwise use the existing narrow exact-normalised-title fallback within
   that parent feed.
4. Prefer RSS enclosure URL, duration, media type, description and artwork.
5. If it cannot be reconciled safely, disable playback and explain that the
   publisher feed no longer exposes the episode.

Do not stream an Apple preview URL as though it were the podcast enclosure.

### 5.5 Playback origin and mutation policy

The current tvOS player assumes playback belongs to Library/History. It authors
companion EpisodeSyncState at start/completion and auto-advances into the
phone-authored Up Next queue when an episode finishes. Reusing that behaviour
unchanged for an unsubscribed Discover episode would violate browse-only policy
even though no Subscribe button was pressed.

Add an explicit playback origin, for example `.library`, `.history` and
`.discover`. For `.discover`:

1. Resolve episode identity through `TVEpisodeResolver`.
2. Use a transient playback-preference carrier only for engine configuration;
   never persist it as a `Subscription`.
3. Record genuine playback position, History and Stats using the self-contained
   history record so listening can still resume across devices.
4. Do not author subscription-owned EpisodeSyncState for an episode that cannot
   be reconciled to a real synced subscription.
5. Do not add, pin, archive or reorder Up Next.
6. Stop at natural completion unless a separate, explicitly approved Discover
   continuation policy is introduced; do not silently auto-advance into the
   phone-authored Priority Stack.

### 5.5 Storefront

- Default to the Apple TV locale region, falling back to US.
- Persist the user's Discover country locally on Apple TV.
- Use the same `ChartCountry` definitions and storefront-localised genre names
  as iPhone.
- Changing country invalidates only visible Discover requests and their route
  data; it must not touch subscriptions or iCloud settings.
- A future cross-device storefront preference can be considered separately,
  but is not required for the first release.

## 6. Focus, layout and Apple TV interaction

### 6.1 Card system

Use existing `TVTheme` tokens and one shared Discover card family:

- square show artwork;
- episode artwork with square fallback unless reliable landscape art exists;
- two-line titles;
- one-line publisher/show metadata;
- strong single focus border/glow, never nested duplicate borders;
- stable fixed card dimensions per shelf;
- no card resizing when asynchronous metadata arrives.

### 6.2 Focus behaviour

- Each shelf receives a stable identity independent of network reloads.
- Each item is keyed by Apple collection/track ID, not array offset.
- Returning from a child page restores the originating card and shelf offset.
- Failed artwork or late duration metadata cannot rebuild the focus hierarchy.
- Search results preserve the selected result while episode/show sections load
  independently.
- Motion respects Reduce Motion; no automatic carousel should steal focus.

### 6.3 Remote actions

- **Select:** open Show Detail, Episode Detail or play when the visible control
  explicitly says Play.
- **Long-press Select on an episode:** Episode Description when resolved.
- **Menu/Back:** return exactly one level without cancelling playback.
- No hidden Subscribe gesture and no destructive action menu.

## 7. Loading and failure design

Each shelf owns its own state: idle, loading, loaded, empty, failed or stale
cache. A category failure must not replace the entire page with an error.

- Paint cached content immediately when available.
- Show skeletons only for the first cold load.
- Replace slow shelf skeletons with a compact retry tile after a deadline.
- Retain already-loaded shelves during a storefront refresh.
- Use `ContentUnavailableView` for full-page offline/empty states.
- If playback preparation fails, use the existing bounded player retry UI.

## 8. Performance budgets

The iPhone page currently stages 19 category rails. Apple TV must keep that
discipline and tighten rendering ownership:

- load Top Episodes, category names and the first useful podcast shelf first;
- eagerly fetch no more than the first 4–6 shelves on cold open;
- prefetch the next shelf only as focus approaches the boundary;
- cap simultaneous chart/feed requests;
- load 20 recent episodes on initial Show Detail, with an explicit **More** path;
- downsample artwork to its rendered card size;
- cancel route-owned feed work when the user backs out;
- keep parsing and catalogue projection off the main actor;
- publish observable arrays once per completed batch, not once per item;
- apply memory-pressure cache trimming through the existing TV image/cache path.

Initial physical-device acceptance budgets:

- cached Discover usable within 1 second;
- cold first shelf usable within 3 seconds on normal broadband;
- focus movement never waits on network work;
- no main-actor operation above 100 ms during shelf navigation;
- no sustained memory climb after browsing ten category pages;
- opening and closing a detail page 20 times leaves one player owner and no
  orphaned network task.

## 9. Diagnostics

Add persisted, redacted events with route generation and storefront:

- `tv.discover.opened`
- `tv.discover.phaseChanged`
- `tv.discover.shelfLoaded`
- `tv.discover.shelfFailed`
- `tv.discover.cacheHit`
- `tv.discover.searchStarted`
- `tv.discover.searchCompleted`
- `tv.discover.showResolved`
- `tv.discover.feedPreviewLoaded`
- `tv.discover.episodeReconciled`
- `tv.discover.playRequested`
- `tv.discover.playFailed`
- `tv.discover.requestCancelled`

Metadata should include IDs/hashes rather than raw search text or feed URLs in
the redacted export. Record durations, result counts, cache state, route
generation, reconciliation method and cancellation reason. Never log episode
description bodies or user-entered search text.

## 10. Phased delivery

### Phase 0 — Contracts and safety rails

1. Characterise current iPhone chart order, storefront behaviour and category
   set with tests.
2. Add a code-level `TVDiscoverMutationPolicy` that exposes no subscription,
   queue or archive mutation operations.
3. Define immutable TV catalogue models and typed routes.
4. Add tests proving Discover cannot call subscription/order/queue writes.
5. Clean the current tvOS Search prototype: remove unused `SubscribeState`,
   `onSubscribe`, dead subscription labels and the inaccurate “add a podcast”
   copy. Record explicitly that its result cards remain non-interactive until
   the read-only Show Detail route lands, rather than presenting an ambiguous
   dead end as completed search behaviour.

**Exit:** architecture compiles with no visible UI and the no-mutation boundary
is mechanically testable.

### Phase 1 — Repository and cache

1. Expose a deliberately small public chart-provider/DTO surface from
   `AutohopCore`, then implement the actor-backed TV repository around those
   existing chart clients, lookup, public search providers and bounded feed
   loading. This is access and orchestration work, not duplicated networking.
2. Add storefront-scoped cache keys, TTLs, request deduplication and cancellation.
3. Add offline cache and malformed/unavailable feed tests.
4. Add repository diagnostics.

**Exit:** headless tests can load the landing-page model, resolve a show and
reconcile an episode without creating a subscription.

### Phase 2 — Navigation shell and landing page

1. Replace Search with Discover in `TVTab`.
2. Add a persistent Discover navigation path.
3. Build Top Episodes, category, New & Notable and Top Podcasts shelves using
   shared cards and progressive loading.
4. Add storefront picker and independent shelf failure states.

**Exit:** physical Apple TV can browse the landing page smoothly and reliably
restore focus after tab changes.

### Phase 3 — Read-only Show and Episode Detail

1. Build the Show Detail header and bounded episode list.
2. Build Episode Detail with full description and Play.
3. Add long-press Episode Description to Discover episode lists.
4. Ensure no subscription/settings controls are rendered.

**Exit:** any resolvable chart show can be inspected without changing Library,
Up Next, subscription count or CloudKit state.

### Phase 4 — Playback integration

1. Convert reconciled RSS episodes through `TVDiscoverPlaybackFactory`, then
   canonicalise them through the existing `TVEpisodeResolver`.
2. Add an explicit `.discover` playback origin and route playback through the
   existing `TVPlaybackCoordinator`/`TVPlaybackModel` with the mutation policy
   in §5.5.
3. Confirm video classification, speed inheritance, Vocal Boost policy,
   description menu and player dismissal/resume behaviour.
4. Record genuine listening/watching in shared History and Stats while leaving
   EpisodeSyncState, Up Next and subscriptions untouched for catalogue-only
   episodes.
5. Verify natural completion stops rather than auto-advancing into the
   phone-authored queue.

**Exit:** audio and video Discover episodes play, checkpoint and contribute to
History/Stats without becoming subscriptions or queue entries.

### Phase 5 — Search

1. Move the existing tvOS search into Discover.
2. Use independent show and episode providers with correct storefront.
3. Present clearly separated Shows and Episodes.
4. Add conservative Publisher/Creator groupings from exact author metadata.
5. Make every result card a real focusable navigation control and route it to
   the same read-only detail/playback flow; this is the phase that turns the
   deliberately non-interactive Phase-0 prototype into a complete search path.

**Exit:** search selection never returns to a blank page, never creates a
subscription and restores result focus after detail dismissal.

### Phase 6 — Expanded charts and polish

1. Add Top 50/Top 100 child pages and international spotlights.
2. Tune shelf ordering from physical-device use without changing iPhone content
   definitions.
3. Complete accessibility labels, Reduce Motion, VoiceOver order and contrast.
4. Validate slow network, offline, empty and partial-result states.

**Exit:** feature-complete Discover passes the device matrix and design review.

### Phase 7 — Release hardening

1. Run prolonged browsing memory/CPU profiling on physical Apple TV.
2. Verify no CloudKit schema change and no subscription/order writes.
3. Add release validation that tvOS Discover remains browse/play only.
4. Update `FEATURES.md`, `PAGES.md`, `DESIGN.md`, website/support claims and
   `VERSION_1.5.md` only for phases actually completed.
5. Roll out behind a local feature gate for one diagnostic capture before
   enabling by default.

**Exit:** reproducible Release build with diagnostics, documentation and safe
rollback.

## 11. Test matrix

### Automated

- storefront fallback and country switching;
- chart ordering and category localisation;
- cache TTL, stale-cache fallback and cancellation;
- concurrent request deduplication;
- show lookup without SubscriptionStore writes;
- GUID and exact-title episode reconciliation;
- unresolved episode refusal;
- separate show/episode search ordering;
- conservative creator grouping;
- transient playback conversion for audio and video;
- route generation and stale-result rejection;
- history/stats write without queue/subscription mutation;
- redacted logging excludes query/description/feed URL.

### Physical Apple TV

- cold and cached launch;
- AU, US and UK storefronts;
- Siri Remote focus across every shelf and child page;
- rapid Back/Select during loading;
- slow Wi-Fi, offline and restored network;
- audio and multi-gigabyte video episode playback;
- dismiss/reopen player and retain speed/position;
- browse at least ten categories while monitoring memory and CPU;
- verify iPhone subscription count, order and Up Next remain unchanged;
- verify permitted History/Stats playback updates reach iPhone.

## 12. Acceptance criteria

Discover is ready only when:

1. Its content decisions visibly align with iPhone Discover.
2. It remains responsive without network-completion-driven focus jumps.
3. Every playable item resolves to a publisher RSS enclosure.
4. Audio/video playback uses the existing player and correct resume/speed rules.
5. No Discover action can change subscriptions, priority or Up Next.
6. Episode descriptions are available from detail/player surfaces.
7. Search separates Shows and Episodes and uses the chosen storefront.
8. Cached content degrades gracefully offline.
9. Diagnostics explain slow shelves, failed resolution and playback failure.
10. Physical-device profiling meets the budgets above.

## 13. Recommended implementation order

Implement Phases 0–1 first, then land Phase 2 as a browse-only vertical slice.
Do not begin visual duplication of all 19 category rails before the repository,
cancellation, caching and no-mutation tests exist. Add Show/Episode Detail and
playback next; search and expanded charts should reuse those proven routes.

This sequence delivers a useful, testable Discover page early without copying
the iPhone's hidden subscription mechanism or expanding `TVAppModel` again.
