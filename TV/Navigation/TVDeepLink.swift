import Foundation
import Observation
import AutohopCore

// AI CONTEXT — Strict identity-only routes accepted from the Top Shelf
// extension. URLs never carry media/artwork URLs or trusted display data.
// TVPendingRouteCoordinator generation-owns only the newest route across cold
// bootstrap so stale Home Screen actions cannot execute later.

enum TVDeepLinkAction: String, Equatable, Sendable {
    case episode
    case play
}

struct TVDeepLink: Equatable, Sendable {
    let action: TVDeepLinkAction
    let subscriptionID: UUID
    let episodeKey: String
}

enum TVDeepLinkParser {
    static func parse(_ url: URL) -> TVDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "autohop",
              components.host?.lowercased() == "tv",
              let action = TVDeepLinkAction(rawValue: components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              components.fragment == nil
        else { return nil }
        let queryItems = components.queryItems ?? []
        guard queryItems.count == 2,
              Set(queryItems.map(\.name)) == ["subscriptionID", "episodeKey"],
              queryItems.filter({ $0.name == "subscriptionID" }).count == 1,
              queryItems.filter({ $0.name == "episodeKey" }).count == 1,
              let subscriptionValue = queryItems.first(where: { $0.name == "subscriptionID" })?.value,
              let subscriptionID = UUID(uuidString: subscriptionValue),
              let episodeKey = queryItems.first(where: { $0.name == "episodeKey" })?.value,
              !episodeKey.isEmpty, episodeKey.count <= 4_096
        else { return nil }
        return .init(action: action, subscriptionID: subscriptionID, episodeKey: episodeKey)
    }
}

@MainActor
@Observable
final class TVPendingRouteCoordinator {
    private(set) var route: TVDeepLink?
    private(set) var generation: UInt64 = 0

    func accept(_ url: URL) {
        guard let parsed = TVDeepLinkParser.parse(url) else {
            AppLogger.shared.warning("tv.topShelf.deepLinkRejected", "Rejected malformed TV deep link")
            return
        }
        generation &+= 1
        route = parsed
        AppLogger.shared.info("tv.topShelf.deepLinkAccepted", "Accepted TV Top Shelf route", metadata: [
            "action": parsed.action.rawValue,
            "generation": "\(generation)"
        ])
    }

    func clear(ifGeneration owned: UInt64) {
        guard owned == generation else { return }
        route = nil
    }
}
