import Foundation
import AutohopCore

// AI CONTEXT — Pure Continue Listening projection boundary. History remains
// authoritative for display; local episode resolution only controls playability.
struct TVContinueListeningProjector {
    static func project(
        entry: ListeningHistoryEntry?,
        resolver: TVEpisodeResolver
    ) -> TVContinueListening? {
        entry.map { TVContinueListening(entry: $0, episode: resolver.resolveEpisode(from: $0)) }
    }
}
