import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - Root player

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedPanel = 0
    @State private var showMenu = false
    @State private var showQueue = false
    @State private var sliderValue: Double = 0
    @State private var isSeeking = false
    @State private var showAudioControlMenu = false
    @State private var showSleepTimer = false
    @State private var showArchiveConfirmation = false
    @State private var showShareSheet = false
    @State private var showFullScreenVideo = false
    @State private var pictureInPictureStartToken = 0
    @State private var isPlayerVisible = false
    @State private var audioRouteName = PlayerView.currentAudioRouteName()

    private var episode: Episode? { appState.currentPlayerEpisode }
    private var isVideoEpisode: Bool { episode?.mediaKind == .video && appState.currentVideoPlayer != nil }
    private var visiblePanels: [PlayerPanel] {
        appState.currentEpisodeSupportsChapters ? PlayerPanel.allCases : [.nowPlaying, .details]
    }

    // Show queue[1] when queue[0] is already playing (avoids duplication), otherwise show queue[0].
    private var playerPageUpNext: Episode? {
        let queue = appState.downloadedQueue
        guard !queue.isEmpty else { return nil }
        if let current = appState.currentPlayerEpisode, queue.first?.id == current.id {
            return queue.count > 1 ? queue[1] : nil
        }
        return queue.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                TabView(selection: $selectedPanel) {
                    nowPlayingPanel.tag(PlayerPanel.nowPlaying.rawValue)
                    detailsPanel.tag(PlayerPanel.details.rawValue)
                    if appState.currentEpisodeSupportsChapters {
                        chaptersPanel.tag(PlayerPanel.chapters.rawValue)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: appState.currentPlayerTime) { _, time in
            if !isSeeking { sliderValue = time }
        }
        .onAppear {
            isPlayerVisible = true
            appState.updateIdleTimer(playerVisible: true)
        }
        .onDisappear {
            isPlayerVisible = false
            appState.updateIdleTimer(playerVisible: false)
        }
        .onChange(of: appState.isPlaying) { _, _ in
            appState.updateIdleTimer(playerVisible: isPlayerVisible)
        }
        .onChange(of: appState.settingsStore.appSettings.keepScreenAwakeDuringPlayback) { _, _ in
            appState.updateIdleTimer(playerVisible: isPlayerVisible)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            audioRouteName = Self.currentAudioRouteName()
        }
        .onChange(of: appState.currentEpisodeSupportsChapters) { _, supportsChapters in
            if !supportsChapters && selectedPanel == PlayerPanel.chapters.rawValue {
                selectedPanel = PlayerPanel.nowPlaying.rawValue
            }
        }
        .sheet(isPresented: $showMenu) { MenuSheetView() }
        .sheet(isPresented: $showQueue) { QueueSheetView() }
        .background {
            if isVideoEpisode, let videoPlayer = appState.currentVideoPlayer {
                VideoPictureInPictureHost(player: videoPlayer, startToken: pictureInPictureStartToken)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
        }
        .fullScreenCover(isPresented: $showFullScreenVideo) {
            if let videoPlayer = appState.currentVideoPlayer {
                ZStack(alignment: .topLeading) {
                    NativeVideoPlayerView(player: videoPlayer)
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
                    .padding(.top, 18)
                    .padding(.leading, 18)
                }
                .background(Color.black.ignoresSafeArea())
                .onAppear {
                    VideoOrientationController.allowVideoOrientations()
                    videoPlayer.play()
                }
                .onDisappear {
                    VideoOrientationController.restorePortrait()
                }
            }
        }
        .sheet(isPresented: $showAudioControlMenu) {
            AudioControlsSheetView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerSheetView(sleepTimer: appState.sleepTimerService)
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
                let sub = appState.subscriptionStore.subscription(id: ep.subscriptionID)
                EpisodeShareSheet(episode: ep, subscription: sub)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            NavigationLink(value: AppRoute.podcasts) {
                Image(systemName: "list.number")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            HStack(spacing: 2) {
                ForEach(visiblePanels) { panel in
                    Button(panel.title) {
                        withAnimation(.easeInOut(duration: 0.22)) { selectedPanel = panel.rawValue }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selectedPanel == panel.rawValue ? .white : Color(white: 0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedPanel == panel.rawValue ? Color(white: 0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            Spacer()

            Button { showQueue = true } label: {
                Text("\(appState.downloadedQueue.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(white: 0.18), lineWidth: 0.5))
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

    private var nowPlayingPanel: some View {
        GeometryReader { geo in
            let hasChapters = !appState.activeChapters.isEmpty
            let upNext = playerPageUpNext

            let reserved      = nowPlayingReservedHeight(hasChapters: hasChapters, hasUpNext: upNext != nil)
            let maxFromWidth  = geo.size.width - 44   // 22pt padding each side
            let maxFromHeight = geo.size.height - reserved
            let artworkSize   = max(80, min(maxFromWidth, maxFromHeight))
            let cornerRadius: CGFloat = hasChapters ? 18 : 20
            let isVideo = episode?.mediaKind == .video && appState.currentVideoPlayer != nil
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
        }
    }

    // MARK: - Artwork

    private var artworkURL: URL? {
        episode.flatMap { appState.subscriptionStore.subscription(id: $0.subscriptionID)?.artworkURL }
            ?? episode?.artworkURL
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
                if episode?.mediaKind == .video, let videoPlayer = appState.currentVideoPlayer {
                    ZStack(alignment: .bottomTrailing) {
                        VideoPlayer(player: videoPlayer)
                            .background(Color.black)
                        videoOverlayControls
                            .padding(12)
                    }
                } else {
                    CachedArtworkImage(url: artworkURL) {
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

    // MARK: - Chapter strip

    private var chapterStripView: some View {
        let active = appState.activeChapters
        let current = appState.currentChapter
        let activeIdx = active.firstIndex(where: { $0.position == current?.position }) ?? 0

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
            .disabled(activeIdx <= 0)

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { selectedPanel = 2 }
            } label: {
                VStack(spacing: 2) {
                    Text(current?.title ?? active.first?.title ?? "")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text("Chapter \(activeIdx + 1) of \(active.count)")
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
            .disabled(activeIdx >= active.count - 1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
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

                if let sub = appState.subscriptionStore.subscription(id: ep.subscriptionID) {
                    NavigationLink {
                        SubscriptionEpisodesView(subscriptionID: sub.id)
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

                Text(appState.nextPlayableEpisode != nil ? "Tap play to start" : "Add a feed and download an episode")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.33))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Scrubber

    private var scrubberView: some View {
        let total = max(1, episode?.durationSeconds ?? 0)
        let rawDisplayTime = isSeeking ? sliderValue : appState.currentPlayerTime
        let displayTime = min(max(0, rawDisplayTime), total)
        let remainingTime = max(0, total - displayTime)

        return VStack(spacing: 6) {
            Slider(
                value: $sliderValue,
                in: 0...total,
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        let target = min(max(0, sliderValue), total)
                        sliderValue = target
                        appState.seek(to: target)
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

    // MARK: - Controls

    private var controlsView: some View {
        HStack(alignment: .center) {
            Button {
                let skip = appState.settingsStore.appSettings.skipBackSeconds
                let target = max(0, appState.currentPlayerTime - skip)
                sliderValue = target
                appState.seek(to: target)
            } label: {
                SkipIntervalIcon(direction: .backward, seconds: appState.settingsStore.appSettings.skipBackSeconds)
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await appState.togglePlayPause() }
            } label: {
                Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Color.purple)
                    .clipShape(Circle())
                    .shadow(color: Color.purple.opacity(0.35), radius: 14)
            }
            .disabled(appState.currentPlayerEpisode == nil && appState.nextPlayableEpisode == nil)

            Button {
                guard let dur = appState.currentPlayerEpisode?.durationSeconds else { return }
                let skip = appState.settingsStore.appSettings.skipForwardSeconds
                if appState.currentPlayerTime + skip >= dur {
                    // Overshoot — advance to next episode rather than clamping to the end.
                    // Exclude the current episode so playNextEpisode doesn't restore it.
                    let currentID = appState.currentPlayerEpisode?.id
                    Task { await appState.playNextEpisode(excluding: currentID.map { [$0] } ?? []) }
                } else {
                    let target = appState.currentPlayerTime + skip
                    sliderValue = target
                    appState.seek(to: target)
                }
            } label: {
                SkipIntervalIcon(direction: .forward, seconds: appState.settingsStore.appSettings.skipForwardSeconds)
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
                    playerActionIcon("slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .disabled(episode == nil)

                Button {
                    showSleepTimer = true
                } label: {
                    sleepTimerButtonLabel
                }
                .buttonStyle(.plain)
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

                Button {
                    showArchiveConfirmation = true
                } label: {
                    playerActionIcon("archivebox")
                }
                .buttonStyle(.plain)
                .disabled(episode == nil)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func playerActionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color.purple.opacity(0.85))
            .frame(width: 44, height: 32)
            .background(Color.purple.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.purple.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder
    private var sleepTimerButtonLabel: some View {
        let timer = appState.sleepTimerService
        ZStack(alignment: .topTrailing) {
            Image(systemName: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(timer.isActive ? Color.white : Color.purple.opacity(0.85))
                .frame(width: 44, height: 32)
                .background(Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.purple.opacity(0.3), lineWidth: 0.5))

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
        let remaining = appState.sleepTimerService.timeRemaining
        guard remaining >= 0 else { return nil }
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
            HStack(spacing: 7) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.purple.opacity(0.9))

                Text(audioRouteName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            // The system route picker owns the tap target and opens AirPlay/audio output.
            AudioRoutePickerView(tintColor: .clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.02)
        }
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 30)
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
                        CachedArtworkImage(url: url) {
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
                            showsFirstImage: false
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }

                    let sub = appState.subscriptionStore.subscription(id: ep.subscriptionID)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if let date = ep.publishedAt {
                            metaCard("Published", date.formatted(date: .abbreviated, time: .omitted))
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            } else {
                ContentUnavailableView("No Episode Playing", systemImage: "waveform")
                    .padding(.top, 60)
            }
        }
    }

    private func metaCard(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
    }

    private func detailsArtworkURL(for episode: Episode) -> URL? {
        appState.subscriptionStore.subscription(id: episode.subscriptionID)?.artworkURL
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
        let ep = appState.episodeForChapters
        let sub = ep.flatMap { appState.subscriptionStore.subscription(id: $0.subscriptionID) }
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
                            for ch in chapters where sub.chapterFilter.skippedPositions.contains(ch.position) {
                                appState.subscriptionStore.toggleChapter(subscriptionID: sub.id, position: ch.position)
                            }
                        }
                        Button("None") {
                            let currentPos = appState.currentChapter?.position
                            for ch in chapters where ch.position != currentPos && !sub.chapterFilter.skippedPositions.contains(ch.position) {
                                appState.subscriptionStore.toggleChapter(subscriptionID: sub.id, position: ch.position)
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.purple.opacity(0.8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider().background(Color.white.opacity(0.075))

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
                }
            }
        }
    }

    private func chapterRow(chapter: Chapter, subscription: Subscription?) -> some View {
        let isSkipped = subscription?.chapterFilter.skippedPositions.contains(chapter.position) ?? false
        let isCurrentlyPlaying = appState.currentChapter?.position == chapter.position && appState.currentPlayerEpisode != nil

        return Button {
            appState.seek(to: chapter.startSeconds)
        } label: {
            HStack(spacing: 11) {
                Button {
                    guard let sub = subscription else { return }
                    appState.subscriptionStore.toggleChapter(subscriptionID: sub.id, position: chapter.position)
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
            .padding(.horizontal, 20)
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
        let s = max(0, Int(seconds))
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
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatDurationLong(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
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

    init(
        html: String,
        fontSize: CGFloat,
        color: Color,
        linkColor: Color = .purple,
        showsFirstImage: Bool = true
    ) {
        self.html = html
        self.fontSize = fontSize
        self.color = color
        self.linkColor = linkColor
        self.showsFirstImage = showsFirstImage
    }

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

            if let attributedText = Self.attributedText(from: html) {
                Text(attributedText)
                    .font(.system(size: fontSize))
                    .lineSpacing(5)
                    .foregroundStyle(color)
                    .tint(linkColor)
                    .textSelection(.enabled)
            }
        }
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

    private static func attributedText(from html: String, fontSize: CGFloat = 15) -> AttributedString? {
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
            nsAttributed.addAttribute(.font, value: newFont, range: range)
        }

        // 3. Re-colour links to purple.
        nsAttributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            nsAttributed.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: range)
            nsAttributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }

        let string = nsAttributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        return try? AttributedString(nsAttributed, including: \.uiKit)
    }

    private static func plainText(from html: String) -> String {
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
// conflicts. Custom drag is used instead, matching the Queue page interaction model.

private struct UpNextRow: View {
    @EnvironmentObject private var appState: AppState
    let episode: Episode

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false

    private let actionWidth: CGFloat = 80
    private let openThreshold: CGFloat = 40
    private let cornerRadius: CGFloat = 14
    private var spring: Animation { .spring(response: 0.3, dampingFraction: 0.75) }

    var body: some View {
        let sub = appState.subscriptionStore.subscription(id: episode.subscriptionID)

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
        HStack(spacing: 12) {
            // Position indicator — arrow.forward (user-confirmed)
            Image(systemName: "arrow.forward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.purple)
                .frame(width: 20)

            // Artwork column — 44×44 image + badges centred below
            VStack(alignment: .center, spacing: 4) {
                CachedArtworkImage(url: sub?.artworkURL) {
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
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9))

            }

            // Text stack (Text-PodcastTitle / Text-EpisodeTitle / Text-MetadataRow)
            VStack(alignment: .leading, spacing: 2) {
                Text(sub?.title ?? "Unknown Podcast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(episode.title)
                        .font(.subheadline.bold())
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
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.075), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if episode.mediaKind == .video || episode.isExplicit == true {
                HStack(spacing: 3) {
                    if episode.mediaKind == .video { VideoBadge() }
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
        let s = Int(seconds)
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
        ZStack {
            Image(systemName: direction == .backward ? "gobackward" : "goforward")
                .font(.system(size: 36, weight: .regular))

            Text("\(Int(seconds))")
                .font(.system(size: textSize, weight: .medium, design: .rounded))
                .monospacedDigit()
                .offset(y: 3)
        }
        .frame(width: 64, height: 64)
        .foregroundStyle(Color(white: 0.9))
        .accessibilityLabel(
            direction == .backward
                ? "Skip back \(Int(seconds)) seconds"
                : "Skip forward \(Int(seconds)) seconds"
        )
    }

    private var textSize: CGFloat {
        Int(seconds) >= 100 ? 12 : 15
    }
}

// MARK: - Archive Confirmation Sheet

private struct ArchiveConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
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
        .background(Color(red: 0.10, green: 0.10, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }
}

// MARK: - Audio Controls Sheet

struct AudioControlsSheetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var episode: Episode? { appState.currentPlayerEpisode }
    private var subscription: Subscription? {
        episode.flatMap { appState.subscriptionStore.subscription(id: $0.subscriptionID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            speedRow

            rowDivider

            trimSilenceRow

            rowDivider

            vocalBoostRow

            Spacer(minLength: 24)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }

    private var trimSilenceOn: Bool { subscription?.playbackPreference.trimSilence != .off }
    private var vocalBoostOn: Bool { subscription?.playbackPreference.vocalBoostLevel != .off }

    private var sheetHeight: CGFloat {
        var height: CGFloat = 300           // base: speed + trim header + vocal header
        if trimSilenceOn { height += 68 }   // trim silence segmented picker
        if vocalBoostOn  { height += 68 }   // vocal boost segmented picker
        return height
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
            .background(Color(white: 0.20))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .background(Color(white: 0.20))
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
        case .nowPlaying: return "Now Playing"
        case .details: return "Details"
        case .chapters: return "Chapters"
        }
    }
}
