import Foundation

// AI CONTEXT — App/WidgetDeepLinkParser.swift
//
// PURPOSE:
// Strict Stage 3 parser for widget navigation. It accepts only the four
// documented autohop:// routes and produces typed commands. Unknown hosts,
// credentials, ports, fragments, extra path components, invalid UUIDs, and
// empty/oversized episode keys are rejected rather than partially handled.

enum WidgetDeepLinkDestination: Equatable {
    case player
    case upNext
    case discover
    case episode(WidgetEpisodeIdentity)
}

enum WidgetDeepLinkParseResult: Equatable {
    case destination(WidgetDeepLinkDestination)
    case rejected
}

struct WidgetDeepLinkParser {
    private let maximumEpisodeKeyLength = 2_048

    func parse(_ url: URL) -> WidgetDeepLinkParseResult {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        components.scheme?.lowercased() == WidgetDeepLink.scheme,
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.fragment == nil,
        let host = components.host?.lowercased()
        else { return .rejected }

        let encodedPathParts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard encodedPathParts.allSatisfy({ !$0.isEmpty }),
              encodedPathParts.allSatisfy({
                  $0.removingPercentEncoding != nil
              })
        else { return .rejected }
        let pathParts = encodedPathParts.compactMap {
            $0.removingPercentEncoding
        }
        switch host {
        case "player":
            return pathParts.isEmpty ? .destination(.player) : .rejected
        case "up-next":
            return pathParts.isEmpty ? .destination(.upNext) : .rejected
        case "discover":
            return pathParts.isEmpty ? .destination(.discover) : .rejected
        case "episode":
            guard pathParts.count == 2,
                  let subscriptionID = UUID(uuidString: pathParts[0]),
                  !pathParts[1].isEmpty,
                  pathParts[1].count <= maximumEpisodeKeyLength
            else { return .rejected }
            return .destination(.episode(WidgetEpisodeIdentity(
                subscriptionID: subscriptionID,
                episodeKey: pathParts[1]
            )))
        default:
            return .rejected
        }
    }
}
