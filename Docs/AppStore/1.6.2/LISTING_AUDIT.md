# Australian App Store listing audit — 4 October 2026

<!-- AI CONTEXT — Read-only public-store evidence for the 1.6.2 candidate.
The public listing establishes shipped metadata, not App Store Connect draft fields,
uploaded builds, contact details or questionnaire answers. Preserve this distinction.
All post-1.6.1 changes remain in VERSION_1.7.md; do not treat that development label
as the requested marketing version or include TV-only changes in iOS release notes. -->

## Baseline verified

Inspected the [Australian listing](https://apps.apple.com/au/app/autohop-podcast-player/id6777946512)
in Chrome after the initial web fetch returned HTTP 429.

| Field | Observed |
| --- | --- |
| Name | Autohop: Podcast Player |
| Subtitle | Auto-queue, sync & sleep |
| Published version/date | 1.6.1, 8 September |
| Price/platform | Free; Designed for iPad; iPhone, iPad and Apple TV selector |
| Seller/category | Kevin Perry; News |
| Compatibility | iOS 17.0 or later |
| Language | English |
| Age rating | 13+ |
| Privacy | Data Not Collected |
| Accessibility declarations | VoiceOver, Voice Control, Larger Text, Dark Interface |
| Rating/size at inspection | 5.0 from 2 ratings; 14.6 MB |
| Public URLs | https://kevmarl.com/autohop and https://kevmarl.com/autohop/privacy |

The observed promotional paragraph and description match the 1.6.1 package. The
release notes still describe the final-minute Play Instant protection. No public
Replay or Binge Mode description is present. Do not edit the historical release
notes: replace the new version's fields with the prepared 1.6.2 payloads.

## Findings and prepared response

| Finding | Response |
| --- | --- |
| Existing title and subtitle remain accurate | Retain them in APP_NAME.txt and SUBTITLE.txt. |
| Promotion omits the principal new feature | Lead PROMOTIONAL_TEXT.txt with Replay and Binge Mode. |
| Description omits Replay and its constraints | Add calendar/Binge behaviour, available-feed limits and one scheduling device; retain established features without calling them new. |
| Play Instant now protects two minutes | Describe two-minute protection and direct interrupted-episode restoration in the new description/release notes. |
| Previous What's New is already shipped | WHATS_NEW.txt uses only implemented post-1.6.1 iOS changes from VERSION_1.7.md. |
| Historical review notes concern a rejection/resubmission | Replace them with current access instructions and a concrete Replay/Binge review path; retain publisher-ad and RSS-content explanations. |
| Search keywords are not exposed publicly | KEYWORDS.txt is a proposed replacement, not a verified copy of the saved field. No ranking claim is made. |
| Public rating/privacy badges do not expose questionnaire answers | Verify saved App Store Connect declarations before submitting; do not infer Advertising=Yes from 13+. |
| Public screenshots show the old Sleep Schedule | Replace that screenshot with a capture from this candidate or omit it from the new version's set if another accurate set satisfies the slot requirements. |
| No Replay/Binge screenshot in the inspected carousel | Recommend a real Replay screen near the front of the next screenshot set. No fabricated UI or proposal mock-up should represent shipping behaviour. |

## Screenshot review

The inspected iPhone carousel shows five assets: Sleep Schedule, Release Radar,
Stats, podcast/episode search and an unframed player capture. The Sleep Schedule
image visibly uses the old form, a green toggle and text saying playback pauses
at the prompt. The current page uses purple/glass controls and explains the chime
over continuing playback. That asset needs replacing for this update.

Suggested order/captions for refreshed assets:
1. Player / Subscriptions — “Your podcasts. Your order.”
2. Replay calendar — “Rediscover a favourite. At your pace.”
3. Binge Mode — “One episode ready for what’s next.”
4. Sleep Schedule — “Fall asleep without losing your place.”
5. Stats or Discover — retain accurate existing feature coverage.

Use actual iPhone and iPad captures with readable text; do not stretch one device's
image into another device slot. Existing accurate assets may be retained. This
task audits and documents the asset changes; it does not claim new marketing
screenshots were captured or uploaded. The old simulator test fixtures are
validation images, not publication-ready screenshots.

## Scope and exclusions

VERSION_1.7.md is the complete post-1.6.1 ledger, including TV, website and
documentation work. The iOS package excludes standalone TV cache/bootstrap/Home
repairs, earlier 1.6.1 additions already on sale, unimplemented Replay owner
failover, and unrelated proposals. Shared Replay/CloudKit behaviour is described
with compatible-client and scheduling-device limits. No claim is made that a
new Apple TV binary has been submitted.

The public listing was read-only. App Store Connect draft version, uploaded build
numbers, saved keyword values, review contacts and questionnaire answers were not
inspected. The website was not deployed or updated by this preparation.


## Linked website checks

The marketing, support and privacy pages opened successfully in the browser.
The support page links to a working contact-form page. Its published guide still
labels Replay and the refreshed RSS workflow as Version 1.7 previews; the local
exporter now prepares Version 1.6.2 labels. Publishing the refreshed website is a
separate action, and the “not yet released” notice must remain until approval/live
status is confirmed. No website files or deployment were changed in this task.

The privacy page still explains private iCloud, publisher network requests and
user-directed diagnostic exports. It predates Replay-specific wording. Review
its notification/sync examples when publishing the new guide; do not claim the
public policy or App Store privacy questionnaire was updated here.

## Replacement artwork follow-up — 4 October 2026

The user supplied the current Sleep Schedule screen and old marketing image.
[Replacement artwork and provenance](../../../AppStoreScreenshots/iOS-1.6.2/README.md)
now exist locally. The generated 850 × 1850 PNG preserves the marketing copy and
visual style; accepted-size export and final UI-fidelity review remain before
App Store upload. This supersedes the earlier absence of replacement artwork,
not the need to replace the remote screenshot.
