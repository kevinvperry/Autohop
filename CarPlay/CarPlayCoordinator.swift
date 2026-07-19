import CarPlay
import Combine
import Foundation
import UIKit

// ============================================================================
// AI CONTEXT - CarPlay/CarPlayCoordinator.swift
//
// PURPOSE: Coordinator for Autohop's CarPlay scene. It owns the
// CPInterfaceController reference while CarPlay is connected, installs a safe
// root template immediately, runs launch readiness for CarPlay-only starts, and
// projects shared domain coordinators into read-only CarPlay templates while
// retaining AppState only as the high-level command façade.
//
// CURRENT SCOPE: Real-hardware CarPlay adapter. The coordinator renders Now
// Playing, Up Next, Subscriptions, subscription episode lists, download progress,
// and empty states from the shared stores/coordinators. It observes those
// domain owners directly (plus SettingsStore for Shared Listening and speed)
// instead of subscribing to AppState's broad compatibility publisher, and
// delegates behavior decisions to
// CarPlayActionRouter so Play/Play Next/Archive/speed/Shared Listening paths can
// be tested without a live CarPlay runtime. Dialog-style templates always include
// a visible Cancel action; pushed list pages rely on the native Back button only.
// CarPlay-only cold launches use AppState.sharedOrBootstrap() so selecting
// Autohop in CarPlay after the iPhone app was swiped closed still creates the
// shared queue/playback model before templates are rendered. Never switch to
// CPNowPlayingTemplate unless current metadata can be projected; otherwise
// CarPlay shows Apple's blank player shell.
// Connecting CarPlay must not activate audio by itself, refresh feeds, search,
// browse, or create any separate CarPlay queue/playback/settings state. Driver-
// confirmed manual downloads are allowed only from subscription episode Play
// Now/Next/Last actions, and they route through AppState's existing download
// path. The CarPlay Up Next list remains labelled to match the iPhone sheet,
// while internal queue model names still refer to AppState.downloadedQueue.
// Subscriptions are exposed as a CarPlay-safe browser over real subscribed
// podcasts; episode rows can include not-yet-downloaded episodes. Loading,
// downloading, and empty lists use CPListTemplate's native empty-view APIs
// instead of fake disabled rows. All CarPlay navigation operations log rejected
// templates so real-hardware failures leave a diagnostic trail.
//
// TEMPLATE STACK COUNT:
//  - Loading: CPListTemplate root only (depth 1).
//  - No current episode: Up Next CPListTemplate root -> optional action list
//    -> optional Archive confirmation (depth 3).
//  - Current episode: CPNowPlayingTemplate root -> optional Up Next list ->
//    optional action list -> optional Archive confirmation (depth 4).
//  - Subscriptions: CPNowPlayingTemplate root -> Subscriptions list ->
//    subscription episode list -> action list -> optional Download/Archive
//    confirmation (depth 5). Confirmed downloads temporarily replace the stack
//    with a native spinner root to avoid exceeding depth.
//  - Speed: CPNowPlayingTemplate root -> pushed speed list with slower/faster
//    controls plus native Back (depth 2). The Now Playing speed control uses a
//    custom text image derived from AppState's effective configured speed. Do not
//    replace it with CPNowPlayingPlaybackRateButton: that system button renders
//    MPNowPlayingInfoPropertyPlaybackRate, which legitimately becomes 0 while
//    paused and can briefly lag engine state, producing the misleading "0x" bug.
//    The custom glyph uses 34-point heavy compressed digits and an image cropped
//    to the measured text bounds. Fixed transparent canvases make CarPlay scale
//    the actual glyph down and must not be reintroduced; the label should have
//    the same visual prominence as adjacent symbols on real vehicle displays.
//  - Shared Listening: CPNowPlayingTemplate root -> one action sheet with toggle,
//    speed picker entry, and Cancel (depth 2), or a pushed short speed list
//    (depth 2). No action opens another action sheet.
//
// NEXT PHASES: Keep this as an adapter layer over AppState. Any future CarPlay
// controls should call existing app services or small AppState helpers rather
// than creating a second CarPlay-only queue, playback, or settings model.
// ============================================================================

@MainActor
final class CarPlayCoordinator: NSObject {
    private(set) weak var interfaceController: CPInterfaceController?
    private var readinessTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let presenter = CarPlayEpisodePresenter()
    private let artworkProvider = CarPlayArtworkProvider()

    private var queueTemplate: CPListTemplate?
    private var queueActionTemplate: CPListTemplate?
    private var subscriptionsTemplate: CPListTemplate?
    private var subscriptionEpisodesTemplate: CPListTemplate?
    private var selectedSubscriptionID: UUID?
    private var playbackSpeedTemplate: CPListTemplate?
    private var isShowingDownloadProgress = false
    private var rootRoute: RootRoute = .loading
    private var lastSnapshot: Snapshot?
    private let maximumSharedListeningSpeedActions = 4
    private let logger = AppLogger.shared

    private enum RootRoute {
        case loading
        case download
        case nowPlaying
        case queue
    }

    private enum EpisodeAction {
        case playNow
        case playNext
        case playLast

        var title: String {
            switch self {
            case .playNow: return "Play Now"
            case .playNext: return "Play Next"
            case .playLast: return "Play Last"
            }
        }

        var downloadMessage: String {
            switch self {
            case .playNow:
                return "Download this episode before playing it?"
            case .playNext:
                return "Download this episode before moving it to Play Next?"
            case .playLast:
                return "Download this episode before moving it to Play Last?"
            }
        }
    }

    private struct Snapshot: Equatable {
        let currentEpisodeID: UUID?
        let isPlaying: Bool
        let currentPlaybackSpeed: Double?
        let sharedListeningActive: Bool
        let sharedListeningSpeed: Double
        let queueIDs: [UUID]
        let subscriptionSignature: [String]

        @MainActor
        init(appState: AppState) {
            let currentEpisode = appState.currentPlayerEpisode
            currentEpisodeID = currentEpisode?.id
            isPlaying = appState.isPlaying
            if let currentEpisode,
               let subscription = appState.subscriptionStore.subscription(id: currentEpisode.subscriptionID) {
                currentPlaybackSpeed = appState.effectiveSpeed(for: subscription)
            } else {
                currentPlaybackSpeed = nil
            }
            sharedListeningActive = appState.sharedListeningActive
            sharedListeningSpeed = appState.sharedListeningSpeed
            queueIDs = appState.downloadedQueue.map(\.id)
            subscriptionSignature = appState.subscriptionStore.subscriptions
                .filter { $0.browseDate == nil }
                .sorted {
                    if $0.priorityRank != $1.priorityRank {
                        return $0.priorityRank < $1.priorityRank
                    }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                .map { subscription in
                    let playableCount = Snapshot.availableCount(subscription)
                    return "\(subscription.id.uuidString)|\(subscription.priorityRank)|\(subscription.title)|\(subscription.excludeFromAutoFeedRefresh)|\(playableCount)"
                }
        }

        private static func availableCount(_ subscription: Subscription) -> Int {
            let episodes = subscription.episodes.isEmpty
                ? subscription.latestEpisode.map { [$0] } ?? []
                : subscription.episodes
            return episodes.count
        }
    }

    func connect(interfaceController: CPInterfaceController) {
        logger.info("carplay.connect", "CarPlay interface connected")
        self.interfaceController = interfaceController
        configureNowPlayingTemplate()
        setLoadingRootTemplate(animated: false)
        startReadinessFlow(for: interfaceController)
    }

    func disconnect(interfaceController: CPInterfaceController) {
        guard self.interfaceController === interfaceController else { return }
        readinessTask?.cancel()
        readinessTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancellables.removeAll()
        CPNowPlayingTemplate.shared.remove(self)
        queueTemplate = nil
        queueActionTemplate = nil
        subscriptionsTemplate = nil
        subscriptionEpisodesTemplate = nil
        selectedSubscriptionID = nil
        playbackSpeedTemplate = nil
        isShowingDownloadProgress = false
        rootRoute = .loading
        lastSnapshot = nil
        self.interfaceController = nil
        logger.info("carplay.disconnect", "CarPlay interface disconnected")
    }

    private func startReadinessFlow(for interfaceController: CPInterfaceController) {
        readinessTask?.cancel()
        readinessTask = Task { @MainActor [weak self, weak interfaceController] in
            guard let self, let interfaceController else { return }

            let isCarPlayColdLaunch = AppState.shared == nil
            let appState = AppState.sharedOrBootstrap()
            if isCarPlayColdLaunch {
                await appState.resumePlaybackForCarPlayLaunchIfNeeded()
            } else {
                await appState.startPlaybackOnLaunchIfNeeded()
            }
            guard !Task.isCancelled, self.interfaceController === interfaceController else { return }
            self.observeAppState()
            self.showInitialTemplate(appState: appState, animated: true)
        }
    }

    private func showInitialTemplate(appState: AppState, animated: Bool) {
        if configureNowPlayingMetadata(appState: appState) {
            configureNowPlayingButtons(appState: appState)
            rootRoute = .nowPlaying
            logger.info("carplay.root", "Showing Now Playing root", metadata: [
                "episode": appState.currentPlayerEpisode?.title ?? "none"
            ])
            setRootTemplate(CPNowPlayingTemplate.shared, animated: animated)
        } else {
            rootRoute = .queue
            logger.info("carplay.root", "Showing Up Next root", metadata: [
                "queueCount": "\(appState.downloadedQueue.count)"
            ])
            setRootTemplate(makeQueueTemplate(appState: appState), animated: animated)
        }
        lastSnapshot = Snapshot(appState: appState)
    }

    private func setRootTemplate(_ template: CPTemplate, animated: Bool) {
        interfaceController?.setRootTemplate(template, animated: animated) { [weak self] success, error in
            self?.logTemplateCompletion(
                operation: "rootTemplate",
                template: template,
                success: success,
                error: error
            )
        }
    }

    private func setLoadingRootTemplate(animated: Bool) {
        setRootTemplate(makeLoadingTemplate(), animated: animated)
    }

    private func makeLoadingTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Autohop", sections: [])
        template.emptyViewTitleVariants = ["Loading Autohop"]
        if #available(iOS 18.4, *) {
            template.showsSpinnerWhileEmpty = true
        }
        return template
    }

    private func makeQueueTemplate(appState: AppState) -> CPListTemplate {
        let template = CPListTemplate(title: "Up Next", sections: makeQueueSections(appState: appState))
        template.emptyViewTitleVariants = ["No downloaded episodes"]
        template.trailingNavigationBarButtons = [makeSubscriptionsBarButton()]
        return template
    }

    private func makeQueueSections(appState: AppState) -> [CPListSection] {
        let rows = presenter.rows(from: appState)
        return rows.isEmpty ? [] : [CPListSection(items: rows.map { makeListItem(row: $0) })]
    }

    private func makeListItem(row: CarPlayEpisodeRow) -> CPListItem {
        let item = CPListItem(
            text: row.title,
            detailText: row.requiresDownload ? "Not downloaded" : row.podcastTitle,
            image: artworkProvider.placeholderImage()
        )
        item.userInfo = row.id
        item.isPlaying = row.isCurrentEpisode
        item.playingIndicatorLocation = .trailing
        if let progress = row.playbackProgress {
            item.playbackProgress = progress
        }
        item.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in
                self?.showQueueActions(for: row)
            }
        }

        Task { @MainActor [weak item, artworkProvider] in
            let image = await artworkProvider.image(for: row.artworkURL)
            item?.setImage(image)
        }
        return item
    }

    private func showQueueTemplate() {
        guard let appState = AppState.shared else { return }
        let queue = makeQueueTemplate(appState: appState)
        queueTemplate = queue
        pushTemplate(queue, animated: true)
    }

    private func pushTemplate(_ template: CPTemplate, animated: Bool) {
        interfaceController?.pushTemplate(template, animated: animated) { [weak self] success, error in
            self?.logTemplateCompletion(
                operation: "pushTemplate",
                template: template,
                success: success,
                error: error
            )
        }
    }

    private func configureNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        template.remove(self)
        template.add(self)
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Up Next"
        template.isAlbumArtistButtonEnabled = false
        if let appState = AppState.shared {
            configureNowPlayingButtons(appState: appState)
        } else {
            template.updateNowPlayingButtons([])
        }
    }

    private func configureNowPlayingButtons(appState: AppState) {
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            makeSubscriptionsButton(appState: appState),
            makePlaybackSpeedButton(appState: appState),
            makeSharedListeningButton(appState: appState),
            makeArchiveNowPlayingButton(appState: appState)
        ])
    }

    @discardableResult
    private func configureNowPlayingMetadata(appState: AppState) -> Bool {
        guard let metadata = presenter.currentMetadata(from: appState) else {
            NowPlayingService.shared.clear()
            return false
        }
        NowPlayingService.shared.update(
            episode: metadata.episode,
            podcastTitle: metadata.podcastTitle,
            currentTime: appState.currentPlayerTime,
            duration: metadata.episode.durationSeconds,
            speed: metadata.speed,
            isPlaying: appState.isPlaying || appState.playbackEngine.isPlaying,
            artworkURL: metadata.artworkURL
        )
        return true
    }

    private func observeAppState() {
        cancellables.removeAll()
        guard let appState = AppState.shared else { return }
        var changePublishers: [AnyPublisher<Void, Never>] = [
            appState.playbackCoordinator.objectWillChange
                .map { _ in () }
                .eraseToAnyPublisher(),
            appState.queueCoordinator.objectWillChange
                .map { _ in () }
                .eraseToAnyPublisher(),
            appState.subscriptionStore.objectWillChange
                .map { _ in () }
                .eraseToAnyPublisher(),
            appState.downloadCoordinator.objectWillChange
                .map { _ in () }
                .eraseToAnyPublisher()
        ]
        changePublishers.append(
            appState.settingsCoordinator.objectWillChange
                .map { _ in () }
                .eraseToAnyPublisher()
        )

        Publishers.MergeMany(changePublishers)
            .sink { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refreshFromAppState()
        }
    }

    private func refreshFromAppState() {
        let appState = AppState.sharedOrBootstrap()
        let snapshot = Snapshot(appState: appState)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        queueTemplate?.updateSections(makeQueueSections(appState: appState))
        subscriptionsTemplate?.updateSections(makeSubscriptionSections(appState: appState))
        if let selectedSubscriptionID {
            subscriptionEpisodesTemplate?.updateSections(
                makeSubscriptionEpisodeSections(subscriptionID: selectedSubscriptionID, appState: appState)
            )
        }

        guard !isShowingDownloadProgress else { return }

        if configureNowPlayingMetadata(appState: appState) {
            configureNowPlayingButtons(appState: appState)
            if rootRoute != .nowPlaying {
                rootRoute = .nowPlaying
                logger.info("carplay.root", "Switching to Now Playing root", metadata: [
                    "episode": appState.currentPlayerEpisode?.title ?? "none"
                ])
                setRootTemplate(CPNowPlayingTemplate.shared, animated: true)
            }
        } else if rootRoute != .queue {
            rootRoute = .queue
            logger.info("carplay.root", "Switching to Up Next root", metadata: [
                "queueCount": "\(appState.downloadedQueue.count)"
            ])
            setRootTemplate(makeQueueTemplate(appState: appState), animated: true)
        }
    }

    private func playEpisode(_ episode: Episode) async {
        guard let appState = AppState.shared else { return }
        await CarPlayActionRouter(appState: appState).play(episode)
        configureNowPlayingMetadata(appState: appState)
        configureNowPlayingButtons(appState: appState)
        rootRoute = .nowPlaying
        setRootTemplate(CPNowPlayingTemplate.shared, animated: true)
        refreshFromAppState()
    }

    private func showQueueActions(for row: CarPlayEpisodeRow) {
        let play = makeActionItem(title: "Play Now", detail: nil) { [weak self] in
            await self?.performEpisodeAction(.playNow, row: row)
        }
        let playNext = makeActionItem(title: "Play Next", detail: nil) { [weak self] in
            await self?.performEpisodeAction(.playNext, row: row)
        }
        let playLast = makeActionItem(title: "Play Last", detail: nil) { [weak self] in
            await self?.performEpisodeAction(.playLast, row: row)
        }
        let archive = makeActionItem(title: "Archive", detail: nil) { [weak self] in
            self?.presentArchiveConfirmation(
                title: "Archive Episode?",
                message: row.title,
                afterArchive: { [weak self] in self?.popTemplate() },
                archive: { [weak self] in await self?.archiveEpisode(row.episode) }
            )
        }

        let template = CPListTemplate(
            title: row.title,
            sections: [CPListSection(items: [play, playNext, playLast, archive])]
        )
        queueActionTemplate = template
        pushTemplate(template, animated: true)
    }

    private func performEpisodeAction(_ action: EpisodeAction, row: CarPlayEpisodeRow) async {
        if row.requiresDownload {
            presentDownloadConfirmation(action: action, episode: row.episode)
            return
        }

        await performDownloadedEpisodeAction(action, episode: row.episode)
    }

    private func performDownloadedEpisodeAction(_ action: EpisodeAction, episode: Episode) async {
        switch action {
        case .playNow:
            await playEpisode(episode)
        case .playNext:
            playEpisodeNext(episode)
            popTemplate()
        case .playLast:
            playEpisodeLast(episode)
            popTemplate()
        }
    }

    private func presentDownloadConfirmation(action: EpisodeAction, episode: Episode) {
        let confirm = CPAlertAction(title: "Download", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    Task { @MainActor in
                        await self?.downloadAndPerform(action, episode: episode)
                    }
                }
            }
        }

        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.dismissPresentedTemplate() }
        }

        let sheet = CPActionSheetTemplate(
            title: action.title,
            message: action.downloadMessage,
            actions: [confirm, cancel]
        )
        presentTemplate(sheet, animated: true)
    }

    private func downloadAndPerform(_ action: EpisodeAction, episode: Episode) async {
        guard let appState = AppState.shared else { return }
        showDownloadProgressTemplate(action: action, episode: episode)

        let router = CarPlayActionRouter(appState: appState)
        guard let downloadedEpisode = await router.downloadForAction(episode) else {
            isShowingDownloadProgress = false
            restoreRootTemplate(appState: appState)
            presentDownloadFailure(for: episode)
            return
        }

        isShowingDownloadProgress = false
        await performDownloadedEpisodeActionAfterDownload(action, episode: downloadedEpisode, appState: appState)
    }

    private func performDownloadedEpisodeActionAfterDownload(
        _ action: EpisodeAction,
        episode: Episode,
        appState: AppState
    ) async {
        switch action {
        case .playNow:
            await playEpisode(episode)
        case .playNext:
            await CarPlayActionRouter(appState: appState).playNext(episode)
            configureNowPlayingMetadata(appState: appState)
            configureNowPlayingButtons(appState: appState)
            restoreRootTemplate(appState: appState)
            refreshFromAppState()
        case .playLast:
            CarPlayActionRouter(appState: appState).playLast(episode)
            configureNowPlayingMetadata(appState: appState)
            configureNowPlayingButtons(appState: appState)
            restoreRootTemplate(appState: appState)
            refreshFromAppState()
        }
    }

    private func showDownloadProgressTemplate(action: EpisodeAction, episode: Episode) {
        let template = CPListTemplate(title: "Downloading", sections: [])
        template.emptyViewTitleVariants = ["Downloading episode"]
        template.emptyViewSubtitleVariants = [episode.title]
        if #available(iOS 18.4, *) {
            template.showsSpinnerWhileEmpty = true
        }
        isShowingDownloadProgress = true
        rootRoute = .download
        setRootTemplate(template, animated: true)
        logger.info("carplay.download", "CarPlay download started", metadata: [
            "episode": episode.title,
            "action": action.title
        ])
    }

    private func restoreRootTemplate(appState: AppState) {
        if configureNowPlayingMetadata(appState: appState) {
            rootRoute = .nowPlaying
            setRootTemplate(CPNowPlayingTemplate.shared, animated: true)
        } else {
            rootRoute = .queue
            setRootTemplate(makeQueueTemplate(appState: appState), animated: true)
        }
    }

    private func presentDownloadFailure(for episode: Episode) {
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.dismissPresentedTemplate() }
        }
        let sheet = CPActionSheetTemplate(
            title: "Download Failed",
            message: episode.title,
            actions: [cancel]
        )
        presentTemplate(sheet, animated: true)
    }

    private func showSubscriptionsTemplate() {
        guard let appState = AppState.shared else { return }
        let template = makeSubscriptionsTemplate(appState: appState)
        subscriptionsTemplate = template
        pushTemplate(template, animated: true)
    }

    private func makeSubscriptionsTemplate(appState: AppState) -> CPListTemplate {
        let template = CPListTemplate(
            title: "Subscriptions",
            sections: makeSubscriptionSections(appState: appState)
        )
        template.emptyViewTitleVariants = ["No subscriptions"]
        return template
    }

    private func makeSubscriptionSections(appState: AppState) -> [CPListSection] {
        let rows = presenter.subscriptionRows(from: appState)
        return rows.isEmpty ? [] : [CPListSection(items: rows.map { makeSubscriptionItem(row: $0) })]
    }

    private func makeSubscriptionItem(row: CarPlaySubscriptionRow) -> CPListItem {
        let countText = row.availableEpisodeCount == 1
            ? "1 episode"
            : "\(row.availableEpisodeCount) episodes"
        let detail = row.isInactive ? "Inactive · \(countText)" : countText
        let item = CPListItem(
            text: row.title,
            detailText: detail,
            image: artworkProvider.placeholderImage()
        )
        item.userInfo = row.id
        item.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in
                self?.showSubscriptionEpisodes(for: row.subscription.id)
            }
        }

        Task { @MainActor [weak item, artworkProvider] in
            let image = await artworkProvider.image(for: row.artworkURL)
            item?.setImage(image)
        }
        return item
    }

    private func showSubscriptionEpisodes(for subscriptionID: UUID) {
        guard let appState = AppState.shared,
              let subscription = appState.subscriptionStore.subscription(id: subscriptionID)
        else { return }

        selectedSubscriptionID = subscriptionID
        let template = CPListTemplate(
            title: subscription.title,
            sections: makeSubscriptionEpisodeSections(subscriptionID: subscriptionID, appState: appState)
        )
        template.emptyViewTitleVariants = ["No episodes"]
        subscriptionEpisodesTemplate = template
        pushTemplate(template, animated: true)
    }

    private func makeSubscriptionEpisodeSections(subscriptionID: UUID, appState: AppState) -> [CPListSection] {
        guard let subscription = appState.subscriptionStore.subscription(id: subscriptionID) else {
            return []
        }
        let rows = presenter.episodeRows(for: subscription, appState: appState)
        return rows.isEmpty ? [] : [CPListSection(items: rows.map { makeListItem(row: $0) })]
    }

    private func playEpisodeNext(_ episode: Episode) {
        guard let appState = AppState.shared else { return }
        Task { @MainActor [weak self] in
            await CarPlayActionRouter(appState: appState).playNext(episode)
            self?.refreshFromAppState()
        }
    }

    private func playEpisodeLast(_ episode: Episode) {
        guard let appState = AppState.shared else { return }
        CarPlayActionRouter(appState: appState).playLast(episode)
        refreshFromAppState()
    }

    private func archiveEpisode(_ episode: Episode) async {
        guard let appState = AppState.shared else { return }
        await CarPlayActionRouter(appState: appState).archive(episode)
        refreshFromAppState()
    }

    private func archiveCurrentEpisode() async {
        guard let appState = AppState.shared else { return }
        await CarPlayActionRouter(appState: appState).archiveCurrent()
        refreshFromAppState()
    }

    private func presentArchiveCurrentConfirmation() {
        guard let appState = AppState.shared,
              let episode = appState.currentPlayerEpisode
        else { return }

        presentArchiveConfirmation(
            title: "Archive Current Episode?",
            message: episode.title,
            afterArchive: nil,
            archive: { [weak self] in await self?.archiveCurrentEpisode() }
        )
    }

    private func showPlaybackSpeedTemplate() {
        guard let appState = AppState.shared else { return }

        let template = CPListTemplate(
            title: "Playback Speed",
            sections: makePlaybackSpeedSections(appState: appState)
        )
        playbackSpeedTemplate = template
        pushTemplate(template, animated: true)
    }

    private func makePlaybackSpeedSections(appState: AppState) -> [CPListSection] {
        let currentSpeed = currentPlaybackSpeed(appState: appState)
        let nearestIndex = nearestPlaybackSpeedIndex(to: currentSpeed)
        let current = CPListItem(
            text: "Current Speed",
            detailText: PlaybackPreference.speedLabel(currentSpeed)
        )
        current.isEnabled = false

        let slower = makePlaybackSpeedAdjustmentItem(
            title: "− Slower",
            direction: -1,
            isEnabled: nearestIndex > PlaybackPreference.speedOptions.startIndex
        )
        let faster = makePlaybackSpeedAdjustmentItem(
            title: "+ Faster",
            direction: 1,
            isEnabled: nearestIndex < PlaybackPreference.speedOptions.index(before: PlaybackPreference.speedOptions.endIndex)
        )

        return [CPListSection(items: [current, slower, faster])]
    }

    private func makePlaybackSpeedAdjustmentItem(title: String, direction: Int, isEnabled: Bool) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        item.isEnabled = isEnabled
        item.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in
                self?.adjustPlaybackSpeed(direction: direction)
            }
        }
        return item
    }

    private func adjustPlaybackSpeed(direction: Int) {
        guard let appState = AppState.shared else { return }
        let currentSpeed = currentPlaybackSpeed(appState: appState)
        let index = nearestPlaybackSpeedIndex(to: currentSpeed)
        let targetIndex = max(
            PlaybackPreference.speedOptions.startIndex,
            min(PlaybackPreference.speedOptions.index(before: PlaybackPreference.speedOptions.endIndex), index + direction)
        )
        guard targetIndex != index else { return }
        appState.setPlaybackSpeedForCurrentEpisode(PlaybackPreference.speedOptions[targetIndex])
        configureNowPlayingMetadata(appState: appState)
        configureNowPlayingButtons(appState: appState)
        playbackSpeedTemplate?.updateSections(makePlaybackSpeedSections(appState: appState))
        refreshFromAppState()
    }

    private func nearestPlaybackSpeedIndex(to speed: Double) -> Int {
        PlaybackPreference.speedOptions.indices.min {
            abs(PlaybackPreference.speedOptions[$0] - speed) < abs(PlaybackPreference.speedOptions[$1] - speed)
        } ?? PlaybackPreference.speedOptions.startIndex
    }

    private func currentPlaybackSpeed(appState: AppState) -> Double {
        guard let episode = appState.currentPlayerEpisode,
              let subscription = appState.subscriptionStore.subscription(id: episode.subscriptionID)
        else { return 1.0 }
        return appState.effectiveSpeed(for: subscription)
    }

    private func presentSharedListeningActions() {
        guard let appState = AppState.shared else { return }

        let toggleTitle = appState.sharedListeningActive
            ? "Turn Off Shared Listening"
            : "Turn On Shared Listening"
        let toggle = CPAlertAction(title: toggleTitle, style: .default) { [weak self] _ in
            Task { @MainActor in
                guard let appState = AppState.shared else { return }
                self?.dismissPresentedTemplate()
                CarPlayActionRouter(appState: appState).setSharedListening(active: !appState.sharedListeningActive)
                self?.configureNowPlayingMetadata(appState: appState)
                self?.configureNowPlayingButtons(appState: appState)
                self?.refreshFromAppState()
            }
        }

        let chooseSpeed = CPAlertAction(title: "Choose Speed", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    self?.showSharedListeningSpeedPicker()
                }
            }
        }

        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.dismissPresentedTemplate() }
        }

        let sheet = CPActionSheetTemplate(
            title: "Shared Listening",
            message: appState.sharedListeningActive
                ? "Current speed \(PlaybackPreference.speedLabel(appState.sharedListeningSpeed))"
                : nil,
            actions: [toggle, chooseSpeed, cancel]
        )
        presentTemplate(sheet, animated: true)
    }

    private func showSharedListeningSpeedPicker() {
        guard let appState = AppState.shared else { return }

        let items = AppState.sharedListeningSpeedOptions.prefix(maximumSharedListeningSpeedActions).map { speed in
            makeActionItem(
                title: PlaybackPreference.speedLabel(speed),
                detail: abs(speed - appState.sharedListeningSpeed) < 0.01 ? "Current" : nil
            ) { [weak self] in
                guard let appState = AppState.shared else { return }
                CarPlayActionRouter(appState: appState).selectSharedListeningSpeed(speed)
                self?.configureNowPlayingMetadata(appState: appState)
                self?.configureNowPlayingButtons(appState: appState)
                self?.refreshFromAppState()
                self?.popTemplate()
            }
        }

        let template = CPListTemplate(
            title: "Shared Speed",
            sections: [CPListSection(items: Array(items))]
        )
        pushTemplate(template, animated: true)
    }

    private func presentArchiveConfirmation(
        title: String,
        message: String?,
        afterArchive: (() -> Void)?,
        archive: @escaping () async -> Void
    ) {
        let confirm = CPAlertAction(title: "Archive", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    Task { @MainActor in
                        await archive()
                        afterArchive?()
                    }
                }
            }
        }

        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.dismissPresentedTemplate() }
        }

        let sheet = CPActionSheetTemplate(
            title: title,
            message: message,
            actions: [confirm, cancel]
        )
        presentTemplate(sheet, animated: true)
    }

    private func makeActionItem(
        title: String,
        detail: String?,
        action: @escaping () async -> Void
    ) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        item.handler = { _, completion in
            completion()
            Task { @MainActor in
                await action()
            }
        }
        return item
    }

    private func dismissPresentedTemplate(completion: (() -> Void)? = nil) {
        interfaceController?.dismissTemplate(animated: true) { [weak self] success, error in
            self?.logTemplateCompletion(
                operation: "dismissTemplate",
                template: nil,
                success: success,
                error: error
            )
            Task { @MainActor in completion?() }
        }
    }

    private func popTemplate() {
        interfaceController?.popTemplate(animated: true) { [weak self] success, error in
            self?.logTemplateCompletion(
                operation: "popTemplate",
                template: nil,
                success: success,
                error: error
            )
        }
    }

    private func presentTemplate(_ template: CPTemplate, animated: Bool) {
        interfaceController?.presentTemplate(template, animated: animated) { [weak self] success, error in
            self?.logTemplateCompletion(
                operation: "presentTemplate",
                template: template,
                success: success,
                error: error
            )
        }
    }

    private func logTemplateCompletion(
        operation: String,
        template: CPTemplate?,
        success: Bool,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.logger.warning("carplay.templateFailed", "CarPlay rejected template operation", metadata: [
                "operation": operation,
                "template": template.map { String(describing: type(of: $0)) } ?? "none",
                "success": "\(success)",
                "error": error.localizedDescription
            ])
        }
    }

    private func makeSubscriptionsBarButton() -> CPBarButton {
        let button = CPBarButton(title: "Subscriptions") { [weak self] _ in
            Task { @MainActor in self?.showSubscriptionsTemplate() }
        }
        button.buttonStyle = .rounded
        return button
    }

    private func makeSubscriptionsButton(appState: AppState) -> CPNowPlayingImageButton {
        let image = UIImage(systemName: "list.bullet.rectangle") ?? UIImage(systemName: "list.bullet") ?? UIImage()
        let button = CPNowPlayingImageButton(image: image) { [weak self] _ in
            Task { @MainActor in self?.showSubscriptionsTemplate() }
        }
        button.isEnabled = !appState.subscriptionStore.subscriptions.filter { $0.browseDate == nil }.isEmpty
        return button
    }

    private func makePlaybackSpeedButton(appState: AppState) -> CPNowPlayingImageButton {
        let speed = currentPlaybackSpeed(appState: appState)
        let button = CPNowPlayingImageButton(image: playbackSpeedButtonImage(speed: speed)) { [weak self] _ in
            Task { @MainActor in self?.showPlaybackSpeedTemplate() }
        }
        button.isEnabled = appState.currentPlayerEpisode != nil && !appState.sharedListeningActive
        return button
    }

    /// Renders the configured speed rather than the instantaneous media playback
    /// rate. CarPlay tints template images, so the glyph is encoded as alpha-only
    /// text and stays legible across vehicle light/dark appearances. Keep the
    /// canvas tight around the glyph: CarPlay scales the complete image into its
    /// standard control slot, so excess transparent width makes the text tiny.
    private func playbackSpeedButtonImage(speed: Double) -> UIImage {
        let text = PlaybackPreference.speedLabel(speed)
            .replacingOccurrences(of: "x", with: "×")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .heavy, width: .compressed),
            .foregroundColor: UIColor.white,
            .kern: -1.0
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        // Crop to the glyph plus a one-point anti-aliasing margin. CarPlay sizes
        // the entire UIImage, so a conventional 46×36 transparent canvas made
        // the previous 24-point label appear much smaller than nearby symbols.
        let size = CGSize(
            width: max(1, ceil(measured.width) + 2),
            height: max(1, ceil(measured.height) + 2)
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            (text as NSString).draw(at: CGPoint(x: 1, y: 1), withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func makeSharedListeningButton(appState: AppState) -> CPNowPlayingImageButton {
        let image = UIImage(systemName: "person.2.fill") ?? UIImage()
        let button = CPNowPlayingImageButton(image: image) { [weak self] _ in
            Task { @MainActor in self?.presentSharedListeningActions() }
        }
        button.isEnabled = appState.currentPlayerEpisode != nil
        button.isSelected = appState.sharedListeningActive
        return button
    }

    private func makeArchiveNowPlayingButton(appState: AppState) -> CPNowPlayingImageButton {
        let image = UIImage(systemName: "archivebox") ?? UIImage()
        let button = CPNowPlayingImageButton(image: image) { [weak self] _ in
            Task { @MainActor in
                self?.presentArchiveCurrentConfirmation()
            }
        }
        button.isEnabled = appState.currentPlayerEpisode != nil
        return button
    }
}

extension CarPlayCoordinator: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            self?.showQueueTemplate()
        }
    }
}
