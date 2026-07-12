import Foundation

// AI CONTEXT — Relay/RelayModels.swift
// Wire types for the Autohop Relay Worker (~/Developer/autohop-relay, a SEPARATE
// repo — see Docs/RELAY_TIER1_IMPLEMENTATION.md §9 API CONTRACTS). These mirror
// src/routes.ts request/response bodies field-for-field; keep both sides in sync
// by hand since the Worker and this app are not code-generated from a shared schema.
// PROTOCOL V2 (2026-07-12): `/v1/feeds` returns the authoritative normalized
// membership plus stable opaque IDs. RelayFeedMappingStore persists only the
// ID→canonical-URL protocol cache used to target silent pushes; SubscriptionStore
// remains the user-library authority. RelayFeedURLCanonicalizer mirrors the
// Worker's normalization rules, and RelayRetryPolicy is the deterministic delay
// primitive used by AppState's persisted membership/sync-nudge circuit breakers.
// Response additions are optional for safe app-first rollout against a v1 Worker.
// SHARED WITH tvOS (moved into AutohopCore's Package.swift `sources:` 2026-07-10,
// physically stays in this Relay/ folder — the iOS Xcode target still compiles it
// directly via its source glob, unaffected; TV gets it via the AutohopCore package
// product). Zero UIKit dependency, so this was a clean move — `public` throughout
// is what actually makes it visible across that package boundary for TV.

/// POST /v1/register and /v1/register-paired response.
public struct RelayRegisterResponse: Decodable {
    public let deviceId: String
    public let deviceSecret: String
    public let entitlement: RelayEntitlement
}

/// Shared shape returned by /v1/register, /v1/register-paired, and /v1/heartbeat.
public struct RelayEntitlement: Decodable {
    public let status: String        // "active" | "grace" | "expired" | "revoked"
    public let expiresAt: Int?       // unix seconds
}

/// Opaque relay identity for one normalized feed URL. The ID, rather than the
/// RSS URL, is carried by APNs so a wake can target work without disclosing the
/// user's subscriptions in push payloads.
public struct RelayFeedDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }
}

/// POST /v1/feeds response. `feeds`, `revision`, and `changed` are optional so
/// an app upgrade remains compatible while an older Worker is still deployed.
public struct RelayFeedsResponse: Decodable {
    public let count: Int
    public let feeds: [RelayFeedDescriptor]?
    public let revision: String?
    public let changed: Int?
}

/// `{ "error": { "code": ..., "message": ... } }` — the shape every non-2xx
/// response uses (routes.ts `unauthorized()` / the inline `json({ error: ... })` calls).
public struct RelayErrorEnvelope: Decodable {
    public struct Body: Decodable {
        public let code: String
        public let message: String
        public let retryAfter: TimeInterval?
    }
    public let error: Body
}

/// Silent-push payload from apns.ts. Protocol v2 feed wakes also include an
/// array of opaque `feed_ids`; v1 payloads remain accepted as a bounded fallback.
public enum RelayPushType: String {
    case feedUpdated = "feed-updated"
    case syncNudge = "sync-nudge"
}

/// Every case (except .notRegistered, which never reaches the network) carries
/// the same `X-Request-Id` this client sent — the Worker logs that ID on every
/// request via Workers Logs (autohop-relay wrangler.jsonc `observability`), so
/// a diagnostic-log review can grep the Worker's own logs for the exact failing
/// request instead of correlating by timestamp alone.
public enum RelayError: Error {
    case notRegistered
    case server(requestID: String, code: String, message: String, retryAfter: TimeInterval?)
    case http(requestID: String, status: Int)
    case transport(requestID: String, underlying: Error)

    public var requestID: String? {
        switch self {
        case .notRegistered: return nil
        case .server(let id, _, _, _), .http(let id, _), .transport(let id, _): return id
        }
    }

    public var retryAfter: TimeInterval? {
        guard case .server(_, _, _, let retryAfter) = self else { return nil }
        return retryAfter
    }
}

// MARK: - Relay feed identity persistence

/// AI CONTEXT — This store is a protocol cache, not user library storage. The
/// authoritative subscription list remains SubscriptionStore; this cache only
/// translates opaque APNs IDs back to canonical feed URLs after `/v1/feeds`
/// acknowledges membership. Replacing the whole map on every successful server
/// response makes removals and server-side normalization self-healing.
public enum RelayFeedMappingStore {
    private static let mappingKey = "com.autohop.relay.feedMappings.v2"

    public static func replace(with descriptors: [RelayFeedDescriptor], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        defaults.set(data, forKey: mappingKey)
    }

    public static func urlStrings(for ids: [String], defaults: UserDefaults = .standard) -> (known: Set<String>, unknown: Set<String>) {
        let descriptors: [RelayFeedDescriptor]
        if let data = defaults.data(forKey: mappingKey),
           let decoded = try? JSONDecoder().decode([RelayFeedDescriptor].self, from: data) {
            descriptors = decoded
        } else {
            descriptors = []
        }
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0.url) })
        var known = Set<String>()
        var unknown = Set<String>()
        for id in ids {
            if let url = byID[id] { known.insert(url) }
            else { unknown.insert(id) }
        }
        return (known, unknown)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: mappingKey)
    }
}

/// Mirrors the Worker's `normalizeFeedUrl` sufficiently for membership diffs
/// and opaque-ID lookup: HTTP(S) only, lowercase scheme/host, no fragment, and
/// common tracking parameters removed. The server remains authoritative and
/// returns its canonical URL after every successful mutation.
public enum RelayFeedURLCanonicalizer {
    public static func string(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased()
        else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        // JavaScript URL.toString(), used by the Worker, canonicalizes a bare
        // origin to a trailing slash. Match it so a root feed resolves back to
        // the same local subscription when its opaque ID arrives.
        if components.path.isEmpty { components.path = "/" }
        if let items = components.queryItems {
            let filtered = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && name != "fbclid" && name != "gclid"
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.url?.absoluteString
    }
}

/// Deterministic exponential delay used by feed-membership and sync-nudge
/// circuit breakers. Once repeated failures reach the cap, new triggers remain
/// coalesced until the next allowed attempt rather than launching more requests.
public enum RelayRetryPolicy {
    public static func delay(
        failureCount: Int,
        base: TimeInterval = 30,
        maximum: TimeInterval = 15 * 60
    ) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        return min(maximum, base * pow(2, Double(min(failureCount - 1, 10))))
    }
}
