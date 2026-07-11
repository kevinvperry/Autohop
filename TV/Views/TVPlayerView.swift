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
    let onExit: () -> Void

    @State private var isVideoFullscreen = false

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
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = playbackModel.errorMessage {
            TVPlaybackRetryView(
                message: errorMessage,
                onRetry: { Task { await playbackModel.retry() } },
                onExit: onExit
            )
        } else if isVideoFullscreen, let player = playbackModel.avPlayer {
            TVAVPlayerRepresentable(player: player, playbackModel: playbackModel)
                .ignoresSafeArea()
                .onExitCommand {
                    // Menu in fullscreen returns to the windowed page.
                    isVideoFullscreen = false
                }
        } else if playbackModel.currentEpisode != nil {
            TVPlayerPage(
                playbackModel: playbackModel,
                onEnterFullscreen: { isVideoFullscreen = true }
            )
            .onExitCommand {
                playbackModel.dismissedCover()
                onExit()
            }
        } else {
            ProgressView()
        }
    }
}

// MARK: - The player page (audio full-page / video windowed)

private struct TVPlayerPage: View {
    let playbackModel: TVPlaybackModel
    let onEnterFullscreen: () -> Void

    private var episode: Episode? { playbackModel.currentEpisode }
    private var isVideo: Bool { episode?.mediaKind == .video }
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
                    Text(episode?.title ?? "")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
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
            if isVideo, let player = playbackModel.avPlayer {
                TVVideoSurface(player: player)
                    .frame(width: 832, height: 468)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .overlay { bufferingOverlay(cornerRadius: 16) }
            } else {
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

            if isVideo {
                Button {
                    onEnterFullscreen()
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
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

// MARK: - Plain video surface (no system chrome — our page provides controls)

private struct TVVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

// MARK: - Fullscreen system player (video)

private struct TVAVPlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let playbackModel: TVPlaybackModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        applyTransportBarMenu(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        applyTransportBarMenu(to: controller)
    }

    private func applyTransportBarMenu(to controller: AVPlayerViewController) {
        let menu = UIMenu(title: "Playback Speed", children: PlaybackPreference.speedOptions.map { speed in
            UIAction(title: PlaybackPreference.speedLabel(speed)) { _ in
                playbackModel.setSpeed(speed)
            }
        })
        controller.transportBarCustomMenuItems = [menu]
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
