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

- Add validation requirements alongside each implemented Version 1.6 change,
  then remove or resolve them as testing is completed.
- Before De-Esser implementation begins, capture a clean iOS playback baseline
  and validate the proposed custom audio-unit target/project-generation path.
