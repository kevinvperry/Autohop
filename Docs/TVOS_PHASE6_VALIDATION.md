# tvOS Phase 6 physical-device validation

<!-- AI CONTEXT — Human evidence gate for the tvOS rebuild. Automated builds
cannot truthfully mark these physical Apple TV checks complete. Check boxes only
after testing the exact signed release candidate; attach diagnostic log details. -->

Release candidate: Version 1.6 (build 13), submitted 22 August 2026
Apple TV model / tvOS version: _not recorded_
Date: _evidence not recorded in this document_

- [ ] Fresh install and warm-cache launch tested
- [ ] Wi-Fi, interruption and recovery tested
- [ ] Phone queue updates while TV active, inactive and relaunched
- [ ] Audio and video start, seek, pause, resume and auto-advance
- [ ] Thirty-minute navigation soak during active sync
- [ ] Several-hour mixed playback soak
- [ ] Focus restoration and VoiceOver/Reduce Motion review
- [ ] Memory reaches a stable plateau
- [ ] No indefinite loading, buffering or “Syncing…” state
- [ ] Cache purge and CloudKit rebuild tested
- [ ] Product owner physical-device sign-off

## Dynamic Top Shelf release gates

- [ ] Signed archive embeds `AutohopTVTopShelf.appex`; app and extension have
      the identical production App Group entitlement
- [ ] Static fallback and dynamic rows reviewed at 1080p and 4K with Autohop in
      the Apple TV top row
- [ ] Continue Listening precedes Up Next; ordering, progress and final-minute
      exclusion match the in-app Home projection
- [ ] Select opens exact episode details from terminated and running states
- [ ] Play/Pause starts or resumes the exact episode from terminated and running
      states; unavailable identities show a clear non-destructive message
- [ ] Offline, corrupt/stale snapshot and missing-artwork cases fall back safely
- [ ] Apple TV user/account switching never exposes the prior scope's titles or
      artwork
- [ ] Focus, VoiceOver, Reduce Motion and rapid repeated actions are reviewed on
      physical hardware

Version 1.6 (build 13) was submitted on 22 August 2026. These boxes remain
unchecked because the repository does not contain enough signed human/device
evidence to mark them complete retrospectively. Before replacing the submitted
binary or shipping a later build, complete this record against that exact
candidate and run `Scripts/validate-tvos-release.sh` against its exported app.
