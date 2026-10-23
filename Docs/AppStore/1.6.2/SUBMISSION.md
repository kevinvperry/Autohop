# Autohop 1.6.2 — iOS submission preparation

<!-- AI CONTEXT — Release package prepared 4 October 2026.
VERSION_1.7.md must retain every change since 1.6.1, including this preparation.
1.6.2 is the user's requested App Store marketing version, not a new feature scope.
project.yml is authoritative for app/widget 1.6.2 (18); TV stays 1.6.1 (1).
Plain .txt payloads deliberately omit AI headers so they can be pasted verbatim.
Do not infer remote metadata save, review submission, approval or device acceptance
from the confirmed archive/upload. Update validation below only from observed results.
4 October 2026: signed archive 1.6.2 (18) validated and uploaded through Xcode. -->

## Status and scope

**Signed archive validated and uploaded to Apple; not submitted for review.** Public baseline:
1.6.1, dated 8 September, verified on the Australian App Store on 4 October 2026.
Source baseline at the start of preparation: commit 4aefaa86c7e7740dd230c6d209654b677e05fd7a.

The user confirmed **1.6.2** as the submission version, correcting the earlier
erroneous 6.2 preparation. Build 18 is retained. The complete source ledger remains
[VERSION_1.7.md](../../../VERSION_1.7.md), as explicitly requested. Separate TV
changes remain documented there but are not promoted as new iOS features.

| Target | Marketing version | Build | Scope |
| --- | --- | --- | --- |
| Autohop | 1.6.2 | 18 | iPhone/iPad and compatible Designed-for-iPad Mac |
| AutohopWidgets | 1.6.2 | 18 | Embedded iOS-family widget |
| AutohopTV | 1.6.1 | 1 | Unchanged separate submission |
| AutohopTVTopShelf | 1.6.1 | 1 | Unchanged separate extension |

Build 18 advances the checked-in iOS build 17. Xcode Organizer confirmed the signed
1.6.2 (18) archive passed validation and was accepted by Apple's upload service at
7:51 pm on 4 October 2026. App Store Connect processing and build selection remain.

## Copy-ready fields

| App Store Connect field | File / value |
| --- | --- |
| App name — retain | [APP_NAME.txt](APP_NAME.txt) |
| Subtitle — retain | [SUBTITLE.txt](SUBTITLE.txt) |
| Promotional text — replace | [PROMOTIONAL_TEXT.txt](PROMOTIONAL_TEXT.txt) |
| Description — replace | [DESCRIPTION.txt](DESCRIPTION.txt) |
| What's New — replace | [WHATS_NEW.txt](WHATS_NEW.txt) |
| Keywords — proposed replacement | [KEYWORDS.txt](KEYWORDS.txt) |
| App Review Notes — replace historical rejection text | [REVIEW_NOTES.txt](REVIEW_NOTES.txt) |
| Version | 1.6.2 |
| Marketing URL — retain | https://kevmarl.com/autohop |
| Privacy policy URL — retain | https://kevmarl.com/autohop/privacy |
| Support URL — reachable with contact-form link | https://kevmarl.com/autohop/support |
| Copyright | 2026 Kevin Perry |
| Review sign-in required | No |
| Review contact | Retain the owner's current verified saved name/email/international phone; not included or invented here. |
| Price/category | Retain existing Free / News; no category/pricing change requested. |
| Release timing | Choose in App Store Connect; no remote setting changed. |

The text is Australian English. Review notes are within the 4,000-byte limit;
description/What's New within 4,000 characters; promotion within 170 characters;
name/subtitle within 30 characters; keywords within 100 UTF-8 bytes.
The [listing audit](LISTING_AUDIT.md) records current claims and screenshot work.

## Validated payload lengths

| Field file | Length | Limit |
| --- | ---: | --- |
| APP_NAME.txt | 23 | 30 characters |
| SUBTITLE.txt | 24 | 30 characters |
| PROMOTIONAL_TEXT.txt | 163 | 170 characters |
| DESCRIPTION.txt | 3787 | 4000 characters |
| WHATS_NEW.txt | 1938 | 4000 characters |
| KEYWORDS.txt | 94 | 100 bytes |
| REVIEW_NOTES.txt | 3630 | 4000 bytes |

## Ledger-to-release coverage

| Post-1.6.1 ledger work | 1.6.2 treatment |
| --- | --- |
| Startup splash coverage and Episode Detail show link | Interface refinements in What's New |
| Play Instant final-two-minute boundary, restore priority and pause preservation | Playback section; no repeat-interruption promise beyond implemented queue rules |
| Replay initial implementation, guided setup, calendar refinement and Binge Mode | Lead feature; final calendar/Binge implementation supersedes abandoned interval UI |
| Replay sync journals, logical queue readiness, reservations, caught-up decisions | Description/review instructions; retain fixed scheduling-owner and compatible-client boundaries |
| Feed Filters guided cards, defaults/persistence audit and phrase-field fix | Clearer controls; no claim that previously saved user filters were reset |
| Main/per-podcast settings clarity and guided RSS entry/preview | Clearer setup section |
| Support audit, corrections and website exporter/publication | Updated in-app guide; separate website deployment is historical, not a new app feature |
| Diagnostic recording and reliability repairs | Playback/download reliability plus improved local support exports |
| Sleep Schedule redesign and preservation audit | New presentation; existing saved settings, intervals and behaviours retained |
| iOS 27 shared Back policy and continuous mini-player glass | Interface fixes |
| AI headers, project documents, tests and release records | Technical ledger/submission evidence, not marketing bullet padding |
| TV-only cache storage, bootstrap and recovery/diagnostics | Excluded from iOS What's New; separate TV release required |

## Archive and submission sequence

1. Review the candidate on an iPhone/iPad, especially Replay/Binge, existing-library
   upgrade, playback/pause/return, Sleep Schedule, iOS 27 Back and mini-player glass.
   Validate the existing accessibility declarations with the updated screens.
2. Confirm the version is 1.6.2 in App Store Connect and build 18 is unused. Complete
   any required current questionnaire fields, including the social-media capability
   question now required by Apple. Autohop has public podcast discovery but no
   in-app social posting/follower/comment feed; answer against Apple's definitions
   and actual functionality, not the selected News category.
3. Keep Advertising declared Yes for publisher-provided ads/sponsorships. Do not
   manually force the age rating to 13+; Apple derives it from saved answers.
   Review the existing Data Not Collected declaration against actual behaviour.
   This update introduces no new developer analytics service; diagnostic exports
   are user-directed and private iCloud sync is distinct from developer collection.
4. Replace the outdated Sleep Schedule screenshot or remove it from the new set;
   retain other assets only where accurate. The audit provides a screenshot brief.
   Verify the support page/contact link, privacy URL and current review contacts.
5. **Completed 4 October 2026.** In Xcode, open Autohop.xcodeproj, select **Autohop** and **Any iOS Device (arm64)**,
   then **Product > Archive**. The scheme's Archive action uses Release. Use the
   existing signing team and bundle IDs; no signing identity was changed here.
6. **Xcode validation and upload completed 4 October 2026.** Run the existing signed-archive validator on that exact archive:
   `Scripts/validate-release.sh --archive "/absolute/path/Autohop.xcarchive"`.
   It checks the distribution APNs entitlement; the local unsigned build cannot.
   In Organizer, Validate App, then Distribute App to App Store Connect. The
   selected signed archive was verified as Autohop 1.6.2 (18), validation succeeded,
   and Xcode reported “App upload complete”. Preserve the archive/dSYMs.
7. After processing, select the new 1.6.2 build. Paste the prepared fields into the
   intended English localisation; do not overwrite other languages with English.
   Confirm export compliance using the existing non-exempt-encryption declaration
   and actual compiled app. Resolve any validation prompts against evidence.
8. Add for Review and complete submission. Record the actual submission/build
   identifiers in VERSION_1.7.md and here. Only mark approved/live after confirmation.

## Validation and limitations

- Xcode 27.0 (27A266a), iOS 27 SDK.
- Regenerated the Xcode project from project.yml.
- Temporary website export passed for all 23 support sections, with unique IDs,
  preserved legacy anchors, corrected Play Instant guidance and 1.6.2 labels.
  The public website was not modified.
- Release configuration guard passed.
- Corrected **1.6.2 (18) unsigned generic iOS Release rebuild passed**. Both
  built app and widget Info.plists were verified after the final build. Release
  configuration, metadata lengths, document links and support export checks passed.
  This supersedes the earlier incorrectly numbered binary preparation.
- Before the version-number correction, **104 focused iOS 27 simulator tests passed**, covering Replay (47), audio
  recovery (4), subscription sync (22), redaction (10), Play Instant (6), episode
  completion (4) and stats write coalescing (11).
- Copy-ready field lengths and UTF-8 byte limits passed; final whitespace check
  passed. Existing Swift concurrency capture warnings remain in the build log;
  this is not a warning-free build.
- Signed archive, Organizer validation and App Store Connect upload completed for
  Autohop 1.6.2 (18). Xcode recorded “Uploaded to Apple” at 7:51 pm on 4 October
  2026. Remote metadata editing, build selection and review submission remain.
- Previous simulator/device evidence remains in the individual audits. This
  preparation does not establish physical Bluetooth, overnight scheduling, real
  owner/follower/TV CloudKit propagation, or long-duration energy/disk behaviour.
- Replay depends on its designated scheduling installation and compatible updated
  clients. No automatic owner failover or capability negotiation is implemented;
  the old TV binary is not made compatible by changing the iOS marketing version.

Corrected final build log: /tmp/autohop-release-1-6-2-build-final.log.
Historical pre-correction logs: /tmp/autohop-release-6-2-build-final.log,
/tmp/autohop-release-6-2-build.log and
/tmp/autohop-release-6-2-tests.log. Test bundle:
/tmp/autohop-release-6-2-tests.xcresult.

## Apple references checked for this preparation

- [Version and review fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [SDK upload minimums](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)
- [Current submission guidance](https://developer.apple.com/app-store/submitting/)
- [September 2026 social-media declaration requirement](https://developer.apple.com/wwdc26/guides/app-store/)
