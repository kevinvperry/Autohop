# tvOS 1.6.1 (1) submission package

<!--
AI CONTEXT — Docs/AppStore/tvOS-1.6.1/SUBMISSION.md
Historical package for Apple TV 1.6.1 build 1, submitted for approval as
confirmed by the user on 8 September 2026. Submitted scope is closed; all
future iOS/tvOS code changes belong together in VERSION_1.7.md.
The sibling TXT files are copy-ready store fields; deliberately keep AI headers
out of those payloads. Record ownership and validation here. This is a separate
platform release from the completed iOS 1.6.1 (17). VERSION_1.7.md records this
preparation under the user's future-work documentation rule; do not reopen the
closed iOS ledger or imply that TV changes shipped in the iOS binary.
Preserve the build-15 evidence discrepancy and never claim upload/approval from
local configuration or a simulator build. Update review paths against TV/Demo.
-->

## Status and scope

**Submitted for approval**, confirmed by the user on 8 September 2026.
Approval/public release of this TV version is not yet confirmed.
AutohopTV and AutohopTVTopShelf are
both 1.6.1 (1). iOS app/widget remain 1.6.1 (17).

The user's App Store Connect screenshot on 8 September shows tvOS 1.6 **build 15**,
uploaded 22 August, Ready for Distribution. This supersedes older documentation
that described build 13 as the latest submitted TV build or approval as pending.
Local August 22 archives inspected during the comparison identify build 13;
therefore the exact build-15 source boundary has not been independently recovered.
The release notes focus on later source changes rather than claiming an exact
binary-to-binary diff or repeating features already present in the August release.

## Copy-ready fields

| App Store Connect field | File |
| --- | --- |
| What's New | [WHATS_NEW.txt](WHATS_NEW.txt) |
| Description | [DESCRIPTION.txt](DESCRIPTION.txt) |
| Promotional Text | [PROMOTIONAL_TEXT.txt](PROMOTIONAL_TEXT.txt) |
| Keywords | [KEYWORDS.txt](KEYWORDS.txt) |
| App Review Notes | [REVIEW_NOTES.txt](REVIEW_NOTES.txt) |

Retain the current shared app name **Autohop: Podcast Player** and subtitle
**Auto-queue, sync & sleep**; do not change shared app metadata solely for this
TV maintenance release. TV copy does not promise the iPhone's automation or
Sleep Schedule controls on Apple TV. The keyword list removes “offline” because
normal TV playback streams; only the bundled demo is guaranteed offline.
Keywords are relevant suggestions, not measured search-volume claims.

Retain the existing platform URLs shown in the user's screenshot:

- Marketing: https://kevmarl.com/autohop/apple-tv
- Support: https://kevmarl.com/autohop/apple-tv#guide

URLs were taken from supplied metadata, not live availability-tested in this task.
Retain existing privacy-policy URL, copyright, contact details and screenshots
where still accurate. No new contact identity or privacy URL has been invented.
No sign-in credentials are required; use the bundled Demo Library review path.

## Review-sensitive details

- Verify the saved age-rating Advertising answer remains Yes before pasting notes
  that state it is Yes. Publisher ads are distinct from an advertising SDK.
- Review must work without a pre-existing iCloud library. The notes lead with the
  bundled offline demo and explain that production sync/statistics need a personal library.
- Do not claim offline publisher downloads, Vocal Boost Strong, the new iOS search
  UI or the iOS Downloads design as new Apple TV features.
- The new app and Top Shelf extension must share version/build values.

## Historical preparation validation and checklist

The checklist below records preparation-time evidence and tasks. The user has
since confirmed submission; this does not retroactively establish unrecorded
hardware or archive checks. Future code updates are Version 1.7 work.

- XcodeGen regeneration completed.
- `Scripts/validate-tvos-release.sh` passed configuration and AI-header checks.
- Metadata character limits validated: description/What's New 4,000; promotional
  text 170; keywords 100; review notes conservatively below 4,000 UTF-8 bytes.
- Release tvOS simulator build passed. Built app and Top Shelf Info.plists
  both verified as 1.6.1 (1).
- Before upload: run the physical-TV checklist in Docs/TVOS_PHASE6_VALIDATION.md,
  including clean-install demo audio/video, personal iCloud sync, remote playback,
  archive/resume and Top Shelf. Exercise the existing-install storage migration.
- Archive 1.6.1 (1) for distribution and run the release validator against the
  signed archive using its documented archive mode. Verify effective entitlements.
- Create the tvOS 1.6.1 version in App Store Connect, upload/select build 1, paste
  the supplied fields, confirm contact/privacy/age-rating details, and submit.
- These preparations do not establish distribution signing, hardware validation,
  an upload or an App Review submission.
