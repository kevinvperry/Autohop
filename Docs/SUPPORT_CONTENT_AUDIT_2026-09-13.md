# Support content audit — 13 September 2026

<!-- AI CONTEXT: Read-only content/code audit. This is a findings and remediation document, not a record of content fixes or deployment. Compare live HTML, local website source and in-app SupportContent separately. Version 1.7 is unreleased; do not publish its features as generally available. Preserve existing uncommitted work in both repositories. -->

## Outcome

**The support surfaces are not synchronised and are not ready to be described as current for all features.** There are three versions of the guide: live website, local website source, and in-app content. Local website edits have not all reached production. The in-app guide also contains obsolete instructions and lacks the new Replay workflow.

No app support content or website source was changed or deployed during this audit. This report and the Version 1.7 ledger are the only deliverables. Publishing corrections remains separate work.

## Scope and evidence

- In-app guide: `Views/SupportContent.swift`, rendered by `Views/SupportView.swift`.
- Main settings, podcast settings, Downloads, subscription search, RSS entry, notifications, Replay, Play Instant, category charts and Apple TV setup/diagnostic implementations were inspected to check key claims.
- Website source: `/Users/kevinperry/Developer/kevmarl-site/support.html`, `tvos.html`, `priority.html`, `intelligence.html`, `privacy.html`, `contact.html`, and build pipeline.
- Live pages fetched successfully via HTTPS: [user guide](https://kevmarl.com/autohop/support), [Apple TV guide](https://kevmarl.com/autohop/apple-tv), [Priority Stack](https://kevmarl.com/autohop/priority), [Intelligence](https://kevmarl.com/autohop/intelligence), [privacy](https://kevmarl.com/autohop/privacy), [contact](https://kevmarl.com/contact).
- Compared extracted visible text, excluding scripts, CSS and SVG. Source/live word counts are not parity tests because the build adds shared navigation/footer content.
- Confirmed source/live differences by specific phrases: local support contains Play Instant, Mono Audio and Volume Adjustment; live support contains none of these. Local Intelligence contains Play Instant; live Intelligence does not.
- `build.js` embeds HTML in generated `worker.js`. Changes to HTML alone do not update the live site. Both repositories already contain substantial uncommitted work, so deployment must be reviewed against that full change set.

This is a content/source audit, not a visual/accessibility audit or exhaustive device test. A successful page fetch does not prove all links, forms, controls or examples work. Installed App Store binaries were not reverse-engineered; release assignment must be checked against the closed 1.6.1 ledgers before publishing.

## Priority findings

| Priority | Issue | Evidence and required correction |
| --- | --- | --- |
| High | Removed control still documented | Live App Settings guide lists Radar sensitivity, a 1–60 minute range and 5-minute default. SettingsView now exposes automatic Release Radar, notification settings and schedule inspection. Remove manual sensitivity instructions. |
| High | Notification scope is misleading | Live guide calls it a global master toggle. Current NotificationSettingsView and SettingsView distinguish future-subscription defaults from existing per-show choices. Explain this explicitly; retain Enable All/Disable All separately. |
| High | Obsolete player navigation | In-app and live guides describe a top-left return-to-player button on every page. Current navigation uses back buttons and mini-player ownership. Explain tapping the mini-player where shown; avoid promising it is visible over every modal or keyboard. |
| High | Incorrect Downloads actions | In-app guide says tap row to pause/resume and swipe left to cancel. DownloadsView uses explicit Pause/Resume/Retry controls and playback/archive swipes. Describe actual state-specific controls, including Re-download for archived entries. |
| High | Version 1.7 Play Instant threshold wrong in app guide | SupportContent and its AI header say 60 seconds. PlayInstantWorkflow uses 120 seconds and checks again during the warning. Update 1.7 guidance to two minutes and verify all cancellation/return wording against transport workflow. Live guide currently omits Play Instant entirely. |
| High | Missing Replay instructions | No dedicated in-app or live guide for Replay. Add start selection, Daily/Weekdays/Choose Days, multiple times, saving, shared Episode Limit, filters, caught-up decision, disabling, and normal-download replacement. Label website material as 1.7 until released. |
| High | Missing Binge Mode and sync limits | Explain prefetch on playback start, one upcoming episode plus the playing episode for limit 1, unchanged Up Next priority/manual ordering, fixed scheduling-device responsibility and best-effort background timing. Do not imply automatic cross-device scheduling failover or exact-time delivery. |
| Medium | Old page names | “Priority page” appears repeatedly in both guides. Use Subscriptions for the page and Priority Stack for the ordering concept. Replace the misleading “three main pages” overview with current navigation routes. |
| Medium | Category chart size | In-app Getting Started says category Top 50; PodcastCharts loads category Top 100 and top-eight episode highlights. Separate category charts from other lists that legitimately use 50. |
| Medium | Missing subscription search | Explain magnifying glass beside +, local inline filtering, Clear/Cancel and that this searches existing subscriptions rather than Discover. |
| Medium | Episode-result navigation missing | Explain that episode results open episode details, and the linked show name opens its podcast page for subscription/browsing. Guide currently assumes every search result is a show. |
| Medium | Manual RSS instructions too thin | Add Settings → Subscriptions → Add RSS Feed, publisher RSS link, preview, verification and Subscribe. For 1.7 describe the conditional Preview Podcast button and retry guidance. Do not suggest the example placeholder is an entered URL. |
| Medium | Filter editor lacks operational guidance | Add independent off-by-default groups, multiple Include/Exclude rules, All/Any, Exclude precedence, blank-rule handling, automatic saving, live preview and manual bypass. Explain new 1.7 presentation separately from the underlying existing filter feature. |
| Medium | Missing audio settings on live web | Local guide contains Mono Audio and Volume Adjustment, live guide does not. Publish release-appropriate guidance and include audio/video distinctions. |
| Medium | Refresh cadence mismatch | Live guide says Auto Archive runs at most every 30 minutes. Current coordinator has a 25-minute gate; in-app guide already says 25. Prefer “runs automatically when the app can perform maintenance” unless a precise interval helps the user. |
| Medium | Apple TV setup contradiction | In-app/main website guide discusses finite setup and Demo Library. Live dedicated TV guide instead tells users to wait for startup and omits those recovery choices. TVRootView exposes Check iCloud Again and Explore Demo Library. Align the dedicated guide for the appropriate TV release. |
| Medium | TV Top Shelf instructions incomplete | Dedicated live TV guide lacks the full Top Shelf troubleshooting flow available in TVDiagnosticsView and the main guide. Include top-row placement and Refresh Top Shelf Now with version coverage checked. |
| Medium | iPad/Mac coverage absent or incomplete | Site navigation/footer and guide frequently say iPhone only. Add iPad layouts/widgets and Designed-for-iPad Apple-silicon Mac usage. Do not describe this build as native macOS or promise a menu-bar status icon. Document actual DesktopCommands shortcuts. |
| Medium | Overconfident sync wording | Both guide variants imply position never jumps backwards and downloaded-file separation means mobile data is never used for audio. Explain that each device fetches its own files subject to its network settings, sync is asynchronous, and simultaneous playback may conflict. |
| Medium | Listening Recaps missing from app guide | Live website has a Listening Recaps section; SupportContent notifications section does not. NotificationSettingsView exposes RecapSettingsView. Add weekly/monthly/yearly setup and clarify notification permission. |
| Medium | OPML backup overstatement | “Restore your entire library” overstates a feed-list export. Explain subscription-list portability separately from downloaded files, playback history, settings and iCloud restoration. Verify ordering round-trip before promising it. |
| Low | Excessive internals | RMS, AVAudioEngine/AVPlayer and private storage schema details distract novices. Keep practical behaviour first; move technical explanations into optional details. |
| Low | Bug-report template incomplete | Contact guidance asks only for iOS version. Ask for app version/build, device/platform/OS, steps, expected/actual result and affected podcast/episode; diagnostics only when requested. |

## Coverage matrix

| Topic | Audit outcome |
| --- | --- |
| Getting Started / Discover | Existing but stale page name, category size and show-versus-episode route. |
| Priority / Subscriptions | Core concept covered; local search and current status/navigation missing. Add Replay pill only to 1.7 guidance. |
| Up Next | Priority/manual ordering covered. Explicitly preserve these semantics when adding Binge documentation. Full action behaviour needs a final device walkthrough. |
| Player | Main panels covered; return navigation obsolete. |
| Audio Controls | Live omits controls present in local/app guide. Numeric ranges/defaults should be rechecked at release; no new exhaustive DSP accuracy claim made. |
| CarPlay | Existing focused audio scope is appropriate. Keep streaming/discovery/settings out of CarPlay guidance. No end-to-end car test performed. |
| Chapters | Position-based policy covered; verify current-chapter protection separately for Player and Podcast Settings. Do not conflate their behaviours. |
| Downloads | State-specific controls need correction; avoid universal no-streaming claims that would include Apple TV Discover. |
| Podcast Settings | Main settings covered; new layout, Replay and concise task paths need coverage. |
| Sleep Timer | Existing duration/episode-count instructions present; final runtime preset/fade confirmation remains a release check. |
| Sleep Schedule | Existing setup/check-in instructions present; retain best-effort platform constraints and manual-timer override. Runtime notification testing not performed. |
| Video | Existing basic guidance present; update platform-specific fullscreen/chapters instructions and avoid iPhone rotation assumptions on iPad/Mac. |
| Notifications | High-priority default-versus-master correction plus missing in-app recaps. |
| OPML | Workflow covered but restoration claim too broad. Export UI route should be verified on each platform. |
| iCloud | Coverage exists; correct platform scope, delivery guarantees and media-data wording. Add 1.7 Replay owner semantics. |
| History | Local app guide has richer historical event semantics than live website. Preserve event-time labels versus current episode status. |
| Stats | Broad coverage exists. Retain top-50 shows versus episodes distinction and caveat that historical data predates some counters. All numerical metric claims not independently recomputed. |
| Widgets | Existing guide primarily says iPhone. Add iPad and preserve snapshot freshness/privacy limits. |
| App Settings | Remove obsolete Radar control, clarify defaults, add current paths and device coverage. |
| Contact / Privacy | Links respond; privacy is a separate policy surface, not an app instruction guide. Retain distinction between optional website analytics and the app. No legal compliance certification or contact form submission performed. |
| Dedicated TV guide | Fetches successfully; setup and Top Shelf material lag the main guide. Treat TV release status independently. |
| Priority / Intelligence web explainers | Keep conceptual content aligned; Intelligence source has unpublished Play Instant material. Review duplicate instructions whenever support changes. |

## Release-safe remediation plan

1. Establish release coverage from VERSION_1.6.1.md, TV release ledger and VERSION_1.7.md. Current 1.7 ledger explicitly says not released. Do not infer TV approval from iOS approval.
2. Correct already-shipped instruction defects in both SupportContent and support.html. Add missing 1.6.1 platform coverage after checking the release ledger.
3. Write dedicated 1.7 Replay/Binge, filters and manual RSS walkthroughs. Include availability notices on the website; the next app build can carry its matching guide.
4. Update tvos.html independently for the TV build available to users. Align Priority/Intelligence and shared website navigation terminology.
5. Simplify paragraphs without removing important scope, recovery or timing caveats. Use short steps with exact current control labels.
6. Review website diff including existing unrelated edits before generating worker.js. Run `node build.js` only as part of the reviewed site update; never hand-edit generated worker.js.
7. Validate local routes/anchors, then test the guide against installed builds on iPhone, iPad, Mac and TV. Test search, RSS, subscription settings and Replay on a development build without changing a real library unintentionally.
8. Deploy only the reviewed release-appropriate site changes. Re-fetch production and compare the actual guide text with the approved output. A local build is not proof of publication.

## Preventing recurrence

Replace the current manual mirror contract with a shared, versioned content source that can render Swift support blocks and web HTML, or at minimum maintain a feature-to-section parity checklist. Store platform and introduced-version metadata per topic. CI should detect missing section IDs, stale UI labels and broken local links; numeric timing claims should link to the owning implementation. Keep production publication and app release as explicit separate checks.

## Acceptance criteria for a subsequent correction task

- No instructions for removed controls or obsolete navigation.
- Every released user-facing feature has a task-based guide route.
- 1.7 features clearly distinguished from released features online.
- All in-app section topics have corresponding web coverage; web-only illustrations may differ.
- Platform limitations and setting scope are explicit.
- Build, local links, visual/accessibility checks and post-deployment text comparison each recorded separately.

**Current status: audit complete at the source/content level; corrections, device walkthroughs and publication remain outstanding.**

## Implementation follow-up

Source corrections are now implemented in SupportContent and the local website. The guide exports from one Swift content source using `Scripts/export_support_website.py /Users/kevinperry/Developer/kevmarl-site`; run `node build.js` in that website repository afterwards. All 23 sections are included. Existing audio subsection anchors remain supported. The website availability notice distinguishes unreleased 1.7 workflows and the Play Instant threshold from 1.6.1. Dedicated TV recovery instructions are conditional on installed-version capability because TV approval was not confirmed in this task.

The generated website guide replaces bespoke guide-body illustrations with the same text/tables as the app. Priority illustrations remain on the separate Priority explainer. The renderer emits semantic headings, lists and tables, but browser visual/accessibility checks remain required.

Build and structural checks passed. Publication is pending: the existing website bundle includes unrelated edits to stats-api.js, stats.html, privacy.html, worker configuration and other pages. Do not deploy that entire bundle under an assumption that it contains only these support changes. Review the website diff before approving publication, or isolate the support changes against a known deployed-source revision.

Remaining acceptance checks: installed-device walkthroughs, browser presentation/accessibility, review of bundled website changes and post-deployment live comparison. The live site is unchanged by this task.

## Publication completed

On 13 September 2026 the user explicitly authorised all website updates, including the pre-existing bundle changes. Wrangler deployed version `b4bf9f23-2777-478c-981a-5a82923a5c86`. Fresh public-domain requests confirmed the updated support, TV, contact and Intelligence content; privacy and Priority routes responded successfully. Initial cached output was old, so verification used a release query parameter. Visual/device/accessibility walkthroughs and authenticated stats checks remain separate outstanding checks; publication is no longer pending.
