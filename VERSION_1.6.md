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

## Release status

- **Development status:** active development following the Version 1.5 App
  Store submission.
- **Submission status:** not submitted.

## Completed

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
