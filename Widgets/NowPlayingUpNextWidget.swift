import SwiftUI
import UIKit
import WidgetKit

// AI CONTEXT — Widgets/NowPlayingUpNextWidget.swift
//
// PURPOSE:
// Stage 3/4 interactive renderer for Autohop's adaptive "Now Playing & Up Next"
// widget. The provider reads one versioned App Group snapshot plus app-prepared
// local JPEGs. Home Screen families render live current/ready episodes and
// Lock Screen/StandBy accessories render live privacy-sensitive summaries.
// Home Screen families use an opaque textured charcoal glass surface: iOS 26+
// adds native Liquid Glass while iOS 17–25 receive a stable gradient/stroke
// fallback. Playback controls deliberately use a rendered gradient/stroke glass
// treatment on every OS because applying native glass directly to an App Intent
// Toggle can make its label disappear in the WidgetKit host. Accessories retain
// WidgetKit's system-rendered background.
//
// DATA / PERFORMANCE:
// There is one timeline entry and `.never` policy. App-side meaningful events
// request targeted reloads. Artwork reads are local and bounded by family:
// small=1, medium=2, large=5. The extension never networks, opens GRDB, imports
// AutohopCore, derives queue policy, or runs a playback countdown.
//
// FAILURE STATES:
// Missing valid data shows a Discover-oriented empty state. Snapshots older
// than 24 hours or unreadable snapshots show a neutral "Open Autohop" recovery
// message rather than presenting misleading episode state. Downloaded rows use
// AudioPlaybackIntent without foregrounding; navigation uses validated links.

private enum WidgetContentState {
    case content
    case empty
    case stale
    case unavailable
    case placeholder
}

private struct WidgetTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let artwork: [String: Data]
    let state: WidgetContentState

    static let placeholder = WidgetTimelineEntry(
        date: .now,
        snapshot: WidgetSnapshot(
            generatedAt: .now,
            upNextTotalCount: 4,
            isPlaying: true,
            episodes: [
                WidgetDisplayEpisode(
                    identity: WidgetEpisodeIdentity(
                        subscriptionID: UUID(),
                        episodeKey: "preview"
                    ),
                    episodeTitle: "Your current episode",
                    podcastTitle: "Autohop",
                    durationSeconds: 3_600,
                    remainingSeconds: 2_520,
                    isCurrent: true,
                    thumbnailFilename: nil,
                    isVideo: false,
                    isExplicit: nil
                )
            ]
        ),
        artwork: [:],
        state: .placeholder
    )
}

private struct WidgetSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetTimelineEntry {
        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (WidgetTimelineEntry) -> Void
    ) {
        completion(loadEntry(family: context.family))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<WidgetTimelineEntry>) -> Void
    ) {
        completion(Timeline(
            entries: [loadEntry(family: context.family)],
            policy: .never
        ))
    }

    private func loadEntry(family: WidgetFamily) -> WidgetTimelineEntry {
        let storage = WidgetSharedStorage()
        do {
            guard let snapshot = try storage.read() else {
                return WidgetTimelineEntry(
                    date: .now,
                    snapshot: nil,
                    artwork: [:],
                    state: .empty
                )
            }
            let isStale = Date().timeIntervalSince(snapshot.generatedAt)
                > WidgetSharedConfiguration.staleSnapshotInterval
            let artworkLimit: Int
            switch family {
            case .systemSmall:
                artworkLimit = 1
            case .systemMedium:
                artworkLimit = 2
            case .systemLarge:
                artworkLimit = WidgetSnapshot.maximumDisplayEpisodeCount
            default:
                artworkLimit = 0
            }
            var artwork: [String: Data] = [:]
            for episode in snapshot.episodes.prefix(artworkLimit) {
                guard let filename = episode.thumbnailFilename,
                      let url = try? storage.thumbnailURL(filename: filename),
                      let byteCount = try? url.resourceValues(
                        forKeys: [.fileSizeKey]
                      ).fileSize,
                      byteCount <= WidgetSharedConfiguration.maximumThumbnailBytes,
                      let data = try? Data(
                        contentsOf: url,
                        options: [.mappedIfSafe]
                      )
                else { continue }
                artwork[filename] = data
            }
            return WidgetTimelineEntry(
                date: snapshot.generatedAt,
                snapshot: snapshot,
                artwork: artwork,
                state: isStale
                    ? .stale
                    : (snapshot.episodes.isEmpty ? .empty : .content)
            )
        } catch {
            try? storage.removeSnapshot()
            return WidgetTimelineEntry(
                date: .now,
                snapshot: nil,
                artwork: [:],
                state: .unavailable
            )
        }
    }
}

struct NowPlayingUpNextWidget: Widget {
    static let kind = WidgetSharedConfiguration.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: WidgetSnapshotProvider()
        ) { entry in
            WidgetSnapshotView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetContainerBackground()
                }
        }
        .configurationDisplayName("Now Playing & Up Next")
        .description("See what Autohop is playing and what is ready next.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

private struct WidgetContainerBackground: View {
    @Environment(\.widgetFamily) private var family

    @ViewBuilder
    var body: some View {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge:
            WidgetCharcoalGlassBackground()
        default:
            Color.clear
        }
    }
}

/// AI CONTEXT — Widget wallpaper varies, so Material alone cannot guarantee
/// contrast. This surface begins with opaque charcoal, then layers restrained
/// depth and glass above it. The result looks translucent without allowing
/// arbitrary wallpaper colours to compromise text legibility.
private struct WidgetCharcoalGlassBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.047, blue: 0.054)

            LinearGradient(
                colors: [
                    Color(red: 0.145, green: 0.15, blue: 0.17),
                    Color(red: 0.065, green: 0.067, blue: 0.077),
                    Color(red: 0.105, green: 0.088, blue: 0.115)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.88)

            RadialGradient(
                colors: [
                    Color.purple.opacity(0.17),
                    Color.purple.opacity(0.035),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 260
            )

            WidgetCharcoalTexture()

            LinearGradient(
                colors: [
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.015),
                    Color.black.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.screen)

            nativeGlassSheen

            ContainerRelativeShape()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.055),
                            Color.purple.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
    }

    @ViewBuilder
    private var nativeGlassSheen: some View {
        if #available(iOSApplicationExtension 26.0, *) {
            Color.white.opacity(0.018)
                .glassEffect(
                    .regular.tint(Color.white.opacity(0.035)),
                    in: ContainerRelativeShape()
                )
        } else {
            Color.white.opacity(0.015)
        }
    }
}

/// AI CONTEXT — Fixed modular coordinates provide subtle fibre/grain without
/// randomness, image assets, animation, or persistent state. Keep this bounded
/// and faint so texture never competes with artwork or episode metadata.
private struct WidgetCharcoalTexture: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<72 {
                let xUnit = CGFloat((index * 47 + 13) % 101) / 100
                let yUnit = CGFloat((index * 83 + 29) % 103) / 102
                let diameter = CGFloat(1 + (index % 3)) * 0.55
                let rect = CGRect(
                    x: xUnit * size.width,
                    y: yUnit * size.height,
                    width: diameter,
                    height: diameter
                )
                let colour = index.isMultiple(of: 4)
                    ? Color.black.opacity(0.22)
                    : Color.white.opacity(0.12)
                context.fill(Path(ellipseIn: rect), with: .color(colour))
            }

            for index in 0..<14 {
                let yUnit = CGFloat((index * 31 + 7) % 97) / 96
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yUnit * size.height))
                path.addLine(
                    to: CGPoint(
                        x: size.width,
                        y: min(size.height, yUnit * size.height + 0.7)
                    )
                )
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(0.025)),
                    lineWidth: 0.45
                )
            }
        }
        .blendMode(.softLight)
        .opacity(0.7)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WidgetSnapshotView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetTimelineEntry
    /// Explicit contrast token for Home Screen widgets. `.secondary` can resolve
    /// to a near-black system colour while the widget forces a black container,
    /// making duration/podcast metadata effectively disappear.
    private let homeMetadataColor = Color.white.opacity(0.64)

    var body: some View {
        switch family {
        case .systemSmall:
            homeScreenContent { smallContent }
        case .systemMedium:
            homeScreenContent { mediumContent }
        case .systemLarge:
            homeScreenContent { largeContent }
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        default:
            homeScreenContent { smallContent }
        }
    }

    @ViewBuilder
    private func homeScreenContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch entry.state {
        case .content, .placeholder:
            content()
        case .empty:
            Link(destination: WidgetDeepLink.discover) {
                recoveryState(
                    icon: "sparkles",
                    title: "Ready for something new?",
                    detail: "Open Discover in Autohop"
                )
            }
        case .stale:
            recoveryState(
                icon: "arrow.clockwise",
                title: "Widget needs refreshing",
                detail: "Open Autohop to update"
            )
        case .unavailable:
            recoveryState(
                icon: "waveform.badge.exclamationmark",
                title: "Autohop is unavailable",
                detail: "Open the app to reconnect"
            )
        }
    }

    private var smallContent: some View {
        let episode = visibleEpisodes.first
        return VStack(alignment: .leading, spacing: 7) {
            Link(destination: WidgetDeepLink.player) {
                squareArtwork(for: episode, size: 70)
                    .frame(maxWidth: .infinity)
            }
            episodeLink(episode) {
                Text(episode?.episodeTitle ?? "Ready to play")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                Text(remainingText(for: episode))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(homeMetadataColor)
                Spacer(minLength: 4)
                playbackControl(for: episode, size: 27)
            }
        }
    }

    private var mediumContent: some View {
        let episodes = visibleEpisodes
        let primary = episodes.first
        let following = episodes.dropFirst().first
        return HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                Link(destination: WidgetDeepLink.player) {
                    squareArtwork(for: primary, size: 68)
                }
                Text(primary?.isCurrent == true ? "NOW PLAYING" : "READY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.purple)
                episodeLink(primary) {
                    Text(primary?.episodeTitle ?? "Ready to play")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                HStack {
                    Text(remainingText(for: primary))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(homeMetadataColor)
                    Spacer()
                    playbackControl(for: primary, size: 25)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Color.white.opacity(0.14))

            VStack(alignment: .leading, spacing: 10) {
                Link(destination: WidgetDeepLink.upNext) {
                    Label(
                        upNextLabel,
                        systemImage: "square.stack.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                }
                if let following {
                    episodeRow(following, artworkSize: 38)
                } else {
                    Text("You’re all caught up")
                        .font(.caption)
                        .foregroundStyle(homeMetadataColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var largeContent: some View {
        let episodes = visibleEpisodes
        let primary = episodes.first
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Link(destination: WidgetDeepLink.player) {
                    squareArtwork(for: primary, size: 76)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(primary?.isCurrent == true ? "NOW PLAYING" : "READY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                    episodeLink(primary) {
                        Text(primary?.episodeTitle ?? "Ready to play")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    Text(primary?.podcastTitle ?? "Autohop")
                        .font(.caption)
                        .foregroundStyle(homeMetadataColor)
                        .lineLimit(1)
                    Text(remainingText(for: primary))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(homeMetadataColor)
                }
                Spacer(minLength: 4)
                playbackControl(for: primary, size: 40)
            }

            Divider().overlay(Color.white.opacity(0.14))

            Link(destination: WidgetDeepLink.upNext) {
                Label(upNextLabel, systemImage: "square.stack.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }

            ForEach(Array(episodes.dropFirst().prefix(4)), id: \.identity) {
                episode in
                episodeRow(episode, artworkSize: 38)
            }
            if episodes.count == 1 {
                Text("You’re all caught up")
                    .font(.caption)
                    .foregroundStyle(homeMetadataColor)
            }
        }
    }

    private var accessoryCircular: some View {
        Link(destination: WidgetDeepLink.upNext) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "square.stack.fill")
                        .font(.caption.weight(.semibold))
                        .widgetAccentable()
                    Text("\(entry.snapshot?.upNextTotalCount ?? 0)")
                        .font(.headline.monospacedDigit().weight(.bold))
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    private var accessoryRectangular: some View {
        Link(
            destination: accessoryEpisode.flatMap {
                WidgetDeepLink.episode($0.identity)
            } ?? WidgetDeepLink.upNext
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    accessoryEpisode?.isCurrent == true
                        ? "Now Playing"
                        : "Up Next",
                    systemImage: "waveform"
                )
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
                Group {
                    Text(accessoryEpisode?.episodeTitle ?? "Open Autohop")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(accessoryEpisode?.podcastTitle ?? "No episode ready")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .privacySensitive()
            }
        }
    }

    private var accessoryEpisode: WidgetDisplayEpisode? {
        guard entry.state == .content else { return nil }
        return visibleEpisodes.first
    }

    private var visibleEpisodes: [WidgetDisplayEpisode] {
        entry.snapshot?.episodes ?? []
    }

    private var upNextLabel: String {
        let count = entry.snapshot?.upNextTotalCount ?? 0
        return count == 1 ? "1 Up Next" : "\(count) Up Next"
    }

    private func artwork(
        for episode: WidgetDisplayEpisode?
    ) -> some View {
        Group {
            if let filename = episode?.thumbnailFilename,
               let data = entry.artwork[filename],
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.purple.opacity(0.72), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "waveform")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.11), lineWidth: 0.7)
        }
    }

    /// AI CONTEXT — Widget snapshots preserve source-image aspect ratios, and
    /// video feeds commonly publish 16:9 episode thumbnails. Apply the square
    /// frame and clipping at this outer boundary (after `scaledToFill`) so those
    /// thumbnails cannot paint beyond the intended podcast-artwork slot. Keeping
    /// this policy in one helper prevents each widget family from accidentally
    /// reintroducing rectangular video artwork through modifier-order changes.
    private func squareArtwork(
        for episode: WidgetDisplayEpisode?,
        size: CGFloat
    ) -> some View {
        artwork(for: episode)
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func episodeRow(
        _ episode: WidgetDisplayEpisode,
        artworkSize: CGFloat
    ) -> some View {
        HStack(spacing: 8) {
            squareArtwork(for: episode, size: artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                episodeLink(episode) {
                    Text(episode.episodeTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(remainingText(for: episode))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(homeMetadataColor)
            }
            Spacer(minLength: 3)
            playbackControl(for: episode, size: 24)
        }
    }

    @ViewBuilder
    private func playbackControl(
        for episode: WidgetDisplayEpisode?,
        size: CGFloat
    ) -> some View {
        if let episode {
            Toggle(
                isOn: episode.isCurrent && entry.snapshot?.isPlaying == true,
                intent: PlayAutohopEpisodeIntent(identity: episode.identity)
            ) {
                EmptyView()
            }
            .toggleStyle(WidgetPlaybackToggleStyle(size: size))
        } else {
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .modifier(WidgetPlaybackSurface())
        }
    }

    @ViewBuilder
    private func episodeLink<Content: View>(
        _ episode: WidgetDisplayEpisode?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let episode,
           let destination = WidgetDeepLink.episode(episode.identity) {
            Link(destination: destination, label: content)
        } else {
            content()
        }
    }

    private func remainingText(
        for episode: WidgetDisplayEpisode?
    ) -> String {
        guard let seconds = episode?.remainingSeconds
            ?? episode?.durationSeconds else {
            return "Downloaded"
        }
        let minutes = max(0, Int(seconds.rounded(.up))) / 60
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "\(hours) hr left"
            : "\(hours) hr \(remainder) min left"
    }

    private func recoveryState(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.purple)
            Spacer(minLength: 2)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(homeMetadataColor)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct WidgetPlaybackToggleStyle: ToggleStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Image(systemName: configuration.isOn ? "pause.fill" : "play.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .modifier(WidgetPlaybackSurface())
            .widgetAccentable()
    }
}

/// AI CONTEXT — Keep this surface independent of `.glassEffect`. In an ordinary
/// SwiftUI hierarchy native glass is visual only, but the WidgetKit host may
/// extract App Intent Toggle labels into a separate rendering layer. Applying
/// `.glassEffect` directly to that label caused the complete play/pause control
/// to disappear on-device. This deterministic gradient, highlight, border, and
/// shadow retain the glass appearance while keeping the intent label visible.
private struct WidgetPlaybackSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.91, green: 0.10, blue: 0.96),
                        Color(red: 0.62, green: 0.08, blue: 0.76)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.purple.opacity(0.24), radius: 3, y: 1)
    }
}

#if DEBUG
#Preview("Small", as: .systemSmall) {
    NowPlayingUpNextWidget()
} timeline: {
    WidgetTimelineEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    NowPlayingUpNextWidget()
} timeline: {
    WidgetTimelineEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    NowPlayingUpNextWidget()
} timeline: {
    WidgetTimelineEntry.placeholder
}
#endif
