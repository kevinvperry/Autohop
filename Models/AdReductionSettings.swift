import Foundation

/// Local-only consent and routing. Unselected feeds (including private feeds) stay direct.
struct AdReductionSettings: Equatable, Codable {
    var enabled = false
    var endpoint = ""
    var publicSubscriptionIDs: Set<UUID> = []
    var normalDownloadEpisodeIDs: Set<UUID> = []
}

