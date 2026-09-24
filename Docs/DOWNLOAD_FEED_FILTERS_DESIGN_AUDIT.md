# Download Feed Filters — design audit

<!-- AI CONTEXT — Version 1.7, 13 September 2026. Implementation authority:
DownloadFiltersView in Views/SubscriptionSettingsView.swift. Presentation changes
must preserve DownloadFilterSettings.evaluation/storage semantics. Keep FEATURES,
PAGES, DESIGN and VERSION_1.7 aligned. Record runtime validation separately from
build/tests; no claim of physical-device or CloudKit acceptance is implied. -->

## Design changes

| Surface | Previous issue | Implemented improvement |
| --- | --- | --- |
| Introduction | Began with an unexplained All/Any selector | Podcast identity, benefit statement, active status and immediate-save/manual-download/Replay explanation |
| Disabled groups | Rule editors remained visible | Hide editors while off; preserve saved rules and explain that they remain available |
| Length rules | Comparison and minute stepper competed horizontally | Separate rows, native 1–300-minute stepper, Include/Exclude and a sentence summarising the rule |
| Text rules | Generic Match/Text labels | Title/description examples, words-or-phrase field, contains/not-contains picker, blank-rule explanation and rule summary |
| Multiple rules | Visually merged together | Distinct inset rule panels and visible Add/Remove actions |
| Rule combination | All/Any was unexplained | Dedicated explanatory card after the rule groups; examples of AND/OR and Exclude precedence |
| Preview | Stale settings captured before fetch; no match totals | Cache Episodes and evaluate current rules live, including edits made during fetch; match/skip counts |
| Preview readability | Skipped results heavily faded | Explicit Matches/Skipped labels and readable wrapping reasons; no opacity reduction |
| Empty/loading/error | Minimal feedback | Clear idle guidance, loading, retry and empty-feed copy |
| Page chrome | Default grouped rows | Replay-style dark glass cards, purple controls/icons, adaptive sizing and shared spacing |

## Preserved functionality

Duration Include/Exclude, longer/shorter comparisons, every integer minute from 1–300, title and description Include/Exclude, contains/does-not-contain, multiple rules, rule removal, All/Any, Exclude precedence, blank-term handling, immediate saving and existing iCloud projection are retained. Group switches never delete rules. Preview remains a read-only RSS fetch of up to 50 entries; no media downloads or fallback to stale stored catalogue. Onboarding and contextual mini-player remain attached. Manual episode actions still bypass filters; Replay and Binge Mode still use the shared evaluator.


Preview initially shows five episodes, with Show All / Show Fewer controls retaining access to every fetched result. Counts always describe the full fetched set.

## Validation

24 focused iOS simulator tests passed (20 subscription-sync, 4 Replay filter regressions). Final iOS simulator build and whitespace checks passed. Simulator inspection covered default cards, purple styling, disabled groups, enabling length filters, adding an Include Longer than 40-minute rule, the resulting summary, preview fetch and counts. Turning length filters off updated the cached preview from 48 matches/2 skipped to 50 matches/0 skipped without another fetch. All groups were left off; a disabled example length rule remains on the local test simulator. The final compact preview was verified in the simulator: five initial episode results and a Show All 50 Episodes button, with counts covering all 50 entries. No audio playback or media download was initiated by the preview.

Physical iPad/Mac, maximum Dynamic Type, VoiceOver, keyboard behaviour and exhaustive text-rule interaction checks remain outstanding. Logs: `/tmp/feed-filter-design-tests.log`, `/tmp/feed-filter-design-final-build.log`.

## Default-state follow-up — 13 September 2026

All filter groups already default off in `DownloadFilterSettings.default`. The editor binds to saved subscription settings and has no appearance-time enable operation. Preserve saved true/false values even when a group has no rules; do not infer that these are unconfigured. Regression tests cover new subscriptions, legacy missing settings and persistence/sync round trips. The reported title-on state has not been reproduced as a fresh-default defect.

Validation: all 22 SubscriptionSyncTests passed on the iOS simulator, including the new default/preservation cases; `git diff --check` passed. No existing user settings were rewritten.

### Text-rule input visibility — 13 September 2026

The reported black bar is the editable phrase field. Explicit plain text-field styling, white semibold text, intrinsic vertical sizing and a minimum 44-point input height now prevent a compressed or low-contrast field inside the nested Form card. A subtle purple border and “Words or phrase” label identify the editable value. Shorter group explanations and removal of the duplicate rule sentence reduce clutter. Both title and description editors share the fix; saved terms and matching behaviour are unchanged. Long phrases can grow to six visible lines and scroll within the field.

Validation: iOS simulator build succeeded and whitespace checks passed. This follow-up has not yet been visually verified on a running device or simulator; confirm phrase visibility and editing with the reported “The Breakers” rule.
