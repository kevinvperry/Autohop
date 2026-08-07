import SwiftUI
import AVKit
import AutohopCore

// AI CONTEXT — TV/Views/TVPlayerView.swift
// REDESIGNED 2026-07-04 (Kevin's spec) from the original bare
// AVPlayerViewController cover into a proper player page:
// - AUDIO: full page — large artwork, episode/show metadata, playback
//   position bar with elapsed/remaining, and focusable transport controls
//   (skip ±, play/pause, speed menu).
// - VIDEO: the SAME page layout but with a small live video window (plain
//   AVPlayerLayer surface, TVVideoSurface below — no system chrome) in place
//   of the artwork, plus a "Full Screen" button that switches to the system
//   AVPlayerViewController (transport bar, scrubbing); Menu/onExitCommand in
//   fullscreen returns to this windowed page rather than closing the cover.
// - Menu on the windowed page exits the cover; audio keeps playing
//   (UIBackgroundModes: audio). onPlayPauseCommand toggles from anywhere.
// FAILURE UX unchanged: `TVPlaybackModel.errorMessage` renders a focusable
// retry card instead of the player (§8 item 5).
// CHAPTERS (round 9, 2026-07-11): the WINDOWED page now has full chapter
// navigation — prev/next chapter buttons in the unified transport row (shown
// only when the episode has chapters) + the current chapter title above the
// position bar, via TVPlaybackModel.currentChapter/skipTo{Next,Previous}Chapter
// (PlaybackSessionPolicy prev/next-start logic). The FULLSCREEN
// AVPlayerViewController's chapter navigationMarkerGroups remain NOT wired
// (2026-07-04 build-break note — exact AVPlayerItem API needs Xcode
// confirmation); its speed menu via transportBarCustomMenuItems IS wired.
// Round 9 also unified the windowed controls into ONE focus row (Full Screen
// moved into it; the standalone button forced vertical focus hops).
struct TVPlayerView: View {
    let playbackModel: TVPlaybackModel
    let resolveEpisodeDescription: (Episode) async -> Episode
    let onArchive: () -> Void
    let onExit: () -> Void
    @State private var descriptionItem: TVEpisodeDescriptionItem?
    @State private var isResolvingDescription = false

    var body: some View {
        ZStack {
            // Opaque base — REQUIRED (fix 2026-07-04): tvOS `.fullScreenCover`
            // does not force an opaque background, and TVPlayerPage's own base
            // layer is a blurred artwork at 0.25 opacity, so the Home screen
            // bled through and the two views overlapped into "a confusing
            // mess" (Kevin's real-device report). A full-bleed black backdrop
            // makes the cover genuinely replace what's behind it.
            Color.black.ignoresSafeArea()

            content
        }
        .onPlayPauseCommand {
            playbackModel.togglePlayPause()
        }
        .preferredColorScheme(.dark)
        .tvEpisodeDescriptionSheet(
            item: $descriptionItem,
            resolveEpisode: resolveEpisodeDescription
        )
        .overlay {
            if isResolvingDescription {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Loading episode description…").font(.headline)
                }
                .padding(.horizontal, 42)
                .padding(.vertical, 28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = playbackModel.errorMessage {
            TVPlaybackRetryView(
                message: errorMessage,
                onRetry: { Task { await playbackModel.retry() } },
                onExit: onExit
            )
        } else if playbackModel.currentEpisode?.mediaKind == .video {
            // Never render a video episode through the audio/artwork player
            // during the brief interval before AVPlayer is published. That
            // branch became sticky on physical tvOS and hid the video surface.
            if let player = playbackModel.avPlayer {
                TVAVPlayerRepresentable(
                    player: player,
                    playbackModel: playbackModel,
                    playbackSpeed: playbackModel.currentSpeed,
                    onShowDescription: showDescription,
                    onArchive: onArchive
                )
                    .ignoresSafeArea()
                    .onExitCommand {
                        onExit()
                    }
            } else {
                ProgressView("Preparing playback…")
                    .controlSize(.large)
            }
        } else if playbackModel.currentEpisode != nil {
            TVPlayerPage(
                playbackModel: playbackModel,
                onShowDescription: showDescription,
                onArchive: onArchive
            )
            .onExitCommand {
                onExit()
            }
        } else {
            ProgressView()
        }
    }

    private func showDescription() {
        guard let episode = playbackModel.currentEpisode,
              !isResolvingDescription else { return }
        let podcastTitle = playbackModel.currentSubscriptionTitle
        if episode.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            descriptionItem = TVEpisodeDescriptionItem(episode: episode, podcastTitle: podcastTitle)
            return
        }
        isResolvingDescription = true
        Task { @MainActor in
            let resolved = await resolveEpisodeDescription(episode)
            isResolvingDescription = false
            descriptionItem = TVEpisodeDescriptionItem(episode: resolved, podcastTitle: podcastTitle)
        }
    }
}

// MARK: - The player page (audio full-page / video windowed)

private struct TVPlayerPage: View {
    let playbackModel: TVPlaybackModel
    let onShowDescription: () -> Void
    let onArchive: () -> Void

    private var episode: Episode? { playbackModel.currentEpisode }
    private var duration: TimeInterval? { episode?.durationSeconds }

    var body: some View {
        ZStack {
            // Blurred artwork backdrop (PC BlurredCoverBackground intent).
            TVArtworkImage(url: episode?.artworkURL, cornerRadius: 0)
                .blur(radius: 80)
                .opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer(minLength: 20)

                mediaSurface

                VStack(spacing: 10) {
                    TVMarqueeText(text: episode?.title ?? "")
                    Text(playbackModel.currentSubscriptionTitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 120)

                positionBar

                transportControls

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 90)
        }
    }

    /// Video → small live window (Full Screen moved INTO the unified
    /// transport row, 2026-07-11 round 9 — the standalone button above the
    /// controls forced awkward vertical focus hops); audio → large artwork.
    @ViewBuilder
    private var mediaSurface: some View {
        Group {
            if episode != nil {
                // 1200 px decoded for the 440 pt player hero — ~2.5× density
                // on the 4K composite (see TVArtworkImage's targetPixels note).
                // Purple radial glow behind the artwork = the phone's
                // Artwork-Player token (DESIGN.md), ported 2026-07-11.
                TVArtworkImage(url: episode?.artworkURL, cornerRadius: 24, targetPixels: 1200)
                    .frame(width: 440, height: 440)
                    .background {
                        RadialGradient(
                            colors: [Color.purple.opacity(0.45), .clear],
                            center: .center,
                            startRadius: 60,
                            endRadius: 420
                        )
                        .frame(width: 840, height: 840)
                    }
                    .shadow(radius: 30)
                    .overlay { bufferingOverlay(cornerRadius: 24) }
            }
        }
    }

    /// Buffering spinner over the media surface (Kevin's request 2026-07-04):
    /// a clear "playback is about to start" signal while the stream fills.
    /// Shown while buffering AND not yet advancing (currentTime == 0 covers
    /// the initial start-up; a mid-stream stall shows it too via isBuffering).
    @ViewBuilder
    private func bufferingOverlay(cornerRadius: CGFloat) -> some View {
        if playbackModel.isBuffering {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.black.opacity(0.45))
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Buffering…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
        }
    }

    private var positionBar: some View {
        VStack(spacing: 8) {
            // Current chapter (2026-07-11, round 9): windowed chapter context,
            // paired with the prev/next chapter buttons in the transport row.
            if let chapter = playbackModel.currentChapter {
                Text(chapter.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: progressFraction)
                .tint(.purple)
            HStack {
                Text(timeLabel(playbackModel.currentTime))
                Spacer()
                if let duration {
                    Text("-" + timeLabel(max(0, duration - playbackModel.currentTime)))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 900)
    }

    private var progressFraction: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(playbackModel.currentTime / duration, 0), 1)
    }

    /// ONE unified control row (2026-07-11, round 9 — "playback controls are
    /// not easy to navigate in the windowed view; chapter control only in
    /// full screen"): everything is a single left-to-right focus pass —
    /// [prev chapter] · skip back · play/pause · skip forward · [next
    /// chapter] · speed · [Full Screen]. Chapter buttons appear only when the
    /// episode has chapters; Full Screen only for video. No vertical hops.
    private var transportControls: some View {
        HStack(spacing: 40) {
            if playbackModel.currentChapter != nil {
                Button {
                    playbackModel.skipToPreviousChapter()
                } label: {
                    Image(systemName: "backward.end.alt")
                }
            }

            Button {
                playbackModel.skipBackward()
            } label: {
                Image(systemName: "gobackward.15")
            }

            Button {
                playbackModel.togglePlayPause()
            } label: {
                Image(systemName: playbackModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button {
                playbackModel.skipForward()
            } label: {
                Image(systemName: "goforward.30")
            }

            if playbackModel.currentChapter != nil {
                Button {
                    playbackModel.skipToNextChapter()
                } label: {
                    Image(systemName: "forward.end.alt")
                }
            }

            Menu {
                ForEach(PlaybackPreference.speedOptions, id: \.self) { speed in
                    Button(PlaybackPreference.speedLabel(speed)) {
                        playbackModel.setSpeed(speed)
                    }
                }
            } label: {
                Label("Speed", systemImage: "gauge.with.needle")
            }

            Button(action: onShowDescription) {
                Label("Description", systemImage: "text.page")
            }

            Button(role: .destructive, action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }

        }
        .buttonStyle(.bordered)
        .focusSection()
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Native system video player

private final class TVNativePlayerViewController: AVPlayerViewController {
    var onReadyForCustomMenu: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onReadyForCustomMenu?()
    }
}

private struct TVAVPlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let playbackModel: TVPlaybackModel
    /// Passed separately so SwiftUI observes rate changes and refreshes the
    /// native transport menu instead of leaving a stale checked item.
    let playbackSpeed: Double
    let onShowDescription: () -> Void
    let onArchive: () -> Void

    func makeUIViewController(context: Context) -> TVNativePlayerViewController {
        let controller = TVNativePlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        controller.requiresLinearPlayback = false
        // AVKit's transport view has zero width before presentation. Installing
        // a custom menu at that point creates unsatisfiable focus/menu
        // constraints and can make Siri Remote navigation feel erratic.
        controller.onReadyForCustomMenu = { [weak controller] in
            guard let controller else { return }
            applyTransportBarMenu(to: controller)
        }
        logSurface("attached", controller: controller)
        return controller
    }

    func updateUIViewController(_ controller: TVNativePlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
            logSurface("reattached", controller: controller)
        }
        controller.onReadyForCustomMenu = { [weak controller] in
            guard let controller else { return }
            applyTransportBarMenu(to: controller)
        }
        if controller.viewIfLoaded?.window != nil, controller.view.bounds.width > 0 {
            applyTransportBarMenu(to: controller)
        }
    }

    static func dismantleUIViewController(
        _ controller: TVNativePlayerViewController,
        coordinator: Void
    ) {
        // The AVPlayer belongs to StreamingPlaybackEngine, not this transient
        // cover. Detach the retiring controller so reopening creates a clean
        // presentation surface around the same still-playing player.
        AppLogger.shared.info("tv.videoSurface", "Native video surface detached", metadata: [
            "player": controller.player.map { "\(ObjectIdentifier($0).hashValue)" } ?? "none",
            "itemStatus": controller.player?.currentItem.map { "\($0.status.rawValue)" } ?? "none",
            "rate": String(format: "%.2f", Double(controller.player?.rate ?? 0.0))
        ], alwaysPersist: true)
        controller.player = nil
        controller.transportBarCustomMenuItems = []
    }

    private func logSurface(_ action: String, controller: AVPlayerViewController) {
        AppLogger.shared.info("tv.videoSurface", "Native video surface \(action)", metadata: [
            "player": "\(ObjectIdentifier(player).hashValue)",
            "controllerHasPlayer": "\(controller.player === player)",
            "itemStatus": player.currentItem.map { "\($0.status.rawValue)" } ?? "none",
            "rate": String(format: "%.2f", player.rate),
            "defaultRate": String(format: "%.2f", player.defaultRate),
            "expectedSpeed": String(format: "%.2f", playbackSpeed),
            "position": String(format: "%.1f", player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            "episodeID": playbackModel.currentEpisode?.id.uuidString ?? "none"
        ], alwaysPersist: true)
    }

    private func applyTransportBarMenu(to controller: AVPlayerViewController) {
        let menu = UIMenu(
            title: "Speed · \(PlaybackPreference.speedLabel(playbackSpeed))",
            image: UIImage(systemName: "gauge.with.needle"),
            children: PlaybackPreference.speedOptions.map { speed in
            let action = UIAction(
                title: PlaybackPreference.speedLabel(speed),
                state: abs(speed - playbackSpeed) < 0.001 ? .on : .off
            ) { _ in
                playbackModel.setSpeed(speed)
            }
            return action
        })
        let archive = UIAction(
            title: "Archive Episode",
            image: UIImage(systemName: "archivebox"),
            attributes: .destructive
        ) { _ in
            onArchive()
        }
        let description = UIAction(
            title: "Episode Description",
            image: UIImage(systemName: "text.page")
        ) { _ in
            onShowDescription()
        }
        let archiveMenu = UIMenu(
            title: "Episode",
            image: UIImage(systemName: "ellipsis.circle"),
            children: [description, archive]
        )
        controller.transportBarCustomMenuItems = [menu, archiveMenu]
    }
}

// MARK: - Failure UX (§8 item 5)

private struct TVPlaybackRetryView: View {
    let message: String
    let onRetry: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button("Close", action: onExit)
                    .buttonStyle(.bordered)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}
