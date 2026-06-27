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
// CURRENT SCOPE: Real-hardware CarPlay adapter. The coordinator renders Now
// Playing, Queue, and empty states from AppState.downloadedQueue,
// observes AppState conservatively, and delegates behavior decisions to
// CarPlayActionRouter so Play/Play Next/Archive/speed/Shared Listening paths can
// be tested without a live CarPlay runtime. Dialog-style templates always include
// a visible Cancel action; pushed list pages rely on the native Back button only.
// CarPlay-only cold launches use AppState.sharedOrBootstrap() so selecting
// Autohop in CarPlay after the iPhone app was swiped closed still creates the
// shared queue/playback model before templates are rendered.
// Connecting CarPlay must not activate audio by itself, refresh feeds, download
// episodes, search, browse, or create any separate CarPlay queue/playback/settings
// state.
//
// TEMPLATE STACK COUNT:
//  - Loading: CPListTemplate root only (depth 1).
//  - No current episode: Queue CPListTemplate root -> optional Queue action list
//    -> optional Archive confirmation (depth 3).
//  - Current episode: CPNowPlayingTemplate root -> optional Queue list ->
//    optional Queue action list -> optional Archive confirmation (depth 4).
//  - Speed: CPNowPlayingTemplate root -> one action sheet with slower/faster plus
//    Cancel (depth 2).
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
    private var rootRoute: RootRoute = .loading
    private var lastSnapshot: Snapshot?
    private let maximumSharedListeningSpeedActions = 4

    private enum RootRoute {
        case loading
        case nowPlaying
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
        queueTemplate = nil
        queueActionTemplate = nil
        rootRoute = .loading
        lastSnapshot = nil
        self.interfaceController = nil
    }

    private func startReadinessFlow(for interfaceController: CPInterfaceController) {
        readinessTask?.cancel()
        readinessTask = Task { @MainActor [weak self, weak interfaceController] in
            guard let self, let interfaceController else { return }

            let appState = AppState.sharedOrBootstrap()
            await appState.startPlaybackOnLaunchIfNeeded()
            guard !Task.isCancelled, self.interfaceController === interfaceController else { return }
            self.observeAppState()
            self.showInitialTemplate(appState: appState, animated: true)
        }
    }

    private func showInitialTemplate(appState: AppState, animated: Bool) {
        if appState.currentPlayerEpisode != nil {
            configureNowPlayingMetadata(appState: appState)
            configureNowPlayingButtons(appState: appState)
            rootRoute = .nowPlaying
            setRootTemplate(CPNowPlayingTemplate.shared, animated: animated)
        } else {
            rootRoute = .queue
            setRootTemplate(makeQueueTemplate(appState: appState), animated: animated)
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

    private func makeQueueTemplate(appState: AppState) -> CPListTemplate {
        CPListTemplate(title: "Queue", sections: makeQueueSections(appState: appState))
    }

    private func makeQueueSections(appState: AppState) -> [CPListSection] {
        let rows = presenter.rows(from: appState)
        guard !rows.isEmpty else {
            return [CPListSection(items: [makeEmptyQueueItem()])]
        }

        return [CPListSection(items: rows.map { makeListItem(row: $0) })]
    }

    private func makeEmptyQueueItem() -> CPListItem {
        let item = CPListItem(text: "No downloaded episodes", detailText: nil)
        item.isEnabled = false
        return item
    }

    private func makeListItem(row: CarPlayEpisodeRow) -> CPListItem {
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
        interfaceController?.pushTemplate(template, animated: animated) { _, _ in }
    }

    private func configureNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        template.remove(self)
        template.add(self)
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Queue"
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

        if appState.currentPlayerEpisode != nil {
            configureNowPlayingMetadata(appState: appState)
            configureNowPlayingButtons(appState: appState)
            if rootRoute != .nowPlaying {
                rootRoute = .nowPlaying
                setRootTemplate(CPNowPlayingTemplate.shared, animated: true)
            }
        } else if rootRoute != .queue {
            rootRoute = .queue
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
            await self?.playEpisode(row.episode)
        }
        let playNext = makeActionItem(title: "Play Next", detail: nil) { [weak self] in
            self?.playEpisodeNext(row.episode)
            self?.popTemplate()
        }
        let playLast = makeActionItem(title: "Play Last", detail: nil) { [weak self] in
            self?.playEpisodeLast(row.episode)
            self?.popTemplate()
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

    private func presentPlaybackSpeedActions() {
        guard let appState = AppState.shared else { return }

        let currentSpeed = currentPlaybackSpeed(appState: appState)
        let slower = CPAlertAction(title: "−", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    self?.adjustPlaybackSpeed(direction: -1)
                }
            }
        }
        let faster = CPAlertAction(title: "+", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate {
                    self?.adjustPlaybackSpeed(direction: 1)
                }
            }
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.dismissPresentedTemplate() }
        }

        let sheet = CPActionSheetTemplate(
            title: "Playback Speed",
            message: "Current \(PlaybackPreference.speedLabel(currentSpeed))",
            actions: [slower, faster, cancel]
        )
        interfaceController?.presentTemplate(sheet, animated: true) { _, _ in }
    }

    private func adjustPlaybackSpeed(direction: Int) {
        guard let appState = AppState.shared else { return }
        let currentSpeed = currentPlaybackSpeed(appState: appState)
        guard let index = PlaybackPreference.speedOptions.indices.min(by: {
            abs(PlaybackPreference.speedOptions[$0] - currentSpeed) < abs(PlaybackPreference.speedOptions[$1] - currentSpeed)
        }) else { return }
        let targetIndex = max(
            PlaybackPreference.speedOptions.startIndex,
            min(PlaybackPreference.speedOptions.index(before: PlaybackPreference.speedOptions.endIndex), index + direction)
        )
        appState.setPlaybackSpeedForCurrentEpisode(PlaybackPreference.speedOptions[targetIndex])
        configureNowPlayingMetadata(appState: appState)
        configureNowPlayingButtons(appState: appState)
        refreshFromAppState()
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
        interfaceController?.presentTemplate(sheet, animated: true) { _, _ in }
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
        interfaceController?.presentTemplate(sheet, animated: true) { _, _ in }
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
        interfaceController?.dismissTemplate(animated: true) { _, _ in
            Task { @MainActor in completion?() }
        }
    }

    private func popTemplate() {
        interfaceController?.popTemplate(animated: true) { _, _ in }
    }

    private func makePlaybackSpeedButton(appState: AppState) -> CPNowPlayingPlaybackRateButton {
        let button = CPNowPlayingPlaybackRateButton { [weak self] _ in
            Task { @MainActor in self?.presentPlaybackSpeedActions() }
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
