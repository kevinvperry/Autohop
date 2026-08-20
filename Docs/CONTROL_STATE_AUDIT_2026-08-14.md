# Interactive Control State Audit — 14 August 2026

<!--
AI CONTEXT — End-to-end audit for controls that successfully persist a command
but fail to redraw because their displayed value observes the wrong owner. Keep
this aligned with the Stage 14 narrow-observable architecture and update it when
new control families or state owners are introduced.
-->

## Audit question

For every native or custom interactive control, does the displayed value observe
the object that publishes the mutation, or an intentional local draft that is
reconciled with its persisted owner? Calling a command through `AppState` is not
enough to refresh a view because AppState intentionally does not forward domain
`objectWillChange` events.

## Results

| Surface | Controls | Display owner | Result |
|---|---|---|---|
| Player Audio Controls | Shared Listening toggle/speed; podcast speed, trim and vocal controls | `SettingsViewModel` for Shared Listening; `SubscriptionStore` for podcast preferences | Shared controls repaired. Podcast controls already correct. |
| Player action row | Shared Listening highlight, Sleep Timer, playback controls, scrubber | `SettingsViewModel`, `SleepTimerService`, `PlaybackCoordinator`/`PlaybackClock`, local seek draft | Shared highlight repaired; others correct. |
| App Settings | Launch screen, download networks, screen awake, lock-screen scrubbing, badge, iCloud, diagnostics, default playback/archive, trim drafts | `SettingsViewModel`; local debounced trim/skip drafts | Correct. Cross-domain commands still redraw through the settings publisher. |
| Notification Settings / Recaps | Master, podcast, weekly/monthly/yearly toggles | `SettingsViewModel` and `SubscriptionStore` | Correct. |
| Podcast Settings | Notification, inactive, Play Instant, archive rules, playback controls, episode trim, chapter filter, download filters, priority/title drafts | `SubscriptionStore`, `PlaybackCoordinator`, or explicit local editor draft | Correct. |
| Sleep Schedule | Enable, start/end, cadence choices | `SettingsViewModel` | Correct. |
| Sleep Timer | Presets, episode count, cancel | `SleepTimerService` plus intentional local episode-count draft | Correct. |
| Priority / Up Next / Downloads | Reorder, pin/move/archive, pause/resume/retry | `SubscriptionStore`, `QueueCoordinator`, `DownloadActivityStore` and local gesture drafts | Correct. |
| Discover / Top charts | Country menus, carousels, navigation choices | shared `@AppStorage` country code and local navigation state | Correct. |
| Search | Scope picker, query, result actions | local `@State` and observable search model | Correct. |
| Stats | Range/This–Last selectors, row expansion, recap controls | local selection state, `ListeningStatsStore`, `SettingsViewModel` | Correct. |
| Onboarding / starter packs | Page selection, import/add progress | local task state plus observable subscription/import owners | Correct. |
| tvOS | Focus buttons and playback actions; no matching SwiftUI Toggle/Picker settings forms | `TVAppModel`/playback model | No equivalent stale-control defect found. Shared settings continue through the shared persisted model/CarPlay surface. |

## Confirmed defects

1. `AudioControlsSheetView` displayed Shared Listening through non-publishing
   `AppState`. Persistence and playback succeeded, but the toggle, revealed speed
   picker and selected speed stayed visually stale until sheet reconstruction.
2. The Player sound-controls button used the same stale AppState getter for its
   active white highlight. The sheet repair could incidentally wake the parent,
   but the dependency was architecturally wrong and unreliable.

Both now read `SettingsViewModel.appSettings`. Commands continue through AppState
where live playback side effects are required.

## Guardrail

Future controls must separate command routing from display observation. A view
may invoke AppState for a cross-domain action, but its value, selected state,
disabled state, conditional content and highlight must be derived from the
publishing domain owner injected into that view. Local drafts are appropriate
only for editing/gesture latency and must explicitly commit or reconcile.
