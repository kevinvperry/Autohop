import Combine
import CloudKit
import Foundation
import AutohopCore

// AI CONTEXT — Continue Listening/history projection. Extracted from TVAppModel without changing
// product policy; this extension is tvOS-only and coordinated through focused
// observable state owners defined in TVAppFeatureModels.swift.

extension TVAppModel {
    var historyNeedsReload: Bool {
        get { continueListeningModel.needsReload }
        set { continueListeningModel.needsReload = newValue }
    }
    var cachedContinueEntry: ListeningHistoryEntry? {
        get { continueListeningModel.cachedEntry }
        set { continueListeningModel.cachedEntry = newValue }
    }

    func computeContinueListening() -> TVContinueListening? {
        if historyNeedsReload {
            historyNeedsReload = false
            cachedContinueEntry = subscriptionStore.mostRecentInProgressListeningEntry()
        }
        return TVContinueListeningProjector.project(
            entry: cachedContinueEntry,
            resolver: episodeResolver
        )
    }

    func computeRecentHistory() -> [TVHistoryItem] {
        subscriptionStore.recentCompletedListeningEntries(limit: 50).map { entry in
            TVHistoryItem(entry: entry, episode: episodeResolver.resolveEpisode(from: entry))
        }
    }

    /// One compatibility boundary for queue/history/catalog identity. Keeping
    /// its inputs explicit makes the extraction from TVAppModel incremental:
    /// this resolver can move behind a repository later without changing the
    /// already-tested matching rules.
    var episodeResolver: TVEpisodeResolver {
        TVEpisodeResolver(context: .init(
            subscriptions: librarySubscriptions,
            subscriptionsByID: subscriptionsByID,
            queueItems: upNextItems,
            legacyQueueEpisodes: legacyQueueEpisodes,
            uniqueEpisodesByGUID: uniqueEpisodesByGUID,
            uniqueEpisodesByNormalizedTitle: uniqueEpisodesByNormalizedTitle
        ))
    }

}
