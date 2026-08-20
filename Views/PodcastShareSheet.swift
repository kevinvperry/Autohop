import SwiftUI
import UIKit

// AI CONTEXT — Views/PodcastShareSheet.swift
// Honest podcast-level share surface used by Podcast Detail and Podcast
// Settings. The first safe-sharing increment deliberately exports a branded
// podcast card plus descriptive text only: Subscription currently has no
// separately parsed publisher homepage and its feedURL may be private. Never
// substitute newestEpisode and never expose feedURL. A later sharing stage can
// add a validated channel webpage without changing these call sites. The shared
// ApplePodcastsReviewButton is iOS-family UI: it opens the verified Apple
// Podcasts show page (Apple has no supported direct review-composer URL) and
// tells the listener where the Ratings & Reviews control lives.

struct ApplePodcastsReviewButton: View {
    @Environment(\.openURL) private var openURL

    let showTitle: String
    let feedURL: URL
    var knownApplePodcastID: Int? = nil

    @State private var isResolving = false
    @State private var resolutionFailed = false

    var body: some View {
        Button {
            openReviewPage()
        } label: {
            HStack(spacing: 9) {
                if isResolving {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: "star.bubble")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isResolving ? "Finding Podcast…" : "Review in Apple Podcasts")
                        .font(.system(size: 16, weight: .bold))
                    Text(resolutionFailed ? "This show wasn't found in Apple Podcasts" : "Open the show, then scroll to Ratings & Reviews")
                        .font(.caption)
                        .foregroundStyle(resolutionFailed ? Color.orange : Color.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .accessibilityHint("Opens this show's page in Apple Podcasts; scroll to Ratings and Reviews to write a review")
    }

    private func openReviewPage() {
        isResolving = true
        resolutionFailed = false
        Task {
            let url = await ApplePodcastsReviewResolver.shared.reviewURL(
                showTitle: showTitle,
                feedURL: feedURL,
                knownApplePodcastID: knownApplePodcastID,
                countryCode: Locale.current.region?.identifier
            )
            await MainActor.run {
                isResolving = false
                guard let url else {
                    resolutionFailed = true
                    return
                }
                openURL(url)
            }
        }
    }
}

struct PodcastShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let subscription: Subscription

    @State private var artworkImage: UIImage?
    @State private var isSharing = false
    @State private var shareItems: [Any] = []
    @State private var showActivitySheet = false

    private var subtitle: String {
        let author = subscription.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        return author?.isEmpty == false ? author! : "Podcast"
    }

    private var details: String {
        var lines = [subscription.title]
        if subtitle != "Podcast" { lines.append(subtitle) }
        if let description = subscription.description?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            lines.append(String(description.prefix(500)))
        }
        lines.append("Shared from Autohop")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Capsule()
                    .fill(Color(white: 0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)

                EpisodeShareCardView(
                    episodeTitle: subscription.title,
                    podcastName: subtitle,
                    artworkImage: artworkImage,
                    publishedDate: nil
                )
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)

                Label(
                    "This shares the podcast itself—not its newest episode. A public publisher link will be added when the feed supplies one that Autohop can verify safely.",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 20)

                Button {
                    Task { await prepareAndShare() }
                } label: {
                    HStack(spacing: 9) {
                        if isSharing {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(isSharing ? "Preparing…" : "Share Podcast")
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

                ApplePodcastsReviewButton(
                    showTitle: subscription.title,
                    feedURL: subscription.feedURL
                )
                .padding(.horizontal, 20)

                Button("Cancel") { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .presentationBackground(.regularMaterial)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
        .task { await loadArtwork() }
        .sheet(isPresented: $showActivitySheet) {
            ActivitySheet(items: shareItems).ignoresSafeArea()
        }
    }

    private func loadArtwork() async {
        guard let url = subscription.artworkURL else { return }
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

        let renderer = ImageRenderer(content: EpisodeShareCardView(
            episodeTitle: subscription.title,
            podcastName: subtitle,
            artworkImage: artworkImage,
            publishedDate: nil
        ))
        renderer.scale = 3
        var items: [Any] = []
        if let image = renderer.uiImage { items.append(image) }
        items.append(details)
        shareItems = items
        showActivitySheet = true
    }
}
