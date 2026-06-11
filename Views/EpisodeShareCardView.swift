import SwiftUI
import UIKit

// AI CONTEXT — Views/EpisodeShareCardView.swift. Fixed-size share card
// (artwork, episode title, podcast name, Autohop branding) rendered to a
// UIImage via ImageRenderer by EpisodeShareSheet. Artwork is passed as a
// pre-fetched UIImage so rendering is synchronous.

// MARK: - Share card

/// A self-contained share card rendered at a fixed size.
/// Pass a pre-fetched `UIImage?` for the artwork so the view renders
/// synchronously inside `ImageRenderer` without async load delays.
struct EpisodeShareCardView: View {
    let episodeTitle: String
    let podcastName: String
    let artworkImage: UIImage?
    let publishedDate: Date?

    // Fixed dimensions — exported at 3× scale = 840×1080 px
    static let cardWidth: CGFloat  = 280
    static let cardHeight: CGFloat = 360

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.08, blue: 0.18),
                    Color(red: 0.06, green: 0.06, blue: 0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Purple glow centred behind artwork
            RadialGradient(
                colors: [Color.purple.opacity(0.26), .clear],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 0,
                endRadius: 160
            )

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                // Artwork
                artworkView
                    .frame(width: 176, height: 176)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 14, y: 8)

                Spacer(minLength: 16)

                // Episode title
                Text(episodeTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 20)

                Spacer(minLength: 5)

                // Podcast name
                Text(podcastName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.50))
                    .lineLimit(1)
                    .padding(.horizontal, 20)

                Spacer(minLength: 18)

                // Footer: date + branding
                HStack(alignment: .center) {
                    if let date = publishedDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.28))
                    }

                    Spacer()

                    autohopPill
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var artworkView: some View {
        if let img = artworkImage {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(white: 0.10)
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.purple.opacity(0.45))
            }
        }
    }

    private var autohopPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 8, weight: .bold))
            Text("Autohop")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(Color.purple.opacity(0.9))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.purple.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.purple.opacity(0.28), lineWidth: 0.5))
    }
}
