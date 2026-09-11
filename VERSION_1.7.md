# Autohop Version 1.7 — Change Ledger

<!--
AI CONTEXT — VERSION_1.7.md
Canonical running ledger for every future app, behaviour, design, diagnostic,
documentation, website and user-visible change after Version 1.6.1 was confirmed
approved and live on 8 September 2026. Update this ledger and appropriate project
documents/AI headers in the same task, including small fixes. Record implemented
work with validation and limitations; do not present proposals as completed.
VERSION_1.6.1.md is closed. Its earlier development label was also 1.7, but its
entries shipped under 1.6.1 and must not be copied here as new 1.7 features.
Keep iOS-family and tvOS submission/approval status independent. TV 1.6.1 (1)
was submitted for approval, user-confirmed 8 September 2026. All subsequent
iOS and tvOS code updates share this Version 1.7 ledger; TV 1.6.1 scope is closed.
-->

## Release status

- **Development:** Open; started 8 September 2026 after the 1.6.1 release confirmation.
- **Submission:** Not submitted.
- **Approval:** Not approved.
- **Release:** Not released.
- **Build configuration:** No version/build-setting change requested by this documentation transition.

## Completed changes

### tvOS submission confirmed — 8 September 2026

- User confirmed tvOS 1.6.1 (1) submitted for approval; approval remains pending.
- Closed its submitted scope and updated release records and AI context.
- All future iOS and tvOS code changes are documented together here as Version 1.7.
- Kept submitted build settings intact. Documentation/AI-header-only update;
  whitespace checks passed.


### tvOS 1.6.1 build 1 preparation — 8 September 2026

- At the user’s request, prepared a separate tvOS 1.6.1 (1) candidate to match
  the public iOS marketing version. App and Top Shelf updated through XcodeGen;
  iOS app/widget remain 1.6.1 (17). This entry documents preparation, not a 1.7 binary.
- Created description, promotional text, keywords, What’s New and review notes in
  [the TV submission package](Docs/AppStore/tvOS-1.6.1/SUBMISSION.md).
- Recorded screenshot evidence of tvOS 1.6 (15) Ready for Distribution, superseding
  old build-13/latest-submission assumptions. Exact build-15 provenance remains unknown.
- Configuration/AI-header validation, metadata lengths and Release TV simulator
  build pass. Built app/Top Shelf versions verified as 1.6.1 (1). Remaining
  hardware/archive checks are tracked in the package.
- At preparation time the assistant did not upload or submit. The user
  subsequently confirmed submission; see the status entry above.


### Release-ledger transition — 8 September 2026

- Recorded user confirmation that 1.6.1 is approved and live; closed its ledger.
- Opened this ledger for all future changes and updated documentation/AI context pointers.
- Preserved historical 1.6.1 release material and the separate tvOS status.
- Validation: checked ledger references and diff whitespace. Documentation-only change.

No new app implementation changes recorded yet.

## Startup splash coverage — 12 September 2026

The desktop command host now fills the window’s container safe areas. Its nested
UIKit hosting view still supplies safe-area insets to page content, while the
launch animation’s existing edge-to-edge purple background can cover the status
bar and home-indicator regions. Keyboard avoidance is preserved by ignoring only
container safe areas. Keep this boundary when changing responder-host layout;
adding ignoresSafeArea solely inside the splash cannot expand a constrained host.

Validation: iOS Debug simulator build and diff whitespace checks passed.
Visual confirmation on a device remains outstanding.

## Episode Detail podcast link — 12 September 2026

The show title beneath the episode title is now a tinted, underlined navigation
link at its intrinsic text height with an accessibility hint. It opens the
existing Podcast page to subscribe or browse other episodes. Browse-only search
results retain preview/feed loading and Subscribe behaviour; real subscriptions
retain their stored identity. Opening the link does not subscribe automatically.
Native navigation preserves Back to the episode and its existing mini-player.

Validation: iOS Debug simulator build and diff whitespace checks passed.
Discover search → Episode Detail → Podcast page still needs a visual walkthrough.

### Show-title spacing follow-up — 12 September 2026

User confirmed podcast navigation works. Removed the link’s 44-point minimum
height to significantly reduce the space above and below the show title.
Retained six-point header spacing, text wrapping, styling and navigation.
Validation: inspected the targeted modifier change; diff whitespace checks pass.
