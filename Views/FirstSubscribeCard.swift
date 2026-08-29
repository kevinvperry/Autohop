import SwiftUI

// AI CONTEXT — Views/FirstSubscribeCard.swift ("You're all set" card).
// The first-run "aha" moment (ONBOARDING_PLAN.md Phase 3). Presented as a sheet
// by RootView when `.autohopFirstSubscription` fires — i.e. the user's first
// ever deliberate single subscribe (bulk OPML import is excluded). It ensures
// the show's latest episode is downloading and turns Play into one irresistible
// tap: if the file isn't ready yet, tapping Play arms a wait and playback starts
// the instant the download lands — no autoplay ambush, just a cued first listen.
// Looks the subscription/episode up live from the store each render so download
// progress and the downloaded transition drive the UI reactively. As a dedicated
// onboarding card it uses the same high-contrast white/black language and
// prominent 48-point close control as coach marks and the Getting Started card.
struct FirstSubscribeCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    /// Progress ticks publish on this dedicated model (not AppState) — reading
    /// appState.downloadProgress in body would render stale.
    @EnvironmentObject private var downloadProgressModel: DownloadProgressModel
    @Environment(\.dismiss) private var dismiss
    let subscriptionID: UUID

    @State private var waitingToPlay = false
    @State private var didStartDownload = false
    @State private var showDownloadNote = false

    private var pageBackground: Color {
        .white
    }

    private var subscription: Subscription? {
        subscriptionStore.subscription(id: subscriptionID)
    }
    private var latestEpisode: Episode? { subscription?.newestEpisode }
    private var isDownloaded: Bool { latestEpisode?.downloadState == .downloaded }
    private var progress: Double? {
        guard let id = latestEpisode?.id else { return nil }
        return downloadProgressModel.progress[id]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            HStack {
                Text("FIRST SUBSCRIPTION")
                    .font(.caption.weight(.black))
                    .tracking(1.2)
                    .foregroundStyle(.black.opacity(0.62))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close first subscription card")
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)

            CachedArtworkImage(url: subscription?.artworkURL, targetSize: CGSize(width: 96, height: 96)) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.08))
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.purple.opacity(0.7))
                    )
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 18)

            Text("You're all set 🎧")
                .font(.title2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.bottom, 8)

            Text("Autohop is downloading the latest episode of \(subscription?.title ?? "your show"). When it's ready it'll start Up Next — no tapping play, episode after episode.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.black.opacity(0.68))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

            downloadStatusRow
                .padding(.horizontal, 24)
                .padding(.bottom, showDownloadNote && !isDownloaded ? 10 : 22)

            if showDownloadNote && !isDownloaded {
                Text("Autohop downloads episodes before playing, so they start instantly and work offline — even with no signal.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }

            VStack(spacing: 10) {
                Button(action: playTapped) {
                    Text(playButtonTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Color.black))
                }
                .buttonStyle(.plain)

                Button {
                    // Just dismiss — the user subscribed from within the browse
                    // flow (Discover / Podcast Detail), so closing the card returns
                    // them there to keep adding shows. Avoids pushing a duplicate
                    // Discover onto the stack.
                    dismiss()
                } label: {
                    Text("Add more shows")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)
            }
            .adaptiveContentWidth(.form)
        }
        .background(pageBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear(perform: handleAppear)
        .onChange(of: isDownloaded) { _, downloaded in
            if downloaded && waitingToPlay { playLatest() }
        }
    }

    // MARK: - Status row

    @ViewBuilder
    private var downloadStatusRow: some View {
        let content = HStack(spacing: 10) {
            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready to play")
                    .foregroundStyle(.black.opacity(0.8))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.black)
                Text(progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Starting download…")
                    .foregroundStyle(.black.opacity(0.8))
            }
            Spacer()
        }
        .font(.subheadline.weight(.semibold))
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        content.background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.16), lineWidth: 1))
        )
    }

    private var playButtonTitle: String {
        if isDownloaded { return "Play latest" }
        if waitingToPlay { return "Downloading… we'll start the moment it's ready" }
        return "Play latest"
    }

    // MARK: - Actions

    private func handleAppear() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // One-time download-first education note (Phase 4a). Capture-then-flip so
        // it shows on this first download only.
        if !settingsViewModel.appSettings.hasSeenDownloadFirstNote {
            showDownloadNote = true
            settingsViewModel.appSettings.hasSeenDownloadFirstNote = true
        }
        // Ensure the latest episode is actually downloading (idempotent — the
        // download path guards against re-downloading an in-flight/finished file).
        guard !didStartDownload, !isDownloaded, let subscription else { return }
        didStartDownload = true
        Task { await appState.downloadLatestEpisode(for: subscription) }
    }

    private func playTapped() {
        if isDownloaded {
            playLatest()
        } else {
            // Arm: auto-start the instant the download completes.
            waitingToPlay = true
        }
    }

    private func playLatest() {
        guard let episode = latestEpisode else { return }
        Task {
            await appState.playEpisode(episode)
            dismiss()
            NotificationCenter.default.post(name: .autohopReturnToPlayer, object: nil)
        }
    }
}
