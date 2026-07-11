import Foundation

// AI CONTEXT — Relay/RelayModels.swift
// Wire types for the Autohop Relay Worker (~/Developer/autohop-relay, a SEPARATE
// repo — see Docs/RELAY_TIER1_IMPLEMENTATION.md §9 API CONTRACTS). These mirror
// src/routes.ts request/response bodies field-for-field; keep both sides in sync
// by hand since the Worker and this app are not code-generated from a shared schema.
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

/// POST /v1/feeds response.
public struct RelayFeedsResponse: Decodable {
    public let count: Int
}

/// `{ "error": { "code": ..., "message": ... } }` — the shape every non-2xx
/// response uses (routes.ts `unauthorized()` / the inline `json({ error: ... })` calls).
public struct RelayErrorEnvelope: Decodable {
    public struct Body: Decodable { public let code: String; public let message: String }
    public let error: Body
}

/// Silent-push payload from apns.ts `sendPush`: `{ aps: {...}, type, v: 1 }`.
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
    case server(requestID: String, code: String, message: String)
    case http(requestID: String, status: Int)
    case transport(requestID: String, underlying: Error)

    public var requestID: String? {
        switch self {
        case .notRegistered: return nil
        case .server(let id, _, _), .http(let id, _), .transport(let id, _): return id
        }
    }
}
