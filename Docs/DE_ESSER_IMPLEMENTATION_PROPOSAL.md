# AUTOHOP iOS DE-ESSER — PHASED IMPLEMENTATION SPECIFICATION

DOCUMENT_ID: `autohop.ios_audio.de_esser.ai_spec.v1`

DOCUMENT_STATUS: `approved architecture / implementation not commenced`

REPO_ROOT: `/Users/kevinperry/Developer/Autohop`

TARGET_APP: `Autohop iOS`

TARGET_PLATFORM: `iOS 17+`

EXCLUDED_TARGETS: `tvOS / video playback / AVPlayer-only playback paths`

PRIMARY_MEDIA_MODE: `downloaded local audio files`

LANGUAGES:

- Swift 5.9+ for orchestration, preferences, UI, diagnostics and offline test tooling.
- C++17 or Objective-C++ for the production real-time DSP kernel.

INTENDED_READER: `AI coding agent / code reviewer / implementation planner`

HUMAN_READABILITY_PRIORITY: `medium`

EXECUTION_DETAIL_PRIORITY: `maximum`

---

## 000_DOCUMENT_RULES

RULE_000_001:

This document specifies planned Version 1.6 work. It does not claim the feature
is implemented.

RULE_000_002:

Implementation agents must verify every referenced path and API against the
current working tree before editing. Line numbers are intentionally omitted
because the repository changes frequently.

RULE_000_003:

Do not broaden scope to tvOS, video, streaming, breath removal, wind removal,
plosive removal or generic noise reduction without a separate approved design.

RULE_000_004:

Do not edit `VERSION_1.5.md`. Version 1.5 was submitted to Apple on 9 August
2026. Every completed implementation change must be recorded in
`VERSION_1.6.md`.

RULE_000_005:

The offline Swift/vDSP prototype is an experimental tuning instrument. It is
not the production playback architecture.

RULE_000_006:

The production feature must execute as a custom node inside the
`AVAudioEngine` graph. It must not perform de-essing in the upstream
4096-frame file-read loop.

---

## 001_PRODUCT_OBJECTIVE

IMPLEMENT_FEATURE:

`De-Esser`

USER_OUTCOME:

Reduce the perceived harshness of speech sibilance, especially exaggerated
`s`, `sh`, `ch`, `z` and `t` energy in podcasts recorded with bright,
unprotected or poorly positioned microphones.

PRODUCT_LANGUAGE:

- Feature name: `De-Esser`
- Supporting description: `Softens harsh “sss” sounds in speech.`
- Available strengths: `Off`, `Light`, `Strong`

BEHAVIORAL_CONSTRAINT:

The feature must reduce only short, detected high-frequency events. It must not
apply a permanent dulling equalizer to the entire episode.

QUALITY_PRIORITY:

1. Avoid audible lisping.
2. Avoid dulling music, cymbals, applause and ambience.
3. Avoid pumping or unstable stereo imaging.
4. Preserve intelligibility at high playback speeds.
5. Bound CPU and battery cost during screen-locked playback.

DEFAULT_POLICY:

- Existing users: `Off`
- New users: `Off`
- Existing subscriptions: unchanged and therefore effectively `Off`
- New subscriptions: inherit the user's global De-Esser default
- Factory global De-Esser default: `Off`

---

## 002_SCOPE MATRIX

| Playback situation | Version 1 scope | Required behavior |
|---|---:|---|
| Downloaded audio episode on iPhone | Included | De-Esser available |
| Play Instant audio episode | Included | De-Esser available after automatic download completes |
| Audio started from an unsubscribed/preview feed after local download | Included if routed through local audio engine | Use global default preference |
| Audio with Trim Silence enabled | Included | Both features must compose safely |
| Audio with Vocal Boost enabled | Included | Both features must compose safely |
| Audio with playback speed adjustment | Included | Detector processes time-scaled output |
| Audio with mono mode | Included | Preserve deterministic channel behavior |
| Shared Listening mode | Included | De-Esser remains active unless product policy later changes |
| Video episode on iPhone | Excluded | Existing video behavior unchanged |
| Audio track embedded in video | Excluded | Existing AVPlayer/video path unchanged |
| tvOS audio or video | Excluded | No tvOS UI, model or DSP changes |
| CarPlay controlling iPhone audio | Included indirectly | Uses the same iPhone playback engine and setting |
| AirPlay/Bluetooth output from iPhone audio | Included indirectly | Processing occurs before route output |
| Generic breath removal | Excluded | Separate research project |
| Plosive/wind/rumble suppression | Excluded | Separate research project, likely 80–120 Hz tuning |

SCOPE_ASSERTION:

Play Instant is included because Autohop begins Play Instant only after the
episode has completed its automatic download. It is not a streaming playback
path.

---

## 003_VERIFIED_CURRENT_ARCHITECTURE

FACT_003_001:

`PlaybackEngine` requires a local media URL and checks that the file exists
before playback.

SOURCE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackEngine.swift`

FACT_003_002:

iOS audio has two possible playback paths:

- `AVAudioEngine`: used when audio processing requires Vocal Boost, Trim
  Silence, mono handling or another engine-only option.
- `AVPlayer`: retained for unprocessed audio and video paths.

REQUIRED_DE_ESSER_EFFECT:

An enabled De-Esser must make an audio episode eligible for the
`AVAudioEngine` path. It must never silently remain enabled in UI while the
episode bypasses the processor through `AVPlayer`.

FACT_003_003:

The existing processed-audio graph is conceptually:

`AVAudioPlayerNode → TimePitch → HighPass → Dynamics → Limiter → VolumeAdjustment → MainMixer`

SOURCE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackEngine.swift`

FACT_003_004:

The file-read loop uses 4096-frame buffers. At 48 kHz this is approximately
85.3 ms per buffer.

ARCHITECTURAL_CONSEQUENCE:

The production processor must not be attached to that read loop. Although a
sample-accurate envelope could run inside each buffer, read-loop processing
would necessarily occur:

- before TimePitch;
- before Vocal Boost dynamics;
- before the output the listener actually hears; and
- before Trim Silence discards some buffered material.

Those ordering constraints, not buffer granularity, disqualify the read loop
as the production insertion point.

FACT_003_005:

The codebase currently uses vDSP for generation, RMS, multiply, scalar
multiply and addition operations. It does not contain an existing reusable
biquad implementation.

CONSEQUENCE:

The De-Esser requires new, independently tested filter and envelope DSP.

FACT_003_006:

Per-podcast audio behavior is persisted in
`Subscription.playbackPreference` using `PlaybackPreference`.

SOURCES:

- `/Users/kevinperry/Developer/Autohop/Models/PlaybackPreference.swift`
- `/Users/kevinperry/Developer/Autohop/Models/Subscription.swift`
- `/Users/kevinperry/Developer/Autohop/Models/SyncState.swift`

FACT_003_007:

Default settings for new subscriptions flow through app settings and
`PlaybackPreferenceWorkflow`.

SOURCES:

- `/Users/kevinperry/Developer/Autohop/Models/AppSettings.swift`
- `/Users/kevinperry/Developer/Autohop/App/PlaybackPreferenceWorkflow.swift`
- `/Users/kevinperry/Developer/Autohop/Views/SettingsView.swift`

FACT_003_008:

The current user-facing audio controls exist in reusable and player-specific
views.

SOURCES:

- `/Users/kevinperry/Developer/Autohop/Views/PlaybackControlsCard.swift`
- `/Users/kevinperry/Developer/Autohop/Views/PlayerView.swift`
- `/Users/kevinperry/Developer/Autohop/Views/SubscriptionSettingsView.swift`

---

## 004_ARCHITECTURE DECISION RECORD

DECISION_ID: `ADR-DEESSER-001`

DECISION:

The production De-Esser will be a custom `AUAudioUnit` hosted as an
`AVAudioUnit` node in the existing iOS `AVAudioEngine` graph.

RATIONALE:

1. It processes the time-scaled signal heard by the listener.
2. It allows controlled A/B placement before or after the Vocal Boost dynamics
   stage.
3. It avoids reacting to audio later discarded by upstream Trim Silence
   scheduling behavior.
4. It provides sample-accurate attack/release behavior.
5. It centralizes the processor in the actual audio graph rather than mixing
   DSP responsibilities into file scheduling.
6. It provides a future path for other real-time audio-only processors without
   changing source files.

REJECTED_ALTERNATIVE_A:

`Process each AVAudioPCMBuffer in the file-read queue.`

REJECTION_REASON:

Incorrect graph position and no post-dynamics placement option. The rejection
is not based on the 4096-frame buffer size; sample-accurate processing inside a
buffer is technically possible.

REJECTED_ALTERNATIVE_B:

`Preprocess and permanently save a second de-essed episode file.`

REJECTION_REASON:

- duplicates large media files;
- delays playback until preprocessing completes;
- complicates storage cleanup and file identity;
- invalidates output when strength changes;
- does not automatically enable tvOS because processed files are not synced to
  Apple TV;
- increases energy and disk-write cost.

REJECTED_ALTERNATIVE_C:

`Apply a static high-frequency EQ reduction.`

REJECTION_REASON:

It would dull the whole program instead of responding only to harsh events.

LANGUAGE_BOUNDARY:

- Swift owns lifecycle, graph attachment, preferences, state snapshots,
  logging and tests that do not execute in the render callback.
- C++ owns sample processing, filter state and envelope state in the render
  callback.
- Objective-C++ may bridge the C++ kernel to the custom `AUAudioUnit` subclass
  if Swift cannot provide the required deterministic render integration without
  allocations or runtime bridging.

LICENSE_BOUNDARY:

Place new De-Esser implementation in new files with explicit provenance. Do
not insert the DSP kernel into Pocket Casts-derived MPL-covered files merely
for convenience. Existing `PlaybackEngine.swift` may require graph integration
changes and remains subject to its existing file-level licensing status.

---

## 005_SIGNAL PROCESSING SPECIFICATION

### 005.1 Detector overview

The processor must use a composite detector. A high-frequency ratio alone is
insufficient because cymbals, applause, bright music and some ambience also
contain strong high-frequency energy.

REQUIRED_DETECTOR_COMPONENTS:

1. `broadbandEnvelope`: level estimate of the full signal.
2. `sibilanceEnvelope`: level estimate of a configurable high-frequency
   detection band.
3. `speechPresenceEnvelope`: optional mid-band level estimate used to avoid
   reacting to isolated high-frequency music.
4. `relativeHighFrequency`: relationship between sibilance-band and broadband
   energy.
5. `absoluteFloorGate`: prevents gain reduction on low-level hiss/noise.
6. `softKnee`: avoids binary or chattering transitions.
7. `attackReleaseEnvelope`: smooths desired gain reduction.
8. `maximumReduction`: hard safety limit per preset.

### 005.2 Candidate frequency ranges

These are experimental starting ranges, not locked production constants:

- Sibilance detection band: approximately `4.5–10 kHz`
- Dynamic reduction shelf/bell centre: approximately `5.5–8 kHz`
- Optional speech-presence band: approximately `500 Hz–4 kHz`

REQUIREMENT:

The prototype must test multiple centres because sibilance varies across
voices, microphones, encoders and playback speeds. Do not assume one narrow
frequency fits every speaker.

### 005.3 Candidate detection equation

Use a decibel-domain composite score equivalent to:

```text
relativeHFdB = sibilanceEnvelopeDB - broadbandEnvelopeDB

relativeTerm = softKnee(relativeHFdB, relativeThresholdDB, relativeKneeDB)
absoluteTerm = softKnee(sibilanceEnvelopeDB, absoluteThresholdDB, absoluteKneeDB)
speechTerm   = optionalSpeechPresenceWeight(speechPresenceEnvelopeDB)

detectionScore = clamp(relativeTerm * absoluteTerm * speechTerm, 0, 1)
targetReductionDB = -maxReductionDB * detectionScore
```

This is conceptual. The final kernel may use linear-domain approximations if
they are measurably cheaper and produce equivalent results.

### 005.4 Dynamic gain shape

The gain stage should dynamically reduce a broad high shelf or wide bell. It
must not reduce full-band gain unless listening tests prove no acceptable
frequency-selective implementation exists.

PREFERRED_OPTIONS:

1. Dynamic high shelf with detector-controlled gain.
2. Wide bell attenuation centred on the dominant sibilance band.
3. Split-band attenuation only if phase/reconstruction tests prove it safe.

DISCOURAGED_OPTION:

Independent crossover bands that are later recombined without verified phase
alignment.

### 005.5 Stereo behavior

REQUIREMENT:

Detection must be stereo linked. Use the maximum or energy-combined detector
value across channels, then apply the same reduction trajectory to both
channels.

RATIONALE:

Independent left/right reduction can shift the apparent voice position and
produce unstable stereo imaging.

MONO_INPUT:

Use the same kernel with one active channel. Do not create a separate sonic
policy for mono sources.

### 005.6 Envelope behavior

STARTING_CANDIDATES:

- Attack: `0.5–5 ms`
- Release: `30–150 ms`
- Lookahead: initially `0 ms`; optionally test `1–3 ms` only if latency and
  buffer management remain safe
- Hold: optional `0–15 ms`

REQUIREMENT:

Attack and release coefficients must derive from the current sample rate, not
hard-coded 44.1 or 48 kHz assumptions.

### 005.7 Preset envelopes

Initial targets for listening tests:

| Setting | Relative sensitivity | Maximum reduction | Intended character |
|---|---:|---:|---|
| Off | none | 0 dB | Bit-identical bypass objective |
| Light | conservative | 2–4 dB | Transparent softening |
| Strong | moderate | 5–8 dB | Clearly audible control without lisping |

The exact thresholds, knees and reduction limits must be established during
offline testing. Do not expose them as user controls.

### 005.8 Bypass behavior

When `Off`:

- Prefer an audio-unit bypass state if graph stability is preserved.
- The kernel must not continue expensive analysis unnecessarily.
- Output should null-test against input within floating-point tolerance.
- Toggling Off/On must not rebuild the graph unless runtime testing proves a
  parameter update cannot be made safely.

---

## 006_REAL-TIME SAFETY CONTRACT

The render callback must obey all of the following:

- no heap allocation;
- no Swift/Objective-C reference counting on the render path where avoidable;
- no locks, mutexes, semaphores or condition variables;
- no file I/O;
- no logging;
- no notification posting;
- no dispatch to the main actor;
- no collection growth;
- no exceptions;
- no dynamic format discovery;
- no preference decoding;
- no construction/destruction of filters;
- no calls with undocumented real-time behavior.

STATE_UPDATE_PROTOCOL:

UI and orchestration code must publish a compact immutable parameter snapshot
through an atomic or lock-free mechanism. The render thread reads the latest
snapshot at buffer boundaries and performs any coefficient interpolation using
preallocated state.

FORMAT_PROTOCOL:

Allocate and initialize channel/filter state outside the render callback when
the audio format changes. Support the channel counts and sample formats
actually produced by Autohop's engine. Fail safely to bypass for unsupported
formats and emit the diagnostic outside the render callback.

SEEK_PROTOCOL:

Seeking must reset or deliberately preserve detector/filter state according to
test results. Default proposal: reset envelopes and filter delays on a new
playback generation to avoid stale reduction after a discontinuity.

ROUTE_CHANGE_PROTOCOL:

Sample-rate or channel-layout changes require coefficient/state reconfiguration
outside the render callback. Playback must not crash or emit invalid audio
during AirPods, Bluetooth, speaker or AirPlay transitions.

---

## 007_GRAPH PLACEMENT EXPERIMENT

Two candidate production positions must be tested:

PLACEMENT_A:

```text
PlayerNode → TimePitch → HighPass → DeEsser → Dynamics → Limiter
```

PLACEMENT_B:

```text
PlayerNode → TimePitch → HighPass → Dynamics → DeEsser → Limiter
```

PLACEMENT_A_HYPOTHESIS:

Controlling sibilance before compression may prevent the compressor from
reacting excessively to high-frequency peaks and may sound more natural.

PLACEMENT_B_HYPOTHESIS:

Detecting after compression may better match the sibilance balance actually
heard after Vocal Boost and may control compressor-emphasized harshness.

MANDATORY_TEST_MATRIX:

- Vocal Boost Off + De-Esser Light/Strong
- Vocal Boost Light + De-Esser Light/Strong
- Vocal Boost Standard + De-Esser Light/Strong
- Vocal Boost Strong + De-Esser Light/Strong
- Playback speed 1.0×, 1.5×, 2.0× and 2.5×
- Trim Silence Off and at least one enabled strength
- Stereo and mono output preference
- Female, male and mixed voices
- Speech over music

SELECTION_RULE:

Choose the placement with the best overall transparency and robustness. Do not
choose solely from one problematic podcast. Record the evidence and selected
position in this document's implementation-results appendix when Phase 2 is
complete.

---

## 008_DATA MODEL AND SYNC DESIGN

### 008.1 New enum

PROPOSED_TYPE:

```swift
public enum DeEsserLevel: String, Codable, CaseIterable, Sendable {
    case off
    case light
    case strong
}
```

REQUIRED_PROPERTIES:

- stable raw values;
- user-facing title;
- optional short explanatory text;
- no DSP constants embedded in the persisted model;
- DSP preset mapping owned by playback/DSP configuration code.

### 008.2 PlaybackPreference integration

Add:

```swift
public var deEsserLevel: DeEsserLevel
```

DECODING_RULE:

Missing key decodes to `.off`.

ENCODING_RULE:

Encode the explicit current value.

COMPATIBILITY_RULE:

Older synced records without the field must remain valid. Existing
subscriptions must not be changed by migration.

### 008.3 Default preference integration

Add the same field to the default playback preference used when creating new
subscriptions and previewing eligible locally downloaded audio.

FACTORY_DEFAULT:

`.off`

### 008.4 iCloud synchronization

Because `PlaybackPreference` is synchronized as part of subscription state,
the field must participate in Codable equality, dirty-state propagation and
merge behavior exactly like Vocal Boost and Trim Silence.

SYNC_SCOPE:

iCloud may carry the preference value to another iOS device. tvOS must ignore
the setting because it does not implement this feature. The presence of an
unknown/new field must not break older clients.

### 008.5 No media-derived persistence

Do not persist detector envelopes, momentary reduction or per-episode analysis
results. Version 1 is entirely real time and preference driven.

---

## 009_UI AND PRODUCT DESIGN

### 009.1 Current-podcast Audio Controls

Add a row consistent with Trim Silence and Vocal Boost:

- icon: choose an SF Symbol that communicates softened high frequencies or
  speech processing; validate availability on iOS 17;
- title: `De-Esser`;
- supporting text: `Softens harsh “sss” sounds in speech.`;
- segmented options: `Off`, `Light`, `Strong`;
- tint: existing Autohop purple/magenta audio-control treatment.

REQUIREMENT:

The entire control must meet a minimum 44×44-point tap target and support VoiceOver.

### 009.2 Individual Subscription Settings

Add the same per-podcast selector to the Audio section. Use the existing
`PlaybackControlsCard` where practical so Audio Controls and subscription
settings cannot drift in labels, ordering or behavior.

### 009.3 Main Settings defaults

Add `De-Esser` to Default Playback Settings. Copy must say clearly:

`Applies to new subscriptions. Existing podcasts keep their current setting.`

### 009.4 Video behavior

For video episodes:

- do not show the De-Esser as active;
- do not promise processing;
- preserve all existing video behavior;
- UI may show an explanatory disabled state only if current audio controls do
  the same for other audio-only features. Prefer consistency over a special
  case.

### 009.5 Live updates

Changing Off/Light/Strong during audio playback must take effect without
restarting the episode, losing position, changing speed or producing a click.

### 009.6 Accessibility

Required VoiceOver examples:

- `De-Esser, Off`
- `De-Esser, Light`
- `De-Esser, Strong`

Required hint:

`Softens harsh s sounds in speech.`

Do not rely on color alone to communicate selection.

---

## 010_PROPOSED FILE PLAN

Final filenames may change after repository inspection, but responsibilities
must remain separated.

### 010.1 New model file

ADD:

`/Users/kevinperry/Developer/Autohop/Models/DeEsserLevel.swift`

RESPONSIBILITY:

- persisted enum;
- titles and user-safe descriptions only;
- no DSP implementation.

### 010.2 New DSP kernel files

ADD, candidate paths:

- `/Users/kevinperry/Developer/Autohop/Playback/DeEsser/DeEsserKernel.hpp`
- `/Users/kevinperry/Developer/Autohop/Playback/DeEsser/DeEsserKernel.cpp`

RESPONSIBILITY:

- biquad or equivalent filter primitives;
- detector filters;
- dynamic reduction filter;
- envelope followers;
- stereo-linked processing;
- parameter smoothing;
- reset and format preparation;
- no UI or app model knowledge.

### 010.3 New audio-unit wrapper

ADD, candidate paths:

- `/Users/kevinperry/Developer/Autohop/Playback/DeEsser/DeEsserAudioUnit.swift`
- Objective-C++ bridge files only if required by the final integration.

RESPONSIBILITY:

- `AUAudioUnit` lifecycle;
- bus/format validation;
- render block wiring;
- atomic parameter snapshot transfer;
- bypass;
- non-real-time error reporting.

### 010.4 New preset/configuration file

ADD:

`/Users/kevinperry/Developer/Autohop/Playback/DeEsser/DeEsserPreset.swift`

RESPONSIBILITY:

- map Light/Strong to tested constants;
- keep persisted enum independent of tuning constants;
- expose testable parameter validation.

### 010.5 New offline prototype/test tool

ADD under tests or developer tooling, not production runtime:

`DeEsserOfflineRenderer`

RESPONSIBILITY:

- read fixture audio;
- render candidate parameters and placements;
- write comparison files into a temporary/test output directory;
- calculate objective peak/RMS/reduction metrics;
- never upload audio.

### 010.6 Existing files likely requiring edits

- `Models/PlaybackPreference.swift`
- `Models/AppSettings.swift`
- `Models/SyncState.swift` if explicit field handling is required
- `Playback/PlaybackEngine.swift`
- `App/PlaybackPreferenceWorkflow.swift`
- `App/AppState.swift`
- `Views/PlaybackControlsCard.swift`
- `Views/PlayerView.swift`
- `Views/SubscriptionSettingsView.swift`
- `Views/SettingsView.swift`
- `Views/SupportContent.swift`
- relevant tests and project-generation configuration
- `VERSION_1.6.md` after each completed phase

PROJECT_GENERATION_REQUIREMENT:

If the project is generated from configuration, add all new source files to
the correct iOS target through the generator and regenerate. Do not manually
patch only the `.xcodeproj` if regeneration would discard the change.

TARGET_MEMBERSHIP_REQUIREMENT:

The De-Esser implementation must belong to the iOS app/core targets required
for iPhone playback tests. It must not be compiled into AutohopTV unless a
future approved tvOS phase explicitly adds support.

---

## 011_DIAGNOSTIC SPECIFICATION

All diagnostics must be emitted outside the render callback.

### 011.1 Configuration event

EVENT_KEY:

`playback.deEsserConfigured`

FIELDS:

- `episodeID` redacted/hash-safe form consistent with existing diagnostics
- `level`: off/light/strong
- `placement`: preDynamics/postDynamics
- `sampleRate`
- `channelCount`
- `playbackSpeed`
- `vocalBoostLevel`
- `trimSilenceLevel`
- `engineGeneration`
- `bypassed`

### 011.2 State/lifecycle events

- `playback.deEsserAttached`
- `playback.deEsserBypassed`
- `playback.deEsserFormatChanged`
- `playback.deEsserReset`
- `playback.deEsserUnsupportedFormat`
- `playback.deEsserConfigurationFailed`

### 011.3 Aggregate effectiveness event

Do not log per-buffer activity. At pause/stop/episode change, optionally emit:

EVENT_KEY:

`playback.deEsserSessionSummary`

FIELDS:

- `activeSeconds`
- `processedSeconds`
- `meanReductionDB`
- `maxReductionDB`
- `reductionDutyCycle`
- `level`
- `placement`

PRIVACY:

No audio samples, fingerprints, transcripts or detected speech content may be
logged or uploaded.

### 011.4 Performance instrumentation

Measure outside the production render callback using development-only signposts
or controlled test hooks:

- mean render duration;
- p95/p99 render duration;
- maximum render duration;
- render deadline misses;
- CPU delta against bypass;
- battery/energy comparison during screen-locked playback.

---

## 012_TEST STRATEGY

### 012.1 Pure DSP unit tests

TEST_DSP_001:

Off/bypass produces output equal to input within defined floating-point
tolerance.

TEST_DSP_002:

Silence produces finite output, no NaN/Inf and no reduction chatter.

TEST_DSP_003:

A synthetic sibilance burst above threshold produces bounded reduction.

TEST_DSP_004:

A low-frequency speech-like tone without high-frequency burst produces no
material reduction.

TEST_DSP_005:

Maximum reduction never exceeds the preset safety limit.

TEST_DSP_006:

Attack/release timing remains equivalent at 44.1 kHz and 48 kHz within
tolerance.

TEST_DSP_007:

Stereo-linked detector applies identical gain trajectory to left and right.

TEST_DSP_008:

Mono input processes safely.

TEST_DSP_009:

State reset after seek removes stale detector/reduction state.

TEST_DSP_010:

Parameter changes are smoothed and do not generate discontinuities above the
accepted click threshold.

TEST_DSP_011:

Very small and maximum supported render frame counts process safely.

TEST_DSP_012:

Repeated prepare/reset/process cycles do not leak state or memory.

### 012.2 Model compatibility tests

- Decode legacy `PlaybackPreference` JSON without De-Esser field → `.off`.
- Encode/decode Off, Light and Strong.
- Equality and hash behavior include De-Esser where applicable.
- Existing subscriptions remain Off after migration/bootstrap.
- New subscription inherits global default.
- Changing global default does not alter existing subscriptions.
- Sync merge retains the newest legitimate De-Esser preference.
- Older-record simulation does not fail.

### 012.3 PlaybackEngine integration tests

- Enabled De-Esser selects engine path for audio even when Vocal Boost and Trim
  Silence are Off.
- Disabled De-Esser preserves existing path-selection behavior.
- Video never attaches De-Esser.
- Play Instant local audio receives the effective preference.
- Mid-playback strength change does not restart playback.
- Playback position and speed remain stable after setting change.
- Pause/resume preserves correct setting.
- Seek resets state correctly.
- Route change reconstructs or reconfigures safely.
- Episode transition applies the next podcast's own De-Esser preference.
- Shared Listening does not accidentally disable or overwrite the setting.

### 012.4 UI tests

- Audio Controls displays Off/Light/Strong.
- Subscription Settings changes only the selected subscription.
- Default Settings changes only future subscriptions/default previews.
- VoiceOver labels announce selected level.
- Controls meet tap-target requirements.
- Video state does not falsely promise processing.

### 012.5 Listening fixture corpus

Fixtures should be short, legally usable and checked into an appropriate test
asset location only when licensing permits. Otherwise document repeatable local
test sources without committing copyrighted recordings.

Required categories:

- clean studio speech;
- harsh close-mic speech;
- low-bitrate MP3 speech;
- female voice with strong sibilance;
- male voice with strong sibilance;
- overlapping speakers;
- speech with music bed;
- applause;
- cymbals/high-hats;
- hiss-heavy breath;
- full inhalation;
- silence and low-level noise;
- mono and stereo.

### 012.6 Subjective scoring

For each candidate render, score:

- sibilance reduction;
- speech naturalness;
- lisping;
- brightness loss;
- music damage;
- pumping;
- stereo stability;
- fatigue after extended listening.

Use blinded A/B or ABX-style naming where practical. Do not select presets only
from visual waveforms or detector metrics.

---

## 013_PERFORMANCE BUDGETS

Initial acceptance budgets must be measured on at least one older supported
iPhone and one current device.

PROPOSED_BUDGETS:

- No render underruns attributable to De-Esser in a two-hour playback test.
- No main-actor work per audio buffer.
- No allocations observed in the kernel render path after preparation.
- Incremental steady-state CPU target: less than 3 percentage points on the
  older validation device at 1×; investigate any higher result.
- Incremental memory: fixed and bounded; no growth proportional to playback
  duration.
- No measurable increase in launch time when feature is Off.
- Battery comparison documented for screen-locked playback at 1× and 2×.

These are initial engineering gates, not public claims. Revise only with
documented evidence.

---

## 014_PHASED IMPLEMENTATION ROADMAP

### PHASE 0 — Repository baseline and safety

OBJECTIVE:

Create a reproducible baseline before DSP work.

TASKS:

1. Confirm the current iOS audio graph and target membership.
2. Record clean/dirty working-tree provenance.
3. Run existing playback, preference, sync and UI tests.
4. Capture baseline CPU, memory and energy for representative audio at 1× and
   2× with Vocal Boost/Trim Silence combinations.
5. Confirm project-generation workflow for C++/Objective-C++ files.
6. Confirm licensing headers for new original files.

EXIT CRITERIA:

- baseline results stored in implementation notes;
- existing tests green;
- no application behavior changed;
- Version 1.6 ledger notes proposal/baseline work accurately.

### PHASE 1 — Offline Swift/vDSP research prototype

OBJECTIVE:

Prove the detector and dynamic reduction concept without touching production
playback.

TASKS:

1. Implement an offline renderer using local test fixtures.
2. Implement experimental filter/envelope primitives.
3. Generate Light/Strong candidate renders.
4. Test composite detector variants.
5. Confirm music/applause false-positive behavior.
6. Measure reduction bounds and numerical stability.
7. Document candidate constants; do not expose them to UI.

EXIT CRITERIA:

- at least one Light and one Strong candidate reduce harsh sibilance;
- no obvious lisping on clean speech;
- no unacceptable permanent dulling;
- no NaN/Inf or unstable filter state;
- prototype remains disconnected from shipping playback.

STOP CONDITION:

If no candidate provides meaningful benefit without broad quality damage, stop
the feature. Do not proceed merely because UI work has been planned.

### PHASE 2 — Graph placement listening study

OBJECTIVE:

Select pre-dynamics or post-dynamics placement using evidence.

TASKS:

1. Produce equivalent offline/manual-render variants representing Placement A
   and Placement B.
2. Run the mandatory Vocal Boost/speed/voice matrix.
3. Perform blinded listening evaluation.
4. Record false positives and interaction failures.
5. Lock the production placement and preset constants.

EXIT CRITERIA:

- one placement selected with written rationale;
- selected presets have maximum-reduction safety bounds;
- rejected placement remains documented for future maintainers.

### PHASE 3 — Real-time kernel and custom audio unit

OBJECTIVE:

Build production DSP in isolation from the app UI.

TASKS:

1. Implement C++ filter and envelope primitives.
2. Implement stereo-linked processing.
3. Implement immutable/atomic parameter snapshots.
4. Implement format preparation and state reset.
5. Implement `AUAudioUnit` wrapper and `AVAudioUnit` instantiation.
6. Add bypass and unsupported-format behavior.
7. Add pure DSP and audio-unit lifecycle tests.
8. Run allocation and thread-safety instrumentation.

EXIT CRITERIA:

- DSP unit tests pass;
- render path has no known allocations/locks/logging;
- bypass is transparent;
- parameter changes are click-free;
- unsupported formats fail to bypass, not crash.

### PHASE 4 — PlaybackEngine integration behind an internal feature gate

OBJECTIVE:

Attach the node to iOS audio playback without exposing user controls.

TASKS:

1. Register/instantiate the custom audio unit.
2. Insert at the Phase 2-selected graph position.
3. Update audio path selection so internally enabled De-Esser forces
   `AVAudioEngine` for audio.
4. Keep video/AVPlayer behavior unchanged.
5. Reconfigure on format, route and generation changes.
6. Add lifecycle/configuration diagnostics outside render callback.
7. Exercise Play Instant and automatic episode transitions.

EXIT CRITERIA:

- internal builds can enable each preset;
- audio starts, seeks, pauses, resumes and transitions correctly;
- video regressions absent;
- performance within provisional budgets;
- feature remains hidden from normal users.

### PHASE 5 — Preference model, sync and workflow

OBJECTIVE:

Persist global-default and per-podcast De-Esser settings safely.

TASKS:

1. Add `DeEsserLevel`.
2. Extend `PlaybackPreference` with missing-key `.off` decoding.
3. Extend default preference storage.
4. Add workflow methods for current podcast and global default.
5. Live-apply setting to current audio playback.
6. Confirm subscription sync behavior.
7. Add legacy record and merge regression tests.

EXIT CRITERIA:

- legacy data decodes safely;
- existing subscriptions remain Off;
- new subscriptions inherit global default;
- global changes never rewrite existing subscriptions;
- preference sync works between iOS devices;
- tvOS remains unaffected.

### PHASE 6 — User interface and accessibility

OBJECTIVE:

Expose a consistent, understandable control.

TASKS:

1. Add row to Audio Controls.
2. Add row to Individual Subscription Settings.
3. Add row to Default Playback Settings.
4. Reuse a common control component where possible.
5. Add explanatory copy and audio-only qualification.
6. Add VoiceOver labels, hints and selected values.
7. Validate tap targets and responsive layouts.

EXIT CRITERIA:

- all three UI surfaces agree;
- controls are operable with VoiceOver;
- live setting changes are click-free;
- no UI suggests video/tvOS support;
- screenshots pass small and large iPhone layout review.

### PHASE 7 — Field diagnostics and controlled dogfood

OBJECTIVE:

Validate real podcasts, battery and route behavior before public release.

TASKS:

1. Enable for internal builds/users only.
2. Collect configuration/session summary events.
3. Test screen locked, foreground, Bluetooth, AirPods, speaker and CarPlay.
4. Test long sessions at common speeds.
5. Compare Off/Light/Strong on problematic and clean podcasts.
6. Investigate crashes, underruns, CPU spikes or route failures.
7. Retune only through versioned preset changes with tests.

EXIT CRITERIA:

- no DSP-related crashes;
- no repeatable underruns;
- battery/CPU acceptable;
- Light is transparent on clean speech;
- Strong provides meaningful benefit on harsh speech;
- route changes and interruptions recover correctly.

### PHASE 8 — Documentation and release preparation

OBJECTIVE:

Make user and AI documentation match the implemented feature exactly.

TASKS:

1. Update `FEATURES.md` with implemented scope only.
2. Update `DESIGN.md` audio architecture.
3. Update support/user guide content.
4. Add AI CONTEXT headers to every new source file.
5. Update `VERSION_1.6.md` with completed behavior and validation status.
6. Add App Store release-note candidate only after implementation is complete.
7. Run release configuration checks to confirm no accidental tvOS source or UI
   exposure.

EXIT CRITERIA:

- documentation matches code;
- no planned feature is described as shipped;
- Version 1.6 ledger complete;
- release build/tests pass.

### PHASE 9 — Post-release evaluation

OBJECTIVE:

Determine whether further tuning or platform expansion is justified.

TASKS:

1. Review crash/performance diagnostics.
2. Review qualitative feedback for lisping, dullness or ineffectiveness.
3. Avoid silent preset changes without documenting them.
4. Decide separately whether to research tvOS or video support.
5. Keep rumble/plosive reduction as an independent proposal.

EXIT CRITERIA:

- stable presets retained or revised with evidence;
- follow-up work documented under the correct future version.

---

## 015_FAILURE MODES AND MITIGATIONS

FAILURE_001: `Speech sounds lisped.`

MITIGATION:

Reduce maximum attenuation, narrow detector sensitivity, lengthen release or
increase absolute threshold.

FAILURE_002: `Music/cymbals trigger excessive reduction.`

MITIGATION:

Strengthen absolute/speech-presence conditions, soften ratio weighting and cap
duty cycle/reduction.

FAILURE_003: `Click when changing strength.`

MITIGATION:

Interpolate parameters and reduction; never step coefficients/gain abruptly.

FAILURE_004: `Audio underrun or high CPU.`

MITIGATION:

Profile the kernel, simplify filter topology, avoid per-sample expensive
transcendentals and retain fixed memory. Do not move work to the main actor.

FAILURE_005: `Setting enabled but no processing.`

MITIGATION:

Make De-Esser part of engine-path eligibility, assert attachment in debug and
emit configuration diagnostics.

FAILURE_006: `Video behavior regresses.`

MITIGATION:

Keep video routing explicitly excluded and add regression tests.

FAILURE_007: `Existing subscriptions unexpectedly turn on.`

MITIGATION:

Missing-key decode to Off; no migration that rewrites existing preferences;
add fixture tests.

FAILURE_008: `Stereo image moves.`

MITIGATION:

Link detector/reduction across channels.

FAILURE_009: `AirPods/route transition crashes.`

MITIGATION:

Perform format/state reconfiguration outside render callback and generation
guard stale units.

FAILURE_010: `Strong preset amplifies background hiss perception.`

MITIGATION:

Require absolute high-band floor, bound release, and test low-level noisy
recordings.

---

## 016_NON_GOALS

- No tvOS implementation.
- No video implementation.
- No cloud audio processing.
- No uploaded audio or fingerprints.
- No machine-learning requirement.
- No transcription.
- No permanent media modification.
- No generic noise suppression.
- No promise to remove all breathing.
- No wind/plosive/rumble feature.
- No user-facing threshold/frequency/attack/release controls.
- No automatic enablement based on podcast identity.
- No claim that all sibilance is caused by poor microphones.

---

## 017_PRIVACY AND SECURITY

PRIVACY:

- Processing occurs locally on device.
- Audio is not uploaded.
- No transcript is created.
- No acoustic fingerprint is stored.
- Diagnostics contain numeric aggregate behavior only.

SECURITY:

- Validate channel count, sample rate, frame count and buffer pointers before
  processing.
- Avoid integer overflow when calculating frame/channel offsets.
- Bound every loop by host-provided frame count and prepared capacity.
- Fail to bypass on unsupported formats.
- Fuzz or stress malformed/edge buffer configurations in tests where possible.

---

## 018_DEFINITION OF DONE

The De-Esser is complete only when all conditions below are true:

- production custom audio unit is integrated into iOS audio graph;
- graph placement was chosen from documented A/B evidence;
- Off/Light/Strong work during downloaded iPhone audio playback;
- Play Instant audio is supported;
- video and tvOS remain explicitly unaffected;
- existing users and subscriptions remain Off by default;
- new subscriptions inherit the global default;
- per-podcast override persists and syncs between iOS devices;
- no render-thread allocations, locks or logging are detected;
- playback/route/seek/transition regression tests pass;
- CPU, memory and battery validation is recorded;
- accessibility and responsive UI validation passes;
- documentation and support copy match actual behavior;
- `VERSION_1.6.md` records the completed feature and outstanding validation;
- no code or documentation falsely claims breath, plosive, video or tvOS
  support.

---

## 019_IMPLEMENTATION RESULTS APPENDIX

STATUS: `empty until implementation begins`

When work commences, append dated evidence rather than rewriting the original
decision history.

Required future entries:

- baseline commit/build and working-tree provenance;
- offline prototype presets tested;
- selected graph placement and rationale;
- final Light/Strong parameter table;
- CPU/memory/battery results;
- device/route test matrix;
- known limitations;
- App Store/user documentation status.
