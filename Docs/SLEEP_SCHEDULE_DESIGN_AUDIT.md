# Sleep Schedule — design and functionality audit

<!-- AI CONTEXT — Presentation audit and preserved-functionality contract for Sleep Schedule.
Keep source headers, FEATURES.md, PAGES.md, DESIGN.md, project_autohop.md and
VERSION_1.7.md aligned when these contracts change. Simulator/source evidence does
not establish physical-device or release validation. -->

20 September 2026. Reference implementations: DownloadFiltersView in
Views/SubscriptionSettingsView.swift and Views/PodcastReplayView.swift.

## Findings and changes

| Surface | Audit finding | Update |
| --- | --- | --- |
| Page structure | Native grouped sections differ from the newer settings pages | Existing glassCard surfaces, black background, purple icons/controls, 20-point card padding, shared adaptive Form sizing and section spacing |
| Introduction | Opens with a toggle and a dense footer | Benefit heading, readable introduction, On/Off status and explicit immediate-save guidance |
| Disabled state | Hours/interval disappear without explaining saved values | Editors still hide; now explains that saved choices are retained. Help remains available |
| Active Hours | Start/End have no window summary | Labelled native time pickers, local-time explanation and readable daytime/overnight summary |
| Equal start/end | Service treats this as always available, but page does not explain it | Explicit all-day/24-hour summary, without changing stored values |
| Ask Every | Checkmark only; tap targets rely on Form layout | All six options retained as separate full-width plain buttons with minimum 44-point targets, selected accessibility traits and visible radio-style selection |
| Behaviour explanation | Incorrectly says playback pauses when a prompt begins | Correctly describes a chime over continuing playback, followed by fade/pause/rewind only without a response |
| Preview | No combined explanation of the chosen settings | Your Schedule summarises the saved hours and interval; explicitly a configuration summary, not a live countdown |
| Help | Dense explanations compete with editing | Expandable help covers responding, timeout/rewind, manual timer priority and notification permission |
| Large text | Existing inline time labels compete for width | Separate picker labels, native compact editors, wrapping text and vertical card layout |

The page reuses the references' existing components and styling. It does not copy
Replay's explicit Save workflow: Sleep Schedule already saves immediately, like
Feed Filters, and retains that behaviour.

## Functionality preservation

- Same SettingsViewModel write-through owner and four AppSettings fields.
- Same enabled binding, including requesting notification permission on enable;
  there is no new permission request on page appearance.
- Same start/end minutes-from-midnight bindings, native locale-aware time input,
  device-local scheduling, daytime and overnight windows.
- Same five presets: 10, 15, 20, 40 and 60 minutes; End of Episode remains 0.
- Turning off retains hours and duration; no new defaulting or migration.
- Same service configuration subscriptions, countdown, chime, response handling,
  lock-screen actions, fade/rewind, episode-boundary behaviour and manual Sleep
  Timer suspension. No playback/service code changed.
- Same menu, Player and desktop entry routes, onboarding tip, Back policy and
  mini-player. The iOS 27 navigation repair remains in place.

## Behaviour checked against implementation

Inspected SleepScheduleService, SleepTimerService, PlaybackCoordinator's prompt
and timeout callbacks, PlaybackStartWorkflow, PlaybackTransportWorkflow,
PlaybackSeekWorkflow, EpisodeCompletionWorkflow, AppRuntimeWorkflow's settings
subscription, SettingsViewModel, AppSettings defaults/decoding, Player prompt and
indicator, notification integration, onboarding copy and existing support guide.

The service starts/re-arms through playback/configuration events, counts only
playing ticks, supports midnight crossing, treats equal times as all day, and
cancels pending check-ins outside its window. The generated chime lasts 60 seconds
(with a 75-second failure fallback); unanswered prompts trigger a 30-second fade.
Timed mode rewinds to the prompt position; episode-boundary mode rewinds to the
start of the next episode. A normal Sleep Timer takes priority for the session.
The existing support guide already describes these semantics accurately.

This is a page design audit with preservation of existing playback behaviour,
not a rewrite of the playback state machine or an expansion to weekday rules,
multiple windows, alarm playback, or notification-permission management.

## Validation

- Simulator build succeeded; `git diff --check` passed.
- Hosted `testSleepSchedulePresentationPreservesSavedConfiguration` passed on
  iPhone with iOS 26.5, iPhone with iOS 27, and iPad with iPadOS 26.5: four
  configurations per run, zero failures.
- Each run covers off, overnight, daytime and all-day End of Episode states,
  including accessibility text size. Isolated settings stores ensure the test
  cannot overwrite the simulator user's schedule. Opening/leaving the page
  preserves the complete settings snapshot; navigation/dismissal is checked.
- Top, middle and bottom screenshots were captured and inspected for layout,
  wrapping, selected intervals and scroll access. Final previews are saved in
  `/Users/kevinperry/Documents/Codex/2026-09-20/autohop-sleep-schedule/`.
- Original settings bindings were compared with the repository version and are
  unchanged verbatim. Playback services were not modified by this refresh.

Final result bundles: `/tmp/autohop-sleep-verified26.xcresult`,
`/tmp/autohop-sleep-verified27.xcresult`, and
`/tmp/autohop-sleep-verified-ipad.xcresult`. The iOS 27 simulator's notification
daemon stalled during app startup; restarting that simulator daemon allowed
the hosted test to run successfully. This is not notification-delivery testing.

Actual overnight audio, physical-device controls, VoiceOver interaction,
notification delivery, and manual interaction with every editor/expanded help
were not verified by these hosted rendering/navigation checks.
