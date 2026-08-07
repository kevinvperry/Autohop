import Foundation
import AutohopCore

// AI CONTEXT — Resolves missing show notes only when the user explicitly opens
// Description. Queue/history records are intentionally compact and may omit
// notes, especially for old episodes. This selected-feed lookup is bounded to
// 250 RSS items: it never sweeps the Library and never performs an unbounded
// archive parse that could compromise Apple TV memory.
extension TVAppModel {
    func episodeWithResolvedDescription(_ source: Episode) async -> Episode {
        if source.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return source
        }
        guard let subscription = playbackModel.currentSubscriptionForDescription
                ?? subscription(id: source.subscriptionID) else {
            return source
        }
        do {
            let feed = try await episodeFeedLoader.fetch(feedURL: subscription.feedURL, limit: 250)
            guard let parsed = feed.episodes.first(where: {
                $0.guid == source.guid || $0.audioURL == source.audioURL
            }) ?? feed.episodes.first(where: {
                Self.normalizedDescriptionLookupTitle($0.title)
                    == Self.normalizedDescriptionLookupTitle(source.title)
            }) else {
                return source
            }
            var resolved = source
            resolved.description = parsed.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? parsed.description
                : parsed.subtitle
            resolved.subtitle = parsed.subtitle ?? source.subtitle
            AppLogger.shared.info(
                "tv.description.resolved",
                "Resolved missing episode description from publisher feed",
                metadata: ["episodeID": source.id.uuidString, "matchedByGUID": "\(parsed.guid == source.guid)"],
                alwaysPersist: true
            )
            return resolved
        } catch {
            AppLogger.shared.warning(
                "tv.description.resolveFailed",
                "Could not resolve missing episode description",
                metadata: ["episodeID": source.id.uuidString, "error": String(describing: type(of: error))],
                alwaysPersist: true
            )
            return source
        }
    }

    private static func normalizedDescriptionLookupTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
