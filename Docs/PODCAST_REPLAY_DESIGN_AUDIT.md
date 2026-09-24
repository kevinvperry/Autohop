# Podcast Replay — design audit and implementation

<!--
AI CONTEXT — Version 1.7 design audit, 13 September 2026.
Scope: Podcast Replay entry, editor and episode picker. Source authorities are
SubscriptionSettingsView.swift and PodcastReplayView.swift; runtime scheduling
remains in PodcastReplayCoordinator/PodcastReplay. This is an implementation
record, not a claim of device or accessibility testing beyond the results below.
Keep section ordering, shortcut indices, design primitives and explanatory copy
aligned with FEATURES.md, DESIGN.md, PAGES.md and VERSION_1.7.md.
-->

## Outcome

Podcast Replay now has a dedicated Podcast Settings section immediately above Download Feed Filters, with a prominent setup/manage link, concise benefit statement and active Replay pill. It also has its own iPad/Mac settings-sidebar shortcut. Both section-to-shortcut mappings were shifted, including the conditional Chapters section and Playback's two sections.

The editor uses the established black workspace, purple controls, regular glass cards (`glassCard(cornerRadius: 12)`), 20-point internal card padding, adaptive Form sizing, shared settings section spacing, `SettingsRowLabel`, circular Back control, inline responsive navigation title and shared mini-player. Native controls retain platform accessibility and keyboard behaviour. Red is reserved for the explicit Turn Off action; the established Replay status pill retains its indigo state colour.

## Section-by-section audit

| Surface | Finding in initial implementation | Implemented improvement |
| --- | --- | --- |
| Settings entry | Replay was a link buried inside the Automation card. | Dedicated section above filters; clear Set Up/Manage wording, short benefit statement, active pill and sidebar shortcut. |
| Page introduction | No introduction or podcast identity; setup began directly with controls. | Dark glass hero card with a purple accent border identifies the podcast and explains the feature in plain language. No unsupported claim of market exclusivity is added. |
| Current schedule | Status, choices and Turn Off appeared together before setup. | Separate status card explains waiting, shows outstanding count and retains caught-up Keep Schedule choice. Turn Off moves to the final action card. |
| Starting episode | Search and a navigation-link Form Picker were mixed together; selected content was hard to inspect. | Artwork, episode title and date show the current choice. A dedicated searchable catalogue page offers full-row selection, a selected checkmark and release dates, oldest first. |
| Catalogue loading | Draft fields were initialised only after an awaited refresh. | Initialise the draft immediately and show a refresh indicator. A late response does not overwrite an episode selected during the fetch. |
| Recurrence | A numeric stepper was the only way to set frequency. | Daily / Weekdays / Choose Days, with a wrapping weekday selector and at least one day required. Additional time rows appear only on Add another time. One episode per unique time per selected day. |
| Release date/time | One control labelled “First / next release” obscured its purpose. | Start date / Continue from plus multiple time controls. The summary and preview show the first actual matching slot, rolling forward past unselected days. Duplicate times prevent Save with clear guidance. |
| Time zone | Native date controls could use the viewing device's zone while the schedule used its stored zone. | Date controls, summary and preview explicitly use the stored schedule time zone; the zone and background-delay explanation are visible. |
| Preview | A list of three titles lacked timing or sequence cues. | Numbered episode preview with planned dates/times and a clear capacity qualification. Draft recurrence changes update the preview. Missing metadata/filter exclusions are explained. |
| Episode Limit / filters | Settings and long technical explanations were combined in a generic section. | “Make room for listening” explains capacity with an everyday example. Filter settings open directly; the inline Episode Limit menu saves immediately through its existing store setting and mirrors Podcast Settings. |
| Notification preference | Toggle shared a schedule section and inherited default system appearance. | Dedicated explanation and shared purple SettingsRowLabel toggle. Copy explains that the caught-up choice remains available with notifications off. |
| Cross-device acknowledgement | Dense terminology and a long toggle title made enablement difficult to understand. | Removed the separate device section and acknowledgement toggle. Concise update/sync and fixed scheduling-device notes appear near Enable/Save. |
| Save/enable | Plain text action gave little indication of importance or why it was disabled. | Full-width purple prominent action, explanation of paused normal downloads, and inline disabled-state guidance. Device identity failure is explained. |
| Turn Off | Destructive action competed with setup at the top of the page. | Separate red action at the bottom with a short explanation that existing downloads remain available. Existing disable behaviour is retained. |
| Missing subscription / no search results | Editor could show an empty Form. | Explicit unavailable-subscription and no-search-results states. |
| Layout and navigation | Default Form tint, backgrounds and title/back treatment did not match adjacent pages. | Shared design primitives on editor and picker; wrapping text, no fixed card heights, semantic headings, native toggles/pickers and mini-player coverage. |

## Behaviour preserved

Draft edits are saved only by Enable Podcast Replay / Save Schedule. Starting point remains fixed for an active session. The compatibility acknowledgement no longer gates saving. Episode Limit saves immediately and Feed Filters retains its existing owner; no duplicate configuration is created. Notifications still request permission only when saving with the preference enabled. Catch-up, disabling, queue ordering, owner identity and background execution policy are unchanged. Calendar schedules now support chosen weekdays and multiple daily slots; unchanged drafts preserve live progress.

## Earlier visual validation (before the calendar-controls refinement)

The final iOS simulator build passed; 37 focused tests passed (25 Podcast Replay and 12 adaptive layout tests). On the iPhone 17 Pro Max simulator running iOS 26.5, inspected the dedicated settings entry and the setup, preview, capacity, notification and device cards; opened Feed Filters and returned to the unchanged draft; confirmed device acknowledgement enables the primary action; searched the catalogue for “Pizza” and selected an earlier episode, verifying the draft title/date changed. This review found excessive saturation and weak secondary-text contrast on the initial highlighted hero, which was replaced with dark glass and a purple border. A final simulator inspection confirmed the corrected hero appearance and the shared mini-player with a paused episode loaded.

Physical Mac/iPad, maximum Dynamic Type, VoiceOver interaction, active/caught-up layouts and older-iOS fallback visual checks remain outstanding; code inspection of their shared layout is not runtime verification. No Replay schedule was enabled during the visual check. No implementation-mirroring tests were added for cosmetic layout. Logs: `/tmp/replay-design-tests.log` and `/tmp/replay-design-final-build.log`.

## Calendar controls and shared limits — 13 September 2026

Daily / Weekdays / Choose Days replace the interval controls. Selected weekdays are required; additional release-time rows appear on demand, duplicate times cannot be saved, and the preview rolls the start date forward to an actual selected slot. The user confirmed that interval compatibility UI is unnecessary because Replay has only one test installation. Old test data still decodes, but the editor adopts the new controls directly.

Episode Limit now saves immediately to the shared AutoArchiveSettings field. The separate device card and acknowledgement gate are removed; concise update/sync and fixed scheduling-device guidance remains near Enable/Save. The fixed scheduling device has not been replaced by automatic failover or capability detection.

Validation: **48 iOS simulator tests passed** (36 Replay, 12 adaptive layout), including chosen weekdays, morning/afternoon slots, weekend skipping, first-date roll-forward, duplicate/invalid schedule validation, filters/capacity, DST gap/repeat handling, stored time zones, JSON round trips, cadence edits merged with old progress, and shared Episode Limit persistence. The test action built the iOS app successfully; the tvOS simulator build also passed. Logs: `/tmp/replay-calendar-tests.log`, `/tmp/replay-calendar-tv-build.log`.

On the iPhone 17 Pro Max/iOS 26.5 simulator, verified Weekdays rolls Sunday forward to Monday, adding a second time updates the preview, and selecting Tuesday/Thursday produces two Tuesday releases followed by Thursday. Inspected the wrapping day buttons, time rows, capacity card and mini-player. Changed Episode Limit from 1 to 2 in Replay, confirmed 2 in Podcast Settings, restored 1 there and confirmed 1 in Replay. The test setting was restored and no Replay schedule was enabled. Enable is available without device acknowledgement. Physical iPad/Mac, maximum Dynamic Type, VoiceOver, real multi-device CloudKit and background/device acceptance remain outstanding.

## Binge Mode refinement — 13 September 2026

A dedicated Binge Mode card sits above Set your pace with the same purple toggle and glass styling. When on, the pace card is absent, the preview explains playback-triggered preparation rather than showing dates, and capacity text explains the started episode plus one upcoming episode at limit 1. Both setup and active-mode saving use the existing draft/commit flow. The existing Up Next priority order remains authoritative; the UI explicitly says so.

Binge validation: 59 focused simulator tests passed (47 Replay, 4 completion, 8 QueueModel); iOS test build and final tvOS simulator build passed. On iPhone 17 Pro Max/iOS 26.5, the Binge toggle hid Set your pace, changed the preview to playback-triggered copy, and restored the same Daily/date/time values when turned off. Card styling and mini-player layout were inspected. No mode was committed and no playback was started during this UI check. Real-device prefetch timing, CloudKit/TV propagation, background execution, iPad/Mac and accessibility remain acceptance checks. Logs: `/tmp/replay-binge-tests-final.log`, `/tmp/replay-binge-tv-build.log`.
