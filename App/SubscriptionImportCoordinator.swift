//
//  SubscriptionImportCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 9 owner for OPML import/export and bulk feed subscription workflows.
//  It is MainActor-isolated because SubscriptionStore is the single mutable
//  library writer. Imports hold security-scoped file access only for the parse
//  and materialization operation, skip existing feed URLs, continue after
//  individual failures, and publish progress through this dedicated observable.
//
//  Feed materialization uses the same FeedServicing boundary as normal refresh.
//  SubscriptionStore membership signals drive OnboardingCoordinator, so bulk
//  completion preserves the existing silent multi-subscription milestone.
//  This coordinator does not download media, modify playback, or own routing.
//

import Foundation

struct SubscriptionImportSummary: Equatable {
    var imported: Int
    var failed: Int
}

@MainActor
final class SubscriptionImportCoordinator: ObservableObject {
    @Published private(set) var progress: (current: Int, total: Int)?
    @Published private(set) var message: String?

    private let feedService: FeedServicing
    private let subscriptionStore: SubscriptionStore
    private let logger: AppLogger
    private let episodeLimit: Int

    init(
        feedService: FeedServicing,
        subscriptionStore: SubscriptionStore,
        episodeLimit: Int = 50,
        logger: AppLogger? = nil
    ) {
        self.feedService = feedService
        self.subscriptionStore = subscriptionStore
        self.episodeLimit = episodeLimit
        self.logger = logger ?? .shared
    }

    func importOPML(from fileURL: URL) async -> SubscriptionImportSummary {
        let canAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if canAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let newURLs: [URL]
        do {
            newURLs = try await OPMLService().importSubscriptions(
                from: fileURL,
                existingFeedURLs: Set(subscriptionStore.subscriptions.map(\.feedURL))
            )
        } catch {
            message = "Could not read the OPML file."
            logger.error("opml.importFailed", "Could not read OPML file", metadata: [
                "file": fileURL.lastPathComponent,
                "error": String(describing: error)
            ])
            return SubscriptionImportSummary(imported: 0, failed: 0)
        }

        guard !newURLs.isEmpty else {
            message = "No new podcasts found in the OPML file."
            logger.info("opml.import", "No new podcasts found", metadata: [
                "file": fileURL.lastPathComponent
            ])
            return SubscriptionImportSummary(imported: 0, failed: 0)
        }

        var imported = 0
        var failed = 0
        for (index, url) in newURLs.enumerated() {
            progress = (index + 1, newURLs.count)
            do {
                try await materialize(feedURL: url)
                imported += 1
            } catch {
                logger.error("opml.importPodcastFailed", "Could not import podcast", metadata: [
                    "feedHost": url.host ?? "unknown",
                    "error": String(describing: error)
                ])
                failed += 1
            }
        }

        progress = nil
        message = imported > 0
            ? "Imported \(imported) podcast\(imported == 1 ? "" : "s")."
            : "No podcasts could be imported (\(failed) failed)."
        logger.info("opml.importComplete", "OPML import complete", metadata: [
            "imported": "\(imported)",
            "failed": "\(failed)"
        ])
        return SubscriptionImportSummary(imported: imported, failed: failed)
    }

    func exportOPML() -> Data? {
        try? OPMLService().exportSubscriptions(subscriptionStore.subscriptions)
    }

    @discardableResult
    func subscribeToFeedURLs(_ urls: [URL]) async -> Int {
        var existing = Set(subscriptionStore.subscriptions.map(\.feedURL))
        var imported = 0
        for url in urls where !existing.contains(url) {
            do {
                try await materialize(feedURL: url)
                existing.insert(url)
                imported += 1
            } catch {
                logger.error("starterPack.subscribeFailed", "Could not subscribe to feed", metadata: [
                    "feedHost": url.host ?? "unknown",
                    "error": String(describing: error)
                ])
            }
        }
        return imported
    }

    private func materialize(feedURL: URL) async throws {
        let subscriptionID = UUID()
        let result = try await feedService.refresh(
            feedURL: feedURL,
            subscriptionID: subscriptionID,
            episodeLimit: episodeLimit
        )
        _ = try subscriptionStore.addSubscription(
            id: subscriptionID,
            feedURL: feedURL,
            title: result.subscriptionTitle,
            description: result.description,
            author: result.author,
            artworkURL: result.artworkURL,
            categories: result.categories,
            isExplicit: result.isExplicit,
            latestEpisode: result.latestEpisode,
            insertAtBottom: true
        )
        subscriptionStore.updateEpisodes(
            subscriptionID: subscriptionID,
            episodes: result.episodes
        )
        logger.info("opml.importPodcast", "Imported podcast", metadata: [
            "podcast": result.subscriptionTitle,
            "feedHost": feedURL.host ?? "unknown"
        ])
    }
}
