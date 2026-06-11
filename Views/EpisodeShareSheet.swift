import SwiftUI
import UIKit

// AI CONTEXT — Views/EpisodeShareSheet.swift ("Episode Share" sheet, from the
// Player's audio row). Previews the rendered EpisodeShareCardView image, then
// exports image + episode audio URL through UIActivityViewController.

// MARK: - Episode share sheet

/// Bottom sheet that previews the share card, then exports it via the
/// system share sheet together with the episode's audio URL.
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

    // State
    @State private var artworkImage: UIImage?
    @State private var isSharing = false
    @State private var shareItems: [Any] = []
    @State private var showActivitySheet = false

    var body: some View {
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

            // Cancel
            Button { dismiss() } label: {
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

            Spacer(minLength: 20)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
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
        artworkImage = await ArtworkImageCache.shared.image(for: url)
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

        var items: [Any] = []
        if let cardImage = renderer.uiImage {
            items.append(cardImage)
        }
        // Tier 1: audio URL so recipients see something useful even without the image
        items.append(episode.audioURL)

        shareItems = items
        showActivitySheet = true
    }
}

// MARK: - UIActivityViewController wrapper

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
