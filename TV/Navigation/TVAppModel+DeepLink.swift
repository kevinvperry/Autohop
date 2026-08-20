import Foundation
import AutohopCore

// AI CONTEXT — Exact Top Shelf identity resolver. It consults only the current
// compact Continue/Up Next projections, performs at most one targeted refresh,
// and never substitutes a different episode when the selected identity is gone.

struct TVDeepLinkResolution {
    let episode: Episode
    let podcastTitle: String
}

extension TVAppModel {
    func resolveTopShelfRoute(_ route: TVDeepLink) async -> TVDeepLinkResolution? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        if let current = topShelfResolution(route) {
            logTopShelfResolution(route: route, outcome: "resolvedFromProjection", startedAt: startedAt)
            return current
        }
        await primeLibraryFromCloudSoon(reason: "tv.topShelf.deepLink")
        let result = topShelfResolution(route)
        logTopShelfResolution(
            route: route,
            outcome: result == nil ? "unavailableAfterRefresh" : "resolvedAfterRefresh",
            startedAt: startedAt
        )
        return result
    }

    private func topShelfResolution(_ route: TVDeepLink) -> TVDeepLinkResolution? {
        if let row = queueRows.first(where: {
            $0.id == route.episodeKey && $0.subscriptionID == route.subscriptionID
        }), let episode = row.episode {
            return .init(episode: episode, podcastTitle: row.podcastTitle)
        }
        if let continuation = continueListening,
           let episode = continuation.episode,
           episode.subscriptionID == route.subscriptionID,
           PlaybackPositionStore.key(for: episode) == route.episodeKey {
            return .init(episode: episode, podcastTitle: continuation.entry.podcastTitle)
        }
        return nil
    }

    private func logTopShelfResolution(route: TVDeepLink, outcome: String, startedAt: CFAbsoluteTime) {
        AppLogger.shared.info("tv.topShelf.deepLinkResolved", "Resolved Top Shelf action", metadata: [
            "action": route.action.rawValue,
            "outcome": outcome,
            "ms": "\(max(0, Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)))"
        ], alwaysPersist: outcome == "unavailableAfterRefresh")
    }
}
