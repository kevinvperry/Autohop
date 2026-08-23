import AVFoundation
import AVKit
import SwiftUI
import UIKit

// AI CONTEXT — Views/PlayerView.swift ("Player" page). Full-screen now-playing
// UI, permanently mounted as the NavigationStack root (see RootView). Three
// horizontally swipeable panels: Now Playing (artwork/scrubber/transport),
// Details (description), Chapters (only when the episode has chapters).
// Also hosts the shared HTMLDescriptionText component (used here + episode
// detail + podcast settings). CRASH FIX July 2026: it must NEVER call the
// WebKit-backed NSAttributedString HTML importer inside `body`/layout — that
// intermittently crashed the app (~50% of taps opening EpisodeDetailView).
// The parse now runs in `.task` (a plain main-actor turn) with an NSCache;
// keep it that way. A regex-only plain-text fallback renders until it lands.
// PERF-1: the scrubber's 2 Hz time comes from the @EnvironmentObject
// PlaybackClock (playbackClock.time), NOT appState.currentPlayerTime — reading
// the AppState proxy in body would not re-render on ticks (AppState no longer
// publishes them). Event handlers (skip buttons) may read the AppState proxy.
// STAGE 13 OBSERVATION: episode/playing state, queue projection, and
// subscription metadata are observed from PlaybackCoordinator,
// The Details panel ends with the iOS-family Review in Apple Podcasts action,
// immediately below its metadata-card grid. It resolves the current episode's
// subscription by exact RSS identity through ApplePodcastsReviewButton.
// QueueCoordinator, and SubscriptionStore. AppState remains only for
// cross-domain player commands and compatibility state not yet assigned to a
// dedicated observable owner.
// FULLSCREEN VIDEO STATE (2026-08-13): capture the AVPlayer's live effective
// rate and play/pause state before presenting the full-screen cover, then
// restore both after AVKit attaches. AVKit may call plain play() while appearing,
// so defaultRate must be aligned too. This transition is layout-independent and
// must remain valid on iPhone, iPad, Mac-compatible and future folding widths.
// MAC MODAL SAFETY (2026-08-23): AudioControlsSheetView receives every model
// through its initializer. Do not restore implicit @EnvironmentObject lookup in
// that sheet: the iOS-on-Mac presentation host can form a separate modal
// subtree, and a missing inherited object terminates the process immediately.
// RESTORED-SCRUBBER FIX (2026-07-12): sliderValue is drag-local @State and
// therefore starts at zero even when AppState restores PlaybackClock before this
// permanently-mounted view appears. onAppear and current-episode changes call
// synchronizeSliderWithPlaybackClock(), while the existing clock observer keeps
// subsequent ticks aligned. Synchronization is visual only: it MUST NOT call
// appState.seek, start playback, or overwrite an active user drag.
// SCRUB-END RECOVERY (2026-07-17): some system Slider gesture cancellations do
// not deliver `onEditingChanged(false)`. Track the last thumb movement and, once
// playback ticks show the drag has been idle for five seconds, commit it exactly
// once. This prevents isSeeking from pinning the scrubber/timers indefinitely
// while audio continues.
// Top bar (NavRules): quiet list.bullet circle (left) pushes Subscriptions —
// the only nav exit; next to it a Sleep Schedule indicator pill (bed.double
// + minutes until the next "still listening?" prompt, icon-only when not
// counting) appears only while in-window and pushes AppRoute.sleepSchedule;
// icon pills switch panels (selected pill
// expands to icon + label); Up Next button (right, playerActionIcon tint style,
// icon + count, accessibilityLabel "Up Next, N episodes") opens the Up Next
// sheet (QueueSheetView) and momentarily flashes the subscription artwork of
// any episode newly added to the queue (2.5 s, gated on isPlayerVisible).
// Hosts the sheets: AudioControlsSheetView (speed/trim/boost), Sleep Timer,
// Up Next (QueueSheetView), Episode Share, archive confirmation, Podcast
// Settings (SubscriptionSettingsView), and Podcast Detail (PodcastDetailView).
// The latter two are opened from the Up Next row's expanded buttons
// (list.bullet → Detail, gearshape → Settings) using the staged-ID
// "replace the queue" pattern: the subscriptionID is stored in
// queueRequestedDetailID / queueRequestedSettingsID, the Up Next sheet is
// dismissed, and the target sheet is presented in showQueue's onDismiss so
// UIKit never sees two simultaneous sheet transitions. Video
// episodes embed the AVPlayer-backed
// NativeVideoPlayerView with full-screen + PiP and landscape unlock via
// VideoOrientationController. Scrubber uses local sliderValue + isSeeking so
// engine ticks don't fight the user's drag. Also manages the
// keep-screen-awake idle timer via appState.updateIdleTimer(playerVisible:).
// Artwork priority in the Now Playing panel: episode-specific artworkURL first
// (RSS <itunes:image> on the item), falling back to the subscription's artwork
// when the episode URL is absent OR the episode image fails validation/loading.
// Do NOT revert this order — episode art takes precedence by design.
// Queue flashes and queue rows use subscription artwork only (no episode art).
// BACKGROUND VIDEO: a scenePhase observer increments pictureInPictureStartToken
// when the scene becomes .inactive during inline video playback. This triggers
// VideoPictureInPictureHost → startPictureInPicture() so AVPlayer doesn't pause.
// See NativeVideoPlayerView.swift AI CONTEXT for the complementary fix (Option B).
// All artwork goes through CachedArtworkImage with explicit target sizes;
// HTML description images intentionally remain AsyncImage because they are feed
// content, not canonical podcast/episode artwork.
// FIRST-RUN: when there's nothing to play (isPlayerEmpty) the panels are replaced
// by emptyPlayerView — a "Find shows"→Discover state for a user with no real
// subscriptions, or a reassuring "downloading your first episode" state otherwise.
// onAppear requests the playerPanels + speed coach marks (CoachMark.swift) once an
// episode is loaded.

// MARK: - Root player

/// Identifiable wrapper so Up Next sheet shortcuts can drive `.sheet(item:)` —
/// a bare `UUID` is not Identifiable.
private struct PodcastSettingsRoute: Identifiable {
    let id: UUID
}
private struct PodcastDetailRoute: Identifiable {
    let id: UUID
}

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var playbackCoordinator: PlaybackCoordinator
    @EnvironmentObject private var queueCoordinator: QueueCoordinator
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var sleepTimerService: SleepTimerService
    @EnvironmentObject private var sleepScheduleService: SleepScheduleService
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator
    /// 2 Hz playback tick (PERF-1): the scrubber observes this dedicated clock so
    /// AppState no longer publishes on every 0.5 s time update.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    @State private var selectedPanel = 0
    @State private var showMenu = false
    @State private var showQueue = false
    // Staged by Up Next sheet shortcuts, consumed on Up Next dismissal to open
    // the target page in the sheet's place ("replace Up Next").
    @State private var queueRequestedSettingsID: UUID?
    @State private var podcastSettingsRoute: PodcastSettingsRoute?
    @State private var queueRequestedDetailID: UUID?
    @State private var podcastDetailRoute: PodcastDetailRoute?
    @State private var sliderValue: Double = 0
    @State private var isSeeking = false
    @State private var lastSeekInteractionAt = Date.distantPast
    @State private var showAudioControlMenu = false
    @State private var showSleepTimer = false
    @State private var showArchiveConfirmation = false
    @State private var showShareSheet = false
    @State private var showFullScreenVideo = false
    @State private var fullScreenVideoRate: Float = 1
    @State private var fullScreenVideoWasPlaying = false
    @State private var pictureInPictureStartToken = 0
    @State private var isPlayerVisible = false
    @State private var audioRouteName = PlayerView.currentAudioRouteName()
    @State private var queueFlashArtworkURL: URL?
    @State private var queueFlashTask: Task<Void, Never>?

    private var episode: Episode? { playbackCoordinator.currentEpisode }
    private var isVideoEpisode: Bool { episode?.mediaKind == .video && playbackCoordinator.videoPlayer != nil }
    private var shouldAttachVideoSurfaces: Bool { scenePhase != .background }

    /// True when there is genuinely nothing to play — no loaded episode and an
    /// empty downloaded queue. Matches the transport controls' own disabled
    /// condition so the first-run empty state and the controls agree.
    private var isPlayerEmpty: Bool {
        playbackCoordinator.currentEpisode == nil && queueCoordinator.nextPlayableEpisode == nil
    }
    private var visiblePanels: [PlayerPanel] {
        playbackCoordinator.supportsChapters ? PlayerPanel.allCases : [.nowPlaying, .details]
    }

    // Show queue[1] when queue[0] is already playing (avoids duplication), otherwise show queue[0].
    private var playerPageUpNext: Episode? {
        let queue = queueCoordinator.episodes
        guard !queue.isEmpty else { return nil }
        if let current = playbackCoordinator.currentEpisode, queue.first?.id == current.id {
            return queue.count > 1 ? queue[1] : nil
        }
        return queue.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isPlayerEmpty {
                emptyPlayerView
            } else {
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    TabView(selection: $selectedPanel) {
                        nowPlayingPanel.tag(PlayerPanel.nowPlaying.rawValue)
                        detailsPanel.tag(PlayerPanel.details.rawValue)
                        if playbackCoordinator.supportsChapters {
                            chaptersPanel.tag(PlayerPanel.chapters.rawValue)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }

            // Sleep Schedule "still listening?" prompt — mostly answered from
            // the lock screen, but shown here for the screen-on (video) case.
            if sleepScheduleService.isPrompting {
                sleepSchedulePromptOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: playbackClock.time) { _, time in
            if isSeeking,
               Date().timeIntervalSince(lastSeekInteractionAt) >= 5 {
                finishScrubbing()
            } else if !isSeeking {
                sliderValue = clampedSliderTime(time)
            }
        }
        .onChange(of: episode?.id) { _, _ in
            // An episode boundary cancels any stale drag. Never carry the old
            // episode's thumb position into the new episode and seek it later.
            isSeeking = false
            lastSeekInteractionAt = .distantPast
            synchronizeSliderWithPlaybackClock()
        }
        .onAppear {
            isPlayerVisible = true
            synchronizeSliderWithPlaybackClock()
            appState.updateIdleTimer(playerVisible: true)
            // Coach marks: introduce the player's panels, then (later session)
            // the speed controls. Only when there's actually an episode loaded.
            if playbackCoordinator.currentEpisode != nil {
                onboardingCoordinator.requestTip(.playerPanels)
                onboardingCoordinator.requestTip(.speed)
            }
        }
        .onDisappear {
            isSeeking = false
            isPlayerVisible = false
            appState.updateIdleTimer(playerVisible: false)
        }
        .onChange(of: playbackCoordinator.isPlaying) { _, _ in
            appState.updateIdleTimer(playerVisible: isPlayerVisible)
        }
        .onChange(of: settingsViewModel.appSettings.keepScreenAwakeDuringPlayback) { _, _ in
            appState.updateIdleTimer(playerVisible: isPlayerVisible)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            audioRouteName = Self.currentAudioRouteName()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autohopOpenUpNext)) { _ in
            showQueue = true
        }
        .onChange(of: scenePhase) { _, phase in
            // When the scene becomes inactive (home button, lock screen, app switch)
            // during inline video playback, kick off PiP via VideoPictureInPictureHost
            // so iOS doesn't pause the AVPlayer. Full-screen video has its own PiP
            // path through AVPlayerViewController, so skip that case.
            if phase == .inactive, isVideoEpisode, !showFullScreenVideo {
                pictureInPictureStartToken += 1
            }
        }
        .onChange(of: playbackCoordinator.supportsChapters) { _, supportsChapters in
            if !supportsChapters && selectedPanel == PlayerPanel.chapters.rawValue {
                selectedPanel = PlayerPanel.nowPlaying.rawValue
            }
        }
        .adaptiveNavigationPresentation(isPresented: $showMenu) {
            MenuSheetView()
        }
        .adaptiveNavigationPresentation(isPresented: $showQueue, onDismiss: {
            // "Replace Up Next": open the target page only after the Up Next sheet
            // has fully dismissed — presenting during dismissal is dropped by UIKit.
            if let id = queueRequestedSettingsID {
                queueRequestedSettingsID = nil
                podcastSettingsRoute = PodcastSettingsRoute(id: id)
            } else if let id = queueRequestedDetailID {
                queueRequestedDetailID = nil
                podcastDetailRoute = PodcastDetailRoute(id: id)
            }
        }) {
            QueueSheetView(
                onOpenPodcastSettings: { subscriptionID in
                    queueRequestedSettingsID = subscriptionID
                    showQueue = false
                },
                onOpenPodcastDetail: { subscriptionID in
                    queueRequestedDetailID = subscriptionID
                    showQueue = false
                }
            )
        }
        .adaptiveNavigationPresentation(item: $podcastSettingsRoute) { route in
            NavigationStack {
                SubscriptionSettingsView(subscriptionID: route.id)
            }
            .environmentObject(appState)
        }
        .adaptiveNavigationPresentation(item: $podcastDetailRoute) { route in
            NavigationStack {
                PodcastDetailView(subscriptionID: route.id)
            }
            .environmentObject(appState)
        }
        .background {
            if isVideoEpisode, let videoPlayer = playbackCoordinator.videoPlayer {
                VideoPictureInPictureHost(
                    player: videoPlayer,
                    startToken: pictureInPictureStartToken,
                    attached: shouldAttachVideoSurfaces
                )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
        }
        .fullScreenCover(isPresented: $showFullScreenVideo) {
            if let videoPlayer = playbackCoordinator.videoPlayer {
                ZStack(alignment: .topLeading) {
                    NativeVideoPlayerView(player: videoPlayer, attached: shouldAttachVideoSurfaces)
                        .ignoresSafeArea()

                    Button {
                        showFullScreenVideo = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel("Close full screen")
                    .padding(.top, 18)
                    .padding(.leading, 18)
                }
                .background(Color.black.ignoresSafeArea())
                .onAppear {
                    restoreFullScreenPlaybackState(on: videoPlayer)
                }
                .onDisappear {
                    VideoOrientationController.restorePortrait()
                }
            }
        }
        .sheet(isPresented: $showAudioControlMenu) {
            AudioControlsSheetView(
                appState: appState,
                playbackCoordinator: playbackCoordinator,
                subscriptionStore: subscriptionStore,
                settingsViewModel: settingsViewModel
            )
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerSheetView(sleepTimer: sleepTimerService)
        }
        .sheet(isPresented: $showArchiveConfirmation) {
            ArchiveConfirmationSheet {
                if let episode {
                    Task { await appState.archiveEpisodeAndPlayNext(episode) }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let ep = episode {
                let sub = subscriptionStore.subscription(id: ep.subscriptionID)
                EpisodeShareSheet(episode: ep, subscription: sub)
            }
        }
    }

    // MARK: - Sleep Schedule prompt overlay

    private var sleepSchedulePromptOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.purple)

                Text("Are you still listening?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Text("Playback fades out soon unless you respond.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.6))

                // Deliberately huge tap target — easy to hit half-asleep
                // without aiming. Fills the width and stands well off the
                // bottom edge.
                Button {
                    // Confirm without toggling — playback is still going.
                    sleepScheduleService.userResponded()
                } label: {
                    Text("Still Listening")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 160)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .contentShape(RoundedRectangle(cornerRadius: 28))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .transition(.opacity)
    }

    // MARK: - Top bar

    private var topBar: some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: viewportWidth)
        return HStack(spacing: 0) {
            // Quiet icon circle — the player's only navigation exit, the
            // visual twin of the MiniPlayerBar that brings you back.
            NavigationLink(value: AppRoute.podcasts) {
                let icon = Image(systemName: "list.bullet")
                    .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: metrics.navigationControlSize, height: metrics.navigationControlSize)

                if #available(iOS 26, *) {
                    icon.glassEffect(in: Circle())
                } else {
                    icon.background(Color(white: 0.12))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(white: 0.18), lineWidth: 0.5))
                }
            }
            .accessibilityLabel("Subscriptions")

            // Sleep Schedule indicator — appears only while inside the nightly
            // active-hours window. Shows a bed icon + minutes remaining until
            // the window closes; taps push the Sleep Schedule settings page.
            // Matches the playerActionIcon purple tint pill (cf. Queue button).
            sleepScheduleIndicator

            Spacer()

            // Icon pills — the selected panel expands to icon + label so the
            // row stays uncluttered but never cryptic.
            HStack(spacing: 2) {
                ForEach(visiblePanels) { panel in
                    let isSelected = selectedPanel == panel.rawValue
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { selectedPanel = panel.rawValue }
                    } label: {
                        let tab = HStack(spacing: 5) {
                            Image(systemName: panel.icon)
                                .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
                            if isSelected {
                                ViewThatFits(in: .horizontal) {
                                    Text(panel.title)
                                        .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
                                        .lineLimit(1)
                                    EmptyView()
                                }
                                .transition(.opacity)
                            }
                        }
                        .foregroundStyle(isSelected ? .white : Color(white: 0.4))
                        .padding(.horizontal, isSelected ? metrics.scaled(12) : metrics.scaled(9))
                        .frame(height: metrics.navigationControlSize)

                        // Selected tab sits on neutral glass; unselected stays bare
                        // so the strip reads quiet.
                        if #available(iOS 26, *) {
                            if isSelected {
                                tab.glassEffect(in: Capsule())
                            } else {
                                tab
                            }
                        } else {
                            tab
                                .background(isSelected ? Color(white: 0.15) : .clear)
                                .clipShape(Capsule())
                        }
                    }
                    .accessibilityLabel(panel.title)
                }
            }

            Spacer()

            // Matches the audio-row action buttons (playerActionIcon tint
            // style) so the top bar stays calm. When an episode joins the
            // queue, the button momentarily flashes that episode's
            // subscription artwork.
            Button { showQueue = true } label: {
                ZStack {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack")
                            .font(.system(size: metrics.navigationControlFontSize, weight: .bold))
                            .foregroundStyle(Color.purple.opacity(0.85))
                        Text("\(queueCoordinator.episodes.count)")
                            .font(.system(size: metrics.navigationControlFontSize * 0.8, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.purple.opacity(0.85))
                    }
                    .opacity(queueFlashArtworkURL == nil ? 1 : 0)

                    if let url = queueFlashArtworkURL {
                        CachedArtworkImage(url: url, targetSize: CGSize(width: metrics.navigationControlSize, height: metrics.navigationControlSize)) {
                            Rectangle().fill(Color(white: 0.2))
                        }
                        .frame(width: metrics.navigationControlSize, height: metrics.navigationControlSize)
                        .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(8)))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, metrics.scaled(12))
                .frame(height: metrics.navigationControlSize)
                .playerGlassPill()
            }
            .accessibilityLabel("Up Next, \(queueCoordinator.episodes.count) episodes")
        }
        .onChange(of: queueCoordinator.episodes.map(\.id)) { oldIDs, newIDs in
            // Flash the artwork of an episode newly added to the queue.
            // oldIDs is the pre-change list, so cold-start population (old
            // empty before the queue first loads) still flashes only on
            // genuine additions after the player is visible.
            guard isPlayerVisible else { return }
            let added = Set(newIDs).subtracting(oldIDs)
            guard let newID = added.first,
                  let episode = queueCoordinator.episodes.first(where: { $0.id == newID }),
                  let artworkURL = subscriptionStore.subscription(id: episode.subscriptionID)?.artworkURL
            else { return }

            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                queueFlashArtworkURL = artworkURL
            }
            queueFlashTask?.cancel()
            queueFlashTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    queueFlashArtworkURL = nil
                }
            }
        }
    }

    // MARK: - Sleep Schedule indicator

    /// Top-bar pill shown only while inside the Sleep Schedule active-hours
    /// window. The digit counts down the minutes until the next "still
    /// listening?" prompt (the countdown phase); when not counting (paused,
    /// idle, or End-of-Episode mode) the icon shows alone. TimelineView
    /// re-evaluates every 30 s so the pill appears/disappears at the window
    /// edges; the @Published phase keeps the digit live while counting.
    @ViewBuilder
    private var sleepScheduleIndicator: some View {
        let metrics = AdaptiveEditorialMetrics(containerWidth: viewportWidth)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if sleepScheduleService.isActive(context.date) {
                let minutes = sleepScheduleService.minutesUntilPrompt
                NavigationLink(value: AppRoute.sleepSchedule) {
                    HStack(spacing: 5) {
                        Image(systemName: "bed.double.fill")
                            .font(.system(size: metrics.navigationControlFontSize, weight: .bold))
                        if let minutes {
                            Text("\(minutes)")
                                .font(.system(size: metrics.navigationControlFontSize * 0.8, weight: .bold))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(Color.purple.opacity(0.85))
                    .padding(.horizontal, metrics.scaled(12))
                    .frame(height: metrics.navigationControlSize)
                    .playerGlassPill()
                }
                .padding(.leading, 8)
                .accessibilityLabel(minutes.map { "Sleep Schedule active, \($0) minutes until prompt" } ?? "Sleep Schedule active")
            }
        }
    }

    // MARK: - Now Playing panel (non-scrolling, fits device screen)

    /// Sum of vertical space consumed by every non-artwork element.
    /// Called from inside a @ViewBuilder closure, so mutations must live here.
    private func nowPlayingReservedHeight(hasChapters: Bool, hasUpNext: Bool) -> CGFloat {
        var h: CGFloat = 20          // artwork padding: top 11 + bottom 9
        if hasChapters { h += 52 }   // chapter strip content (~44pt) + bottom padding 8
        h += 71                       // episode copy (~59pt) + bottom padding 12
        h += 48                       // scrubber (~44pt) + bottom padding 4
        h += 98                       // controls (76pt button + 16pt internal + 6pt bottom)
        h += 56                       // audio row (~48pt) + bottom padding 8
        if hasUpNext { h += 94 }     // up next row (~64pt) + bottom padding 30
        return h
    }

    // MARK: - Empty / first-run state

    /// Shown in place of the player when there is nothing to play. Two variants:
    /// a brand-new user with no subscriptions is pointed at Discover; a user who
    /// has subscribed but whose first episode hasn't downloaded yet sees a
    /// reassuring "downloading" state. See ONBOARDING_PLAN.md Phase 1a.
    private var emptyPlayerView: some View {
        let hasSubscriptions = onboardingCoordinator.realSubscriptionCount > 0
        let metrics = AdaptiveEditorialMetrics(containerWidth: viewportWidth)

        return VStack(spacing: 0) {
            // Keep a quiet exit so the player is never a dead end.
            HStack {
                NavigationLink(value: AppRoute.podcasts) {
                    let icon = Image(systemName: "list.bullet")
                        .font(.system(size: metrics.navigationControlFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: metrics.navigationControlSize, height: metrics.navigationControlSize)
                    if #available(iOS 26, *) {
                        icon.glassEffect(in: Circle())
                    } else {
                        icon.background(Color(white: 0.12))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(white: 0.18), lineWidth: 0.5))
                    }
                }
                .accessibilityLabel("Subscriptions")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.16))
                        .frame(width: 104, height: 104)
                    if hasSubscriptions {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.purple)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                }

                VStack(spacing: 8) {
                    Text(hasSubscriptions ? "Getting your first episode" : "Nothing playing yet")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(hasSubscriptions
                         ? "Autohop is downloading the latest episode so it plays instantly and works offline. This only takes a moment."
                         : "Subscribe to a show and Autohop fills Up Next automatically. Your latest episodes land here, ready to play.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(white: 0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 36)

                if hasSubscriptions {
                    NavigationLink(value: AppRoute.podcasts) {
                        emptyStateButtonLabel("View subscriptions", filled: true)
                    }
                } else {
                    NavigationLink(value: AppRoute.discover) {
                        emptyStateButtonLabel("Find shows", filled: true)
                    }
                }
            }

            Spacer()
            Spacer()
        }
    }

    private func emptyStateButtonLabel(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(filled ? .white : .purple)
            .padding(.horizontal, 28)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(filled ? Color.purple : Color.purple.opacity(0.14))
            )
    }

    private var nowPlayingPanel: some View {
        GeometryReader { geo in
            let hasChapters = !playbackCoordinator.activeChapters.isEmpty
            let upNext = playerPageUpNext

            let reserved      = nowPlayingReservedHeight(hasChapters: hasChapters, hasUpNext: upNext != nil)
            let maxFromWidth  = geo.size.width - 44   // 22pt padding each side
            let maxFromHeight = geo.size.height - reserved
            let artworkSize   = max(80, min(maxFromWidth, maxFromHeight))
            let cornerRadius: CGFloat = hasChapters ? 18 : 20
            let isVideo = episode?.mediaKind == .video && playbackCoordinator.videoPlayer != nil
            let videoWidth = geo.size.width - 44
            let videoHeight = videoWidth * (9.0 / 16.0)

            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    if isVideo {
                        let vPad = max(0, (artworkSize - videoHeight) / 2)
                        artworkZStack(size: videoWidth, height: videoHeight, cornerRadius: cornerRadius)
                            .padding(.vertical, vPad)
                    } else {
                        artworkZStack(size: artworkSize, cornerRadius: cornerRadius)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 11)
                .padding(.bottom, 9)

                if hasChapters {
                    chapterStripView
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)
                }

                episodeCopyView
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

                scrubberView
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)

                controlsView
                    .padding(.horizontal, 22)
                    .padding(.bottom, 6)

                audioRowView
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                if let up = upNext {
                    upNextView(up)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 30)
                }
            }
            .environment(\.adaptiveViewportWidth, geo.size.width)
        }
    }

    // MARK: - Artwork

    private var artworkURL: URL? {
        episode?.artworkURL ?? channelArtworkURL
    }

    private var channelArtworkURL: URL? {
        episode.flatMap { subscriptionStore.subscription(id: $0.subscriptionID)?.artworkURL }
    }

    private func artworkZStack(size: CGFloat, height: CGFloat? = nil, cornerRadius: CGFloat) -> some View {
        let h = height ?? size
        return ZStack {
            RadialGradient(
                colors: [Color.purple.opacity(0.34), .clear],
                center: .init(x: 0.5, y: 0.66),
                startRadius: 0,
                endRadius: size * 0.54
            )

            Group {
                if episode?.mediaKind == .video,
                   let videoPlayer = playbackCoordinator.videoPlayer,
                   shouldAttachVideoSurfaces {
                    ZStack(alignment: .bottomTrailing) {
                        VideoPlayer(player: videoPlayer)
                            .background(Color.black)
                        videoOverlayControls
                            .padding(12)
                    }
                } else {
                    CachedArtworkImage(
                        url: artworkURL,
                        fallbackURL: channelArtworkURL,
                        targetSize: CGSize(width: size, height: h)
                    ) {
                        Rectangle()
                            .fill(Color(white: 0.07))
                            .overlay(
                                Image(systemName: "waveform")
                                    .font(.system(size: 52, weight: .semibold))
                                    .foregroundStyle(Color.purple.opacity(0.5))
                            )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        .frame(width: size, height: h)
    }

    private var videoOverlayControls: some View {
        HStack(spacing: 8) {
            Button {
                pictureInPictureStartToken += 1
            } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 34)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Mini Player")

            Button {
                // Unlock supported orientations before SwiftUI begins the cover
                // presentation. Forcing a geometry change from the presented
                // view's onAppear can race UIKit and crash immediately.
                VideoOrientationController.allowVideoOrientations()
                if let player = playbackCoordinator.videoPlayer {
                    fullScreenVideoWasPlaying = player.rate > 0
                    fullScreenVideoRate = validVideoRate(
                        player.rate > 0 ? player.rate : player.defaultRate
                    )
                    player.defaultRate = fullScreenVideoRate
                }
                showFullScreenVideo = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 34)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Full Screen Video")
        }
    }

    private func restoreFullScreenPlaybackState(on player: AVPlayer) {
        let rate = validVideoRate(fullScreenVideoRate)
        player.defaultRate = rate
        guard fullScreenVideoWasPlaying else {
            player.pause()
            return
        }

        // AVPlayerViewController may issue its own plain play() while becoming
        // visible. Reapply after the presentation transaction so its final
        // state retains the podcast's effective speed (including overrides).
        Task { @MainActor in
            await Task.yield()
            player.defaultRate = rate
            player.playImmediately(atRate: rate)
        }
    }

    private func validVideoRate(_ rate: Float) -> Float {
        rate.isFinite && rate > 0 ? rate : 1
    }

    // MARK: - Chapter strip

    private var chapterStripView: some View {
        let active = playbackCoordinator.activeChapters
        let current = playbackCoordinator.currentChapter
        let activeIdx = active.firstIndex(where: { $0.position == current?.position })
        let previousTarget = playbackCoordinator.previousChapterTarget
        let nextTarget = playbackCoordinator.nextChapterTarget

        return HStack(spacing: 8) {
            Button { appState.navigateToPreviousChapter() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
            }
            .frame(width: 28, height: 28)
            .background(Color(white: 0.12))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(white: 0.18), lineWidth: 0.5))
            .disabled(previousTarget == nil)

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { selectedPanel = 2 }
            } label: {
                VStack(spacing: 2) {
                    Text(current?.title ?? active.first?.title ?? "")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(activeIdx.map { "Chapter \($0 + 1) of \(active.count)" } ?? "Moving past skipped chapter")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.33))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button { appState.navigateToNextChapter() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
            }
            .frame(width: 28, height: 28)
            .background(Color(white: 0.12))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(white: 0.18), lineWidth: 0.5))
            .disabled(nextTarget == nil)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Episode copy

    private var episodeCopyView: some View {
        VStack(alignment: .center, spacing: 3) {
            if let ep = episode {
                Text(ep.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                if let sub = subscriptionStore.subscription(id: ep.subscriptionID) {
                    NavigationLink {
                        PodcastDetailView(subscriptionID: sub.id)
                    } label: {
                        Text(sub.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.55))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No Episode")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(white: 0.3))
                    .frame(maxWidth: .infinity)

                Text(queueCoordinator.nextPlayableEpisode != nil ? "Tap play to start" : "Add a feed and download an episode")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.33))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Scrubber

    /// Copies the canonical restored/ticking clock into the Slider's drag-local
    /// state without producing a seek side effect. SwiftUI's onChange does not
    /// fire for a value already present when this view appears, so this explicit
    /// initial synchronization is required for a paused restored episode.
    private func synchronizeSliderWithPlaybackClock() {
        guard !isSeeking else { return }
        sliderValue = clampedSliderTime(playbackClock.time)
    }

    private func clampedSliderTime(_ time: TimeInterval) -> TimeInterval {
        let upperBound = max(1, episode?.durationSeconds ?? 0)
        return min(max(0, time), upperBound)
    }

    private var scrubberView: some View {
        let total = max(1, episode?.durationSeconds ?? 0)
        let rawDisplayTime = isSeeking ? sliderValue : playbackClock.time
        let displayTime = min(max(0, rawDisplayTime), total)
        let remainingTime = max(0, total - displayTime)

        return VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { sliderValue },
                    set: { value in
                        sliderValue = value
                        lastSeekInteractionAt = Date()
                    }
                ),
                in: 0...total,
                onEditingChanged: { editing in
                    if editing {
                        isSeeking = true
                        lastSeekInteractionAt = Date()
                    } else {
                        finishScrubbing()
                    }
                }
            )
            .tint(.purple)
            .disabled(episode == nil)

            HStack {
                Text(formatTime(displayTime))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.42))
                Spacer()
                Text("-\(formatTime(remainingTime))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.55))
            }
        }
    }

    /// Ends either the normal Slider gesture or the defensive idle recovery.
    /// Clearing `isSeeking` before invoking AppState lets the next clock publish
    /// immediately resume normal scrubber/timer progression.
    private func finishScrubbing() {
        guard isSeeking else { return }
        let total = max(1, episode?.durationSeconds ?? 0)
        let target = min(max(0, sliderValue), total)
        isSeeking = false
        sliderValue = target
        appState.seek(to: target)
    }

    // MARK: - Controls

    private var controlsView: some View {
        HStack(alignment: .center) {
            Button {
                let skip = settingsViewModel.appSettings.skipBackSeconds
                let target = max(0, appState.currentPlayerTime - skip)
                sliderValue = target
                appState.seek(to: target)
            } label: {
                SkipIntervalIcon(direction: .backward, seconds: settingsViewModel.appSettings.skipBackSeconds)
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await appState.togglePlayPause() }
            } label: {
                let playIcon = Image(systemName: playbackCoordinator.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)

                if #available(iOS 26, *) {
                    playIcon
                        .glassEffect(.regular.tint(.purple), in: Circle())
                        .shadow(color: Color.purple.opacity(0.35), radius: 14)
                } else {
                    playIcon
                        .background(Color.purple)
                        .clipShape(Circle())
                        .shadow(color: Color.purple.opacity(0.35), radius: 14)
                }
            }
            .disabled(playbackCoordinator.currentEpisode == nil && queueCoordinator.nextPlayableEpisode == nil)
            .accessibilityLabel(playbackCoordinator.isPlaying ? "Pause" : "Play")

            Button {
                guard let dur = playbackCoordinator.currentEpisode?.durationSeconds else { return }
                let skip = settingsViewModel.appSettings.skipForwardSeconds
                if appState.currentPlayerTime + skip >= dur {
                    // Overshoot — advance to next episode rather than clamping to the end.
                    // Exclude the current episode so playNextEpisode doesn't restore it.
                    let currentID = playbackCoordinator.currentEpisode?.id
                    Task { await appState.playNextEpisode(excluding: currentID.map { [$0] } ?? []) }
                } else {
                    sliderValue = appState.currentPlayerTime + skip
                    // Routes through skipForward (not seek) so the manual-skip time-saved
                    // stat is credited; the overshoot branch above is an episode advance, not a skip.
                    appState.skipForward(seconds: skip)
                }
            } label: {
                SkipIntervalIcon(direction: .forward, seconds: settingsViewModel.appSettings.skipForwardSeconds)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Audio row

    private var audioRowView: some View {
        HStack(spacing: 10) {
            // Leading cluster: Sound Settings + Sleep Timer
            HStack(spacing: 8) {
                Button {
                    showAudioControlMenu = true
                } label: {
                    // Mirrors the sleep timer button: white while Shared Listening is on.
                    playerActionIcon(
                        "slider.horizontal.3",
                        highlighted: settingsViewModel.appSettings.sharedListeningActive
                    )
                }
                .buttonStyle(.plain)
                .disabled(episode == nil)
                .accessibilityLabel("Audio controls")

                Button {
                    showSleepTimer = true
                } label: {
                    sleepTimerButtonLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sleep timer")
            }
            .frame(width: 96, alignment: .leading)

            audioSourceButton
                .frame(maxWidth: .infinity, alignment: .center)

            // Trailing cluster: Share + Archive
            HStack(spacing: 8) {
                Button {
                    showShareSheet = true
                } label: {
                    playerActionIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(episode == nil)
                .accessibilityLabel("Share episode")

                Button {
                    showArchiveConfirmation = true
                } label: {
                    playerActionIcon("archivebox")
                }
                .buttonStyle(.plain)
                .disabled(episode == nil)
                .accessibilityLabel("Archive episode")
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func playerActionIcon(_ systemName: String, highlighted: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(highlighted ? Color.white : Color.purple.opacity(0.85))
            .frame(width: 44, height: 32)
            .playerGlassPill(highlighted: highlighted)
    }

    @ViewBuilder
    private var sleepTimerButtonLabel: some View {
        let timer = sleepTimerService
        ZStack(alignment: .topTrailing) {
            Image(systemName: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(timer.isActive ? Color.white : Color.purple.opacity(0.85))
                .frame(width: 44, height: 32)
                .playerGlassPill(highlighted: timer.isActive)

            // Badge: countdown or episode count
            if timer.isDurationMode, let badge = sleepTimerBadge {
                Text(badge)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.purple)
                    .clipShape(Capsule())
                    .offset(x: 4, y: -4)
            } else if timer.isEpisodeMode {
                Text("\(timer.episodesRemaining)ep")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.purple)
                    .clipShape(Capsule())
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var sleepTimerBadge: String? {
        let remaining = sleepTimerService.timeRemaining
        guard remaining.isFinite, remaining >= 0 else { return nil }
        let total = Int(remaining)
        let m = total / 60
        let s = total % 60
        // Show "m:ss" when < 1 hour, "Xh" otherwise
        if total >= 3600 {
            return "\(total / 3600)h"
        }
        return String(format: "%d:%02d", m, s)
    }

    private var audioSourceButton: some View {
        ZStack {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Image(systemName: "airplayaudio")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.purple.opacity(0.9))

                    Text(audioRouteName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                }
                Image(systemName: "airplayaudio")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.purple.opacity(0.9))
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .allowsHitTesting(false)

            // The system route picker owns the full visible selector target and opens
            // Apple's AirPlay/audio-output sheet. Its UIKit bridge forwards the whole
            // row to the embedded route button rather than accepting only glyph taps.
            AudioRoutePickerView(tintColor: .clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.02)
                .accessibilityLabel("Choose audio output")
                .accessibilityHint("Opens AirPlay and connected audio devices")
        }
        .frame(minWidth: 48, maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    // MARK: - Up Next

    private func upNextView(_ upNext: Episode) -> some View {
        UpNextRow(episode: upNext)
            .environmentObject(appState)
    }

    // MARK: - Details panel

    private var detailsPanel: some View {
        ScrollView {
            if let ep = episode {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ep.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 10)

                    HStack(spacing: 16) {
                        if let date = ep.publishedAt {
                            Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        }
                        if let dur = ep.durationSeconds {
                            Label(formatDurationLong(dur), systemImage: "hourglass")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                    let descriptionImageURL = ep.description.flatMap { HTMLDescriptionText.firstImageURL(from: $0) }
                    if let url = descriptionImageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                Color(white: 0.07)
                                    .aspectRatio(1.6, contentMode: .fit)
                            default:
                                Color(white: 0.07)
                                    .aspectRatio(1.6, contentMode: .fit)
                                    .overlay(ProgressView().tint(.purple))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    } else if let url = detailsArtworkURL(for: ep) {
                        CachedArtworkImage(url: url, targetSize: CGSize(width: 320, height: 320)) {
                            Color(white: 0.07)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    }

                    if let subtitle = ep.subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(white: 0.55))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                    }

                    if let author = ep.author {
                        Text(author)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.33))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }

                    if let desc = ep.description {
                        HTMLDescriptionText(
                            html: desc,
                            fontSize: 14,
                            color: Color(white: 0.78),
                            linkColor: .purple,
                            showsFirstImage: false,
                            sentenceBreaks: true
                        )
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }

                    let sub = subscriptionStore.subscription(id: ep.subscriptionID)
                    // Glass cards inside a GlassEffectContainer so the tiles read
                    // as one cohesive glass surface (matches the Episode Detail grid).
                    Group {
                        if #available(iOS 26, *) {
                            GlassEffectContainer(spacing: 8) {
                                detailsMetaGrid(ep: ep, sub: sub)
                            }
                        } else {
                            detailsMetaGrid(ep: ep, sub: sub)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    if let sub {
                        ApplePodcastsReviewButton(
                            showTitle: sub.title,
                            feedURL: sub.feedURL
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    }
                }
            } else {
                ContentUnavailableView("No Episode Playing", systemImage: "waveform")
                    .padding(.top, 60)
            }
        }
    }

    @ViewBuilder
    private func detailsMetaGrid(ep: Episode, sub: Subscription?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            if let date = ep.publishedAt {
                metaCard("Distributed", relativePublishedDateLabel(date))
                metaCard("Released", relativeReleasedLabel(date))
                metaCard("Published", releasedWeekdayLabel(date))
            }
            if let dur = ep.durationSeconds {
                metaCard("Duration", formatDurationLong(dur))
            }
            if let bytes = ep.fileSizeBytes {
                metaCard("File size", formatFileSize(bytes))
            }
            metaCard("Classification", explicitRatingText(for: ep))
            metaCard("File Status", fileStatusText(for: ep))
            if let rank = sub?.priorityRank {
                metaCard("Priority rank", ordinalString(rank))
            }
            if !ep.chapters.isEmpty {
                metaCard("Chapters", "\(ep.chapters.count)")
            }
        }
    }

    @ViewBuilder
    private func metaCard(_ key: String, _ value: String) -> some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Color(white: 0.33))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        if #available(iOS 26, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
                .background(Color(white: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
        }
    }

    private func detailsArtworkURL(for episode: Episode) -> URL? {
        subscriptionStore.subscription(id: episode.subscriptionID)?.artworkURL
            ?? episode.artworkURL
    }

    private func fileStatusText(for episode: Episode) -> String {
        switch episode.playedState {
        case .archived: return "Archived"
        default: break
        }
        switch episode.downloadState {
        case .downloaded: return "Downloaded"
        default: return "Available"
        }
    }

    private func explicitRatingText(for episode: Episode) -> String {
        episode.isExplicit == true ? "Explicit" : "Clean"
    }

    // MARK: - Chapters panel

    private var chaptersPanel: some View {
        let ep = playbackCoordinator.chapterEpisode
        let sub = ep.flatMap { subscriptionStore.subscription(id: $0.subscriptionID) }
        let chapters = (ep?.chapters ?? []).sorted { $0.position < $1.position }
        let skippedCount = sub?.chapterFilter.skippedPositions.count ?? 0

        return VStack(spacing: 0) {
            HStack {
                Text("\(chapters.count) chapters")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.33))
                if skippedCount > 0 {
                    Text("· \(skippedCount) skipped")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.55))
                }
                Spacer()
                if let sub {
                    HStack(spacing: 14) {
                        Button("All") {
                            appState.applyChapterFilter(ChapterFilter(), subscriptionID: sub.id)
                        }
                        Button("None") {
                            let currentPos = playbackCoordinator.currentChapter?.position
                            let skipped = Set(chapters.lazy.filter { $0.position != currentPos }.map(\.position))
                            appState.applyChapterFilter(ChapterFilter(skippedPositions: skipped), subscriptionID: sub.id)
                        }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.purple.opacity(0.8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if chapters.isEmpty {
                ContentUnavailableView("No Chapters", systemImage: "list.bullet")
                    .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chapters) { chapter in
                            chapterRow(chapter: chapter, subscription: sub)
                        }
                    }
                    .glassCard(cornerRadius: 16)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func chapterRow(chapter: Chapter, subscription: Subscription?) -> some View {
        let isSkipped = subscription?.chapterFilter.skippedPositions.contains(chapter.position) ?? false
        let isCurrentlyPlaying = playbackCoordinator.currentChapter?.position == chapter.position && playbackCoordinator.currentEpisode != nil

        return Button {
            appState.seek(to: chapter.startSeconds)
        } label: {
            HStack(spacing: 11) {
                Button {
                    guard let sub = subscription else { return }
                    appState.toggleChapter(subscriptionID: sub.id, position: chapter.position)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isSkipped ? .clear : Color.purple)
                            .frame(width: 24, height: 24)
                        if !isSkipped {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Circle()
                            .stroke(isSkipped ? Color(white: 0.33) : Color.purple, lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                    }
                }
                .buttonStyle(.plain)

                Text("\(chapter.position)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isCurrentlyPlaying ? Color.purple : Color(white: 0.33))
                    .frame(width: 18, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSkipped ? Color(white: 0.3) : (isCurrentlyPlaying ? Color.purple.opacity(0.85) : .white))
                        .strikethrough(isSkipped, color: Color(white: 0.3))
                        .lineLimit(1)
                    Text(formatTime(chapter.startSeconds))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.22))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrentlyPlaying {
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 6, height: 6)
                }

                if let dur = chapter.durationSeconds {
                    Text(formatDurationShort(dur))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.22))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isCurrentlyPlaying ? Color.purple.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSkipped ? 0.45 : 1)
        .overlay(alignment: .bottom) {
            Divider().background(Color.white.opacity(0.06))
        }
    }

    // MARK: - Formatting helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private static func currentAudioRouteName() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first else { return "iPhone Speaker" }

        if !output.portName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output.portName
        }

        switch output.portType {
        case .builtInSpeaker:
            return "iPhone Speaker"
        case .builtInReceiver:
            return "iPhone"
        case .headphones:
            return "Headphones"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return "Bluetooth Audio"
        case .airPlay:
            return "AirPlay"
        case .carAudio:
            return "Car Audio"
        case .usbAudio:
            return "USB Audio"
        case .HDMI:
            return "HDMI"
        default:
            return "Audio Source"
        }
    }

    private func formatDurationShort(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatDurationLong(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000
            ? String(format: "%.1f GB", mb / 1000)
            : String(format: "%.0f MB", mb)
    }

    private func ordinalString(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    private func speedLabel(_ speed: Double) -> String {
        PlaybackPreference.speedLabel(speed)
    }
}

struct HTMLDescriptionText: View {
    let html: String
    let fontSize: CGFloat
    let color: Color
    let linkColor: Color
    let showsFirstImage: Bool
    /// When true, the space after each sentence-ending full stop becomes a blank
    /// line, so each sentence reads on its own. Used by the Player Details panel.
    let sentenceBreaks: Bool

    init(
        html: String,
        fontSize: CGFloat,
        color: Color,
        linkColor: Color = .purple,
        showsFirstImage: Bool = true,
        sentenceBreaks: Bool = false
    ) {
        self.html = html
        self.fontSize = fontSize
        self.color = color
        self.linkColor = linkColor
        self.showsFirstImage = showsFirstImage
        self.sentenceBreaks = sentenceBreaks
    }

    /// Rich text parsed OFF the layout pass (see `.task` below). nil until the
    /// first parse lands; a regex-only plain-text fallback renders until then.
    ///
    /// CRASH FIX (July 2026): the WebKit-backed HTML importer
    /// (`NSAttributedString` with `.documentType: .html`) was previously invoked
    /// synchronously inside `body`. Apple documents that importer as main-thread
    /// ONLY and NOT callable during layout — running it mid-layout while a
    /// navigation push transition was in flight intermittently threw WebKit/
    /// TextKit internal-inconsistency exceptions, which crashed the app on
    /// roughly half of the taps opening EpisodeDetailView. `.task` runs in a
    /// plain main-actor turn after the view is installed (a supported context),
    /// and results are cached so the same HTML is never parsed twice.
    @State private var attributedText: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsFirstImage, let url = Self.firstImageURL(from: html) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        EmptyView()
                    default:
                        Rectangle()
                            .fill(Color(white: 0.08))
                            .aspectRatio(1.6, contentMode: .fit)
                            .overlay(ProgressView().tint(.purple))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }

            if let attributedText {
                styledText(Text(attributedText))
            } else {
                // Interim fallback while the WebKit parse is pending — pure
                // regex, safe to build during layout. Replaced by the rich
                // version one main-actor turn later (usually imperceptible).
                let fallback = Self.plainText(from: html)
                if !fallback.isEmpty {
                    styledText(Text(fallback))
                }
            }
        }
        .task(id: html) {
            attributedText = Self.cachedAttributedText(
                from: html, fontSize: fontSize, sentenceBreaks: sentenceBreaks
            )
        }
    }

    private func styledText(_ text: Text) -> some View {
        text
            .font(.system(size: fontSize))
            .lineSpacing(5)
            .foregroundStyle(color)
            .tint(linkColor)
            .textSelection(.enabled)
    }

    /// Memoizes parsed HTML across view instances (reopening an episode page or
    /// re-rendering the Player Details panel must not re-run the importer).
    private final class ParsedHTML {
        let text: AttributedString?
        init(_ text: AttributedString?) { self.text = text }
    }

    private static let parseCache: NSCache<NSString, ParsedHTML> = {
        let cache = NSCache<NSString, ParsedHTML>()
        cache.countLimit = 64
        return cache
    }()

    private static func cachedAttributedText(from html: String, fontSize: CGFloat, sentenceBreaks: Bool) -> AttributedString? {
        let key = "\(Int(fontSize))|\(sentenceBreaks)|\(html)" as NSString
        if let hit = parseCache.object(forKey: key) { return hit.text }
        let parsed = attributedText(from: html, fontSize: fontSize, sentenceBreaks: sentenceBreaks)
        parseCache.setObject(ParsedHTML(parsed), forKey: key)
        return parsed
    }

    static func firstImageURL(from html: String) -> URL? {
        imageURLs(from: html).first
    }

    private static func htmlForTextDisplay(_ html: String) -> String {
        html
            .replacingOccurrences(
                of: #"(?is)<img\b[^>]*>"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)<br\s*/?>"#,
                with: "<br/>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)</p\s*>"#,
                with: "</p>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)<p\b[^>]*>"#,
                with: "<p>",
                options: .regularExpression
            )
            // Convert list items to paragraphs so each item gets proper inter-paragraph
            // spacing. NSAttributedString's HTML renderer packs <li> items tightly.
            .replacingOccurrences(
                of: #"(?is)<li\b[^>]*>"#,
                with: "<p>• ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)</li\s*>"#,
                with: "</p>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?is)</?[uo]l\b[^>]*>"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func imageURLs(from html: String) -> [URL] {
        let pattern = #"(?is)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var urls: [URL] = []
        for match in regex.matches(in: html, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let raw = decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else { continue }
            if !urls.contains(url) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func attributedText(from html: String, fontSize: CGFloat = 15, sentenceBreaks: Bool = false) -> AttributedString? {
        let html = htmlForTextDisplay(html)
        guard let data = html.data(using: .utf8),
              let nsAttributed = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              )
        else {
            let fallback = plainText(from: html)
            return fallback.isEmpty ? nil : AttributedString(fallback)
        }

        let fullRange = NSRange(location: 0, length: nsAttributed.length)

        // 1. Strip HTML-baked foreground colours so SwiftUI's .foregroundStyle applies.
        nsAttributed.removeAttribute(.foregroundColor, range: fullRange)

        // 2. Normalise every font range to San Francisco at the requested size,
        //    preserving bold and italic traits so <b> / <em> still render correctly.
        //    Collect first: mutating NSMutableAttributedString while enumerating
        //    attributes can raise an Objective-C exception for some imported HTML.
        var fontUpdates: [(range: NSRange, font: UIFont)] = []
        nsAttributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let old = value as? UIFont else { return }
            let traits = old.fontDescriptor.symbolicTraits
            let newFont: UIFont
            if traits.contains(.traitBold) && traits.contains(.traitItalic),
               let desc = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                .fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                newFont = UIFont(descriptor: desc, size: fontSize)
            } else if traits.contains(.traitBold) {
                newFont = UIFont.boldSystemFont(ofSize: fontSize)
            } else if traits.contains(.traitItalic),
                      let desc = UIFont.systemFont(ofSize: fontSize)
                        .fontDescriptor.withSymbolicTraits(.traitItalic) {
                newFont = UIFont(descriptor: desc, size: fontSize)
            } else {
                newFont = UIFont.systemFont(ofSize: fontSize)
            }
            fontUpdates.append((range: range, font: newFont))
        }
        for update in fontUpdates {
            nsAttributed.addAttribute(.font, value: update.font, range: update.range)
        }

        // 3. Re-colour links to purple.
        var linkRanges: [NSRange] = []
        nsAttributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            linkRanges.append(range)
        }
        for range in linkRanges {
            nsAttributed.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: range)
            nsAttributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }

        // 4. Sentence breaks: replace the space(s) after a full stop with a blank
        //    line so each sentence reads on its own. Editing the mutableString keeps
        //    the font/link attributes intact. Decimals/URLs have no space after the
        //    dot, so they're left untouched.
        if sentenceBreaks,
           let breaker = try? NSRegularExpression(pattern: #"(?<=\.)[ \t]+"#) {
            breaker.replaceMatches(
                in: nsAttributed.mutableString,
                range: NSRange(location: 0, length: nsAttributed.length),
                withTemplate: "\n\n"
            )
        }

        let string = nsAttributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        return try? AttributedString(nsAttributed, including: \.uiKit)
    }

    static func plainText(from html: String) -> String {
        let withoutImages = htmlForTextDisplay(html)
        let withoutTags = withoutImages.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return decodeEntities(withoutTags)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            // Structural
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            // Dashes
            .replacingOccurrences(of: "&mdash;", with: "\u{2014}")
            .replacingOccurrences(of: "&#8212;", with: "\u{2014}")
            .replacingOccurrences(of: "&ndash;", with: "\u{2013}")
            .replacingOccurrences(of: "&#8211;", with: "\u{2013}")
            // Curly quotes
            .replacingOccurrences(of: "&rsquo;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&lsquo;", with: "\u{2018}")
            .replacingOccurrences(of: "&#8216;", with: "\u{2018}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201D}")
            .replacingOccurrences(of: "&#8221;", with: "\u{201D}")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
            .replacingOccurrences(of: "&#8220;", with: "\u{201C}")
            // Punctuation & symbols
            .replacingOccurrences(of: "&hellip;", with: "\u{2026}")
            .replacingOccurrences(of: "&#8230;", with: "\u{2026}")
            .replacingOccurrences(of: "&bull;", with: "\u{2022}")
            .replacingOccurrences(of: "&#8226;", with: "\u{2022}")
            .replacingOccurrences(of: "&copy;", with: "\u{00A9}")
            .replacingOccurrences(of: "&#169;", with: "\u{00A9}")
            .replacingOccurrences(of: "&reg;", with: "\u{00AE}")
            .replacingOccurrences(of: "&#174;", with: "\u{00AE}")
            .replacingOccurrences(of: "&trade;", with: "\u{2122}")
            .replacingOccurrences(of: "&#8482;", with: "\u{2122}")
    }
}

// MARK: - Up Next row (ListRow-Standard, custom swipe gesture)
//
// .swipeActions requires a List — nesting a List inside a ScrollView causes gesture
// conflicts. Custom drag is used instead, matching the Up Next interaction model.

private struct UpNextRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    let episode: Episode

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false

    private let actionWidth: CGFloat = 80
    private let openThreshold: CGFloat = 40
    private let cornerRadius: CGFloat = 14
    private var spring: Animation { .spring(response: 0.3, dampingFraction: 0.75) }

    var body: some View {
        let sub = subscriptionStore.subscription(id: episode.subscriptionID)

        ZStack(alignment: .center) {
            // Action buttons behind the card
            HStack(spacing: 0) {
                // Play — leading, green (SwipeColor-Semantics)
                Color.green
                    .frame(width: max(0, offset))
                    .overlay(
                        swipeLabel(icon: "play.fill", text: "Play")
                            .opacity(offset > 8 ? 1 : 0)
                    )
                    .clipped()
                    .onTapGesture {
                        withAnimation(spring) { offset = 0 }
                        Task { await appState.skipToEpisode(episode) }
                    }

                Spacer(minLength: 0)

                // Archive — trailing, purple (SwipeColor-Semantics)
                Color.purple
                    .frame(width: max(0, -offset))
                    .overlay(
                        swipeLabel(icon: "archivebox", text: "Archive")
                            .opacity(offset < -8 ? 1 : 0)
                    )
                    .clipped()
                    .onTapGesture {
                        withAnimation(spring) { offset = 0 }
                        Task { await appState.archiveEpisode(episode) }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            // Card — slides over the buttons.
            // Tap on the card itself closes any open swipe action.
            rowContent(sub: sub)
                .offset(x: offset)
                .onTapGesture {
                    guard offset != 0 else { return }
                    withAnimation(spring) { offset = 0 }
                }
        }
        // highPriorityGesture beats the TabView(.page) UIKit pan recognizer.
        // The horizontal guard in onChanged lets vertical drags fall through to the ScrollView.
        // onEnded always snaps to a settled position so the row never sticks half-open.
        .highPriorityGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) * 0.6 else { return }
                    if !isDragging {
                        isDragging = true
                        dragStartOffset = offset
                    }
                    let proposed = dragStartOffset + h
                    offset = min(actionWidth, max(-actionWidth, proposed))
                }
                .onEnded { _ in
                    isDragging = false
                    if offset > openThreshold {
                        withAnimation(spring) { offset = actionWidth }
                    } else if offset < -openThreshold {
                        withAnimation(spring) { offset = -actionWidth }
                    } else {
                        withAnimation(spring) { offset = 0 }
                    }
                }
        )
    }

    private func swipeLabel(icon: String, text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
    }

    // ListRow-Standard layout
    private func rowContent(sub: Subscription?) -> some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        let artworkSize = metrics.artworkSize
        return HStack(spacing: metrics.rowSpacing) {
            // Position indicator — arrow.forward (user-confirmed)
            Image(systemName: "arrow.forward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.purple)
                .frame(width: 20)

            // Artwork column — 44×44 image + badges centred below
            VStack(alignment: .center, spacing: 4) {
                CachedArtworkImage(url: sub?.artworkURL, targetSize: CGSize(width: artworkSize, height: artworkSize)) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.2))

            }

            // Text stack (Text-PodcastTitle / Text-EpisodeTitle / Text-MetadataRow)
            VStack(alignment: .leading, spacing: 2) {
                Text(sub?.title ?? "Unknown Podcast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(episode.title)
                        .font(.system(size: metrics.primaryFontSize, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                HStack(spacing: 4) {
                    if let date = episode.publishedAt {
                        Text(formatDate(date)).lineLimit(1)
                    }
                    if let remaining = remainingTime {
                        Text("•")
                        Text(remaining).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }

            Spacer()

            // Trailing duration (Text-Duration)
            if let dur = episode.durationSeconds {
                Text(formatDuration(dur))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: cornerRadius)
        .overlay(alignment: .topTrailing) {
            if episode.mediaKind == .video || episode.isExplicit == true {
                HStack(spacing: 3) {
                    if episode.mediaKind == .video { VideoPillSmall() }
                    if episode.isExplicit == true { ExplicitPillSmall() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // Text-MetadataAdaptive
    private var remainingTime: String? {
        let elapsed = appState.effectivePlaybackTime(for: episode)
        guard elapsed > 0, let duration = episode.durationSeconds, duration > 0 else { return nil }
        let remaining = max(0, duration - elapsed)
        guard remaining > 0 else { return nil }
        return "\(formatDuration(remaining)) left remaining"
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}


private struct SkipIntervalIcon: View {
    enum Direction {
        case backward
        case forward
    }

    let direction: Direction
    let seconds: TimeInterval

    var body: some View {
        let safeSeconds = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        ZStack {
            Image(systemName: direction == .backward ? "gobackward" : "goforward")
                .font(.system(size: 36, weight: .regular))

            Text("\(safeSeconds)")
                .font(.system(size: textSize, weight: .medium, design: .rounded))
                .monospacedDigit()
                .offset(y: 3)
        }
        .frame(width: 64, height: 64)
        .foregroundStyle(Color(white: 0.9))
        .accessibilityLabel(
            direction == .backward
                ? "Skip back \(safeSeconds) seconds"
                : "Skip forward \(safeSeconds) seconds"
        )
    }

    private var textSize: CGFloat {
        let safeSeconds = Int(seconds.isFinite && seconds > 0 ? seconds : 0)
        return safeSeconds >= 100 ? 12 : 15
    }
}

// MARK: - Archive Confirmation Sheet

private struct ArchiveConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Image(systemName: "archivebox")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.purple.opacity(0.85))
                .padding(.bottom, 12)

            Text("Archive Episode?")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 6)

            Text("This will archive the currently playing episode and delete its downloaded file.")
                .font(.system(size: 14))
                .foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

            Button {
                dismiss()
                onConfirm()
            } label: {
                Text("Archive")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Spacer(minLength: 16)
        }
        .adaptiveContentWidth(.form)
        }
        .presentationBackground(.regularMaterial)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }
}

// MARK: - Audio Controls Sheet

// AI CONTEXT — AudioControlsSheetView ("Audio Controls" sheet, from the
// Player). Dark card sheet editing the CURRENT podcast's PlaybackPreference:
// speed stepper (1.0–2.5x), Trim Silence toggle + Low/Medium/High picker,
// Vocal Boost toggle + Light/Standard/Strong picker. Changes route through
// AppState.update* methods so they apply live to the playing episode AND
// persist on the subscription. Top row is Shared Listening — a GLOBAL
// temporary override (1x–1.3x, Trim Silence forced off, per-sub settings
// untouched); while on, the Speed and Trim rows below are greyed out and the
// player's sound-controls button renders white.
// Shared Listening values MUST be read from SettingsViewModel, the observable
// global-settings owner. AppState remains the command facade for live playback
// side effects but intentionally does not forward settings objectWillChange.
// MODAL DEPENDENCY CONTRACT: all four models are explicit @ObservedObject
// initializer inputs. This keeps the sheet independent of environment-object
// propagation across UIKit's iPhone/iPad sheet host and the iOS-on-Mac host.
struct AudioControlsSheetView: View {
    @ObservedObject private var appState: AppState
    @ObservedObject private var playbackCoordinator: PlaybackCoordinator
    @ObservedObject private var subscriptionStore: SubscriptionStore
    @ObservedObject private var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        appState: AppState,
        playbackCoordinator: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        settingsViewModel: SettingsViewModel
    ) {
        _appState = ObservedObject(wrappedValue: appState)
        _playbackCoordinator = ObservedObject(wrappedValue: playbackCoordinator)
        _subscriptionStore = ObservedObject(wrappedValue: subscriptionStore)
        _settingsViewModel = ObservedObject(wrappedValue: settingsViewModel)
    }

    private var episode: Episode? { playbackCoordinator.currentEpisode }
    private var subscription: Subscription? {
        episode.flatMap { subscriptionStore.subscription(id: $0.subscriptionID) }
    }

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            sharedListeningRow

            rowDivider

            speedRow
                .opacity(sharedListeningActive ? 0.35 : 1)
                .disabled(sharedListeningActive)

            rowDivider

            trimSilenceRow
                .opacity(sharedListeningActive ? 0.35 : 1)
                .disabled(sharedListeningActive)

            rowDivider

            vocalBoostRow

            Spacer(minLength: 24)
        }
        .adaptiveContentWidth(.form)
        }
        .audioControlsPresentationChrome()
    }

    private var sharedListeningActive: Bool {
        settingsViewModel.appSettings.sharedListeningActive
    }

    // MARK: - Shared Listening Row

    private var sharedListeningRow: some View {
        let isOn = sharedListeningActive
        let speeds = AppState.sharedListeningSpeedOptions

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                rowIcon("person.2.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Shared Listening")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Slow every podcast for listening together")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.50))
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { appState.setSharedListening(active: $0) }
                ))
                .labelsHidden()
                .tint(.purple)
            }

            if isOn {
                Picker("", selection: Binding(
                    get: {
                        speeds.first {
                            abs($0 - settingsViewModel.appSettings.sharedListeningSpeed) < 0.01
                        } ?? 1.0
                    },
                    set: { appState.updateSharedListeningSpeed($0) }
                )) {
                    ForEach(speeds, id: \.self) { speed in
                        Text(PlaybackPreference.speedLabel(speed)).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.purple)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }

    // MARK: - Speed Row

    private var speedRow: some View {
        let speed = subscription?.playbackPreference.speed ?? PlaybackPreference.default.speed
        let options = PlaybackPreference.speedOptions

        return HStack(spacing: 14) {
            rowIcon("speedometer")

            Text("Speed")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            // Stepper: − value +
            HStack(spacing: 0) {
                Button {
                    guard let sub = subscription,
                          let idx = options.firstIndex(where: { abs($0 - speed) < 0.01 }),
                          idx > 0
                    else { return }
                    appState.updatePlaybackSpeed(for: sub.id, speed: options[idx - 1])
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 38)
                }

                Text(PlaybackPreference.speedLabel(speed))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 46)

                Button {
                    guard let sub = subscription,
                          let idx = options.firstIndex(where: { abs($0 - speed) < 0.01 }),
                          idx < options.count - 1
                    else { return }
                    appState.updatePlaybackSpeed(for: sub.id, speed: options[idx + 1])
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 38)
                }
            }
            .glassCard(cornerRadius: 10)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Trim Silence Row

    private var trimSilenceRow: some View {
        let trimSilence = subscription?.playbackPreference.trimSilence ?? .off
        let isOn = trimSilence != .off
        let levels: [TrimSilenceAmount] = [.low, .medium, .high]

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                rowIcon("scissors")

                Text("Trim Silence")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { on in
                        guard let sub = subscription else { return }
                        appState.updateTrimSilence(for: sub.id, amount: on ? .low : .off)
                    }
                ))
                .labelsHidden()
                .tint(.purple)
            }

            if isOn {
                Picker("", selection: Binding(
                    get: { trimSilence },
                    set: { amount in
                        guard let sub = subscription else { return }
                        appState.updateTrimSilence(for: sub.id, amount: amount)
                    }
                )) {
                    ForEach(levels, id: \.self) { amount in
                        Text(amount.title).tag(amount)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.purple)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }

    // MARK: - Vocal Boost Row

    private var vocalBoostRow: some View {
        let level = subscription?.playbackPreference.vocalBoostLevel ?? .off
        let isOn = level != .off
        let levels: [VocalBoostLevel] = [.light, .standard, .strong]

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                rowIcon("speaker.wave.2.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Vocal Boost")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Voices sound clearer")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.50))
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { on in
                        guard let sub = subscription else { return }
                        appState.updateVocalBoost(for: sub.id, level: on ? .strong : .off)
                    }
                ))
                .labelsHidden()
                .tint(.purple)
            }

            if isOn {
                Picker("", selection: Binding(
                    get: { level },
                    set: { newLevel in
                        guard let sub = subscription else { return }
                        appState.updateVocalBoost(for: sub.id, level: newLevel)
                    }
                )) {
                    ForEach(levels, id: \.self) { l in
                        Text(l.title).tag(l)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.purple)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }

    // MARK: - Helpers

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.purple)
            .frame(width: 26)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 60)
    }
}

private enum PlayerPanel: Int, CaseIterable, Identifiable {
    case nowPlaying
    case details
    case chapters

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Playing"
        case .details: return "Details"
        case .chapters: return "Chapters"
        }
    }

    var icon: String {
        switch self {
        case .nowPlaying: return "waveform"
        case .details: return "info.circle"
        case .chapters: return "list.number"
        }
    }
}

// MARK: - Audio controls presentation

private extension View {
    /// Keeps the Audio Controls content universal while allowing the host
    /// platform to own modal mechanics. iOS-on-Mac has no touch-driven sheet
    /// gesture, so it uses the system's default modal size and omits detent,
    /// drag-indicator and custom-corner configuration. iPhone and iPad retain
    /// the established resizable bottom sheet.
    @ViewBuilder
    func audioControlsPresentationChrome() -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            presentationBackground(.regularMaterial)
                .preferredColorScheme(.dark)
        } else {
            presentationBackground(.regularMaterial)
                .preferredColorScheme(.dark)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(20)
        }
    }
}

// MARK: - Player glass pill

private extension View {
    /// Shared glass pill for the Player's top-bar + audio-row action buttons
    /// (Sleep Schedule indicator, Queue, Sound Settings, Sleep Timer, Share,
    /// Archive). Idle = neutral frosted glass with a purple icon; `highlighted`
    /// (Sleep Timer running, Shared Listening on) = purple-tinted glass with a
    /// white icon — mirrors the Priority page reorder toggle. iOS 17–25 falls
    /// back to the original `purple.opacity(0.12)` fill + `purple.opacity(0.3)` stroke.
    @ViewBuilder
    func playerGlassPill(highlighted: Bool = false, cornerRadius: CGFloat = 9) -> some View {
        if #available(iOS 26, *) {
            if highlighted {
                glassEffect(.regular.tint(.purple), in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            background(Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.purple.opacity(0.3), lineWidth: 0.5))
        }
    }
}
