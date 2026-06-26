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
// projects shared AppState into read-only CarPlay templates.
//
// CURRENT SCOPE: Phase 8 test-backed CarPlay adapter. The coordinator renders
// Now Playing, Up Next, Queue, and empty states from AppState.downloadedQueue,
// observes AppState conservatively, and delegates behavior decisions to
// CarPlayActionRouter so Play/Play Next/Archive/speed/Shared Listening paths can
// be tested without a live CarPlay runtime. Connecting CarPlay must not activate
// audio by itself, refresh feeds, download episodes, search, browse, or create
// any separate CarPlay queue/playback/settings state.
//
// TEMPLATE STACK COUNT:
//  - Loading: CPListTemplate root only (depth 1).
//  - No current episode: Up Next CPListTemplate root -> optional Queue list ->
//    optional Queue action sheet (depth 3).
//  - Current episode: CPNowPlayingTemplate root -> optional Up Next list ->
//    optional Queue list -> optional Queue action sheet (depth 4).
//  - Shared Listening: CPNowPlayingTemplate root -> one action sheet with toggle
//    plus the short speed list (depth 2). No action opens another action sheet.
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

    private var upNextTemplate: CPListTemplate?
    private var queueTemplate: CPListTemplate?
    private var rootRoute: RootRoute = .loading
    private var lastSnapshot: Snapshot?
    private let maximumSharedListeningSpeedActions = 4

    private enum RootRoute {
        case loading
        case nowPlaying
        case upNext
    }

    private enum ListMode {
        case upNext
        case queue
    }

    private struct Snapshot: Equatable {
        let currentEpisodeID: UUID?
        let isPlaying: Bool
        let currentPlaybackSpeed: Double?
        let sharedListeningActive: Bool
        let sharedListeningSpeed: Double
        let queueIDs: [UUID]

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
        }
    }

    func connect(interfaceController: CPInterfaceController) {
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
        upNextTemplate = nil
        queueTemplate = nil
        rootRoute = .loading
        lastSnapshot = nil
        self.interfaceController = nil
    }

    private func startReadinessFlow(for interfaceController: CPInterfaceController) {
        readinessTask?.cancel()
        readinessTask = Task { @MainActor [weak self, weak interfaceController] in
            guard let self, let interfaceController else { return }

            await AppState.shared.startPlaybackOnLaunchIfNeeded()
            guard !Task.isCancelled, self.interfaceController === interfaceController else { return }
            self.observeAppState()
            self.showInitialTemplate(animated: true)
        }
    }

    private func showInitialTemplate(animated: Bool) {
        guard let appState = AppState.shared else {
            setLoadingRootTemplate(animated: animated)
            return
        }

        if appState.currentPlayerEpisode != nil {
            configureNowPlayingMetadata(appState: appState)
            configureNowPlayingButtons(appState: appState)
            rootRoute = .nowPlaying
            setRootTemplate(CPNowPlayingTemplate.shared, animated: animated)
        } else {
            rootRoute = .upNext
            setRootTemplate(makeUpNextTemplate(appState: appState), animated: animated)
        }
        lastSnapshot = Snapshot(appState: appState)
    }

    private func setRootTemplate(_ template: CPTemplate, animated: Bool) {
        interfaceController?.setRootTemplate(template, animated: animated) { _, _ in }
    }

    private func setLoadingRootTemplate(animated: Bool) {
        setRootTemplate(makeLoadingTemplate(), animated: animated)
    }

    private func makeLoadingTemplate() -> CPListTemplate {
        let loadingItem = CPListItem(text: "Loading...", detailText: nil)
        loadingItem.isEnabled = false

        let section = CPListSection(items: [loadingItem])
        return CPListTemplate(title: "Autohop", sections: [section])
    }

    private func makeUpNextTemplate(appState: AppState) -> CPListTemplate {
        let template = CPListTemplate(title: "Up Next", sections: makeQueueSections(appState: appState, mode: .upNext))
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Queue") { [weak self] _ in
                Task { @MainActor in self?.showQueueTemplate() }
            }
        ]
        return template
    }

    private func makeQueueTemplate(appState: AppState) -> CPListTemplate {
        CPListTemplate(title: "Queue", sections: makeQueueSections(appState: appState, mode: .queue))
    }

    private func makeQueueSections(appState: AppState, mode: ListMode) -> [CPListSection] {
        let rows = presenter.rows(from: appState)
        guard !rows.isEmpty else {
            return [CPListSection(items: [makeEmptyQueueItem()])]
        }

        return [CPListSection(items: rows.map { makeListItem(row: $0, mode: mode) })]
    }

    private func makeEmptyQueueItem() -> CPListItem {
        let item = CPListItem(text: "No downloaded episodes", detailText: nil)
        item.isEnabled = false
        return item
    }

    private func makeListItem(row: CarPlayEpisodeRow, mode: ListMode) -> CPListItem {
        let item = CPListItem(
            text: row.title,
            detailText: row.podcastTitle,
            image: artworkProvider.placeholderImage()
        )
        item.userInfo = row.id
        item.isPlaying = row.isCurrentEpisode
        item.playingIndicatorLocation = .trailing
        if let progress = row.playbackProgress {
            item.playbackProgress = progress
        }
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                switch mode {
                case .upNext:
                    await self?.playEpisode(row.episode)
                case .queue:
                    self?.presentQueueActions(for: row)
                }
                completion()
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

    private func showUpNextTemplate() {
        guard let appState = AppState.shared else { return }
        let upNext = makeUpNextTemplate(appState: appState)
        upNextTemplate = upNext
        pushTemplate(upNext, animated: true)
    }

    private func pushTemplate(_ template: CPTemplate, animated: Bool) {
        interfaceController?.pushTemplate(template, animated: animated) { _, _ in }
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
            makePlaybackSpeedButton(appState: appState),
            makeSharedListeningButton(appState: appState),
            makeArchiveNowPlayingButton(appState: appState)
        ])
    }

    private func configureNowPlayingMetadata(appState: AppState) {
        guard let metadata = presenter.currentMetadata(from: appState) else { return }
        NowPlayingService.shared.update(
            episode: metadata.episode,
            podcastTitle: metadata.podcastTitle,
            currentTime: appState.currentPlayerTime,
            duration: metadata.episode.durationSeconds,
            speed: metadata.speed,
            isPlaying: appState.isPlaying,
            artworkURL: metadata.artworkURL
        )
    }

    private func observeAppState() {
        cancellables.removeAll()
        guard let appState = AppState.shared else { return }
        appState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refreshFromAppState()
        }
    }

    private func refreshFromAppState() {
        guard let appState = AppState.shared else { return }
        let snapshot = Snapshot(appState: appState)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        upNextTemplate?.updateSections(makeQueueSections(appState: appState, mode: .upNext))
        queueTemplate?.updateSections(makeQueueSections(appState: appState, mode: .queue))

        if appState.currentPlayerEpisode != nil {
            configureNowPlayingMetadata(appState: appState)
            configureNowPlayingButtons(appState: appState)
            if rootRoute != .nowPlaying {
                rootRoute = .nowPlaying
                setRootTemplate(CPNowPlayingTemplate.shared, animated: true)
            }
        } else if rootRoute != .upNext {
            rootRoute = .upNext
            setRootTemplate(makeUpNextTemplate(appState: appState), animated: true)
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

    private func presentQueueActions(for row: CarPlayEpisodeRow) {
        let play = CPAlertAction(title: "Play", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate()
                await self?.playEpisode(row.episode)
            }
        }

        let playNext = CPAlertAction(title: "Play Next", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate()
                self?.playEpisodeNext(row.episode)
            }
        }

        let archive = CPAlertAction(title: "Archive", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate()
                await self?.archiveEpisode(row.episode)
            }
        }

        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.dismissPresentedTemplate() }
        }

        let sheet = CPActionSheetTemplate(
            title: row.title,
            message: row.podcastTitle,
            actions: [play, playNext, archive, cancel]
        )
        interfaceController?.presentTemplate(sheet, animated: true) { _, _ in }
    }

    private func playEpisodeNext(_ episode: Episode) {
        guard let appState = AppState.shared else { return }
        Task { @MainActor [weak self] in
            await CarPlayActionRouter(appState: appState).playNext(episode)
            self?.refreshFromAppState()
        }
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

    private func cyclePlaybackSpeed() {
        guard let appState = AppState.shared else { return }
        CarPlayActionRouter(appState: appState).cyclePlaybackSpeed()
        configureNowPlayingMetadata(appState: appState)
        configureNowPlayingButtons(appState: appState)
        refreshFromAppState()
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

        let speedActions = AppState.sharedListeningSpeedOptions.prefix(maximumSharedListeningSpeedActions).map { speed in
            CPAlertAction(title: PlaybackPreference.speedLabel(speed), style: .default) { [weak self] _ in
                Task { @MainActor in
                    guard let appState = AppState.shared else { return }
                    self?.dismissPresentedTemplate()
                    CarPlayActionRouter(appState: appState).selectSharedListeningSpeed(speed)
                    self?.configureNowPlayingMetadata(appState: appState)
                    self?.configureNowPlayingButtons(appState: appState)
                    self?.refreshFromAppState()
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
            actions: [toggle] + speedActions + [cancel]
        )
        interfaceController?.presentTemplate(sheet, animated: true) { _, _ in }
    }

    private func dismissPresentedTemplate() {
        interfaceController?.dismissTemplate(animated: true) { _, _ in }
    }

    private func makePlaybackSpeedButton(appState: AppState) -> CPNowPlayingPlaybackRateButton {
        let button = CPNowPlayingPlaybackRateButton { [weak self] _ in
            Task { @MainActor in self?.cyclePlaybackSpeed() }
        }
        button.isEnabled = appState.currentPlayerEpisode != nil && !appState.sharedListeningActive
        return button
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
                await self?.archiveCurrentEpisode()
            }
        }
        button.isEnabled = appState.currentPlayerEpisode != nil
        return button
    }
}

extension CarPlayCoordinator: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            self?.showUpNextTemplate()
        }
    }
}
