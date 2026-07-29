import Foundation

// AI CONTEXT — Models/ShareContent.swift
// Pure, UI-independent sharing policy for the first safe-sharing increment.
// It converts untrusted RSS episode-page/GUID candidates into an optional
// public web link and deliberately has NO enclosure or feed-URL input. This
// makes it structurally impossible for the automatic share path to expose a
// paid media enclosure or private RSS address. UIKit/SwiftUI presentation stays
// in Views/EpisodeShareSheet.swift and Views/PodcastShareSheet.swift.

public enum ShareSubjectKind: String, Codable, Equatable, Sendable {
    case episode
    case podcast
}

public enum ShareLinkQuality: String, Codable, Equatable, Sendable {
    case episodePage
    case probableEpisodePage
}

public struct ResolvedShareLink: Equatable, Sendable {
    public let url: URL
    public let quality: ShareLinkQuality

    public init(url: URL, quality: ShareLinkQuality) {
        self.url = url
        self.quality = quality
    }
}

public enum ShareURLResolver {
    private static let sensitiveQueryNames: Set<String> = [
        "access_token", "apikey", "api_key", "auth", "authorization",
        "credential", "key", "password", "signature", "sig", "token"
    ]

    /// Resolves only publisher-facing episode pages. An enclosure is not an
    /// argument by design and therefore can never become a silent fallback.
    public static func episodeLink(
        episodePage: URL?,
        guid: String
    ) -> ResolvedShareLink? {
        if let episodePage, let safe = validatedPublicWebURL(episodePage) {
            return ResolvedShareLink(url: safe, quality: .episodePage)
        }

        if let guidURL = URL(string: guid),
           let safe = validatedPublicWebURL(guidURL) {
            return ResolvedShareLink(url: safe, quality: .probableEpisodePage)
        }

        return nil
    }

    /// Syntactic, non-network validation. DNS is intentionally not consulted:
    /// sharing must not introduce a fetch, and literal local/private addresses
    /// are rejected before they reach the activity controller or pasteboard.
    public static func validatedPublicWebURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty,
              !isLocalOrPrivateHost(rawHost),
              url.absoluteString.count <= 2_048 else {
            return nil
        }

        let hasSensitiveQuery = (components.queryItems ?? []).contains {
            sensitiveQueryNames.contains($0.name.lowercased())
        }
        guard !hasSensitiveQuery else { return nil }
        return components.url
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return true
        }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || octets[0] == 0
    }
}
