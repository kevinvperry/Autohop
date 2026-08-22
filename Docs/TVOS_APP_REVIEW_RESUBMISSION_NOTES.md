# Autohop tvOS App Review Resubmission Notes

<!--
AI CONTEXT — Docs/TVOS_APP_REVIEW_RESUBMISSION_NOTES.md

PURPOSE: Record of the reviewer-facing notes for the tvOS resubmission that
follows the Version 1.5 (build 6) Guideline 2.1(a) rejection. Keep the
navigation path and privacy claims synchronized with TV/Views/TVRootView.swift
and TV/Demo.

STATUS: SUBMITTED. Version 1.6 build 13 was submitted to Apple App Review on 22
August 2026. This record does not imply approval or public release.

DESIGN DECISION: Autohop has no developer-operated login or shared test account.
The production app therefore exposes a deterministic offline Demo Library that
is available to reviewers and customers and cannot write to production storage,
CloudKit, listening history, or statistics.
-->

## App Review Information — submitted Version 1.6 (build 13)

### Review notes

This submission resolves the launch and access issues reported for tvOS Version
1.5 (build 6).

Autohop normally synchronizes a user's podcast library through that user's
private iCloud account. Autohop does not operate a separate account service, so
there is no username or password that can grant access to another user's private
iCloud library.

On a clean Apple TV installation, the app now completes its initial library
check within a bounded presentation period and displays a stable setup screen.
It does not remain on an indefinite loading screen. The setup screen provides
four visible choices:

1. Explore Demo Library
2. Open Discover
3. Check iCloud Again
4. Settings

To review the app without an existing iPhone library:

1. Launch Autohop on Apple TV.
2. Wait for the initial library check to complete. If the review Apple Account
   has no Autohop data, the setup screen appears automatically.
3. Select **Explore Demo Library**.
4. Use the Home, Subscriptions, History and Settings tabs.
5. Select an audio or video episode to test playback. Queue, archive, completion
   and playback-progress interactions are available within the demonstration.
6. In Demo Settings, choose **Reset Demo** to restore the sample state or
   **Exit Demo** to return to the setup screen.

The Demo Library and its audio/video media are included in the submitted app
and work without network access. It is clearly labelled throughout. All demo
state is temporary and isolated in memory: it is not written to the user's real
podcast library, CloudKit database, listening history, statistics, widgets or
analytics.

Customers who already use Autohop on iPhone can instead enable Settings → Sync
→ iCloud Sync on iPhone, use the same Apple Account on Apple TV, and select
**Check iCloud Again**.

### Submission record

- [x] App Store Connect submission identified as Version 1.6 (build 13).
- [x] Submitted to Apple App Review on 22 August 2026.

### Physical and archive evidence record

The repository does not contain enough signed evidence to retrospectively mark
the following human/device checks complete. Preserve them as an auditable
record rather than inferring completion from the App Store submission:

- [ ] Delete the app from a physical Apple TV, reinstall the Release candidate,
  and verify the setup screen appears with an empty private iCloud library.
- [ ] Verify every setup-screen action with the Siri Remote.
- [ ] Verify bundled audio and video playback offline.
- [ ] Verify Demo Reset and Exit, then relaunch and confirm no demo state entered
  the production library.
- [ ] Verify an existing iPhone/iCloud library still reaches the normal Home
  experience.
- [ ] Inspect the signed distribution archive and confirm production APNs plus
  the intended CloudKit container and services.
- [ ] Attach concise reproduction notes to the internal release record.
