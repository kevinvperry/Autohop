import Foundation

// AI CONTEXT — Widgets/Shared/WidgetDeepLink.swift
//
// PURPOSE:
// Canonical URL construction shared by widget UI and app-side parser tests.
// Navigation URLs never carry media paths or credentials. Episode links carry
// only the same untrusted stable identity used by the playback intent.

enum WidgetDeepLink {
    static let scheme = "autohop"

    static let player = URL(string: "autohop://player")!
    static let upNext = URL(string: "autohop://up-next")!
    static let discover = URL(string: "autohop://discover?source=widget")!

    static func episode(_ identity: WidgetEpisodeIdentity) -> URL? {
        var pathAllowed = CharacterSet.alphanumerics
        pathAllowed.formUnion(CharacterSet(charactersIn: "-._~"))
        guard let encodedKey = identity.episodeKey.addingPercentEncoding(
            withAllowedCharacters: pathAllowed
        ) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "episode"
        components.percentEncodedPath =
            "/\(identity.subscriptionID.uuidString)/\(encodedKey)"
        components.queryItems = [
            URLQueryItem(name: "source", value: "widget")
        ]
        return components.url
    }
}
