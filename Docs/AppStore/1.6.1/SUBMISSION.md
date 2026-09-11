# iOS-family Version 1.6.1 submission preparation

<!--
AI CONTEXT — Docs/AppStore/1.6.1/SUBMISSION.md
Owns the 2026-09-06 replacement-submission metadata and its verification limits.
DESCRIPTION.txt, PROMOTIONAL_TEXT.txt, WHATS_NEW.txt and REVIEW_NOTES.txt
are copy-ready App Store fields: deliberately
omit AI headers from those payloads. Keep ownership, rationale and validation here.
VERSION_1.6.1.md is the closed release ledger; VERSION_1.7.md owns future work; VERSION_1.6.md preserves
the rejected iOS submission and independent tvOS submission history. Do not infer
upload, saved remote metadata, approval, or device verification from local edits.
Refresh these payloads if the release scope changes before upload.
Release update (2026-09-06): user confirmed Mac Menu crash resolved; issue closed.
User confirmed Version 1.6.1 approved and live on 8 September 2026.
Preparation notes and checks below are historical; the release is complete.
-->

## Final release status — 8 September 2026

**Complete:** the user confirmed Version 1.6.1 approved and live in the App Store.
All future work is tracked in [VERSION_1.7.md](../../../VERSION_1.7.md).
The following preparation record is retained as historical evidence, including
what was and was not performed by the assistant at that time.

## Description and search positioning

The 1.6.1 description leads with automatic podcast listening, priority order and
offline downloads, then supports discovery, per-show audio, Sleep Schedule and
private sync with concrete benefits. It includes subscription search, Downloads
swipes, category charts, Mac shortcuts and Stats exports. Publisher advertising
is explicitly distinguished from developer advertising SDKs. Shared Listening
copy reflects its speed/Trim Silence behaviour without implying all audio settings
are disabled. The plain-text description was checked against the 4,000-character limit.

Apple recommends natural, informative description copy rather than keyword stuffing.
Search optimisation also requires the actual app name, subtitle and keyword field;
those fields were not supplied or changed in this task. No search-volume or ranking
guarantee is claimed. See [Apple product-page guidance](https://developer.apple.com/app-store/product-page/)
and [App Store search guidance](https://developer.apple.com/app-store/search/).

## Promotional text

PROMOTIONAL_TEXT.txt leads with automatic downloads, priority playback and per-show
audio controls, followed by discovery, offline listening and device coverage.
Validated against Apple’s 170-character limit. Promotional text does not affect
App Store search ranking; its purpose here is conversion and clear product value,
with natural podcast terminology rather than keyword stuffing. Mac refers to the
compatible Apple-silicon Designed-for-iPad app described in DESCRIPTION.txt.
See [Apple search guidance](https://developer.apple.com/app-store/search/).

## Prepared material

- [Promotional text](PROMOTIONAL_TEXT.txt): copy-ready 1.6.1 promotion.
- [App description](DESCRIPTION.txt): copy-ready full product description for 1.6.1.
- [What's New](WHATS_NEW.txt): combined customer-facing improvements from both release ledgers, ordered by reach and customer value.
- [App Review Information](REVIEW_NOTES.txt): paste into review Notes after verifying the saved Advertising answer is Yes.
- [Closed release ledger](../../../VERSION_1.6.1.md): renamed from the planned 1.7 ledger at the user's request; no completed entries removed.
- [Historical 1.6 ledger](../../../VERSION_1.6.md): closed; rejection status corrected without moving new work into it.

The iOS app and widget version is now 1.6.1 (17), with both build counters
advanced from 10 to 17 at the user’s request. The separate tvOS targets remain 1.6 (13); this request
concerns the iOS-family rejection and does not establish a new tvOS submission.

## Rejection record

- 31 August 2026: Apple rejected iOS 1.6 under 2.3.6 because Advertising was not declared Yes.
- 31 August: Kevin reported changing it to Yes and explained publisher ads in RSS media, with no developer advertising SDK or inserted advertisements.
- 6 September: Apple asked for resubmission. A reply alone did not restart review.
- 6 September: user requested the current source as 1.6.1, replacing the planned 1.7 label. The new review notes supersede the old metadata-only/no-new-binary request.

The correspondence is user-provided evidence. This task has not independently
inspected App Store Connect or changed its age-rating questionnaire.

## Marketing coverage

| Combined ledger theme | What's New treatment |
| --- | --- |
| Native iPad, Designed-for-iPad Mac, responsive typography/artwork/presentations, pointer/keyboard support, wide Stats, universal widget | Lead with device coverage and Mac menus; group layout refinements. |
| Discover scaling, category Top 8/Top 100, artwork fallback | Dedicated discovery section. |
| Local subscription search, keyboard space, episode-row navigation, adaptive Episode Detail | Dedicated subscription section. |
| Downloads typography/artwork/status hierarchy and swipe actions | Dedicated Downloads section. |
| Listening accounting, Top Shows, completion counts, streaks, time saved, backups/recovery, exports, coverage | Dedicated Stats section; expressly avoid promising reconstruction of missing history. |
| Multi-release downloads, completion/queue integrity, Play Instant, fullscreen speed/stability, Shared Listening, audio route labels | Everyday playback section. |
| Onboarding/tips, mini-player coverage, correct Playing destination, final-minute labels, richer metadata, Apple Podcasts reviews | Helpful details section. |
| Private sync, duplicate subscription protection, new-install defaults, notification/recap preferences, beta link | Private sync/preferences section. |
| Internal audits, documentation repairs, screenshots, build provenance, performance implementation details | Represent customer effects above where relevant; technical records remain in both ledgers. |
| Separate tvOS Top Shelf, demo/recovery UI and remote/video implementation | Retained in the ledgers, excluded from this iOS-family store field. |
| Proposed De-Esser, future native Mac/status icon and other unimplemented proposals | Excluded because proposals are not shipping features. |

The full ledgers remain the comprehensive technical record. The store text
consolidates related changes instead of repeating each intermediate repair.
Do not describe public podcast playback as ad-free or imply Autohop controls
publisher media. Advertising disclosure is distinct from the privacy questionnaire;
this task does not change privacy declarations.

## Historical pre-submission checklist

1. Confirm Advertising is saved as Yes in App Information > Age Ratings. Review the remaining answers for the actual app/content. Review notes do not replace questionnaire changes.
2. In the rejected iOS version, use Apple's resolution/edit flow to prepare version 1.6.1 and select its newly uploaded build. If the existing version number cannot be edited in its current state, resolve/remove the rejected item and use the available version workflow; do not accidentally resubmit the old 1.6 binary.
3. Archive current source as 1.6.1 (17), with matching app/widget versions. Run `Scripts/validate-release.sh --archive <actual-path>` to check archive entitlements as well as configuration.
4. **Complete:** the user confirmed the Mac Main Menu crash resolved on 6 September 2026. This release check is closed based on that confirmation.
5. Walk through search/keyboard behaviour, Downloads layout and swipes, iPad tip cards, playback and the review test path. Prior simulator builds/tests are evidence of those changes, not validation of a new distribution archive.
6. Paste both text fields, check screenshots/device availability against the build, save, Add for Review, then complete Resubmit to App Review. Confirm the resulting submission status.

## Validation performed for this preparation

- Regenerated Autohop.xcodeproj from authoritative project.yml.
- `Scripts/validate-release.sh --configuration-only` passed.
- Metadata payloads checked below the 4,000-character/byte bounds respectively.
- No distribution archive, upload, remote metadata change, or review submission performed.
- Approval cannot be guaranteed by review wording; the advertising mismatch is addressed directly, and the Mac crash check is complete based on user confirmation.

## Apple references

[Age-rating questionnaire](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
explains where to save content descriptors.
[Resolve and resubmit rejected items](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/manage-a-submission-with-unresolved-issues/)
requires editing and adding for review, then resubmitting.
[Platform metadata reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
defines the store/review fields.
