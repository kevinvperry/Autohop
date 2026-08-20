import SwiftUI
import UIKit
import LinkPresentation

// AI CONTEXT — Views/EpisodeShareSheet.swift ("Episode Share" sheet, from the
// Player's audio row). Previews the rendered EpisodeShareCardView image, then
// exports the card image plus a SAFE publisher-facing link through
// UIActivityViewController. ShareURLResolver prefers Episode.episodeLink then a
// validated HTTP(S) GUID; it deliberately cannot accept the media enclosure or
// feed URL. When no safe page exists the sheet explains that clearly and shares
// card + episode details only. Share-card artwork is
// fetched through ArtworkImageCache at the rendered card-art size so sharing
// reuses validated disk source bytes and avoids full-size cover decodes.
// When the RSS show can be matched exactly in Apple's directory, the same sheet
// also offers the iOS-family-only Review in Apple Podcasts action.

// MARK: - Episode share sheet

/// Bottom sheet that previews the share card, then exports it via the
/// system share sheet together with a safe publisher page when available.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showShareSheet) {
///     if let ep = episode, let sub = subscription {
///         EpisodeShareSheet(episode: ep, subscription: sub)
///     }
/// }
/// ```
struct EpisodeShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let episode: Episode
    let subscription: Subscription?

    // Derived helpers
    private var podcastName: String {
        subscription?.title ?? episode.author ?? "Unknown Podcast"
    }
    private var artworkURL: URL? {
        subscription?.artworkURL ?? episode.artworkURL
    }
    private var resolvedLink: ResolvedShareLink? {
        ShareURLResolver.episodeLink(
            episodePage: episode.episodeLink,
            guid: episode.guid
        )
    }
    private var episodeDetails: String {
        var lines = [episode.title, podcastName]
        if let publishedAt = episode.publishedAt {
            lines.append(publishedAt.formatted(date: .long, time: .omitted))
        }
        if let url = resolvedLink?.url {
            lines.append(url.absoluteString)
        }
        lines.append("Shared from Autohop")
        return lines.joined(separator: "\n")
    }

    // State
    @State private var artworkImage: UIImage?
    @State private var isSharing = false
    @State private var shareItems: [Any] = []
    @State private var showActivitySheet = false
    @State private var didCopyLink = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            // Card preview
            EpisodeShareCardView(
                episodeTitle: episode.title,
                podcastName: podcastName,
                artworkImage: artworkImage,
                publishedDate: episode.publishedAt
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)

                Spacer(minLength: 24)

                if resolvedLink == nil {
                    Label(
                        "No safe public episode link is available. Autohop will share the card and episode details without exposing the media download.",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }

            // Share button
            Button {
                Task { await prepareAndShare() }
            } label: {
                HStack(spacing: 9) {
                    if isSharing {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(isSharing ? "Preparing…" : "Share Episode")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.purple.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isSharing)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

                if let url = resolvedLink?.url {
                    Button {
                        UIPasteboard.general.url = url
                        didCopyLink = true
                    } label: {
                        Label(didCopyLink ? "Link Copied" : "Copy Link", systemImage: didCopyLink ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassCard(cornerRadius: 14)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityHint("Copies the public episode page, not the media download")
                }

                if let subscription {
                    ApplePodcastsReviewButton(
                        showTitle: subscription.title,
                        feedURL: subscription.feedURL
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

            // Cancel
            Button { dismiss() } label: {
                let inner = Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                if #available(iOS 26, *) {
                    inner.glassCard(cornerRadius: 14)
                } else {
                    inner
                        .background(Color(white: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

                Spacer(minLength: 20)
            }
        }
        .presentationBackground(.regularMaterial)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
        .task { await loadArtwork() }
        .sheet(isPresented: $showActivitySheet) {
            ActivitySheet(items: shareItems)
                .ignoresSafeArea()
        }
    }

    // MARK: - Private

    private func loadArtwork() async {
        guard let url = artworkURL else { return }
        artworkImage = await ArtworkImageCache.shared.image(
            for: url,
            targetSize: CGSize(width: 176, height: 176),
            scale: 3
        )
    }

    @MainActor
    private func prepareAndShare() async {
        isSharing = true
        defer { isSharing = false }

        // Render share card to UIImage at 3× resolution
        let card = EpisodeShareCardView(
            episodeTitle: episode.title,
            podcastName: podcastName,
            artworkImage: artworkImage,
            publishedDate: episode.publishedAt
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0

        let cardImage = renderer.uiImage

        var items: [Any] = []
        if let cardImage {
            items.append(cardImage)
        }
        if let url = resolvedLink?.url {
            // A safe page is wrapped in Link Presentation metadata. The media
            // enclosure never reaches this path.
            items.append(
                EpisodeLinkItemSource(
                    url: url,
                    title: "\(episode.title) — \(podcastName)",
                    image: cardImage
                )
            )
        } else {
            items.append(episodeDetails)
        }

        shareItems = items
        showActivitySheet = true
    }
}

// MARK: - Rich link item source

/// Supplies the share payload as a URL while providing `LPLinkMetadata` so the
/// share-sheet preview (and delivered message) shows the episode's card image
/// and title rather than a raw link.
private final class EpisodeLinkItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String
    private let image: UIImage?

    init(url: URL, title: String, image: UIImage?) {
        self.url = url
        self.title = title
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }

    func activityViewControllerLinkMetadata(
        _ controller: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let image {
            metadata.imageProvider = NSItemProvider(object: image)
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}

// MARK: - UIActivityViewController wrapper

/// Shared UIKit destination picker used by episode and podcast share surfaces.
/// Keep `[Any]` confined to this final adapter boundary.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
