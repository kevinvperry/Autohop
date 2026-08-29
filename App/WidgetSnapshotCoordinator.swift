import Combine
import CryptoKit
import Foundation
import UIKit
import WidgetKit

// AI CONTEXT — App/WidgetSnapshotCoordinator.swift
//
// PURPOSE / OWNERSHIP:
// Stage 2 owner of the device-local widget display projection. It observes only
// QueueCoordinator, PlaybackCoordinator, and SubscriptionStore's explicit
// presentationDidChange stream; resolves fresh store values; prepares up to
// five downloaded episodes and their bounded thumbnails; atomically publishes
// the App Group snapshot; and requests one targeted WidgetKit timeline reload.
//
// CONCURRENCY / CANCELLATION:
// MainActor owns subscriptions, debounce state, and domain reads. A debounce
// Task may be cancelled only while sleeping. Once publication starts, later
// events accumulate reasons for a follow-up pass instead of cancelling artwork
// or filesystem work—background sync cancellation must not recur here.
// WidgetSnapshotPersistence is an actor so JSON/JPEG I/O and garbage collection
// never block the main actor.
//
// INVARIANTS:
// - Never observe AppState.objectWillChange or the 0.5-second PlaybackClock.
// - Never publish an undownloaded/archived/played episode with a play surface.
// - Identity is subscriptionID + PlaybackPositionStore.key(for:), never UUID.
// - The extension never networks or opens GRDB; only this app-side owner asks
//   ArtworkImageCache for prepared JPEG bytes.
// - Equivalent visible projections are hash-deduped before disk/reload work.
// - remainingSeconds is nil for an untouched episode. A non-nil value means
//   playback progress is positive, allowing the extension to label total
//   duration and resumed-episode remaining time without opening app storage.
// - Thumbnail filenames include episode identity AND artwork source identity.
//   Existing matching files are reused without invoking ArtworkImageCache; an
//   artwork URL change naturally creates a new filename and one fresh render.
// - Publication diagnostics expose projection, lookup, artwork, persistence,
//   and timeline-reload timings so asynchronous artwork latency is not confused
//   with continuous main-actor blocking.
// - OS BGTask execution suppresses all nonessential projection work before
//   domain projection/artwork preparation begins. Reasons accumulate and resume
//   only when AppState confirms foreground or active-audio runtime, or on the
//   next foreground/domain trigger.
// - This coordinator owns no playback, queue, download, archive, or navigation
//   policy and must not become a general application event bus.

actor WidgetSnapshotPersistence {
    struct Result: Sendable {
        let snapshotByteCount: Int
        let artworkCount: Int
    }

    private let storage: WidgetSharedStorage

    init(storage: WidgetSharedStorage = WidgetSharedStorage()) {
        self.storage = storage
    }

    func existingThumbnailFilenames() -> Set<String> {
        (try? storage.thumbnailFilenames()) ?? []
    }

    func publish(
        snapshot: WidgetSnapshot,
        thumbnails: [String: Data]
    ) throws -> Result {
        let previousFilenames = (try? storage.read())?.episodes.reduce(
            into: Set<String>()
        ) { result, episode in
            if let filename = episode.thumbnailFilename {
                result.insert(filename)
            }
        } ?? []

        for (filename, data) in thumbnails {
            try storage.writeThumbnail(data, filename: filename)
        }
        try storage.write(snapshot)

        let currentFilenames = snapshot.episodes.reduce(
            into: Set<String>()
        ) { result, episode in
            if let filename = episode.thumbnailFilename {
                result.insert(filename)
            }
        }
        try storage.removeThumbnails(
            except: currentFilenames.union(previousFilenames)
        )

        let byteCount = (
            try? storage.snapshotURL().resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        ) ?? 0
        return Result(
            snapshotByteCount: byteCount,
            artworkCount: currentFilenames.count
        )
    }
}

@MainActor
final class WidgetSnapshotCoordinator {
    typealias ArtworkLoader = @Sendable (URL) async -> Data?
    typealias TimelineReloader = @MainActor () -> Void

    private struct EpisodeProjection {
        let episode: Episode
        let podcastTitle: String
        let artworkURL: URL?
        let remainingSeconds: TimeInterval?
        let isCurrent: Bool
    }

    private struct FingerprintEnvelope: Codable {
        let upNextTotalCount: Int
        let isPlaying: Bool
        let episodes: [WidgetDisplayEpisode]
        let artworkSources: [String]
    }

    private let queueCoordinator: QueueCoordinator
    private let playbackCoordinator: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let playbackPositionStore: PlaybackPositionStore
    private let persistence: WidgetSnapshotPersistence
    private let artworkLoader: ArtworkLoader
    private let reloadTimeline: TimelineReloader
    private let logger: AppLogger
    private let now: () -> Date
    private let debounceDuration: Duration

    private var cancellables = Set<AnyCancellable>()
    private var pendingReasons = Set<String>()
    private var debounceTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var lastPublishedHash: String?
    private var lastPublicationDiagnosticAt: Date?
    private var hasStarted = false

    init(
        queueCoordinator: QueueCoordinator,
        playbackCoordinator: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        playbackPositionStore: PlaybackPositionStore,
        persistence: WidgetSnapshotPersistence = WidgetSnapshotPersistence(),
        artworkLoader: @escaping ArtworkLoader = { url in
            await ArtworkImageCache.shared.widgetJPEGData(for: url)
        },
        reloadTimeline: @escaping TimelineReloader = {
            WidgetCenter.shared.reloadTimelines(
                ofKind: WidgetSharedConfiguration.widgetKind
            )
        },
        logger: AppLogger = .shared,
        now: @escaping () -> Date = Date.init,
        debounceDuration: Duration = .milliseconds(350)
    ) {
        self.queueCoordinator = queueCoordinator
        self.playbackCoordinator = playbackCoordinator
        self.subscriptionStore = subscriptionStore
        self.playbackPositionStore = playbackPositionStore
        self.persistence = persistence
        self.artworkLoader = artworkLoader
        self.reloadTimeline = reloadTimeline
        self.logger = logger
        self.now = now
        self.debounceDuration = debounceDuration
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        queueCoordinator.$episodes
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.schedulePublication(reason: "queue.changed")
            }
            .store(in: &cancellables)

        queueCoordinator.$upNextEpisode
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.schedulePublication(reason: "upNext.changed")
            }
            .store(in: &cancellables)

        playbackCoordinator.$currentEpisode
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.schedulePublication(reason: "playback.episodeChanged")
            }
            .store(in: &cancellables)

        playbackCoordinator.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.schedulePublication(reason: "playback.stateChanged")
            }
            .store(in: &cancellables)

        subscriptionStore.presentationDidChange
            .sink { [weak self] in
                self?.schedulePublication(reason: "presentation.changed")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )
        .sink { [weak self] _ in
            self?.schedulePublication(
                reason: "lifecycle.background",
                immediately: true
            )
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )
        .sink { [weak self] _ in
            self?.schedulePublication(
                reason: "lifecycle.active",
                immediately: true
            )
        }
        .store(in: &cancellables)

        schedulePublication(reason: "widget.startup", immediately: true)
    }

    func stop() {
        hasStarted = false
        cancellables.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        publicationTask?.cancel()
        publicationTask = nil
        pendingReasons.removeAll()
    }

    func schedulePublication(
        reason: String,
        immediately: Bool = false
    ) {
        guard hasStarted else { return }
        pendingReasons.insert(reason)
        if BackgroundWakeMonitor.shared.hasActiveWake {
            BackgroundWakeMonitor.shared.recordWidgetProjectionDeferred()
            debounceTask?.cancel()
            debounceTask = nil
            return
        }
        guard publicationTask == nil else { return }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !immediately {
                try? await Task.sleep(for: debounceDuration)
            }
            guard !Task.isCancelled else { return }
            debounceTask = nil
            beginPublicationLoop()
        }
    }

    /// Called by the single BGTask completion-gate winner after closing the
    /// BackgroundWakeMonitor session. Plain suspended background keeps the
    /// reasons pending; foreground or active audio has execution time to publish
    /// one coalesced final projection without consuming the finite BGTask window.
    func backgroundTaskExecutionDidEnd(
        allowImmediatePublication: Bool
    ) {
        guard hasStarted,
              allowImmediatePublication,
              !pendingReasons.isEmpty else {
            return
        }
        schedulePublication(
            reason: "backgroundTask.finished",
            immediately: true
        )
    }

    private func beginPublicationLoop() {
        guard publicationTask == nil, !pendingReasons.isEmpty else { return }
        publicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !pendingReasons.isEmpty {
                let reasons = pendingReasons.sorted()
                pendingReasons.removeAll()
                await publish(reasons: reasons)

                if !pendingReasons.isEmpty {
                    try? await Task.sleep(for: debounceDuration)
                }
            }
            publicationTask = nil
        }
    }

    private func publish(reasons: [String]) async {
        let startedAt = CFAbsoluteTimeGetCurrent()
        var memorySample = ResourceMonitor.shared.memoryFootprintSample()
        let projectionStartedAt = CFAbsoluteTimeGetCurrent()
        let projections = makeEpisodeProjections()
        let projectionMs =
            (CFAbsoluteTimeGetCurrent() - projectionStartedAt) * 1_000
        if projectionMs >= 100 {
            logger.warning(
                "ui.mainActorOperationSlow",
                "Widget projection occupied the main actor",
                metadata: [
                    "operation": "widget.makeEpisodeProjections",
                    "durationMs": String(format: "%.1f", projectionMs),
                    "reason": reasons.joined(separator: ","),
                    "queueCount": "\(queueCoordinator.episodes.count)"
                ]
            )
        }
        let lookupStartedAt = CFAbsoluteTimeGetCurrent()
        let existingThumbnails = await persistence.existingThumbnailFilenames()
        let thumbnailLookupMs =
            (CFAbsoluteTimeGetCurrent() - lookupStartedAt) * 1_000
        let artworkStartedAt = CFAbsoluteTimeGetCurrent()
        let prepared = await prepareDisplayEpisodes(
            projections,
            existingThumbnails: existingThumbnails
        )
        memorySample = ResourceMonitor.shared.logMemoryStageDelta(
            stage: "widget.artworkPreparation",
            from: memorySample,
            context: ["reason": reasons.joined(separator: ",")]
        )
        let artworkPreparationMs =
            (CFAbsoluteTimeGetCurrent() - artworkStartedAt) * 1_000
        guard !Task.isCancelled else { return }

        let currentIdentity = playbackCoordinator.currentEpisode.map {
            stableIdentity(for: $0)
        }
        let followingCount = max(
            0,
            Set(
                queueCoordinator.episodes
                    .map(stableIdentity)
                    .filter { $0 != currentIdentity }
            ).count
        )
        let isPlaying = playbackCoordinator.isPlaying
            && projections.first?.isCurrent == true
        let snapshot = WidgetSnapshot(
            generatedAt: now(),
            upNextTotalCount: followingCount,
            isPlaying: isPlaying,
            episodes: prepared.episodes
        )
        let hash = fingerprint(
            snapshot: snapshot,
            artworkSources: projections.map {
                $0.artworkURL?.absoluteString ?? ""
            }
        )
        let reason = reasons.joined(separator: ",")

        guard hash != lastPublishedHash else {
            logger.verbose(
                "widget.publishSkipped",
                "Skipped equivalent widget snapshot",
                metadata: [
                    "reason": reason,
                    "dedupeHash": hash,
                    "episodeCount": "\(snapshot.episodes.count)"
                ]
            )
            return
        }

        do {
            let persistenceStartedAt = CFAbsoluteTimeGetCurrent()
            let result = try await persistence.publish(
                snapshot: snapshot,
                thumbnails: prepared.thumbnails
            )
            _ = ResourceMonitor.shared.logMemoryStageDelta(
                stage: "widget.persistence",
                from: memorySample,
                context: [
                    "reason": reason,
                    "artworkCount": "\(prepared.thumbnails.count)"
                ]
            )
            let persistenceMs =
                (CFAbsoluteTimeGetCurrent() - persistenceStartedAt) * 1_000
            guard !Task.isCancelled else { return }
            lastPublishedHash = hash
            let reloadStartedAt = CFAbsoluteTimeGetCurrent()
            reloadTimeline()
            let reloadMs =
                (CFAbsoluteTimeGetCurrent() - reloadStartedAt) * 1_000
            let publishMetadata = [
                    "reason": reason,
                    "dedupeHash": hash,
                    "dedupeResult": "published",
                    "episodeCount": "\(snapshot.episodes.count)",
                    "artworkCount": "\(result.artworkCount)",
                    "artworkRendered": "\(prepared.renderedCount)",
                    "artworkReused": "\(prepared.reusedCount)",
                    "snapshotBytes": "\(result.snapshotByteCount)",
                    "widgetKind": WidgetSharedConfiguration.widgetKind,
                    "projectionMs": String(format: "%.1f", projectionMs),
                    "thumbnailLookupMs": String(
                        format: "%.1f", thumbnailLookupMs
                    ),
                    "artworkPreparationMs": String(
                        format: "%.1f", artworkPreparationMs
                    ),
                    "persistenceMs": String(format: "%.1f", persistenceMs),
                    "timelineReloadMs": String(format: "%.1f", reloadMs),
                    "durationMs": String(
                        format: "%.1f",
                        (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
                    )
                ]
            let materialIdentityChange = reason.contains("episodeChanged")
                || reason.contains("queue.changed")
            let periodicSummaryDue = lastPublicationDiagnosticAt.map {
                now().timeIntervalSince($0) >= 60 * 60
            } ?? true
            if materialIdentityChange || periodicSummaryDue {
                lastPublicationDiagnosticAt = now()
                logger.info(
                    "widget.published",
                    "Published material widget display snapshot",
                    metadata: publishMetadata
                )
            } else {
                logger.verbose(
                    "widget.published",
                    "Published routine widget display snapshot",
                    metadata: publishMetadata
                )
            }
        } catch {
            logger.warning(
                "widget.publishFailed",
                "Could not publish widget display snapshot",
                metadata: [
                    "reason": reason,
                    "episodeCount": "\(snapshot.episodes.count)",
                    "error": String(describing: error)
                ],
                alwaysPersist: true
            )
        }
    }

    private func makeEpisodeProjections() -> [EpisodeProjection] {
        let currentIdentity = playbackCoordinator.currentEpisode.map(
            stableIdentity
        )
        var ordered: [Episode] = []
        var includedIdentities = Set<String>()

        if let current = playbackCoordinator.currentEpisode,
           let resolved = freshEpisode(for: current),
           isPlayable(resolved) {
            ordered.append(resolved)
            includedIdentities.insert(stableIdentity(for: resolved))
        }
        for queued in queueCoordinator.episodes {
            guard let resolved = freshEpisode(for: queued),
                  isPlayable(resolved),
                  includedIdentities.insert(
                    stableIdentity(for: resolved)
                  ).inserted
            else { continue }
            ordered.append(resolved)
        }

        if ordered.isEmpty {
            ordered = recentDownloadedFallback()
        }

        return ordered
            .prefix(WidgetSnapshot.maximumDisplayEpisodeCount)
            .compactMap { episode in
                guard let subscription = subscriptionStore.subscription(
                    id: episode.subscriptionID
                ) else { return nil }
                let isCurrent = stableIdentity(for: episode)
                    == currentIdentity
                let elapsed = isCurrent
                    ? playbackCoordinator.clock.time
                    : playbackPositionStore.savedTime(for: episode)
                // Preserve the semantic difference between an untouched
                // episode and one with genuine resume progress. Publishing the
                // full duration as "remaining" made every widget row say
                // "left" even when playback had never begun.
                let remaining = elapsed > 0
                    ? episode.durationSeconds.map { max(0, $0 - elapsed) }
                    : nil
                return EpisodeProjection(
                    episode: episode,
                    podcastTitle: subscription.title,
                    artworkURL:
                        episode.artworkURL ?? subscription.artworkURL,
                    remainingSeconds: remaining,
                    isCurrent: isCurrent
                )
            }
    }

    private func freshEpisode(for episode: Episode) -> Episode? {
        guard let subscription = subscriptionStore.subscription(
            id: episode.subscriptionID
        ) else { return nil }
        let candidates = subscription.episodes.isEmpty
            ? subscription.latestEpisode.map { [$0] } ?? []
            : subscription.episodes
        if let exact = candidates.first(where: { $0.id == episode.id }) {
            return exact
        }
        let identity = PlaybackPositionStore.key(for: episode)
        return candidates.first {
            PlaybackPositionStore.key(for: $0) == identity
        }
    }

    private func recentDownloadedFallback() -> [Episode] {
        subscriptionStore.subscriptions
            .flatMap(\.episodes)
            .filter(isPlayable)
            .sorted {
                ($0.downloadedAt ?? $0.publishedAt ?? .distantPast)
                    > ($1.downloadedAt ?? $1.publishedAt ?? .distantPast)
            }
            .prefix(WidgetSnapshot.maximumDisplayEpisodeCount)
            .map { $0 }
    }

    private func isPlayable(_ episode: Episode) -> Bool {
        episode.downloadState == .downloaded
            && (episode.localFileURL != nil || episode.localFileName != nil)
            && episode.playedState != .played
            && episode.playedState != .archived
    }

    private func prepareDisplayEpisodes(
        _ projections: [EpisodeProjection],
        existingThumbnails: Set<String>
    ) async -> (
        episodes: [WidgetDisplayEpisode],
        thumbnails: [String: Data],
        renderedCount: Int,
        reusedCount: Int
    ) {
        let requests = projections.enumerated().compactMap {
            index, projection -> (Int, URL, String)? in
            guard let artworkURL = projection.artworkURL else { return nil }
            return (
                index,
                artworkURL,
                thumbnailFilename(
                    for: projection.episode,
                    artworkURL: artworkURL
                )
            )
        }

        var loaded: [Int: (filename: String, data: Data?)] = [:]
        await withTaskGroup(
            of: (Int, String, Data?).self
        ) { group in
            for (index, url, filename) in requests {
                guard !existingThumbnails.contains(filename) else {
                    loaded[index] = (filename, nil)
                    continue
                }
                group.addTask { [artworkLoader] in
                    (
                        index,
                        filename,
                        await artworkLoader(url)
                    )
                }
            }
            for await (index, filename, data) in group {
                loaded[index] = (filename, data)
            }
        }

        var thumbnails: [String: Data] = [:]
        let episodes = projections.enumerated().map {
            index, projection -> WidgetDisplayEpisode in
            let prepared = loaded[index]
            if let data = prepared?.data, let filename = prepared?.filename {
                thumbnails[filename] = data
            }
            let availableFilename: String? = {
                guard let filename = prepared?.filename else { return nil }
                return prepared?.data != nil
                    || existingThumbnails.contains(filename)
                    ? filename
                    : nil
            }()
            return WidgetDisplayEpisode(
                identity: WidgetEpisodeIdentity(
                    subscriptionID: projection.episode.subscriptionID,
                    episodeKey: PlaybackPositionStore.key(
                        for: projection.episode
                    )
                ),
                episodeTitle: projection.episode.title,
                podcastTitle: projection.podcastTitle,
                durationSeconds: projection.episode.durationSeconds,
                remainingSeconds: projection.remainingSeconds,
                isCurrent: projection.isCurrent,
                thumbnailFilename: availableFilename,
                isVideo: projection.episode.mediaKind == .video,
                isExplicit: projection.episode.isExplicit
            )
        }
        let reusedCount = requests.reduce(into: 0) { count, request in
            if existingThumbnails.contains(request.2) { count += 1 }
        }
        return (
            episodes,
            thumbnails,
            thumbnails.count,
            reusedCount
        )
    }

    private func thumbnailFilename(
        for episode: Episode,
        artworkURL: URL
    ) -> String {
        let identity = [
            episode.subscriptionID.uuidString,
            PlaybackPositionStore.key(for: episode),
            artworkURL.absoluteString
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private func stableIdentity(for episode: Episode) -> String {
        [
            episode.subscriptionID.uuidString,
            PlaybackPositionStore.key(for: episode)
        ].joined(separator: "|")
    }

    private func fingerprint(
        snapshot: WidgetSnapshot,
        artworkSources: [String]
    ) -> String {
        let envelope = FingerprintEnvelope(
            upNextTotalCount: snapshot.upNextTotalCount,
            isPlaying: snapshot.isPlaying,
            episodes: snapshot.episodes,
            artworkSources: artworkSources
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(envelope)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
