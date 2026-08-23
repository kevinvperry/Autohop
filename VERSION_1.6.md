# Autohop Version 1.6 — Change Ledger

<!--
AI CONTEXT — VERSION_1.6.md
Canonical running ledger for code, behaviour, diagnostics, design,
documentation and user-visible changes implemented after the paired iOS and
tvOS Version 1.5 builds were submitted to Apple for App Review on 9 August
2026.

Every accepted change made after that submission must be recorded here when it
is implemented, including small fixes, performance-policy changes, diagnostic
improvements, UI refinements, website changes and documentation corrections.
Do not add post-submission work to VERSION_1.5.md. Do not describe planned work
as complete. Public Version 1.6 release notes must be derived from completed
entries and omit internal implementation detail. Updating this ledger is part
of the implementation definition of done.
-->

## 2026-08-23 whole-app large-screen asset upgrade — post-submission

- Completed a page-by-page audit of all shared iOS-family SwiftUI assets and
  documented the implementation and deliberate fixed-size exceptions in
  `Docs/IOS_FAMILY_ASSET_RESPONSIVENESS_AUDIT_2026-08-23.md`.
- Extended Discover's container-width navigation strategy across library,
  queue, settings, stats, charts, search, support, diagnostics, scheduling,
  onboarding and subscription-management pages. Inline headings and toolbar
  actions now grow consistently on iPad and resizable Mac windows while
  retaining established iPhone proportions.
- Made the persistent mini-player's artwork, control, padding and corner radius
  responsive. Export canvases, progress geometry, badges, native list/form rows
  and minimum interaction targets remain deliberately stable.
- This source change postdates the submitted tvOS Version 1.6 build 13 and does
  not alter the tvOS UI or Apple's review binary.
- Repaired Podcast Detail's responsive header regression. Content columns below
  600 points now keep artwork top-leading with title, description, badges and
  metadata beside it, preserving episode-list height on iPhone and narrow split
  views. Wider iPad/Mac columns use the centred editorial header.
- Completed the follow-up all-list density pass. Every native `List` and `Form`
  now receives the shared container-responsive row baseline, while image-led
  subscription, episode, queue, search, download, history and notification rows
  scale artwork from 44 to 52/60 points together with primary/secondary text,
  spacing, padding and progress indentation. Custom support, activity,
  diagnostics and Player Up Next rows follow the same policy.
- Closed the remaining mixed-scale gap on Podcast Detail: show title,
  description, publisher, categories, Subscribe control and notification button
  now grow in the same width bands as its artwork and episode list. Shared
  Video, Explicit and episode-status pills, Settings row labels and trim
  controls also use those bands wherever they appear.
- Corrected the shared viewport-width ownership defect exposed by the iPad
  comparison: Subscriptions and Up Next had applied width to descendants while
  their parent-owned rows still read the 390-point fallback. Root navigation
  now supplies the real resizable container width, and both pages scale row
  copy, metadata, artwork, markers, expanded-row shortcuts, action controls,
  padding and status/media pills in concert with Podcast Detail.
- Standardised vertical episode-list measure against Podcast Detail: Podcast
  Detail, Subscriptions, Up Next, Listening History, Downloads, Search episode
  results and Auto Archive Activity now use 20-point compact gutters and an
  860-point maximum list surface inside the shared 900-point outer measure.
  Editorial episode rails/charts and Player's single embedded Up Next card remain
  intentionally governed by their host compositions.
- Aligned Subscriptions' Priority/refresh action row with the same centred
  episode-list column, removing its wider iPad edge positions. Completed the
  screenshot-led navigation follow-up by applying the shared large-screen
  control metrics to Podcast Detail's Back/Share/Settings toolbar and Player's
  custom Subscriptions, panel, sleep and Up Next controls (including empty state).
- Added fixed shortcut navigation rails to System Settings and Individual
  Subscription Settings on expansive iPad/Mac windows. Icon-and-label shortcuts
  animate the existing right-hand Form to major sections, retain sidebar focus
  for repeated keyboard navigation, reflect the currently appearing section,
  and conditionally include Diagnostics/Chapters only when available. iPhone and
  narrow iPad multitasking keep the established single-column Form unchanged.
- Repaired the shortcut implementation after repeated iPad validation. SwiftUI
  `Form` virtualizes distant rows, so neither header nor row view IDs reliably
  exist for long-distance `ScrollViewReader` commands. The expansive pages now
  bridge shortcut requests to the Form's native collection/table view and scroll
  by explicit section index, which remains addressable before its rows are
  realized. Headers still drive manual-scroll highlighting and shortcut labels
  exactly match their visible Form section headings.
- Centred the combined 240-point rail and Form workspace in landscape. Following
  device review, removed the contrasting grey workspace treatment: the rail,
  Form pane and surrounding canvas now share one consistent black background.
- Reassessed the native bridge after another device failure: its first Form
  lookup depended on an invisible SwiftUI background marker having a meaningful
  UIKit frame, which is not guaranteed. Form discovery now inspects the visible
  hierarchy, selects the full-sized enabled native list by content extent,
  synchronizes layout and performs one bounded retry for presentation races.
- Increased vertical separation between every System Settings and Individual
  Subscription Settings section from 36 to 48 points across iPhone, iPad and
  iOS-family Mac layouts. Internal card-row spacing remains unchanged.
- Changed shortcut destination alignment from top-pinned to vertically centred.
  The selected section's first control now lands near the middle of the Form,
  keeping its supplementary heading and nearby context visible below the title
  bar instead of cropping the heading above the viewport.
- Audited native navigation symbols after iPad screenshots exposed a cropped
  Podcast Detail Share glyph. The previous shared modifier incorrectly gave
  every utility icon the larger circular-Back font (up to 28 points). Navigation
  now has separate responsive contracts: bounded utility symbols use the
  15/18/21-point band inside a 36/44/44-point host, while circular Back symbols
  retain their dedicated 20/25/28-point artwork band. Applied the Back contract
  consistently across all audited iOS page toolbars.

## 2026-08-23 iOS-family Mac player modal repair — post-submission

- Repaired the immediate crash when an iOS-family build running on Mac opened
  Audio Controls from the main Player. The modal no longer relies on inherited
  environment-object propagation across a platform presentation boundary; its
  playback, subscription, settings and command owners are explicit observed
  inputs.
- Preserved one shared Audio Controls implementation and behavior across
  iPhone, iPad and Mac rather than creating a Mac-only settings fork. Mac uses
  native modal sizing while touch platforms retain medium/large sheet detents.
- This source change postdates the submitted tvOS Version 1.6 build 13 and is
  not claimed to exist in Apple's review binary.

### Mac development-signing repair

- Registered the development Mac with Apple through Xcode automatic signing
  and refreshed both the Autohop app and widget provisioning profiles. Each
  profile now contains the Mac identifier, and a normally signed
  Mac-compatible build completes with the configured Apple Development
  certificate. No repository signing override or machine-specific profile
  identifier was added to project configuration.

## 2026-08-23 responsive Player share-sheet repair — post-submission

- Replaced the episode share sheet's generic medium/large detents with one
  measured content-height stop. The initial presentation no longer hides Copy,
  Review or Cancel controls, and an upward swipe can no longer expand the sheet
  into an unnecessarily full-screen surface.
- Short touch-device windows remain safely scrollable when the system clamps
  the measured detent; Mac retains native modal sizing. The exported share card
  remains fixed-size and pixel-stable.

## 2026-08-23 Discover large-screen navigation scaling — post-submission

- Connected the Discover inline heading, Back control and storefront picker to
  the existing container-width editorial bands. The established phone sizes are
  unchanged while iPad, Mac and future wide windows progressively enlarge title
  type, control labels, symbols and interaction targets.
- Added regression coverage for monotonic navigation scaling across standard,
  wide and expansive layouts. No device-model or fixed-screen branching was
  introduced.
- Capped the wide/expansive Back interaction frame to the inline toolbar's
  44-point vertical slot and adjusted the largest glyph to 28 points, preventing
  its circular artwork from being cropped. Confirmed that the Search shortcut
  already scales from 40 to 46 to 52 points high across the same bands.

## 2026-08-22 tvOS legacy iCloud library recovery

- Repaired the build-10 read-only companion regression: Apple TV remains
  structurally unable to upload subscription settings, but may consume a legacy
  UUID-named `SubscriptionState` locally when no namespaced successor exists.
  Namespaced records always win, preventing stale legacy settings from
  overwriting migrated state.
- Subscription-prime diagnostics now report matched/current/legacy fallback/
  shadowed/rejected/result-failure counts instead of the ambiguous `count=0`.
- iPhone and Apple TV sync startup now persist the same privacy-safe CloudKit
  account fingerprint, allowing cross-device account provenance to be compared
  without logging Apple's user record identifier.
- Advanced the tvOS app and embedded Top Shelf extension together to build 13.

## 2026-08-20 tvOS privacy-manifest packaging repair

- Made the repository privacy manifest an explicit resource of both tvOS
  executables. The app and Top Shelf extension now each carry their own
  required-reason API declarations instead of incorrectly relying on GRDB's
  package manifest. The signed-archive gate rejects a missing, invalid,
  tracking-enabled or declaration-free copy in either executable bundle.
- Advanced the tvOS app and embedded Top Shelf extension together to build 11
  so the repaired submission candidate cannot collide with a previously
  processed build number.
- Added an exported-product validation mode for Xcode's automatic-signing
  workflow. The intermediate archive can legitimately retain development
  signing before App Store export; the gate now verifies production APNs,
  distribution entitlements, privacy manifests, nested signatures and compiled
  artwork against the actual exported application while keeping physical Apple
  TV sign-off separate.
- Repaired App Store Connect validation error 90502 by explicitly declaring
  the arm64 device capability in both the tvOS app and Top Shelf extension.
  The exported-product gate now verifies both compiled plists so project
  regeneration cannot silently restore the invalid extension bundle.

## 2026-08-20 tvOS periodic Library projection repair

- Replaced full recursive `[Subscription]` equality during every freshness poll
  with an O(1), process-local store revision check plus explicit survival-kit
  invalidation. The captured device database contained 116 subscriptions and
  4,378 embedded episodes; unchanged refreshes were spending 1.1–1.25 seconds
  on the main actor proving that graph equal. Full projection now runs only
  after a genuine store/materialisation change, with regression coverage and
  an AI-context invariant preventing restoration of graph equality.

## 2026-08-20 tvOS native-video resume repair

- Gave Siri Remote play/pause a single owner: Autohop continues to handle its
  custom audio player, while `AVPlayerViewController` exclusively handles
  video. This prevents one Play press from resuming and immediately pausing the
  same AVPlayer; device diagnostics captured the two transitions 8–250 ms
  apart. Added transport-ownership regression tests and AI-context guidance.

## 2026-08-20 warning and Home projection repairs

- Made parsed RSS projection values genuinely `Sendable` for Swift 6
  concurrency compatibility.
- Removed deprecated CBLAS copying and renderer-format construction while
  preserving mono fold-down and exact-pixel Top Shelf output.
- Home now excludes its Continue Listening hero from the rendered Up Next rail
  by stable episode identity without modifying the phone-authored queue.
- Removed only unassigned asset-catalog child copies; assigned icon images and
  the hardware-proven layered icon structure remain intact.

## Release status

- **tvOS submission status:** Version 1.6 build 13 was submitted to Apple App
  Review on 22 August 2026. Review is pending; submission is not approval or
  public release.
- **Submitted-source boundary:** the submitted tvOS binary is build 13. Changes
  explicitly labelled `post-build 13` below were committed after submission and
  are not claimed to exist in Apple's review binary. They require a new build
  number and replacement submission if they are to be reviewed.
- **Development status:** active post-submission development continues. iOS and
  tvOS release status must be recorded independently when they diverge.

## Historical proposal and implementation record

- **tvOS App Review clean-install access:** Apple rejected Version 1.5 (build
  6) after a clean Apple TV installation appeared to load indefinitely and the
  reviewer could not access a phone-authored private iCloud library. A phased,
  implementation-ready resolution is documented in
  `Docs/TVOS_APP_REVIEW_ACCESS_PROPOSAL.md`. It proposes bounded first-sync
  states, a completed setup screen, library-free Discover and Settings access,
  and a deterministic local demonstration library that cannot write synthetic
  content to production persistence, CloudKit or listening statistics. The
  original proposal is now implemented in runtime code as described under
  Completed. Version 1.6 build 13 was subsequently submitted on 22 August 2026;
  the repository still does not contain signed evidence for every manual
  physical-device checklist item.
  An independent audit of a Claude Opus review subsequently strengthened the
  proposal with stage-level bootstrap deadlines, late-result ownership rules,
  bundled offline media, Release-build demo verification and inspection of the
  archived app's effective APNs/CloudKit entitlements. The audit did not accept
  unproven claims that the local deferred database load definitely caused the
  review failure or that the submitted binary definitely retained the source
  plist's development APNs value.

## Completed

- **tvOS diagnostic-log remediation and Apple design alignment:** The build-6
  diagnostic showed valid ten-item Top Shelf candidates but zero successful
  publications, alongside thousands of SQLite `subscription.feedURL` uniqueness
  failures. Top Shelf publication now uses immutable artwork writes followed by
  one atomic manifest commit, reuses prepared artwork across retries, and reports
  the exact failing App Group operation plus Foundation domain/code without
  recording paths. Subscription materialisation now canonicalises feed URLs,
  suppresses colliding remote UUIDs, preserves an established persisted identity
  and reconciles legacy in-memory duplicates before persistence. Regression tests
  cover canonical feed collisions and privacy-safe storage diagnostics.

- **Apple TV Settings navigation and returning-user launch polish:** The tall
  Settings page now caches its filesystem/memory diagnostic snapshot while the
  user moves focus, uses lazy layout and makes each read-only health row a
  stable focus stop. This prevents the Siri Remote from jumping between widely
  separated buttons at the top and bottom. Launch presentation now distinguishes
  a clean install from durable returning-library evidence in the survival kit
  or cached projection. Returning users remain on the branded refreshing view
  through normal iCloud catch-up—including transient `.empty` projection
  states—rather than flashing the first-time iPhone setup page. A separate
  45-second recovery deadline preserves an actionable escape if refresh is
  genuinely stuck; clean installs retain the ten-second App Review deadline.

- **tvOS diagnostic and performance audit:** Settings now explains Dynamic Top
  Shelf fallback across eligible items, publisher phase/error/duration, App
  Group access, manifest generation/age and the extension's last content-free
  outcome, with a safe manual refresh. The extension records only a bounded
  4 KB operational heartbeat. Launch timing, Demo entry/exit, Top Shelf route
  resolution, memory, thermal state and main-thread hang summaries were added
  without new polling. Existing tvOS title/feed-host diagnostic leakage was
  removed. See `Docs/TVOS_DIAGNOSTICS_AUDIT_2026-08-15.md`.

- **Dynamic Apple TV Top Shelf:** Autohop now embeds a dedicated TVServices
  extension that renders Continue Listening and phone-authoritative Up Next
  from a versioned, size-bounded and atomically replaced App Group snapshot.
  The containing app prepares square 1x/2x artwork with bounded concurrency;
  the extension remains read-only and imports no production model, database,
  CloudKit, RSS or networking layer. Strict identity-only display/play URLs
  support cold and warm launch without substituting a different episode.
  Invalid, stale, empty or account-mismatched snapshots fall back to redesigned
  static artwork, and demo content cannot enter the publisher. Automated schema,
  storage, projection, route, extension-build and configuration gates are in
  place. Signed archive inspection and physical Apple TV 1080p/4K, VoiceOver,
  offline and multiuser validation remain open release gates, not claimed as
  completed device testing.

- **tvOS clean-install recovery and App Review demo:** Apple TV now stops
  presenting launch as an indefinite requirement after ten seconds. This is a
  presentation watchdog rather than an unsafe cancellation race: the existing
  bootstrap keeps its single ownership and may still publish a real library.
  Empty, delayed and recoverable-failure paths show a stable setup page with
  iPhone/iCloud steps, bounded retry, Discover/Settings access and a primary
  Explore Demo Library action. The Release target includes a completely
  separate in-memory demo with four synthetic shows, Up Next, Continue
  Listening, History, local audio/video playback, seek/speed, queue/archive
  actions, Reset and Exit. First-party media is bundled, so review does not
  depend on iCloud, RSS or credentials. Demo code imports no production domain
  module and cannot reach subscriptions, CloudKit, history, queue or Stats
  writers. Added launch-policy and deterministic/resettable fixture tests; the
  complete 37-test tvOS suite and Release simulator build pass. Added matching
  in-app/website support guidance and App Store Connect review notes. Version
  1.6 build 13 was submitted on 22 August 2026; unchecked human/device evidence
  remains explicitly unverified rather than being inferred from submission.

- **Review in Apple Podcasts (iOS family):** Added a clearly labelled review
  action beneath the metadata cards in the Player's Details panel and to its
  Episode Share sheet, with the same action also available in Podcast Share.
  Existing, browse-history and manually added RSS shows are resolved against
  the selected Apple storefront and must
  match the exact normalized feed URL before Autohop opens anything. Successful
  actions use Apple's HTTPS show link so the Podcasts app can handle it, while
  unresolved shows remain in Autohop with an inline explanation. Copy accurately
  explains that Apple requires the listener to scroll to Ratings & Reviews;
  Apple exposes no supported URL for opening its review composer directly. This
  feature is intentionally absent from tvOS.

- **Control-state ownership audit and Shared Listening live repair:** Audited
  native and custom controls across Player, Audio Controls, App/Podcast/
  Notification settings, Sleep Schedule/Timer, Downloads, Priority, Discover
  charts, search, Stats and onboarding for command/display ownership mismatches.
  Reconnected the Player Audio
  Controls sheet to `SettingsViewModel`, the observable owner of global settings.
  The toggle and 1.0×–1.3× segmented speed control had been reading through
  `AppState`, which correctly persists commands but intentionally does not
  republish domain changes; controls therefore looked stuck until the sheet was
  reopened. They now redraw and animate immediately while all live playback
  side effects still route through the existing AppState command facade. Added
  regression coverage for externally published Shared Listening state. The
  Player sound-controls highlight was the only related stale read elsewhere and
  now also observes `SettingsViewModel` directly. All other audited controls
  already observe their owning model or intentional local draft. Findings are
  recorded in `Docs/CONTROL_STATE_AUDIT_2026-08-14.md`.

- **Full Stats-page accounting audit:** Audited every visible Stats section from
  playback/download event capture through daily persistence, additive iCloud
  merge, calendar-period selection and rendering. Fixed iOS AVPlayer listening
  inflation at speeds above 1× by deriving elapsed time from natural media
  progress divided by effective speed, bringing iOS and tvOS under the same
  contract. This repairs all downstream time-based figures prospectively: hero
  listening, Top Shows/rank share, heatmap, trend, listening clock and streak
  qualification. Restored imported pre-daily-bucket listening and time-saved
  totals to every period that wholly contains their known recording interval
  (including 2026 when all listening occurred in 2026), as well as Lifetime;
  trend views disclose that those older totals cannot be assigned to a specific
  month/hour/show.
  Added rate-aware and legacy-summary regression coverage. Full findings and
  verified limitations are recorded in `Docs/STATS_PAGE_AUDIT_2026-08-14.md`.

- **Stats Top Shows accuracy audit and repair:** Replaced the expanded show's
  fragile completion count—which came only from the separately capped and
  mutable listening-history list—with durable per-show start/completion counters
  in each daily Stats bucket. Existing installations recover the strongest
  available historical count from retained history plus sticky completed episode
  state without double-counting matching enclosure URLs. Increased bounded
  history retention from 500 to 5,000 entries for the remaining cadence and
  abandonment insights. The monthly, yearly and Lifetime card now uses the
  greater durable/recovered completion evidence, while new counts sync additively
  across device-owned day partitions.

- **Unified iOS/tvOS Stats time accounting:** Defined `DayStats.wallClockSeconds`
  consistently as real elapsed listening time. tvOS now converts AVPlayer media
  progress back to elapsed time before recording, matching iOS. Corrected
  variable-speed savings to `elapsed × (speed − 1)`; the previous calculation
  divided by speed a second time and understated savings. These corrections apply
  prospectively because historical aggregate buckets cannot be losslessly
  separated into their original playback samples.

- **Play Instant protects nearly finished episodes:** Play Instant no longer
  interrupts when the current episode has exactly 60 seconds or less remaining.
  The downloaded arrival stays safely armed within the existing 30-minute window
  and may trigger after natural queue advancement. Eligibility is checked both
  before the warning and again after its two-second delay, closing the boundary
  race without changing behaviour when an episode's duration is unavailable.
  Added focused tests for below, exactly at and above the threshold.

- **Video speed preserved through fullscreen:** Fullscreen video now carries the
  episode's effective playback rate and paused/playing state through the AVKit
  presentation transition. The iOS AVPlayer path also keeps `defaultRate`
  aligned with the selected per-podcast speed, preventing AVKit's internal
  `play()` calls from silently returning playback to 1x. The shared tvOS
  streaming engine already used the same persistent-rate policy, so platform
  behaviour remains aligned.

- **Video fullscreen crash:** Removed two conflicting UIKit operations from the
  fullscreen transition. The app now unlocks landscape support before presenting
  the fullscreen cover without forcing a scene rotation during presentation,
  and leaves `AVPlayerViewController` containment to SwiftUI instead of manually
  re-parenting it. Fullscreen playback, user-driven landscape rotation and the
  explicit Picture in Picture fallback remain available.

- **Responsive Package 2 — complete Discover content scaling:** Scaled every
  custom Discover content element from the page's live container width across
  narrow, standard, wide and expansive layouts. This includes hero and shelf
  artwork, all page typography, search and starter-pack controls, section and
  rail headings, category chips, rank badges, placeholder and navigation
  symbols, decorative rank numerals, card radii, padding and vertical rhythm.
  Standard iPhone sizing remains the design baseline while iPad and Mac-sized
  viewports receive proportionate text and assets. Native navigation-bar items
  continue to use the platform's own sizing and Dynamic Type behaviour.

- **Responsive Package 2 — correctly sized navigation presentations:** Added a
  shared adaptive presentation policy for navigation-heavy modal surfaces.
  Menu, Stats and the other pages reached through Menu, Up Next, podcast
  settings and podcast details continue to use familiar sheets on compact
  iPhone layouts, but now use the full available navigation canvas on
  regular-width iPad and Mac-sized layouts. This prevents page content and the
  Mini Player from being trapped inside an undersized centred form sheet while
  leaving small confirmation, picker and share sheets unchanged.

- **Native iPad target enabled for responsive device-matrix testing** — Changed
  the durable XcodeGen configuration from iPhone-only compatibility mode to
  native iPhone+iPad support. iPad now receives the real expansive viewport
  required by responsive shelves, adaptive page widths and the two-column Stats
  composition. Added explicit iPad portrait, upside-down and landscape
  orientations for Split View, Stage Manager and hardware-keyboard use. This is
  an implementation/testing milestone; iPad release support remains gated on
  the full visual and interaction matrix recorded in the resizability audit.

- **Responsive Package 2 — keyboard and pointer readiness:** Added standard
  Escape/Cancel dismissal to custom informational-sheet and Back controls,
  exposed a visible Command-F search-focus action, and added pointer hover
  feedback to custom plain-style search results. Native controls keep their
  existing platform focus behaviour, preventing duplicate or invisible focus
  targets. Hardware-keyboard and pointer matrix verification remains required
  before enabling iPad or Mac destinations.

- **Responsive Package 2 — targeted Dynamic Type:** Completed the scoped
  typography classification for the responsive Package 2 surfaces. Discover's
  ordinary starter-pack copy now uses semantic text roles, while custom Stats
  hero values use `@ScaledMetric` tied to meaningful text styles. Decorative
  ranks, symbols, artwork placeholders and compact badges retain deliberate
  fixed sizing. This avoids a risky repository-wide font rewrite and preserves
  the existing visual hierarchy. Accessibility-size visual matrix validation
  remains required before enabling iPad and Mac destinations.

- **Responsive Package 2 — accessible coach marks:** Hardened onboarding tips
  for short windows and large Dynamic Type. Coach cards remain centred and
  bottom aligned in normal layouts, but now become vertically scrollable when
  required so their complete guidance and dismissal action stay reachable.
  Resizing preserves the current tip rather than restarting the tour. iPad and
  Mac targets remain disabled and visual matrix verification is still
  required.

- **Responsive Package 2 — expansive Stats composition:** Added a responsive
  two-column Stats presentation for wide iPad and Mac-sized viewports while
  retaining the established single-column iPhone layout and section order.
  The date range, current/previous-period selection and expanded-show state
  remain owned by one view and survive live width changes; the two-column
  alternative is chosen only when the readable page has enough usable width.
  Listening Recaps remains a modal sheet because it is a focused settings
  workflow rather than lightweight contextual information. iPad and Mac
  targets remain disabled and visual matrix verification is still required.

- **Responsive Package 2 — container-aware page gutters:** Added a shared
  `adaptivePageContent` layout primitive that derives page gutters from the
  current SwiftUI container and combines them with the existing readable-width
  caps without geometry state or physical-screen assumptions. Adopted it on
  Downloads, Stats, Auto Archive Activity, Diagnostic Log and Support section
  detail, keeping outer scrolling backgrounds and chrome full width. Replaced
  the initial `containerRelativeFrame` implementation after iPhone simulator
  testing exposed a zero-width collapse inside vertical scroll views; the
  corrected custom SwiftUI `Layout` preserves content under missing proposals
  and uses the live parent width when available. Native
  List/Form pages remain unchanged pending a section-level design decision;
  iPad and Mac targets remain disabled and visual matrix verification is still
  required.

- **Responsive Package 2 — adaptive Podcast Detail header:** Reworked the
  Podcast Detail identity header into semantic side-by-side and stacked
  alternatives selected from the width offered by its container. Narrow
  layouts no longer squeeze artwork, titles and status pills; expansive
  layouts remain bounded by the shared readable-width policy. Replaced the
  nested description-overflow measurement with a stable Show More/Show Less
  control, preserving podcast identity, subscription state, navigation and
  episode-list behaviour. Updated AI context and the canonical design and
  resizability documentation. iPad and Mac targets remain disabled and visual
  matrix verification is still required.

- **Responsive Package 2 — editorial viewport system:** Added a shared
  container-derived editorial layout vocabulary across Discover, Top Episodes
  and Top Podcasts. Hero cards, shelf artwork, feature and compact chart cards,
  page gutters and spacing now scale within clamped limits from narrow phones
  through expansive windows, while preserving the established standard-iPhone
  composition, artwork proportions, horizontal shelves and navigation. Updated
  AI context and canonical design/resizability documentation. iPad and Mac
  targets remain disabled and visual matrix verification is still required.

- **Responsive Package 2 — first easy-win adoption:** Corrected the stale
  responsive proposal status and began Package 2 on a dedicated Version 1.6
  branch. Top Episodes, Top Podcasts, Auto Archive Activity and Diagnostic Log
  now centre and cap their inner content on expansive viewports while retaining
  full-width scrolling backgrounds and chrome. Updated the design system and
  authoritative resizability audit with the implemented pattern and accurate
  code-complete versus visual-verification status. iPad and Mac targets remain
  disabled; no navigation or playback behaviour changed.

- **De-Esser implementation proposal:** Added the AI-oriented phased
  specification `Docs/DE_ESSER_IMPLEMENTATION_PROPOSAL.md`. The proposed
  feature is deliberately scoped to locally downloaded audio playback on iOS,
  including Play Instant after download. It specifies an offline tuning phase,
  a production custom audio-unit DSP architecture, pre/post-dynamics listening
  validation, Off/Light/Strong controls, per-podcast and new-subscription
  defaults, diagnostics, regression tests and performance gates. This is a
  planning/documentation deliverable only; De-Esser playback behavior has not
  been implemented.

## Validation still required

- Visually verify the responsive Package 2 surfaces on a standard iPhone,
  compact iPhone, large-iPhone landscape, iPad portrait/landscape, half-width
  Split View and a near-square expansive viewport, including Dynamic Type XL.
  Exercise Discover, Top Episodes and Top Podcasts in loaded, loading, empty and
  error states and confirm editorial shelves retain useful focus/scroll
  behaviour at every width. Verify Podcast Detail in side-by-side and stacked
  forms, including live resizing while its description is expanded, and
  confirm the selected podcast, list position and navigation state persist.

- Add validation requirements alongside each implemented Version 1.6 change,
  then remove or resolve them as testing is completed.
- Before De-Esser implementation begins, capture a clean iOS playback baseline
  and validate the proposed custom audio-unit target/project-generation path.

## tvOS Top Shelf and diagnostics repair — 16 August 2026

- Moved regenerable Top Shelf generations to the shared App Group's
  `Library/Caches/TVTopShelf` directory.
- Added independent root and Library/Caches write probes. The on-device page
  now distinguishes a path failure from ineffective signed entitlements.
- Added a three-failure/15-minute publication circuit breaker; manual refresh
  clears the pause and performs a fresh probe.
- Coalesced non-sequencing sync library refreshes while retaining direct
  refreshes where queue/bootstrap code immediately reads the new projection.
- Persisted the tvOS CKSyncEngine state in its reliably writable cache area and
  replaced forced per-record sync traces with record-type batch summaries.
- Made hang and stage timing scene-aware so suspension gaps are excluded.
- Pseudonymised UUIDs and URLs in exported logs with stable correlation hashes.
- Advanced all targets to Version 1.6 build 7; generated build provenance is
  embedded and the signed archive gate verifies both App Group entitlements.

### Dynamic Top Shelf artwork follow-up — build 8

- Changed dynamic episode cards from 608×608 squares to Apple's 404×608 poster
  geometry so four items fit across a 1920-wide Top Shelf.
- Every poster now includes the Autohop purple gradient behind a centered,
  clipped podcast image. Dynamic TVServices content replaces the static fallback
  rather than overlaying it, so baking the brand treatment into each card is the
  supported way to retain a purple visual foundation.
- Artwork preparation now checks the TV's existing disk cache before downloading.
  Diagnostics separately count disk-cache, network and placeholder results.
- Advanced all targets to Version 1.6 build 8 so this presentation can never be
  confused with the storage-repair build.

### tvOS sync and diagnostic performance repair — build 9

- Audited the physical build-7 capture as one session boundary rather than
  mixing cumulative/rotated logs. It showed approximately 900 CloudKit records
  reapplied per minute, repeated main-actor projection work, and two diagnostic
  exports that each blocked the UI for roughly 46 seconds.
- Added privacy-safe CKSyncEngine fetch-cycle and page attribution. Batch logs
  now include cycle/page identity, opaque state fingerprints, persistence
  success, decoded rejection totals, and received-versus-materially-changed
  counts. Tokens and record identifiers are never exported.
- Added no-op guards for remote episode and subscription projection updates and
  stopped identical history entries from requesting another tvOS library
  refresh. This preserves system-field acknowledgement while avoiding visible
  work for unchanged server data.
- Deferred and coalesced tvOS library projection refreshes while the scene is
  inactive. A single duty-cycle-controlled refresh resumes on activation, with
  bounded counters reporting how many requests were deferred or coalesced.
- Moved full diagnostic export stitching, redaction and file writing to a
  detached utility task. Settings remains responsive, shows progress, prevents
  duplicate export requests, and logs export duration and output size.
- Replaced the export pseudonymiser's repeated whole-string mutation with a
  linear forward pass, directly addressing the report-generation delay on
  multi-megabyte rotated logs.
- Added an uptime-versus-wall-clock watchdog safeguard for suspension gaps that
  occur before tvOS delivers a scene-phase callback.
- Corrected the Top Shelf bitmap renderer to use an explicit 1.0 output scale.
  The former device-default 2× scale doubled both requested poster sizes, so
  404×608 cards were physically emitted as 808×1216 and could not achieve the
  intended four-across layout. The 1× and 2× files now match their exact pixel
  contracts while retaining the baked-in purple Autohop background.
- Advanced all targets to Version 1.6 build 9. Build 9 is the first capture that
  can determine whether a CloudKit stream is advancing its opaque state while
  repeatedly delivering records, and quantify how much data actually changes.

### tvOS Top Shelf playback and queue parity — build 10

- Added a dedicated live Currently Playing/Watching Top Shelf projection. It
  reserves the first item regardless of the episode's Up Next rank, reports
  playback progress and deduplicates the same identity from the queue. The
  idle-only Home Continue Listening policy remains unchanged.
- Changed both native Top Shelf actions to the exact playback deep link, so
  Siri Remote Select and Play/Pause consistently start or resume the selected
  episode rather than opening different destinations.
- Projected synced playback positions into immutable tvOS Up Next rows with one
  bounded persistence read. Partially played episodes now show remaining time,
  while untouched episodes retain total runtime, matching the iOS Up Next rule.
- Replaced the single CloudKit fetch-diagnostic slot with nested cycle
  ownership. Overlapping callbacks retain distinct cycle IDs, page and material
  change totals; unbalanced callbacks emit an explicit privacy-safe warning.
- Changed full diagnostic export redaction to bounded per-line processing,
  avoiding repeated multi-megabyte whole-string intermediates while preserving
  the same conservative URL, credential and stable-identity pseudonymisation.
- Made AVKit transport-menu installation idempotent by effective playback
  speed. SwiftUI playback ticks no longer rebuild focus/menu structures during
  video startup; a speed change still refreshes the checked menu item.
- Added regression coverage for a playing episode below the Top Shelf cap,
  playing-episode deduplication/progress, queue tile progress and iOS-matching
  remaining-time projection.
- Advanced all targets to Version 1.6 build 10 so physical-device evidence is
  unambiguously attributable to this repair set.

### Independent tvOS audit repairs — build 10

- Bound Top Shelf manifests to a one-way hash of the current private CloudKit
  user record. Account transitions now clear prior titles and artwork before
  waiting for the new account's sync projection.
- Made old Top Shelf generation pruning best-effort after manifest commit, so
  cleanup failure cannot delete artwork referenced by the live manifest.
- Routed survival-kit materialisation changes through the library refresh
  coalescer instead of rebuilding projections once per CloudKit record.
- Gave Discover one stable repository shared by landing state, cards and
  destinations. Failed media-kind probes now use a five-minute retry backoff.
- Restricted playback checkpointing and decoded-artwork eviction to a true
  background transition; transient inactive phases no longer purge the cache.
- Added regression coverage for account-scope clearing and Discover probe
  backoff.
- Completed the remaining audit repairs: single-pass Library projection,
  hoisted survival-kit reads, truthful cached/freshness status, authoritative
  queue-key preference, bounded Top Shelf thumbnails and accurate paused
  diagnostics.
- Made artwork disk corruption self-healing and write only validated image
  bytes. Now Playing gains artwork, toggle and position commands; terminal
  playback fully clears presentation and handles a missing subscription.
- Reconciled local archive suppression against newer phone snapshots, completed
  demo episodes on natural media end and excluded completed demo progress from
  Continue Listening.
- Removed audited dead seams and excluded engineering Markdown from products.
- Added current-user execution entitlements to the app and extension, retained
  hashed CloudKit account scoping, and expanded the AI context contracts so
  future changes preserve every repaired boundary.
- Restored the hardware-proven complete tvOS icon stack after a Back-only
  cleanup produced the system's white grid placeholder on the Home Screen.
  AI context now forbids icon-layer deletion without signed-device evidence.

### CloudKit Production bootstrap repair — post-build 13

- Diagnosed the Xcode-versus-TestFlight split from physical-device logs: the
  development build found 241 subscription records, while the production-signed
  candidate was authenticated and could upload history but consistently found
  zero subscription records.
- Added a guarded iPhone-authority bootstrap for an empty CloudKit environment.
  It republishes the current real library and ordering, clears environment-bound
  CKRecord system fields, and requeues existing episode state, history, stats and
  queue projections so Production receives a complete material replica.
- Preserved the hard tvOS read-only subscription boundary. A companion build can
  never invoke the bootstrap, and network/query failures cannot masquerade as an
  empty environment.
- Added pure policy and database regression coverage, including proof that fresh
  projections are pending and old system fields are removed.
