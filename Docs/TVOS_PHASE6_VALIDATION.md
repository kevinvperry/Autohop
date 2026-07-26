# tvOS Phase 6 physical-device validation

<!-- AI CONTEXT — Human evidence gate for the tvOS rebuild. Automated builds
cannot truthfully mark these physical Apple TV checks complete. Check boxes only
after testing the exact signed release candidate; attach diagnostic log details. -->

Release candidate: _not assigned_  
Apple TV model / tvOS version: _not recorded_  
Date: _not tested_

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

The tvOS App Store submission feature gate must remain disabled until every box
is complete and `Scripts/validate-tvos-release.sh --archive …` passes.
