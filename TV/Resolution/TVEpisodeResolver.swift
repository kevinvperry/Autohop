import Foundation
import AutohopCore

// AI CONTEXT — Canonical tvOS episode resolution.
//
// Phone-authored QueueSnapshot and ListeningHistory records can outlive an app
// installation, a subscription UUID, or the schema field that now identifies
// audio versus video. Before this type existed, TVAppModel reconstructed those
// two sources independently: queue entries inferred media kind from the URL,
// while legacy history entries defaulted missing mediaKind to audio. Playback
// then performed a third subscription-title lookup. The same Windows Weekly
// episode could consequently render as video in Up Next, audio in Continue
// Watching, and play through a transient subscription at 1x.
//
// This resolver is the ONLY tvOS compatibility boundary for those records. It
// deliberately lives in the TV target: no iPhone queue, history, subscription,
// or playback behaviour is changed. Resolution is conservative:
//  1. stable history/queue identity or exact local UUID;
//  2. exact enclosure URL;
//  3. globally unique GUID/title recovery supplied by TVAppModel;
//  4. a self-contained projection, with URL media inference for legacy rows.
//
// Podcast title normalization never strips "(Video)" or provider suffixes.
// "Windows Weekly" and "Windows Weekly (Video)" remain distinct subscriptions
// so playback preferences and media metadata cannot cross-contaminate.
struct TVEpisodeResolver {
    struct Context {
        let subscriptions: [Subscription]
        let subscriptionsByID: [UUID: Subscription]
        let queueItems: [QueueModel.ResolvedQueueItem]
        let legacyQueueEpisodes: [String: Episode]
        let uniqueEpisodesByGUID: [String: Episode]
        let uniqueEpisodesByNormalizedTitle: [String: Episode]
    }

    struct PlaybackResolution {
        let episode: Episode
        let subscription: Subscription
        let historyEntry: ListeningHistoryEntry?
        /// Only legacy/incomplete history with an extensionless enclosure needs
        /// an AVAsset track probe. Declared video and recognised URL extensions
        /// can enter playback immediately.
        let needsAssetMediaProbe: Bool
    }

    let context: Context

    func playbackResolution(
        for episode: Episode,
        candidateHistory: ListeningHistoryEntry?
    ) -> PlaybackResolution {
        let history = candidateHistory.flatMap {
            historyEntry($0, belongsTo: episode) ? $0 : nil
        }
        let resolvedEpisode = Self.canonicalized(history.flatMap(resolveEpisode(from:)) ?? episode)
        var resolvedSubscription = resolveSubscription(for: resolvedEpisode, history: history)
        if let speed = history?.playbackSpeed, speed.isFinite, speed > 0 {
            resolvedSubscription.playbackPreference.speed = speed
        }
        return PlaybackResolution(
            episode: resolvedEpisode,
            subscription: resolvedSubscription,
            historyEntry: history,
            needsAssetMediaProbe: history?.mediaKind == nil
                && Self.inferredMediaKind(for: resolvedEpisode.audioURL) == nil
        )
    }

    func resolveEpisode(from entry: ListeningHistoryEntry) -> Episode? {
        if let subscription = context.subscriptionsByID[entry.subscriptionID],
           let exact = subscription.episodes.first(where: {
               PlaybackPositionStore.key(for: $0) == entry.id || $0.id == entry.episodeID
           }) {
            return exact
        }

        if let streamURL = entry.streamURL {
            var projected = Episode(
                id: entry.episodeID,
                subscriptionID: entry.subscriptionID,
                guid: Self.guid(fromHistoryID: entry.id) ?? entry.id,
                title: entry.episodeTitle,
                audioURL: streamURL,
                mediaKind: entry.mediaKind ?? Self.inferredMediaKind(for: streamURL) ?? .audio
            )
            projected.artworkURL = entry.artworkURL
            projected.publishedAt = entry.publishedAt
            projected.durationSeconds = entry.durationSeconds ?? entry.episodeDurationSeconds
            return projected
        }

        if let guid = Self.guid(fromHistoryID: entry.id),
           let recovered = context.uniqueEpisodesByGUID[guid] {
            return recovered
        }
        if let recovered = context.legacyQueueEpisodes[entry.id] {
            return recovered
        }
        return context.uniqueEpisodesByNormalizedTitle[Self.normalized(entry.episodeTitle)]
    }

    func resolveSubscription(
        for episode: Episode,
        history: ListeningHistoryEntry?
    ) -> Subscription {
        if let exact = context.subscriptionsByID[episode.subscriptionID] {
            return exact
        }

        let queueTitle = context.queueItems.first {
            $0.episodeKey == PlaybackPositionStore.key(for: episode)
                || $0.episode?.id == episode.id
                || $0.episode?.audioURL == episode.audioURL
        }?.podcastTitle
        let wantedTitle = history?.podcastTitle ?? queueTitle
        if let wantedTitle {
            let identity = Self.normalized(wantedTitle)
            let candidates = context.subscriptions.filter {
                Self.normalized($0.title) == identity
            }
            if candidates.count == 1 {
                return candidates[0]
            }
        }

        return projectionSubscription(
            for: episode,
            title: wantedTitle ?? queueTitle ?? "Podcast"
        )
    }

    func historyEntry(
        _ entry: ListeningHistoryEntry,
        belongsTo episode: Episode
    ) -> Bool {
        if entry.id == PlaybackPositionStore.key(for: episode)
            || entry.episodeID == episode.id
            || entry.streamURL == episode.audioURL {
            return true
        }
        guard Self.normalized(entry.episodeTitle) == Self.normalized(episode.title) else {
            return false
        }
        // A title-only fallback is safe only when the subscription identity is
        // also consistent. This prevents similarly named episodes from another
        // show inheriting resume position or playback settings.
        if entry.subscriptionID == episode.subscriptionID {
            return true
        }
        let queueTitle = context.queueItems.first {
            $0.episode?.id == episode.id || $0.episode?.audioURL == episode.audioURL
        }?.podcastTitle
        return queueTitle.map(Self.normalized) == Self.normalized(entry.podcastTitle)
    }

    private func projectionSubscription(for episode: Episode, title: String) -> Subscription {
        Subscription(
            id: episode.subscriptionID,
            feedURL: episode.audioURL,
            title: title,
            artworkURL: episode.artworkURL,
            priorityRank: Int.max
        )
    }

    static func inferredMediaKind(for url: URL) -> EpisodeMediaKind? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "webm":
            return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus":
            return .audio
        default:
            return nil
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func canonicalGUID(_ value: String) -> String {
        var guid = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let marker = guid.range(of: "|guid:") {
            let unwrapped = String(guid[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unwrapped.isEmpty, unwrapped != guid else { break }
            guid = unwrapped
        }
        return guid
    }

    static func canonicalized(_ episode: Episode) -> Episode {
        var result = episode
        result.guid = canonicalGUID(episode.guid)
        return result
    }

    private static func guid(fromHistoryID id: String) -> String? {
        guard id.contains("|guid:") else { return nil }
        let guid = canonicalGUID(id)
        return guid.isEmpty ? nil : guid
    }
}
