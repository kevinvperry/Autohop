# AUTOPROGRAMMATIC_AD_DUCKING_IMPLEMENTATION_SPEC

DOCUMENT_ID: `autohop.ad_ducking.programmatic_ads.ai_spec.v1`
REPO_ROOT: `/Users/kevinperry/Developer/Autohop`
TARGET_APP: `Autohop`
TARGET_PLATFORM: `iOS 17+`
LANGUAGE: `Swift 5.9`
PRIMARY_MODE: `download-first local playback`
INTENDED_READER: `AI coding agent / code transformation planner`
HUMAN_READABILITY_PRIORITY: `low`
EXECUTION_DETAIL_PRIORITY: `maximum`

## 000_OBJECTIVE

IMPLEMENT_FEATURE:

`Automatic Ad Ducking`

FEATURE_BEHAVIOR:

When a locally downloaded podcast episode contains segments classified as likely programmatic advertisements, Autohop automatically reduces app playback output by `30%` while the playback cursor is inside those segments, then restores normal app playback output when outside those segments.

VOLUME_SEMANTICS:

- `30% volume reduction` means Autohop output scalar is multiplied by `0.7`.
- Do not modify device/system volume.
- Do not modify `AVAudioSession` route volume.
- Do not permanently alter source audio files.
- Do not skip ads.
- Do not remove ads.
- Do not block tracking requests.
- Do not claim deterministic ad identification.
- Feature language should be `Lower detected ads`, not `Block ads`.

PRIVACY_CONSTRAINT:

- Detection must run locally.
- No uploaded audio.
- No uploaded fingerprints in v1.
- No central crowd-sourced database in v1.
- No speech transcript persistence in v1.
- No network calls introduced solely for ad detection in v1.

ROLL_OUT_DEFAULT:

- Default OFF for all existing subscriptions.
- Default OFF for new subscriptions unless user explicitly changes default playback preference later.
- Per-podcast opt-in.
- Optional global default can be added after per-podcast implementation stabilizes.

## 001_EXISTING_ARCHITECTURE_FACTS

FACT_001:

Autohop is currently download-first. `PlaybackEngine` requires `episode.localFileURL` and throws `PlaybackError.missingLocalFile` when absent.

SOURCE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackEngine.swift`

FACT_002:

Playback has two mutually exclusive runtime paths:

- `AVPlayer` path: video episodes; audio when Vocal Boost OFF and Trim Silence OFF.
- `AVAudioEngine` path: audio when Vocal Boost != OFF or Trim Silence != OFF.

SOURCE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackEngine.swift`

FACT_003:

`PlaybackEngine.tickTime()` runs approximately every `0.5s` on both playback paths. This is the correct decision point for ad ducking state transitions because it uses canonical playback file seconds.

SOURCE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackEngine.swift`

FACT_004:

`PlaybackEngine.setVolume(_:)` is already used by Sleep Timer and Sleep Schedule fade logic.

SOURCE:

`/Users/kevinperry/Developer/Autohop/App/AppState.swift`

RISK:

Directly reusing `setVolume(0.7)` for ad ducking will conflict with sleep fades. Required fix: introduce internal volume-intent composition.

FACT_005:

Autohop already has local audio signal processing via `SilenceDetector`, using `AVAudioPCMBuffer`, `AVAudioFile`, and Accelerate/vDSP.

SOURCE:

`/Users/kevinperry/Developer/Autohop/Playback/SilenceDetector.swift`

FACT_006:

Per-podcast playback settings are stored in `Subscription.playbackPreference`, with type definition in `Models/PlaybackPreference.swift` and persistence through `SubscriptionStore`/GRDB.

SOURCE:

`/Users/kevinperry/Developer/Autohop/Models/PlaybackPreference.swift`

FACT_007:

`AppState.effectivePreference(for:)` applies Shared Listening override, disabling Trim Silence and changing speed. Ad ducking should be independent from Shared Listening unless product decides otherwise.

SOURCE:

`/Users/kevinperry/Developer/Autohop/App/AppState.swift`

## 002_NON_GOALS

NON_GOAL_001:

Do not implement ad skipping.

NON_GOAL_002:

Do not implement server-side blocking, redirect tampering, ad call interception, or impression suppression.

NON_GOAL_003:

Do not create a cloud service for shared fingerprints in v1.

NON_GOAL_004:

Do not require Core ML in v1.

NON_GOAL_005:

Do not run full speech-to-text transcription in v1.

NON_GOAL_006:

Do not assume HLS manifests are available. Current playback architecture uses local downloaded files and most podcast enclosures are progressive MP3/M4A assets after server-side stitching.

## 003_USER_VISIBLE_REQUIREMENTS

REQ_UI_001:

Add per-podcast setting in current Audio Controls sheet:

- label: `Lower Detected Ads`
- sublabel: `Turns likely programmatic ads down`
- control: `Toggle`
- default: `false`

REQ_UI_002:

When active ducking is occurring, optional subtle player status:

- text: `Ad lowered`
- visible only while current playback time is inside active detected ad segment
- no interruptive toast
- no notification

REQ_UI_003:

If no segments have been detected yet, toggle still remains allowed. Analysis can run after download and/or lazily before playback.

REQ_UI_004:

Do not expose confidence scores in v1 UI.

REQ_UI_005:

Support copy must avoid absolute claims. Use `likely`, `detected`, `may`, `programmatic-style ads`.

## 004_INTERNAL_REQUIREMENTS

REQ_INTERNAL_001:

Segment detection output must be persisted as derived cache metadata, not as primary user state.

REQ_INTERNAL_002:

Segment timestamps are always real file seconds.

REQ_INTERNAL_003:

Detected segment cache must invalidate when local media file changes.

REQ_INTERNAL_004:

Playback must be able to receive ad-ducking plan before playback starts or while playback is already running.

REQ_INTERNAL_005:

Playback engine must support ducking in both `AVPlayer` and `AVAudioEngine` paths.

REQ_INTERNAL_006:

Volume effects must compose multiplicatively:

`effectiveVolume = baseUserScalar * sleepScalar * adDuckScalar * futureScalarN`

Current app has no explicit user scalar, so v1:

`effectiveVolume = sleepScalar * adDuckScalar`

REQ_INTERNAL_007:

State changes into/out of ad ducking must fade, not hard-step, to avoid clicks and listener discomfort.

REQ_INTERNAL_008:

Analysis tasks must not block playback, feed refresh, UI responsiveness, or download completion.

REQ_INTERNAL_009:

Analysis must be cancellable or at least safely ignorable if episode/file disappears.

REQ_INTERNAL_010:

Feature must be testable without real-time playback.

## 005_PROPOSED_FILE_CHANGES

ADD_FILE:

`/Users/kevinperry/Developer/Autohop/Models/AdDucking.swift`

CONTAINS:

- `AdDuckingMode`
- `AdDuckingSettings`
- `DetectedAdSegment`
- `AdDetectionSignal`
- `AdDuckingPlan`
- `AdDuckingPlanLookup`
- pure helpers for segment active-state lookup

ADD_FILE:

`/Users/kevinperry/Developer/Autohop/Playback/AdSegmentDetector.swift`

CONTAINS:

- local audio analyzer
- signal extraction
- candidate generation
- candidate scoring
- fingerprint feature generation
- deterministic v1 detection

ADD_FILE:

`/Users/kevinperry/Developer/Autohop/Persistence/AdSegmentStore.swift`

CONTAINS:

- derived cache load/save
- file signature computation
- invalidation logic
- cache pruning

ADD_FILE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackVolumeCoordinator.swift`

CONTAINS:

- multiplicative volume component model
- fade interpolation helper
- pure tests for volume composition

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/Models/PlaybackPreference.swift`

CHANGE:

Add ad ducking preference fields with backward-compatible decoding defaults.

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/Playback/PlaybackEngine.swift`

CHANGE:

Add ad-ducking plan ingestion, active segment lookup, volume composition, fade scheduling, and callback exposing active duck state.

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/App/AppState.swift`

CHANGE:

Orchestrate post-download analysis, apply plans to playback, persist user settings, expose active duck state to UI.

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/Views/PlayerView.swift`

CHANGE:

Add audio controls row and optional active indicator.

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/Views/SupportContent.swift`

CHANGE:

Add support description with privacy and uncertainty language.

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/Package.swift`

CHANGE:

If pure model/store types need SwiftPM tests, include new model/store files in `AutohopCore`. Avoid including `Playback/AdSegmentDetector.swift` if it depends on iOS-only AVFoundation APIs unavailable or undesirable in core tests.

MODIFY_FILE:

`/Users/kevinperry/Developer/Autohop/project.yml`

CHANGE:

No package change required if using only system frameworks already included. AVFoundation and Accelerate are already available through app source usage; verify Accelerate linkage if new code references it outside existing files.

## 006_DATA_MODEL_SPEC

### 006_001_AD_DUCKING_SETTINGS

LOCATION:

`Models/AdDucking.swift`

PROPOSED:

```swift
public struct AdDuckingSettings: Equatable, Codable, Sendable {
    public var isEnabled: Bool
    public var volumeScalar: Float
    public var minimumConfidence: Double

    public static let `default` = AdDuckingSettings(
        isEnabled: false,
        volumeScalar: 0.7,
        minimumConfidence: 0.75
    )
}
```

RATIONALE:

- `volumeScalar` allows future user strength without schema migration.
- `minimumConfidence` allows per-podcast sensitivity later; UI can hide in v1.
- Defaults are conservative.

### 006_002_PLAYBACK_PREFERENCE_EXTENSION

LOCATION:

`Models/PlaybackPreference.swift`

ADD_FIELD:

```swift
public var adDucking: AdDuckingSettings
```

UPDATE_DEFAULT:

```swift
public static let `default` = PlaybackPreference(
    speed: 1.0,
    startSkipSeconds: 0,
    endSkipSeconds: 0,
    vocalBoostLevel: .off,
    trimSilence: .off,
    adDucking: .default
)
```

CODABLE:

- Add `case adDucking`.
- Decode with fallback `.default`.
- Encode normally.

BACKWARD_COMPATIBILITY:

Existing persisted playback preferences decode successfully because `adDucking` is optional during decode.

### 006_003_DETECTED_AD_SEGMENT

LOCATION:

`Models/AdDucking.swift`

PROPOSED:

```swift
public struct DetectedAdSegment: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var startSeconds: TimeInterval
    public var endSeconds: TimeInterval
    public var confidence: Double
    public var signals: Set<AdDetectionSignal>
    public var detectedAt: Date
    public var analyzerVersion: Int

    public var durationSeconds: TimeInterval {
        max(0, endSeconds - startSeconds)
    }
}
```

VALIDATION:

- `startSeconds >= 0`
- `endSeconds > startSeconds`
- `durationSeconds >= 5`
- `durationSeconds <= 180`
- `confidence >= 0`
- `confidence <= 1`

### 006_004_AD_DETECTION_SIGNAL

PROPOSED:

```swift
public enum AdDetectionSignal: String, Codable, CaseIterable, Sendable {
    case dynamicEnclosureURL
    case adTechHost
    case longTrackingQuery
    case abruptLoudnessIncrease
    case abruptLoudnessDecrease
    case highCompression
    case spliceSilence
    case spectralDiscontinuity
    case channelCorrelationShift
    case durationPrior
    case repeatedLocalFingerprint
    case chapterTitleHint
    case fileBoundaryPreRoll
    case fileBoundaryPostRoll
}
```

NOTE:

Use `Set<AdDetectionSignal>` in memory. Codable `Set` is acceptable. If stable JSON ordering is desired for tests, encode sorted array manually.

### 006_005_AD_DUCKING_PLAN

PROPOSED:

```swift
public struct AdDuckingPlan: Equatable, Codable, Sendable {
    public var episodeKey: String
    public var fileSignature: MediaFileSignature
    public var analyzerVersion: Int
    public var generatedAt: Date
    public var segments: [DetectedAdSegment]
}
```

### 006_006_MEDIA_FILE_SIGNATURE

PROPOSED:

```swift
public struct MediaFileSignature: Equatable, Codable, Sendable {
    public var localFileName: String
    public var byteCount: Int64
    public var modifiedAt: Date?
    public var durationSeconds: TimeInterval?
    public var quickHash: String?
}
```

QUICK_HASH_OPTION:

Hash only sparse regions to avoid full-file IO:

- first `64 KiB`
- middle `64 KiB`
- last `64 KiB`
- byte count

Algorithm: `SHA256`. Requires `CryptoKit`.

If avoiding `CryptoKit`, omit `quickHash` v1 and use filename/bytes/mtime/duration.

### 006_007_PLAN_LOOKUP

PURE HELPER:

```swift
public struct AdDuckingPlanLookup {
    public var plan: AdDuckingPlan
    public var preRollPadding: TimeInterval = 0.25
    public var postRollPadding: TimeInterval = 0.50
    public var mergeGap: TimeInterval = 2.0

    public func activeSegment(
        at seconds: TimeInterval,
        minimumConfidence: Double
    ) -> DetectedAdSegment?
}
```

LOOKUP_RULE:

Segment active if:

`seconds >= segment.startSeconds - preRollPadding`

and:

`seconds <= segment.endSeconds + postRollPadding`

and:

`segment.confidence >= minimumConfidence`

MERGE_RULE:

If two qualifying segments are separated by `<= mergeGap`, treat as one continuous duck window for volume state to avoid flapping between ads in one pod.

## 007_PERSISTENCE_SPEC

### 007_001_STORE_LOCATION

RECOMMENDED:

`Application Support/Autohop/Derived/AdSegments/`

FILE_FORMAT:

One JSON file per episode/file signature.

FILENAME:

`sha256(episodeKey + "|" + fileSignatureCore).json`

EXCLUDE_FROM_BACKUP:

Yes. Derived analysis can be regenerated.

### 007_002_AD_SEGMENT_STORE_PROTOCOL

```swift
protocol AdSegmentStoring: AnyObject {
    func plan(for episode: Episode, localFileURL: URL) async -> AdDuckingPlan?
    func save(_ plan: AdDuckingPlan, for episode: Episode, localFileURL: URL) async
    func invalidate(for episode: Episode) async
    func prune(maxAgeDays: Int, maxTotalBytes: Int64) async
}
```

THREADING:

- Implement store as `actor AdSegmentStore`.
- File IO must not occur on MainActor.
- Public callers from `AppState` use `Task`.

### 007_003_EPISODE_KEY

Use existing app identity convention:

1. `episode.guid` if non-empty.
2. `episode.audioURL.absoluteString`.

This matches existing comments in `Episode.swift` indicating stable identity is guid/URL, not UUID.

### 007_004_INVALIDATION

Invalidate cached plan if:

- local file missing
- byte count differs
- modified date differs by more than filesystem precision tolerance
- duration differs by `> 0.5s`
- analyzer version changed and migration not supported
- user deletes download
- episode is archived and file deleted

### 007_005_PRUNING

Run opportunistically:

- app launch
- after new plan saved
- after archive/delete pass

Defaults:

- max age: `45 days`
- max bytes: `50 MB`

Prune oldest `generatedAt` first.

## 008_ANALYZER_SPEC

### 008_001_ANALYZER_PROTOCOL

```swift
protocol AdSegmentDetecting: Sendable {
    func analyze(
        episode: Episode,
        localFileURL: URL,
        networkPrior: AdNetworkPrior
    ) async throws -> AdDuckingPlan
}
```

### 008_002_ANALYSIS_SCHEDULING

TRIGGER_AFTER_DOWNLOAD:

`AppState.downloadEpisode(...)` already handles completion and duration update. After marking downloaded, enqueue analysis if:

- episode.mediaKind == `.audio`
- effective/per-podcast ad ducking setting enabled, OR global pre-analysis setting true
- local file URL exists
- no valid cached plan exists

TRIGGER_ON_PLAYBACK_START:

In `AppState.startPlayback(episode:resumeFrom:)`, after local file resolution:

- load cached plan
- if valid, pass to `PlaybackEngine`
- if missing and setting enabled, start background analysis
- do not await analysis before playback

CONCURRENCY_LIMIT:

One active analysis task at a time by default.

Reason:

- audio decoding is IO/CPU heavy
- download-first app may complete several downloads in batch
- preserve battery and thermal headroom

IMPLEMENTATION:

`actor AdAnalysisQueue`

Properties:

- `pending: [EpisodeID/FileSignature]`
- `running: Bool`
- de-duplicate by episode key/file signature

### 008_003_AUDIO_DECODING

Use:

`AVAudioFile(forReading: localFileURL)`

Read:

- frame capacity: `4096` or `8192`
- processing format from file
- downmix to mono feature values, not necessarily write mono buffers

Avoid:

- scheduling audio nodes
- using real-time engine
- blocking MainActor

### 008_004_FEATURE_WINDOWING

Recommended v1 windows:

- `featureWindowSeconds = 1.0`
- `hopSeconds = 0.5`
- if sample rate `44100`, feature window frames `44100`, hop `22050`

For implementation simplicity using `AVAudioFile` buffer chunks:

- read 4096-frame buffers
- accumulate into rolling feature windows
- or compute buffer-level features then aggregate into 1s buckets

V1 simpler approach:

- process buffer-level features
- convert each buffer feature to time range using frame position
- smooth using rolling windows of approximately 1s

### 008_005_FEATURES

Per window compute:

FEATURE_RMS:

- Use `vDSP_rmsqv`.
- For stereo, average channel RMS.
- Convert to dB proxy: `20 * log10(max(rms, 1e-7))`.

FEATURE_PEAK:

- max absolute sample per channel using vDSP.
- `peakDb = 20 * log10(max(peak, 1e-7))`.

FEATURE_CREST_FACTOR:

- `crest = peak / max(rms, 1e-7)`.
- Low crest factor implies high compression.

FEATURE_SILENCE_RATIO:

- proportion of samples where `abs(sample) < 0.0005`.
- exact threshold tune based on fixtures.

FEATURE_ZERO_RUNS:

- detect consecutive near-zero sample runs.
- splice-silence candidate if `50ms <= run <= 250ms`.

FEATURE_SPECTRAL_CENTROID:

- Optional v1. Requires FFT.
- Can be added after RMS/splice implementation.

FEATURE_SPECTRAL_FLUX:

- Optional v1. Compute difference between adjacent magnitude spectra.
- Good for abrupt creative boundary detection.

FEATURE_CHANNEL_CORRELATION:

- For stereo: correlation between L/R.
- Programmatic ad may switch mono/stereo or mastering profile.
- Sudden delta is a boundary signal.

FEATURE_LOCAL_FINGERPRINT:

- Generate robust low-dimensional fingerprint per 5s window.
- V1 lightweight hash:
  - split spectrum into bands if FFT available, OR
  - use vector of RMS/zero-crossing/crest/centroid buckets
  - quantize
  - hash to 64-bit/128-bit value
- Store local occurrence map separately.

### 008_006_NETWORK_PRIOR

STRUCT:

```swift
struct AdNetworkPrior: Equatable, Sendable {
    var score: Double
    var signals: Set<AdDetectionSignal>
}
```

INPUT:

`episode.audioURL`

HEURISTICS:

AD_TECH_HOST_LIST_V1:

- contains `megaphone`
- contains `adswizz`
- contains `tritondigital`
- contains `pdst.fm`
- contains `simplecast`
- contains `omny`
- contains `art19`
- contains `podtrac`
- contains `chartable`
- contains `prefix`
- contains `tracking`

Note: some hosts are general podcast infrastructure, not proof of ads. Use as low-weight prior only.

QUERY_HEURISTICS:

- query length > `120` chars
- query item count > `6`
- keys containing `ip`, `ua`, `device`, `geo`, `ad`, `ads`, `tracking`, `uid`, `sid`, `cachebuster`
- randomized-looking values > `24` chars

SCORE:

- ad-tech host: `+0.10`
- long tracking query: `+0.08`
- multiple suspicious keys: `+0.05`
- cap network prior contribution at `0.18`

### 008_007_BOUNDARY_CANDIDATES

Boundary candidate emitted when any of:

- absolute loudness delta between adjacent smoothed windows >= `6 dB`
- crest factor drops significantly and remains low for >= `10s`
- near-zero splice run `50-250ms`
- channel correlation delta >= `0.35`
- spectral flux spike above rolling median + `3*MAD`
- chapter boundary with ad-like title
- file start at `0-120s` for pre-roll prior
- file end last `0-180s` for post-roll prior

Boundary object:

```swift
struct AdBoundaryCandidate {
    var seconds: TimeInterval
    var confidence: Double
    var signals: Set<AdDetectionSignal>
}
```

### 008_008_SEGMENT_CANDIDATES

Pair boundaries into candidate windows.

Candidate durations:

- min: `10s`
- max: `150s`

Duration priors:

- `15s ± 3s`
- `30s ± 5s`
- `45s ± 5s`
- `60s ± 8s`
- `90s ± 10s`
- `120s ± 12s`

Ad pod support:

- Adjacent candidates separated by `<= 2s` may merge.
- Merged pods can be up to `180s`.

Pre-roll:

- If first strong boundary is at `15-120s`, candidate `[0, boundary]`.

Post-roll:

- If boundary occurs within final `180s`, candidate `[boundary, duration]`.

Mid-roll:

- Pair boundary A and boundary B if duration fits prior and inside segment has sustained ad-like mastering features.

### 008_009_SEGMENT_SCORING

Compute confidence:

```
score =
  0.00
  + networkPrior * 0.50
  + boundaryScoreStart * 0.20
  + boundaryScoreEnd * 0.20
  + durationPriorScore * 0.15
  + masteringScore * 0.25
  + fingerprintRepeatScore * 0.35
  + chapterHintScore * 0.50
  - falsePositivePenalty
```

Clamp to `[0, 1]`.

masteringScore components:

- sustained RMS above local episode median by `>= 3 dB`
- crest factor below episode median by meaningful delta
- low dynamic variability within segment
- abrupt transitions at both edges

falsePositivePenalty:

- segment overlaps known chapter title not ad-like
- segment contains quiet interview-style audio similar to surrounding content
- candidate duration < 10s unless chapter hint
- candidate inside music/interlude pattern repeated as show structure

THRESHOLDS:

- `>= 0.75`: duck
- `0.55-0.75`: store as low-confidence, do not duck by default
- `< 0.55`: discard unless debug logging enabled

### 008_010_LOCAL_FINGERPRINT_DATABASE

V1_PRIVACY_LOCAL_ONLY:

Maintain local occurrence counts for fingerprints across downloaded episodes.

STORE:

`Application Support/Autohop/Derived/AdFingerprints/local-fingerprints.json`

ENTRY:

```swift
struct LocalFingerprintOccurrence: Codable {
    var fingerprint: String
    var episodeKeys: Set<String>
    var firstSeenAt: Date
    var lastSeenAt: Date
    var approximateDurations: [TimeInterval]
}
```

RULE:

If a fingerprint or sequence appears in `>= 2` distinct subscriptions/shows, boost candidate score.

EXCLUSION:

Do not boost repeated segments within same show only. They may be intro/outro/theme.

PRUNING:

- max fingerprints: `100_000`
- max age: `90 days`

## 009_PLAYBACK_ENGINE_SPEC

### 009_001_PROTOCOL_CHANGES

Modify `PlaybackControlling`:

```swift
var onAdDuckingStateChanged: ((Bool) -> Void)? { get set }

func updateAdDuckingPlan(_ plan: AdDuckingPlan?, for episodeID: UUID)
func updateAdDuckingSettings(_ settings: AdDuckingSettings)
```

Potential simpler v1:

```swift
func updateAdDuckingPlan(_ plan: AdDuckingPlan?, settings: AdDuckingSettings, for episodeID: UUID)
```

### 009_002_ENGINE_STATE

Add to `PlaybackEngine`:

```swift
private var currentAdDuckingPlan: AdDuckingPlan?
private var currentAdDuckingSettings: AdDuckingSettings = .default
private var isAdDuckingActive = false
private var adDuckScalar: Float = 1.0
private var sleepVolumeScalar: Float = 1.0
private var volumeFadeTask: Task<Void, Never>?
```

### 009_003_VOLUME_COORDINATION

Replace direct volume assignment:

CURRENT:

```swift
func setVolume(_ volume: Float) {
    let v = min(1, max(0, volume))
    player?.volume = v
    audioPlayerNode?.volume = v
}
```

REPLACE_WITH:

```swift
func setVolume(_ volume: Float) {
    sleepVolumeScalar = clamp01(volume)
    applyEffectiveVolume()
}

private func setAdDuckScalar(_ scalar: Float) {
    adDuckScalar = clamp01(scalar)
    applyEffectiveVolume()
}

private func applyEffectiveVolume() {
    let v = clamp01(sleepVolumeScalar * adDuckScalar)
    player?.volume = v
    audioPlayerNode?.volume = v
}
```

INITIALIZATION:

- On new playback: `sleepVolumeScalar = 1.0`, `adDuckScalar = 1.0`, apply.
- On pause/resume: preserve current scalars.
- On stop: reset to `1.0`.
- On sleep timer cancel/current existing call `setVolume(1.0)` restores sleep scalar only; if ad active, effective remains `0.7`.

### 009_004_DUCKING_STATE_UPDATE

Call in `tickTime()` after `seconds` computed:

```swift
updateAdDuckingState(at: seconds)
```

Pseudo:

```swift
private func updateAdDuckingState(at seconds: TimeInterval) {
    guard currentAdDuckingSettings.isEnabled,
          let plan = currentAdDuckingPlan,
          currentEpisode?.mediaKind == .audio
    else {
        transitionAdDucking(active: false)
        return
    }

    let lookup = AdDuckingPlanLookup(plan: plan)
    let active = lookup.activeSegment(
        at: seconds,
        minimumConfidence: currentAdDuckingSettings.minimumConfidence
    ) != nil

    transitionAdDucking(active: active)
}
```

### 009_005_TRANSITION

```swift
private func transitionAdDucking(active: Bool) {
    guard active != isAdDuckingActive else { return }
    isAdDuckingActive = active
    onAdDuckingStateChanged?(active)
    let target = active ? currentAdDuckingSettings.volumeScalar : 1.0
    fadeAdDuckScalar(to: target, duration: 0.35)
}
```

FADE:

- Duration entering: `0.25s`
- Duration exiting: `0.35s`
- Step interval: `1/30s` or `0.05s`
- Cancel previous fade task when new state arrives.

Important:

- Use `Task { @MainActor }` only if `PlaybackEngine` methods are main. Current engine is used mostly from MainActor but not annotated. GCD/timer callbacks already on main for tick. Keep volume mutation on main path.

### 009_006_SEEK_BEHAVIOR

On seek:

- after updating position, call `updateAdDuckingState(at: target)`.
- If seeking into ad, duck immediately with short fade.
- If seeking out of ad, restore with short fade.

### 009_007_PLAN_APPLICATION

```swift
func updateAdDuckingPlan(_ plan: AdDuckingPlan?, for episodeID: UUID) {
    guard currentEpisode?.id == episodeID else { return }
    currentAdDuckingPlan = plan
    updateAdDuckingState(at: currentPlaybackTime())
}
```

On `startPlayback(...)`:

- accept plan/settings as parameter, OR
- call update immediately after start from `AppState`.

Preferred:

Extend `play(...)` signature only if acceptable:

```swift
func play(_ episode: Episode, preference: PlaybackPreference, filter: ChapterFilter, adDuckingPlan: AdDuckingPlan?) async throws
```

Less invasive:

- keep existing play signature
- after successful `playbackEngine.play(...)`, AppState calls settings/plan update

Tradeoff:

Less invasive may briefly play first tick without ducking if starting inside ad. Since tick interval is 0.5s, acceptable v1. If exact pre-roll ducking desired, pass plan into play.

## 010_APPSTATE_ORCHESTRATION_SPEC

### 010_001_NEW_PROPERTIES

Add to `AppState`:

```swift
let adSegmentStore: AdSegmentStoring
let adSegmentDetector: AdSegmentDetecting
let adAnalysisQueue: AdAnalysisQueue

@Published private(set) var isAdDuckingActive: Bool = false
```

If constructor expansion is noisy, instantiate defaults in bootstrap.

### 010_002_BOOTSTRAP_WIRING

In `AppState.bootstrap()`:

```swift
playbackEngine.onAdDuckingStateChanged = { [weak state] active in
    Task { @MainActor in
        state?.isAdDuckingActive = active
    }
}
```

### 010_003_START_PLAYBACK_FLOW

In `startPlayback(episode:resumeFrom:)`, after local file resolution and before/after `playbackEngine.play(...)`:

1. Resolve subscription.
2. Compute `preference = effectivePreference(for: subscription)`.
3. Load cached plan:

```swift
let adPlan = preference.adDucking.isEnabled
    ? await adSegmentStore.plan(for: playableEpisode, localFileURL: localFileURL)
    : nil
```

4. Start playback.
5. Apply settings + plan:

```swift
playbackEngine.updateAdDuckingPlan(adPlan, settings: preference.adDucking, for: playableEpisode.id)
```

6. If enabled and `adPlan == nil`, enqueue analysis:

```swift
scheduleAdAnalysisIfNeeded(for: playableEpisode, localFileURL: localFileURL, subscription: subscription)
```

### 010_004_POST_DOWNLOAD_ANALYSIS

After successful download:

- if per-podcast setting enabled, enqueue analysis.
- optional: if global pre-analysis enabled, enqueue even if per-podcast off.

Because current app default is off, v1 may analyze only when user enables setting.

### 010_005_SETTING_UPDATE

Add:

```swift
func updateAdDucking(for subscriptionID: UUID, settings: AdDuckingSettings)
```

Flow:

- load subscription
- mutate playbackPreference.adDucking
- persist via `subscriptionStore.updatePlaybackPreference`
- if current episode belongs to subscription:
  - call `playbackEngine.updateAdDuckingSettings(settings)`
  - if settings enabled:
    - load/apply cached plan
    - enqueue analysis if missing
  - else:
    - clear active ducking in engine, but keep cached plan

### 010_006_SHARED_LISTENING_INTERACTION

Decision v1:

Shared Listening affects speed and trim only. It should not disable ad ducking.

Reason:

Listening together does not imply ads should be loud.

Implementation:

Do not alter `adDucking` inside `effectivePreference(for:)` unless product explicitly wants shared listening to disable all processing.

## 011_UI_SPEC

### 011_001_AUDIO_CONTROLS_SHEET

LOCATION:

`/Users/kevinperry/Developer/Autohop/Views/PlayerView.swift`

STRUCT:

`AudioControlsSheetView`

ADD ROW:

Position:

- after `Vocal Boost`, or between `Trim Silence` and `Vocal Boost`.

Recommended:

- after `Vocal Boost`, because it is a detection/comfort feature, not core audio enhancement.

ROW:

```swift
private var adDuckingRow: some View {
    let settings = subscription?.playbackPreference.adDucking ?? .default
    let isOn = settings.isEnabled

    return HStack(spacing: 14) {
        rowIcon("speaker.minus.fill")
        VStack(alignment: .leading, spacing: 3) {
            Text("Lower Detected Ads")
            Text("Turns likely programmatic ads down")
        }
        Spacer()
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { on in
                guard let sub = subscription else { return }
                var newSettings = settings
                newSettings.isEnabled = on
                appState.updateAdDucking(for: sub.id, settings: newSettings)
            }
        ))
    }
}
```

SHEET HEIGHT:

Increase base height by approximately `72`.

### 011_002_PLAYER_ACTIVE_BADGE

LOCATION:

`PlayerView`

Condition:

`if appState.isAdDuckingActive`

Text:

`Ad lowered`

Icon:

`speaker.minus.fill`

Style:

Small pill, visually similar to existing transient indicators. Avoid alarm color. Use neutral/white material.

### 011_003_SETTINGS_DEFAULTS

Default playback preference panel may include the same toggle later.

For v1, optional. Per-podcast only is lower risk.

## 012_SUPPORT_COPY_SPEC

LOCATION:

`/Users/kevinperry/Developer/Autohop/Views/SupportContent.swift`

ADD TO AUDIO CONTROLS SECTION:

Content constraints:

- Mention local detection.
- Mention likely ads.
- Mention it lowers volume rather than skipping.
- Mention not perfect.

COPY:

`Lower Detected Ads analyzes downloaded audio on your device and turns likely programmatic ad breaks down while they play. It does not skip ads or change your device volume. Detection is best-effort, so some ads may stay normal and some non-ad segments may occasionally be lowered.`

## 013_STATS_SPEC

V1:

No stats required.

Reason:

Ducking does not save time.

V2 optional:

Add `adDuckedSeconds` as comfort metric. Do not include in `totalTimeSaved`.

If implemented:

- Add to `DayStats`: `adDuckedSeconds`
- Increment from playback tick when `isAdDuckingActive && isPlaying`
- Add separate Stats UI label: `Ads lowered`

## 014_TEST_SPEC

### 014_001_UNIT_TESTS_PURE

ADD:

`/Users/kevinperry/Developer/Autohop/Tests/AdDuckingPlanLookupTests.swift`

CASES:

- inactive when no segments
- inactive below confidence threshold
- active at exact start
- active with pre-padding
- active at exact end
- active with post-padding
- inactive beyond post-padding
- adjacent segments merge when gap <= 2s
- adjacent segments do not merge when gap > 2s

ADD:

`/Users/kevinperry/Developer/Autohop/Tests/PlaybackVolumeCoordinatorTests.swift`

CASES:

- `sleep=1.0`, `ad=1.0` => `1.0`
- `sleep=1.0`, `ad=0.7` => `0.7`
- `sleep=0.5`, `ad=0.7` => `0.35`
- clamps negative to 0
- clamps above 1
- restoring sleep to 1 while ad active leaves effective 0.7
- disabling ad while sleep fade active returns to sleep scalar

ADD:

`/Users/kevinperry/Developer/Autohop/Tests/PlaybackPreferenceAdDuckingDefaultsTests.swift`

CASES:

- missing `adDucking` decodes as default off
- encode/decode round trip preserves enabled and scalar

ADD:

`/Users/kevinperry/Developer/Autohop/Tests/AdSegmentScoringTests.swift`

CASES:

- strong chapter hint crosses threshold
- network prior alone does not cross threshold
- duration prior alone does not cross threshold
- repeated local fingerprint boosts candidate over threshold when boundary/mastering also present

### 014_002_ANALYZER_FIXTURE_TESTS

Synthetic generation:

- show section: sine/noise/speech-like amplitude with moderate dynamic range
- ad section: louder, compressed, different crest factor, exact 30s
- show section returns to baseline

Assert:

- detected segment overlaps synthetic ad by >= `80%`
- start error <= `3s`
- end error <= `3s`

Use generated fixture inside test runtime if possible to avoid large binary fixture.

### 014_003_APP_TARGET_MANUAL_QA

Manual scenarios:

1. Audio episode, no trim/boost, `AVPlayer` path, ad duck active.
2. Audio episode, trim enabled, `AVAudioEngine` path, ad duck active.
3. Audio episode, vocal boost enabled, `AVAudioEngine` path, ad duck active.
4. Sleep timer fade while ad active.
5. Sleep schedule fade while ad active.
6. Seek into detected ad.
7. Seek out of detected ad.
8. Pause during detected ad, resume inside same ad.
9. Route change during ad.
10. Episode finishes while ducking.
11. Video episode ignores ad ducking.

EXPECTED:

- no volume snap to full during sleep fade
- no persistent lowered volume after stop/new episode
- no crash if plan arrives after episode changed
- no ducking when setting off

## 015_LOGGING_SPEC

Use `AppLogger`.

Events:

`adDucking.analysisQueued`

Metadata:

- episode title
- episode id
- podcast title
- reason

`adDucking.analysisStarted`

Metadata:

- local filename
- byte count
- analyzer version

`adDucking.analysisFinished`

Metadata:

- segment count
- high confidence count
- duration
- elapsed ms

`adDucking.analysisFailed`

Metadata:

- error
- episode id

`adDucking.stateChanged`

Metadata:

- active
- current seconds
- segment start/end
- confidence

`adDucking.planApplied`

Metadata:

- episode id
- segment count
- source: cache/analyzer/live

REDACTION:

- Do not log full audio URLs unless existing diagnostic mode already allows.
- Avoid query strings in URL metadata.

## 016_PERFORMANCE_SPEC

CPU:

- Analyzer runs at `.utility`.
- Max one concurrent analysis.
- Defer analysis while battery low? optional v2.

MEMORY:

- Do not load whole audio file into memory.
- Streaming decode only.
- Feature arrays acceptable: one record per 0.5-1s.
- For 3h episode at 0.5s hop: `21600` records. Fine if compact.

BATTERY:

- Prefer post-download while app active.
- Avoid background task claims unless implementing real BGProcessingTask. Current project explicitly does not declare background processing.

IO:

- Sparse file hash if hashing.
- Derived cache pruning.

UI:

- No MainActor decoding.
- No synchronous file analysis from toggle handler.

## 017_EDGE_CASES

EDGE_001:

Episode downloaded, then dynamic ad insertion URL later serves different file on re-download. File signature invalidates plan.

EDGE_002:

Episode has host-read sponsorship integrated into content. Programmatic detector may miss it. Accept.

EDGE_003:

Show has recurring intro identical across episodes. Local fingerprint may mistake it for ad. Mitigation: require cross-show repetition for strong repeated-fingerprint boost.

EDGE_004:

News bulletins have loud stingers and short segments. Boundary/loudness detector may false-positive. Mitigation: duration prior + two-boundary requirement.

EDGE_005:

Music podcasts have high compression. Mitigation: only duck when multiple signals align.

EDGE_006:

Trim Silence changes file-time to wall-time relationship in engine path. Existing engine tracks file seconds via `.dataRendered`. Use file seconds for ad lookup. Correct.

EDGE_007:

Playback speed changes do not affect file seconds. Use current file seconds. Correct.

EDGE_008:

Sleep timer sets volume to `1.0` on resume. With volume composition, this restores sleep scalar only; ad scalar remains if currently in ad.

EDGE_009:

Plan arrives while playback is already inside ad. Engine should immediately evaluate current time and fade down.

EDGE_010:

Plan arrives for stale episode after user changed episode. Engine ignores by episodeID.

EDGE_011:

User disables setting while ducking. Engine transitions ad scalar to `1.0` and state false.

EDGE_012:

User enables setting during playback and cached plan exists. Apply immediately.

EDGE_013:

User enables setting during playback and no plan exists. Playback continues unchanged; analysis starts.

EDGE_014:

Video episode. Do not analyze or duck in v1.

## 018_INCREMENTAL_IMPLEMENTATION_ORDER

STEP_001:

Add pure model types in `Models/AdDucking.swift`.

STEP_002:

Extend `PlaybackPreference` Codable with `adDucking` default off.

STEP_003:

Add pure `PlaybackVolumeCoordinator` and tests.

STEP_004:

Refactor `PlaybackEngine.setVolume` to use composed volume with behavior-preserving tests where possible and manual QA.

STEP_005:

Add `AdDuckingPlanLookup` tests.

STEP_006:

Add `PlaybackEngine` plan/settings ingestion and active-state tick logic using injected synthetic plans.

STEP_007:

Wire `AppState` setting update and active state callback.

STEP_008:

Add Audio Controls toggle.

STEP_009:

Add `AdSegmentStore`.

STEP_010:

Wire cached plan loading at playback start.

STEP_011:

Add minimal deterministic analyzer:

- URL prior
- RMS/loudness boundary
- splice silence
- duration prior
- segment scoring

STEP_012:

Add post-download/lazy analysis queue.

STEP_013:

Add local fingerprint database.

STEP_014:

Tune thresholds against real downloaded episodes with diagnostic logs.

STEP_015:

Optional active player badge and support docs.

## 019_MINIMAL_V1_CUT

If time constrained, implement only:

- settings model
- volume coordinator
- playback plan lookup
- manual/synthetic ad segment plan application
- deterministic analyzer using loudness/splice/duration only
- no local fingerprint
- no active badge

This still gives end-to-end feature and safe volume behavior.

## 020_PREFERRED_V1_CUT

Implement:

- settings model
- volume coordinator
- playback plan lookup
- cache store
- analyzer with network prior + loudness + splice + compression + duration
- local fingerprint occurrence boost
- Audio Controls row
- support docs
- active badge
- tests for pure logic

## 021_CODE_SHAPES

### 021_001_VOLUME_COORDINATOR

```swift
public struct PlaybackVolumeCoordinator: Equatable, Sendable {
    public var sleepScalar: Float = 1.0
    public var adDuckScalar: Float = 1.0

    public var effectiveVolume: Float {
        Self.clamp01(sleepScalar) * Self.clamp01(adDuckScalar)
    }

    public mutating func setSleepScalar(_ value: Float) {
        sleepScalar = Self.clamp01(value)
    }

    public mutating func setAdDuckScalar(_ value: Float) {
        adDuckScalar = Self.clamp01(value)
    }

    public static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
```

### 021_002_ACTIVE_LOOKUP

```swift
public func activeSegment(
    at seconds: TimeInterval,
    minimumConfidence: Double
) -> DetectedAdSegment? {
    let eligible = plan.segments
        .filter { $0.confidence >= minimumConfidence }
        .sorted { $0.startSeconds < $1.startSeconds }

    for segment in eligible {
        let start = segment.startSeconds - preRollPadding
        let end = segment.endSeconds + postRollPadding
        if seconds >= start && seconds <= end {
            return segment
        }
    }
    return nil
}
```

Enhancement:

Pre-merge eligible windows before lookup.

### 021_003_ANALYSIS_QUEUE

```swift
actor AdAnalysisQueue {
    private var pending: [AdAnalysisRequest] = []
    private var running = false

    func enqueue(_ request: AdAnalysisRequest) {
        guard !pending.contains(where: { $0.key == request.key }) else { return }
        pending.append(request)
        if !running {
            Task { await drain() }
        }
    }

    private func drain() async {
        running = true
        defer { running = false }
        while !pending.isEmpty {
            let request = pending.removeFirst()
            await request.run()
        }
    }
}
```

Need careful with escaping closures and actor isolation. Alternative: AppState owns queue tasks directly.

## 022_PRIVACY_REVIEW_TEXT

APP_REVIEW_NOTES_OPTIONAL:

`Lower Detected Ads analyzes podcast audio files already downloaded by the user. Analysis runs locally on device and is used only to reduce playback volume during likely ad segments. Autohop does not upload podcast audio, transcripts, or ad fingerprints. The feature does not block network requests or alter ad delivery.`

## 023_FAILURE_BEHAVIOR

If analyzer fails:

- log diagnostic
- save no plan
- playback unaffected
- UI remains enabled
- do not show user error

If cache corrupt:

- delete corrupt file
- playback unaffected

If volume coordinator fails logically:

- clamping prevents >1 and <0
- stop/new playback resets scalar

If false positive:

- v1 has no correction UI
- v2 add `Not an ad` button or long-press badge action

If false negative:

- ad plays at normal volume
- acceptable v1

## 024_FUTURE_EXTENSIONS

V2_CORRECTIONS:

- `Not an ad`
- `Lower this section`
- per-show learned suppressions

V2_COREML:

- Train classifier on extracted features, not raw audio where possible.
- Use model to score candidate segments generated by deterministic boundary detector.
- Do not run model across every frame unless performance acceptable.

V2_HLS:

- If app later supports HLS streaming/download, parse manifest.
- Treat `EXT-X-DATERANGE`/SCTE-35 as high-value signal.
- Treat `EXT-X-DISCONTINUITY` as boundary signal only, not proof of ad.

V2_CLOUD:

- Optional privacy-preserving shared fingerprints.
- Requires explicit privacy design.
- Avoid uploading raw fingerprints if they can identify content too precisely.

V2_STATS:

- `adDuckedSeconds`
- per-show comfort metric

## 025_ACCEPTANCE_CRITERIA

AC_001:

When setting off, playback volume behavior is unchanged compared with current app.

AC_002:

When setting on and current playback time enters a supplied high-confidence segment, effective app volume fades to `0.7`.

AC_003:

When current playback time exits supplied segment, effective app volume fades to `1.0`, unless sleep fade scalar is lower.

AC_004:

Sleep timer fade and ad ducking compose multiplicatively.

AC_005:

Sleep schedule fade and ad ducking compose multiplicatively.

AC_006:

Seeking into ad segment activates ducking.

AC_007:

Seeking out of ad segment deactivates ducking.

AC_008:

Plan arriving for non-current episode is ignored.

AC_009:

Cached plan invalidates after file byte count or duration changes.

AC_010:

Existing persisted `PlaybackPreference` JSON without ad ducking fields decodes successfully.

AC_011:

Analyzer failure never blocks playback.

AC_012:

No audio is uploaded or sent to a new external service.

## 026_RISK_REGISTER

RISK_FALSE_POSITIVE:

Impact high. Mitigation: conservative threshold, multi-signal scoring, default off.

RISK_FALSE_NEGATIVE:

Impact medium/low. Mitigation: improve analyzer iteratively.

RISK_VOLUME_CONFLICT:

Impact high. Mitigation: volume coordinator before playback ducking.

RISK_BATTERY:

Impact medium. Mitigation: one analysis at a time, utility priority, local cache.

RISK_STORAGE:

Impact low. Mitigation: derived cache pruning.

RISK_APP_REVIEW:

Impact medium. Mitigation: position as volume comfort feature, not ad blocking; no request blocking.

RISK_LEGAL_AD_MEASUREMENT:

Impact low/medium. Mitigation: do not skip, do not block, do not alter ad delivery; user hears lowered ad.

RISK_USER_TRUST:

Impact high. Mitigation: best-effort language and future correction UI.

## 027_SUMMARY_DIRECTIVE_FOR_AI_AGENT

Implement this feature as a conservative local audio-derived playback-volume modifier. Do not implement network ad blocking. First refactor volume handling so sleep fades and ad ducking compose. Then add ad segment plan models and lookup. Then wire playback tick state transitions. Then add persistence and background local analysis. Then expose per-podcast UI. Keep all detection probabilistic. Default off. Optimize for no regressions in playback reliability.

