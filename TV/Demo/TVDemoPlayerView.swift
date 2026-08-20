import AVKit
import SwiftUI

// AI CONTEXT — Offline demo-only playback surface. Uses a private AVPlayer over
// bundled first-party media and reports progress solely to TVDemoSession. It
// must never call TVPlaybackModel, production history/stats stores, CloudKit,
// Now Playing services, or production archive/queue workflows.

struct TVDemoPlayerView: View {
    let episode: TVDemoEpisode
    let initialPosition: TimeInterval
    let onProgress: (TimeInterval) -> Void
    let onComplete: () -> Void
    let onExit: () -> Void

    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var isPlaying = false
    @State private var speed = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if episode.mediaKind == .video, let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                VStack(spacing: 34) {
                    TVDemoArtwork(title: episode.showTitle, colorHex: 0x6633CC)
                        .frame(width: 360, height: 360)
                    Text(episode.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text(episode.showTitle).font(.title3).foregroundStyle(.secondary)
                    controls
                }
                .padding(70)
            }
        }
        .overlay(alignment: .topLeading) { demoBadge.padding(40) }
        .onAppear(perform: prepare)
        .onDisappear(perform: tearDown)
        .onExitCommand {
            checkpoint()
            onExit()
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            Button { togglePlayback() } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            Button { seek(by: -10) } label: { Label("10 seconds", systemImage: "gobackward.10") }
                .buttonStyle(.bordered)
            Button { seek(by: 10) } label: { Label("10 seconds", systemImage: "goforward.10") }
                .buttonStyle(.bordered)
            Menu {
                ForEach([1.0, 1.25, 1.4, 1.5, 2.0], id: \.self) { value in
                    Button(value == speed ? "✓ \(value.formatted())×" : "\(value.formatted())×") {
                        speed = value
                        if isPlaying { player?.rate = Float(value) }
                    }
                }
            } label: { Label("\(speed.formatted())×", systemImage: "gauge.with.needle") }
            .buttonStyle(.bordered)
            Button(role: .destructive) {
                checkpoint()
                onComplete()
            } label: { Label("Finish Demo Episode", systemImage: "checkmark.circle") }
                .buttonStyle(.bordered)
        }
    }

    private var demoBadge: some View {
        Label("Demo — changes stay on this Apple TV", systemImage: "sparkles.tv")
            .font(.headline)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func prepare() {
        guard let url = episode.mediaURL else { return }
        let created = AVPlayer(url: url)
        player = created
        if initialPosition > 0 {
            created.seek(to: CMTime(seconds: initialPosition, preferredTimescale: 600))
        }
        observer = created.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2),
            queue: .main
        ) { time in
            onProgress(time.seconds)
        }
        created.playImmediately(atRate: Float(speed))
        isPlaying = true
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.playImmediately(atRate: Float(speed)) }
        isPlaying.toggle()
    }

    private func seek(by delta: TimeInterval) {
        guard let player else { return }
        let target = max(0, min(episode.duration, player.currentTime().seconds + delta))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        onProgress(target)
    }

    private func checkpoint() {
        if let seconds = player?.currentTime().seconds, seconds.isFinite { onProgress(seconds) }
    }

    private func tearDown() {
        checkpoint()
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
    }
}

