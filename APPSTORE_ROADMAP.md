# Autohop — App Store Submission Roadmap

**Status legend:** ✅ done · 🔄 in progress · ⬜ not started · 🧍 needs you (Apple account / device / asset / decision)
**Owner:** **[Me]** = doable in-repo by the assistant · **[You]** = requires your Apple account, hardware, or a manual store action.
**Last updated:** 2026-06-14
**STATUS: SUBMITTED — v1.0 (build 1) "Waiting for Review" as of 2026-06-14. Apple ID 6777946512. Awaiting review outcome (24–48h).**

> **v1 scope decision: iPhone only.** `TARGETED_DEVICE_FAMILY = 1`. iPad layout/screenshots are out of scope for v1.

---

## Progress at a glance

| # | Item | Pri | Owner | Status |
|---|------|-----|-------|--------|
| A1 | Remove unused `processing` background mode | P0 | Me | ✅ |
| A2 | Finalize ATS posture + justification | P0 | Me/You | ✅ (reverted to clean global allowance) · 🧍 review note to paste |
| A6 | Defer notification permission to user opt-in | P2 | Me | ✅ |
| A7 | Required-reason API audit (privacy manifest) | P1 | Me | ✅ clean |
| A3 | Time Sensitive Notifications entitlement provisioning | P0 | Me/You | ✅ entitlement provisions cleanly via auto-signing (no errors on device) |
| A4 | Fix stale privacy-manifest comment | P1 | Me | ✅ |
| B5 | iPhone-only cleanup (orientation keys + website badge) | P0 | Me | ✅ |
| C6 | Apple Developer Program enrollment | P0 | You | ⬜ |
| C7 | Signing & team in Xcode | P0 | You | ✅ auto-signing, team Kevin Perry, runs on device |
| C8 | Release archive + validate | P0 | You | ✅ validation successful (1.0/build 1) |
| D9 | Create App Store Connect record | P0 | You | ✅ Apple ID 6777946512, SKU autohop-1 |
| D10 | Category selection | P0 | You | ⬜ |
| D11 | Screenshots (6.9"/6.7" iPhone) | P0 | You | ✅ 6 shots @ 1290×2796 (6.9" slot) |
| D12 | Listing copy (name/subtitle/desc/keywords) | P0 | Me | ✅ draft (Appendix 1) |
| D13 | Support / Marketing / Privacy URLs | P0 | You | ✅ URLs ready |
| D14 | App Privacy "Data Not Collected" answers | P0 | Me/You | ✅ published in ASC (Data Not Collected) |
| D15 | Age rating questionnaire | P0 | You | ✅ 9+ (UGC=No; profanity/substances=Infrequent) |
| D16 | Export compliance (encryption=false) | P0 | — | ✅ already set |
| E17 | MPL-2.0 source availability (link/offer) | P0 | Me/You | ✅ public repo + in-app/NOTICE links |
| E18 | Apple charts/API terms comfort check | P1 | You | ⬜ |
| E19 | App Review notes | P0 | Me | ✅ draft (Appendix 2) |
| F20 | TestFlight beta pass | P1 | You | ⬜ |
| F21 | On-device validation of new features | P1 | You | ✅ on iPhone 17 Pro Max |
| F22 | Accessibility pass | P1 | Me/You | ✅ (labels added) · 🧍 on-device VoiceOver check |
| F23 | Fix `swift test` target import | P2 | Me | ✅ (+ fixed a real parser bug; 4/4 pass) |
| G24 | Real App Store CTA link on website | P1 | Me | 🔄 (badge fixed; link pending approval) |

---

## A. Blocking technical fixes (config)

- ✅ **A1 — Removed `processing` from `UIBackgroundModes`** (`project.yml`). Only `audio` + `fetch` remain — both are actually used. Avoids Guideline 2.5.4 rejection.
- ✅ **A2 — ATS finalized** (`project.yml`). `NSAllowsArbitraryLoads: true`, **no granular sub-keys**. This is required and defensible: feeds/enclosures/artwork are fetched via `URLSession` from unbounded, user-supplied third-party hosts (many HTTP-only); Autohop runs no first-party server. Per-domain `NSExceptionDomains` cannot enumerate an open-ended host set, so domain-scoping is not viable for a general podcast client. **Gotcha avoided:** an earlier attempt added `…InWebContent`/`…ForMedia` sub-keys — but on iOS 10+ the presence of any granular key makes the system *ignore* `NSAllowsArbitraryLoads`, which would have **blocked** our HTTP `URLSession` loads. Those sub-keys were removed. Justification is in Appendix 2 (paste into App Review notes 🧍). NOTE: a stale generated `./Info.plist` on disk still shows the old TODO comment — it is a build artifact and is reconciled on the next `xcodegen generate`.
- ✅ **A6 — Notification permission deferred to user opt-in.** Removed the launch-time `requestPermission()` from `AppState` bootstrap. `NotificationService.configure()` (delegate + categories) still runs at launch but no longer prompts; `requestPermission()` now only fires from user opt-ins: the notification toggles (`NotificationSettingsView`) and enabling Sleep Schedule (`SleepScheduleView`). Better polish + opt-in rates.
- ✅ **A7 — Required-reason API audit.** Confirmed the privacy manifest is complete: no system-boot-time or volume disk-space APIs are used (SettingsView reads per-file `.fileSizeKey` only, which is not the regulated category); file-timestamp (AppLogger) and UserDefaults are both declared. Stale comment corrected (see A4).
- ✅/🧍 **A3 — Time Sensitive Notifications entitlement.** In-repo work done: `project.yml` declares `com.apple.developer.usernotifications.time-sensitive`, it is present in `Autohop.entitlements`, and `xcodegen generate` has been run (project + `Info.plist` reconciled, plist valid). Remaining 🧍: (1) enable the **Time Sensitive Notifications** capability on the App ID in the Apple Developer portal; (2) regenerate the provisioning profile. Without (1) the entitlement will fail to provision and the archive will fail signing.
- ✅ **A4 — Privacy-manifest comment corrected** (`PrivacyInfo.xcprivacy`). The stale "single UUID refresh cursor" note (cursor was removed) now accurately describes UserDefaults usage (app settings + UI prefs). Declaration/reason code unchanged.

## B. Product decision

- ✅ **B5 — iPhone-only for v1.** Removed `UISupportedInterfaceOrientations~ipad` from `project.yml`; website badge changed to "iPhone · iOS 17+" and redeployed. (Optional P2: prune iPad image entries from `AppIcon.appiconset` — harmless to leave.)

## C. Signing & build — 🧍 You

- ⬜ **C6** Enroll in / confirm Apple Developer Program ($99/yr).
- ⬜ **C7** Xcode → Autohop target → Signing & Capabilities: select Team, confirm bundle ID `com.kevinperry.autohop`, automatic signing. (Do this after `xcodegen generate`.)
- ⬜ **C8** `Product → Archive`, validate in Organizer.

## D. App Store Connect — metadata & assets

- ⬜ **D9** Create the app record (name "Autohop", primary language en, bundle ID, SKU).
- ⬜ **D10** Category — recommended **Primary: News**, **Secondary: Entertainment** (matches how Pocket Casts/Overcast are categorized).
- ✅ **D11** Screenshots — 6 captured on a Pro Max device at **1290×2796** (accepted in the 6.9" slot). Set: Now Playing (hero), Sleep Schedule, Audio Controls, Subscriptions/Priority, Top Shows (Stats), Discover. Recommended order: Now Playing → Sleep Schedule → Audio Controls → Subscriptions → Discover → Stats. Optional later polish: Shared Listening ON, Subscriptions from #1, Stats heatmap variant.
- ✅ **D12** Listing copy drafted — Appendix 1.
- ✅ **D13** URLs ready: Support `https://kevmarl.com/autohop/support` · Marketing `https://kevmarl.com/autohop` · Privacy `https://kevmarl.com/autohop/privacy`.
- ✅ **D14** App Privacy answers drafted — Appendix 4 ("Data Not Collected").
- ✅ **D15** Age rating questionnaire completed → **9+ global** (Brazil A10, Korea ALL as auto regional equivalents). Answers: In-App Controls all No; Unrestricted Web Access No; **User-Generated Content No** (podcasts are third-party-published RSS, not app-user content — avoids Guideline 1.2 UGC-safeguard requirements); Messaging/Advertising No; Mature Themes — Profanity and Alcohol/Tobacco/Drug references set to **Infrequent** (honest for an open podcast catalog), Horror None. Age Suitability URL left blank (optional).
- ✅ **D16** Export compliance: `ITSAppUsesNonExemptEncryption = false` already set.

## E. Legal & compliance

- ✅ **E17 — MPL-2.0 source availability.** `SilenceDetector.swift` + `PlaybackEngine.swift` are MPL-covered. The Autohop repo is **public** (`https://github.com/kevinvperry/Autohop`) and both modified files are live on `main`, so MPL §3.2's source-availability requirement for binary recipients is met. Wired the public repo URL into both `NOTICE` (§3.2 paragraph) and the in-app Acknowledgements footer (`AcknowledgementsView.swift`), pointing recipients to Autohop's *own* modified files — separate from, and in addition to, the existing upstream attribution to Pocket Casts / Automattic (unchanged).
- ⬜ **E18 — Apple charts/API comfort check.** Using public RSS + Apple's public iTunes Search / chart feeds is standard; confirm you're comfortable displaying Apple Podcasts charts on Discover.
- ✅ **E19 — App Review notes drafted** — Appendix 2.

## F. QA & testing — mostly 🧍 You

- ⬜ **F20** TestFlight internal beta round on real hardware.
- ⬜ **F21** On-device validation, especially: time-sensitive lock-screen "Still Listening" notification under Sleep Focus; background downloads; Release Radar wake-ups; video full-screen/landscape.
- ✅ **F22 — Accessibility labels added** to the icon-only custom player controls that lacked them: Play/Pause (dynamic), Audio controls, Sleep timer, Share, Archive, and the full-screen-video Close button. (The new Sleep Schedule indicator, Still Listening button, and Support drill-down rows were already labelled or text-based.) 🧍 Remaining: an on-device VoiceOver + Dynamic Type spot-check by you before submission.
- ✅ **F23 — `swift test` fixed.** `RSSParserTests` used `@testable import Autohop`; it now uses a conditional import (`AutohopCore` under SwiftPM via an `AUTOHOP_SPM` define, app module under the Xcode test bundle). Running it surfaced — and I fixed — a **real RSS parser bug**: when a `<media:content>` element (no `length`) preceded the `<enclosure>` (with `length`), the file size was lost; `RSSParser.captureMediaURL` now fills `fileSizeBytes` from whichever playable element carries a real length for the chosen URL. **All 4 tests pass** (`swift test --filter RSSParserTests`, 0 failures).
  - Note: this environment has an intermittent SwiftPM "modified during the build" clock-skew flake on incremental builds; a clean build (`swift package clean`) produces a stable green run.

## H. Pre-archive enhancements (2026-06-14)

- ✅ **Share Sheet — richer cards (Tier 1+2).** Parser now captures the episode web page (`<item><link>`) into `Episode.episodeLink`; the share sheet shares that (fallback: `episodeLink → http(s) permalink guid → enclosure`) wrapped in `LPLinkMetadata` (card image + "Episode — Podcast" title) so recipients get a rich, openable preview instead of a raw enclosure URL. Verified on device. Tiers 3 (text blurb) + 4 (duration on card) logged in `FUTURE_VERSIONS.md`.
- ✅ **Entity-decoding bug fixed.** Double-encoded feeds (Omny/Megaphone `&amp;amp;`) showed literal `&amp;` in titles. `RSSParser.decodingEntities()` repairs display fields (title/subtitle/author/description, episode + channel) — never guid/dates/URLs. Regression tests added; verified on device after a feed refresh. (Single source of truth = parser, so every screen benefits.)
- ✅ **Default settings review.** New-install / new-subscription defaults changed: Download over Cellular → **Off**; new-subscription Speed → **1×**, Vocal Boost → **Off**, Trim Silence → **Off**; global Notify New Episodes → **Off** (per-podcast notifications already Off). Existing subscriptions/installs unaffected (one-shot migrations use hardcoded values). Full defaults table captured during review.

- ✅ **Archive validation fix (iPad multitasking, code 90474).** First `Validate App` failed: the iPhone orientation set lacked `PortraitUpsideDown` "to support iPad multitasking" — i.e. the bundle was going up **iPad-capable**. Root cause: `TARGETED_DEVICE_FAMILY` was only set at the project base in `project.yml`, and the app **target** configs resolved to `1,2`. Fixed by setting `TARGETED_DEVICE_FAMILY: "1"` explicitly on the **app target** in `project.yml` (both app configs now `= 1`; orientations left at 3 since the bundle is now genuinely iPhone-only). Also baked `DEVELOPMENT_TEAM: QT3N6256FG` into `project.yml` so automatic-signing team survives every `xcodegen generate` (it was being wiped on regen).

## G. Website / post-approval

- 🔄 **G24** Website badge now iPhone-only. Remaining: after approval, replace the "Coming to App Store" CTA (`autohop.html`, currently `href="#"`) with the real App Store URL + badge, then redeploy.

---

## Appendix 1 — App Store listing copy (draft)

**App name:** Autohop

**Subtitle (≤30):** `Priority-queue podcast player`

**Promotional text (≤170):**
`Set your show priorities once and listen for hours, hands-free. New: a nightly Sleep Schedule that checks if you're still awake, and one-tap Shared Listening for the car.`

**Keywords (≤100, comma-separated, no spaces):**
`podcast,player,queue,priority,trim silence,vocal boost,sleep timer,download,offline,chapters`

**Description:**
```
Autohop is the podcast player for people who are serious about listening. Set your show priorities once and Autohop runs down the list automatically — downloading ahead, playing in your order, and tidying up after itself — indefinitely. No daily queue management.

PRIORITY STACK
Rank your podcasts once by drag-and-drop. Autohop always plays your highest-priority show's ready episodes first, then moves down the list. Finish an episode mid-commute and the next one starts on its own.

SLEEP SCHEDULE (an Autohop exclusive)
A sleep timer that runs itself, every night. Set your bedtime hours once; Autohop checks in with a soft chime — "still listening?" Tap any control to keep going, even a "Still Listening" button right on your lock screen. Drift off and playback gently fades out and rewinds to the last thing you heard.

SHARED LISTENING
Listening in the car with others? One switch temporarily relaxes every show to a comfortable group speed and pauses silence trimming — and one switch brings all your personal settings straight back.

AUDIO, TUNED PER SHOW
- Trim Silence (four levels) removes dead air without touching speech.
- Vocal Boost (four levels) lifts voices above background noise.
- Per-podcast speed, start skip, and end skip.

BUILT TO STAY AHEAD
- Release Radar learns each show's schedule and catches new episodes within minutes of release.
- Download-first playback — no buffering, no stalls on a weak signal.
- Per-podcast auto-archive keeps storage tidy automatically.
- Chapter support with automatic skipping of chapters you've disabled.
- Audio and video podcasts, with full-screen landscape video.
- A private, on-device Stats page: listening heatmap, 24-hour clock, top shows, streaks, and exactly how much time Autohop has saved you.

PRIVATE BY DESIGN
No account. No analytics. No third-party SDKs. Everything Autohop stores stays on your device.

Autohop is open source under the MIT License, with two audio-engine files used under the Mozilla Public License 2.0 (derived from Pocket Casts for iOS).
```

> Accuracy note: every sentence above describes shipped behaviour — no future/roadmap features are promoted.

---

## Appendix 2 — App Review notes (draft)

```
No account or login is required to use Autohop — open the app and all features are available.

WHAT IT DOES
Autohop is a download-first podcast player. Users subscribe to public RSS podcast feeds (or browse Apple's public Podcasts charts), rank their shows, and Autohop builds and plays an automatic queue.

BACKGROUND MODES
- audio: AVAudioSession keeps podcast playback alive when the screen locks.
- fetch (BGAppRefreshTask "com.autohop.feedrefresh"): periodically checks subscribed feeds for new episodes. No other background modes are declared.

APP TRANSPORT SECURITY
NSAllowsArbitraryLoads is enabled because podcast feeds, episode audio/video enclosures, and artwork are served from arbitrary third-party hosts chosen by the user (and by Apple's public chart feeds). Many podcast hosts still serve plain HTTP, and the set of hosts is unbounded and unknown at build time, so per-domain exceptions are not possible. Autohop adds no first-party HTTP endpoints and operates no server of its own.

TIME SENSITIVE NOTIFICATIONS
The optional "Sleep Schedule" feature posts a local, time-sensitive notification ("Are you still listening?") with a "Still Listening" action so a user can confirm from the lock screen without unlocking. It is generated entirely on-device; APNs is not used.

PRIVACY
Autohop collects no data and contains no analytics, advertising, or tracking SDKs. All user data (subscriptions, playback position, listening history, stats, settings) is stored on-device only. See the privacy manifest and https://kevmarl.com/autohop/privacy.

HOW TO TEST SLEEP SCHEDULE QUICKLY
Menu (☰) → Sleep Schedule → enable, set the active-hours window to cover the current time, set "Ask Every" to the shortest interval, then play any downloaded episode and wait for the prompt.

OPEN SOURCE
Two audio files (SilenceDetector.swift, PlaybackEngine.swift) are derived from Pocket Casts for iOS under MPL-2.0; see in-app Settings → Open Source Acknowledgements.
```

---

## Appendix 3 — Screenshot shot list (iPhone 6.9" + 6.7")

1. **Player — Now Playing** (artwork, scrubber, controls) — the hero shot.
2. **Priority Stack** (Subscriptions home, a few ranked shows).
3. **Queue** with a swipe action revealed (Play Next / Archive).
4. **Audio Controls** sheet (speed / Trim Silence / Vocal Boost) — ideally with Shared Listening on.
5. **Sleep Schedule** page (the exclusive — show the active hours + Ask Every).
6. **Stats** (heatmap + hero numbers).
7. **Discover** (Top-8 hero + a genre rail).

Tip: add a one-line caption overlay per shot leading with the benefit. Keep ordering benefit-first (Player, Priority, Sleep Schedule rank highest).

---

## Appendix 4 — App Privacy answers (App Store Connect)

Answer **"No, we do not collect data from this app."** This matches `PrivacyInfo.xcprivacy` (`NSPrivacyCollectedDataTypes` empty, `NSPrivacyTracking` false) and the privacy policy. No data types, no tracking, no third-party SDKs. Network calls are only to user-chosen feeds/media and Apple's public podcast directory/charts; nothing the user generates is transmitted.
```
