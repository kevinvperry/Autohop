# Autohop Responsive Layout Proposal — iOS 27 Resizability, iPad, and Foldable Readiness

<!--
AI CONTEXT — Docs/RESPONSIVE_LAYOUT_PROPOSAL.md

PURPOSE: Implementation proposal for making Autohop display accurately across
the full range of iPhone and iPad screen sizes — including arbitrary window
sizes (iPhone-app-on-iPad, iPhone Mirroring, iPad multitasking) and the
rumoured folding iPhone — per Apple's WWDC26 app-resizability guidance.
Kevin's brief called this Apple's "Responsive Screen Size" guidelines; Apple's
official framing (WWDC26, June 2026) is the **iOS 27 app resizability push**:
design for "a dynamic range of sizes and aspect ratios", fluid reflow — not
letterboxing — as the default. This doc uses "resizability" throughout.

STATUS: PACKAGE 1 LANDED (2026-07-30); PACKAGE 2 IMPLEMENTATION STARTED
(2026-08-11). `Docs/RESIZABILITY_AUDIT_2026-07-30.md` contains the current
full visual inventory, authoritative Package 2 execution plan and per-work-group
status. Phase status lines below track code progress; iPad and Mac support have
not yet been enabled.

RELATED:
- Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md — its Phase 5 (iPad enablement)
  one-liner is SUPERSEDED by Phase 2 of THIS doc, which is the detailed
  execution. Its Phase 0 (AppState domain extraction) is NOT required for this
  doc's work — resizability is view-layer work — but if both land, do tvOS
  Phase 0 first so iPad split-view view models observe domain objects.
- Docs/WATCH_APP_IMPLEMENTATION_PROPOSAL.md — unaffected (watch layouts are
  their own idiom), but the fluid-layout habits from Phase 1 here apply to any
  future watch screen work.

EPISTEMIC WARNING FOR AI EXECUTORS: The WWDC26 API surface postdates the
assisting model's training data. Every API named in §1 (toolbar
visibilityPriority / toolbarOverflowMenu / topBarPinnedTrailing, hinge-state
APIs, resizable-simulator workflow) MUST be verified against the actual
Xcode 27 SDK headers/docs on Kevin's machine before writing code against it.
Where this doc says "verify at implementation time", that is a hard gate, not
a suggestion. The rumoured foldable iPhone is UNANNOUNCED hardware — §1.4
explains why the plan deliberately does not target its rumoured dimensions.

HOW TO USE: Execute phases in order; Phase 0+1 are one release-sized unit.
Follow §0 constraints at all times. §5 is the per-view work table — keep its
status column current as views are converted.
-->

Source inputs:

- WWDC26 (June 8–12, 2026) materials: Platforms State of the Union
  (developer.apple.com/videos/play/wwdc2026/122/), "What's new in SwiftUI"
  (developer.apple.com/videos/play/wwdc2026/269/), "Modernize your UIKit app",
  WWDC26 iOS/Design/SwiftUI guides (developer.apple.com/wwdc26/guides/).
- Third-party analysis, 2026-06/07: fatbobman, "From Size Class to Available
  Space — Is horizontalSizeClass Still Reliable?"
  (fatbobman.com/en/posts/from-size-class-to-available-space/); The Swift Dev,
  "Make SwiftUI Toolbars Work In Resizable iPhone Apps"; MacRumors/9to5Mac
  reporting on iOS 27 resizability push and `foldState` / `angleDegrees`
  framework strings.
- Initial Autohop codebase audit performed 2026-07-03 (§2), followed by the
  complete all-view viewport audit on 2026-07-30
  (`Docs/RESIZABILITY_AUDIT_2026-07-30.md`).
- Autohop docs: `FEATURES.md`, `DESIGN.md`, `PAGES.md`, `project.yml`,
  `Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md`.

---

## 0. Global constraints (apply to every phase)

1. **XcodeGen**: all target/Info changes via `project.yml` + `xcodegen generate`.
2. **No AI-run builds**: Kevin compiles. Reason hard about compile-correctness;
   layout changes are especially preview-dependent — hand over with explicit
   "views to eyeball in Preview at sizes X/Y/Z" lists.
3. **Docs + headers workflow**: read AI CONTEXT headers before editing any
   view; update headers + `DESIGN.md` after. Layout conventions added here
   become labelled DESIGN.md patterns.
4. **Main branch only** unless Kevin approves a branch. Phase 2 (iPad) is
   release-sized — propose a branch first.
5. **Zero regressions on current iPhones**: every phase's exit gate includes
   the existing portrait iPhone experience pixel-reviewed by Kevin.
6. **Verify post-cutoff APIs against the SDK** before use (header warning).
7. **Design tokens over magic numbers**: any width threshold introduced lives
   in ONE file (`Views/AdaptiveLayout.swift`, Phase 0) — never inline.

---

## 1. What Apple actually announced (WWDC26) — and what it means for Autohop

### 1.1 The resizability push (the "Responsive Screen Size" story)

- Rebuilding against the iOS 27 SDK **auto-opts apps into resizability**:
  the system may present the app at sizes and aspect ratios that match no
  current iPhone — iPhone-app-window-on-iPad, iPhone Mirroring on Mac,
  and (implicitly) future flexible-display hardware. SwiftUI apps using the
  scene lifecycle (Autohop qualifies: `@main AutohopApp`) are "well on your
  way", per Apple.
- Apple's stated design direction: stop designing for specific devices and
  fixed orientations; target **a dynamic range of sizes and aspect ratios**;
  **fluid reflow, not letterboxing**, is the expected behaviour.

### 1.2 Layout guidance shift: host semantics vs available space

The key conceptual change (per WWDC26 + fatbobman's analysis): Apple has
separated *host semantics* from *available geometric space*.
`horizontalSizeClass` is no longer a reliable proxy for width — a wide window
in an iPhone host does not necessarily report `.regular`. Layout decisions
should key off **actual available space** (`onGeometryChange`,
`containerRelativeFrame`, layout that naturally reflows) and reserve size
classes for coarse idiom-level decisions only.

Consequence for Autohop: convenient timing. Autohop has **zero size-class
code today** (§2) — it can adopt the new guidance directly with no legacy
size-class idioms to unwind.

### 1.3 New API surface (verify at implementation time)

- **Toolbar resilience**: `visibilityPriority` (which items survive a narrow
  bar), `toolbarOverflowMenu` (permanent overflow placement),
  `topBarPinnedTrailing` (pin critical actions at any width).
- **Adaptive layout / hinge**: new SwiftUI + UIKit APIs for hinge-state
  detection and multi-configuration displays were signalled; iOS 27 frameworks
  contain `foldState` and `angleDegrees` strings. NO public foldable hardware
  exists; treat any hinge API as "adopt when documented" (R5).
- **Tooling**: resizable iOS simulator (arbitrary sizes/aspect ratios),
  Xcode 27 Live Preview **resize handles**, and an Apple-provided coding-agent
  skill for finding/fixing resizability issues (evaluate it in Phase 0 —
  it is exactly this doc's job, automated).
- **UIKit islands**: "Modernize your UIKit app" covers correct screen-geometry
  determination and orientation-change handling for mixed SwiftUI/UIKit apps —
  directly relevant to Autohop's two UIKit touchpoints (§2.3).

### 1.4 The folding iPhone (rumoured — design posture, not a target)

Reporting around WWDC26: book-style fold, ~5.5″ cover display (tall/narrow),
~7.8″ near-square inner display, possible September 2026 debut; Apple showed
and confirmed nothing. **The plan therefore does not design for rumoured
dimensions.** Apple's own guidance is the shield: an app that reflows fluidly
across arbitrary widths — including very narrow (~cover-display-like) and
near-square (~inner-display-like) windows exercised in the resizable simulator
— is foldable-ready by construction, whatever ships. Hinge-specific behaviour
(continuity across fold state, hinge-aware split placement) is a bounded
Phase 3 addition once real APIs + hardware exist.

---

## 2. Current-state audit (2026-07-03)

### 2.1 Good news (the codebase is largely clean)

- No `UIScreen.main.bounds`-derived layout anywhere (the only `UIScreen.main`
  uses are `scale` for CarPlay artwork rendering — harmless, though
  per-window `displayScale` is the modern replacement; fix in passing).
- No `UIRequiresFullScreen`, no hardcoded device-width branches, no size-class
  code, no orientation-locked storyboards (no storyboards at all).
- Fixed `.frame(width:)` uses are **content sizing** (artwork thumbnails
  104–176 pt in `Views/PodcastsView.swift:194`, `Views/DiscoverView.swift:667`,
  `Views/PlayerView.swift:538`, `Views/EpisodeShareCardView.swift:49`, etc.) —
  legitimate and reflow-safe inside flexible containers; the share card is a
  fixed-size render target by design.
- SwiftUI scene lifecycle throughout → lands in the auto-opt-in happy path.

### 2.2 The three real hazards

1. **Orientation machinery** — `App/AppDelegate.swift:272`
   (`supportedInterfaceOrientationsFor`) + `Views/NativeVideoPlayerView.swift`
   (static `supportedOrientations` mask + programmatic orientation requests;
   app is portrait except video, which rotates to landscape). Resizable hosts
   weaken the whole concept of "the device orientation" — a floating window
   has no orientation to lock. This machinery must become: *portrait-preferred
   on iPhone-shaped hosts, unconstrained elsewhere, video fills whatever
   window it gets* (R3).
2. **`Views/PlayerView.swift`** — permanently mounted NavigationStack root
   with three horizontally swipeable panels and a scrubber. The artwork
   `GeometryReader` at line 647 already constrains against both available width
   and height and is not itself a hazard. The macro panel and transport layout
   still assumes phone-portrait proportions. This is the flagship reflow risk:
   at wide/short sizes it should become side-by-side
   (artwork+transport | details/chapters); at very narrow widths the
   transport row must not clip (§5).
3. **No adaptive vocabulary exists** — every screen was designed at one
   width. Most list-based screens (Queue, Subscriptions, Settings, Downloads)
   will reflow acceptably at narrow widths, but need readable-width constraints
   when wide. Grid/chart/card screens (`StatsView` charts and fixed-count grid,
   Player/Episode metadata, `DiscoverView`'s 19 shelves and in-feed heroes,
   onboarding cards, coach-mark positioning) embed one-width assumptions that
   need explicit reflow behaviour (§5). `SupportView` is the existing good
   `.adaptive(minimum:)` grid example; `PodcastSearchView` is the existing good
   `containerRelativeFrame` example.

### 2.3 UIKit islands to check against "Modernize your UIKit app"

`App/AppDelegate.swift` (orientation, background tasks) and
`Views/NativeVideoPlayerView.swift` (AVKit wrapper + orientation requests).
Everything else is SwiftUI.

---

## 3. Decisions (R-series, locked unless Kevin overrides)

- **R1 — Adopt resizability deliberately, not accidentally.** The iOS 27 SDK
  rebuild will opt Autohop in whether or not it's ready; Phase 0/1 make it
  actually correct before that rebuild ships. Fluid reflow everywhere; no
  letterboxing, no "unsupported size" walls.
- **R2 — Available-space-driven layout, single token file.** Layout branches
  key off measured width via `onGeometryChange`/`containerRelativeFrame`
  (§1.2), never `horizontalSizeClass` (except a possible coarse iPad-idiom
  check in Phase 2 navigation). `Views/AdaptiveLayout.swift` defines the whole
  vocabulary: width bands `narrow` (< ~340 pt — cover-display-like /
  one-third-split), `standard` (current iPhones), `wide` (> ~500 pt — landscape
  phone / half-split / near-square), `expansive` (> ~700 pt — iPad full,
  inner-fold-like), plus grid-column and artwork-size helpers per band. Band
  thresholds are provisional; tune with the resizable simulator, keep in one
  place (§0.7).
- **R3 — Orientation model rework.** Replace "app locks portrait, video flips
  landscape" with: `project.yml` declares all orientations; the AppDelegate
  mask keeps portrait-preferred ONLY for compact phone-shaped hosts (per the
  "Modernize your UIKit app" recipe — verify the recommended pattern at
  implementation time); video plays edge-to-edge in ANY window shape, with
  rotation requests retained only on literal iPhone hardware. Landscape
  iPhone (non-video) becomes a supported reflow case for the first time —
  wide-band layouts must carry it.
- **R4 — Toolbar/nav resilience via the new APIs.** Player top bar
  (`PlayerView` NavRules: subscriptions button, sleep-schedule pill, panel
  pills, Up Next button) adopts `visibilityPriority` + overflow so it degrades
  by design at narrow widths instead of clipping: Up Next pinned trailing,
  panel pills collapse to icons, sleep pill first into overflow. Same
  treatment for any screen whose top bar has >2 actions. (API names: verify —
  §0.6.)
- **R5 — Foldable = fluidity now, hinge APIs later.** Phase 1/2 make every
  screen correct at narrow/near-square/arbitrary sizes (the foldable's real
  requirement). Hinge-state adoption (`foldState`-style APIs), cover↔inner
  continuity behaviour (audio keeps playing, UI re-lays-out without losing
  scroll/sheet state), and hinge-aware split placement wait for public API +
  documented behaviour (Phase 3). Do NOT code against leaked strings.
- **R6 — iPad is the same fluidity plus navigation idiom.**
  `TARGETED_DEVICE_FAMILY: "1,2"`; Library/Queue/Player as
  `NavigationSplitView` at `expansive` width, the existing stack otherwise;
  full multitasking (Split View / window resize on iPadOS 26+) supported via
  the same width bands — no iPad-specific screens. Pointer + hardware-keyboard
  basics (space = play/pause via existing key handling, arrow seek). Every
  screen — Settings farm, onboarding, stats, share flows — gets an iPad
  layout pass because App Review will open all of them (executes and
  supersedes tvOS doc Phase 5).
- **R7 — State survives resize.** Window size changes (drag-resize, fold,
  rotation, split) must never reset navigation, dismiss sheets, stop video, or
  lose scrubber interaction. Resize is a layout event, not a lifecycle event —
  audit `@State` keyed on geometry (the §2.2 GeometryReader sites) for
  accidental identity resets.
- **R8 — Deployment target stays iOS 17.** New toolbar/hinge APIs gate behind
  `#available(iOS 27, *)` with graceful narrow-width fallbacks (truncation
  priorities, manual overflow Menu). Revisit the floor only if gating cost
  exceeds ~a dozen sites (Kevin's call at Phase 1 end).
- **R9 — Test matrix is tool-driven.** Adopt the resizable simulator + Preview
  resize handles as the standard workflow; evaluate Apple's resizability
  coding-agent skill in Phase 0 and fold it into the loop if it earns it.
  Canonical QA sizes: iPhone SE-class, current flagship, current Max,
  landscape flagship, ~340 pt narrow window, ~½ iPad split, near-square
  (~700×740-ish), 11″ + 13″ iPad full screen.

---

## 4. Phases

### Phase 0 — Foundations & hazard removal (iOS-visible changes: none)

**Goal:** the vocabulary and the safety rails exist; known hazards are gone;
the iOS 27 SDK rebuild becomes safe.

1. Create `Views/AdaptiveLayout.swift` (R2): width bands, per-band grid
   columns / artwork sizes / spacing scale; document as DESIGN.md pattern
   `AdaptiveLayout-Bands`. **Complete 2026-07-30**, including boundary/helper
   regression tests.
2. Orientation rework (R3): `project.yml` orientations + AppDelegate mask +
   `NativeVideoPlayerView` behaviour, per the "Modernize your UIKit app"
   recipe. This is the one Phase 0 item with user-visible risk — regression
   test video enter/exit thoroughly on hardware.
3. `UIScreen.main.scale` → per-context `displayScale` in
   `CarPlay/CarPlayArtworkProvider.swift` (audit-driven cleanup).
4. Complete the source-level all-view resizability audit and record findings
   as `Docs/RESIZABILITY_AUDIT_<date>.md`. **Complete 2026-07-30.** The audit
   was performed directly against the current codebase; implementation and
   visual device/simulator verification remain outstanding.
5. Xcode 27 SDK rebuild smoke pass (Kevin): app runs, no layout explosions at
   default sizes.

**Verification:** current-device experience unchanged (Kevin pixel review);
video orientation flows correct; smoke tests green.

### Phase 1 — Fluid iPhone (ship: "Autohop looks right at any window size")

**Goal:** every screen reflows correctly across `narrow`→`wide` bands in an
iPhone-class host: iPhone-app-on-iPad window, iPhone Mirroring, landscape
iPhone, and by construction the rumoured cover display.

1. Work §5 table top-down: PlayerView first (panels → side-by-side at `wide`;
   transport row scales; scrubber full-width at all bands), then RootView/
   MiniPlayerBar, QueueSheetView, PodcastsView grid (band-driven columns),
   DiscoverView shelves, StatsView charts, PodcastDetailView, onboarding +
   coach marks (positioning assumptions!), Settings screens (mostly free).
2. Toolbar resilience pass (R4) on PlayerView top bar + any crowded bars.
3. Sheets/covers audit: presentation detents and `presentationSizing` at
   non-phone sizes; share card stays fixed-render (it's an export artifact).
4. State-survival audit (R7) across all resize paths.

**Verification:** R9 matrix sweep in resizable simulator with per-screen
screenshots into `Docs/RESIZABILITY_QA_PHASE1.md`; Dynamic Type XL × narrow
band spot checks (the compounding case); no clipped/overlapping controls at
any matrix point.

**Ship gate:** this phase alone is releasable (invisible on today's iPhones,
correct everywhere else). Update FEATURES.md; SupportContent/website only if
user-visible claims are made.

### Phase 2 — iPad enablement (separate release; branch proposal to Kevin)

**Goal:** first-class iPad app. Scope per R6:

1. `project.yml`: `TARGETED_DEVICE_FAMILY: "1,2"`; iPad orientations; icons/
   launch already asset-catalog-driven — verify.
2. Navigation idiom: `NavigationSplitView` (sidebar: Queue / Subscriptions /
   Discover / Stats / Settings; detail: current stack content) at `expansive`,
   existing stack otherwise; PlayerView as detail-column resident or floating
   experience — decide with Kevin via mockups BEFORE building (one
   AskUserQuestion-worthy fork: split-view player vs. iPhone-style
   full-screen player on iPad).
3. Multitasking: full width-band coverage in Split View/window drag (mostly
   inherited from Phase 1); keyboard + pointer basics.
4. Every remaining screen (onboarding, stats, sharing, diagnostics) at iPad
   sizes; App Store iPad screenshots; App Review re-screens everything.

### Phase 3 — Foldable-specific adoption (gated on public API + hardware)

1. Verify + adopt hinge-state APIs (§1.3) where behaviour genuinely improves:
   split transport/content placement when half-folded ("flex mode"-style),
   avoiding controls under the crease via safe-area/hinge insets if the API
   exposes them.
2. Cover↔inner continuity QA: playback (audio + video) uninterrupted across
   fold transitions; layout re-bands without state loss (R7 already
   guarantees the mechanism; this phase proves it on hardware).
3. Re-tune band thresholds against real fold geometry; update
   `AdaptiveLayout-Bands` docs.

### Phase 4 — Polish & upkeep

Marketing screenshots at new sizes; DESIGN.md consolidation; fold-state
telemetry-free sanity checklist added to release QA; revisit R8 floor.

---

## 5. Per-view reflow work table (Phase 1 backlog; keep status current)

| View | Assumption today | Reflow behaviour required | Status |
|---|---|---|---|
| `Views/PlayerView.swift` | 3 portrait-oriented panels; crowded top/audio rows; fixed 2-column metadata; fixed sheet sizes | Easy wins landed: route-control fallback, adaptive metadata, safe scrollable sheets and compact selected-tab label. Later: side-by-side wide player and toolbar priorities (R4) | Easy wins complete 2026-07-30; macro layout pending |
| `Views/RootView.swift` | Mini-player chrome spans the viewport; secondary labels compete at narrow widths | Full-width background/progress with capped centred content; title-priority fallback | Complete 2026-07-30 |
| `Views/QueueSheetView.swift` | Rows mostly flex; fixed rank/art/trailing metadata and sheet presentation | Readable list width, touch-target verification and adaptive presentation; sheet vs popover later | Audited; implementation not started |
| `Views/PodcastsView.swift` | Flexible list rows; empty state uses fixed 104 pt artwork and broad padding | Readable list width, adaptive empty state and title priority; no grid conversion required | Audited; implementation not started |
| `Views/DiscoverView.swift` | Heroes fixed around 320/284 pt; shelf cells 124 pt | Hero sizes now aspect-driven and clamped; shelf item expansion remains visual-QA work | Partially complete 2026-07-30 |
| `Views/PodcastSearchView.swift` | Container-relative show rail already adapts well; result lists unbounded at wide widths | Preserve rail pattern; cap result widths; expansive columns only after review | Readable width complete 2026-07-30 |
| `Views/StatsView.swift` | Forced 3-across hero; fixed chart heights; broad single column | Hero now falls back to adaptive grid and page width is capped; chart/dashboard restructure remains later | Partially complete 2026-07-30 |
| `Views/PodcastDetailView.swift` | Forced 128 pt-art horizontal header; nested geometry probes | Stack when cramped; cap content; simplify probes | Audited; implementation not started |
| `Views/WelcomeView.swift`, `FirstSubscribeCard`, `StarterPacksView`, `CoachMark.swift` | Fixed hero/sheet heights and phone-oriented anchor/card composition | Scroll-safe onboarding, adaptive sheets/max widths and centred coach card landed; anchor-specific coach marks do not currently exist | Complete 2026-07-30 |
| `Views/NativeVideoPlayerView.swift` | Orientation-request model | Fill any window without player recreation; R3 rework remains separate | Audited; implementation not started |
| Settings / Downloads / Support / lists | Native lists/forms compress well but stretch without a readable maximum | Shared max-width pattern landed on custom scrolling pages; native Form/List wide-window styling awaits iPad enablement and matrix verification | Partially complete 2026-07-30 |
| `Views/EpisodeShareCardView.swift` | Fixed 176 pt render | None — fixed export artifact by design | N/A |

---

## 6. Documentation & QA obligations

- `DESIGN.md`: new `AdaptiveLayout-Bands` pattern + any per-view reflow
  patterns worth naming; `FEATURES.md` on each ship gate; AI CONTEXT headers
  on every touched view (note its band behaviour in the header).
- QA artifacts: `Docs/RESIZABILITY_AUDIT_<date>.md` (Phase 0),
  `Docs/RESIZABILITY_QA_PHASE<N>.md` screenshot matrices (R9 sizes ×
  key screens), CarPlay/watch untouched-confirmation note per phase.
- Headless smoke tests: band-classification function (width → band) table
  test; grid-column helper per band; nothing view-rendering (can't run
  headless).
