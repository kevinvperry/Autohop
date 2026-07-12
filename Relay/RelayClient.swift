import Foundation

// AI CONTEXT — Relay/RelayClient.swift
// HTTP client for the Autohop Relay Worker (autohop-relay, deployed to
// https://autohop-relay.kevin-453.workers.dev — see Docs/RELAY_TIER1_IMPLEMENTATION.md
// §9 API CONTRACTS and ~/Developer/autohop-relay/src/routes.ts, the source of truth
// for these seven endpoints). Pure networking: callers (AutohopProStore, AppState,
// tvOS's TVAppModel) own WHEN to call these; this type only owns HOW.
// SHARED WITH tvOS (moved into AutohopCore's Package.swift `sources:` 2026-07-10 —
// physically stays in this Relay/ folder; the iOS Xcode target still compiles it
// directly via its source glob, unaffected. TV gets it via the AutohopCore package
// product, hence `public` throughout). Zero UIKit dependency — pure Foundation/
// URLSession — so this was a clean, no-duplication move for both targets.
// PROTOCOL V2 (2026-07-12): setFeeds is the registration/recovery baseline;
// updateFeeds is the ordinary add/remove path. Both return RelayFeedsResponse so
// AppState can persist the server's normalized membership and opaque ID mapping.
// Every request has a 15 s timeout; this type reports retryAfter but does NOT
// retry internally. AppState owns coalescing and the persisted circuit breaker,
// preventing URLSession retries from racing library mutations.
//
// Auth: every call except register()/registerPaired() attaches `Authorization:
// Bearer <deviceId>.<deviceSecret>` from RelayCredentialsStore. Those two are the
// only calls that don't need it (they're what OBTAIN the credentials); calling
// any other method before one of them succeeds throws .notRegistered.
//
// bundleEnv is approximated as DEBUG→sandbox, else→production. This matches
// typical certificate/APNs-environment practice but is a simplification (see
// RELAY_TIER1_IMPLEMENTATION.md §4.2) — TestFlight and App Store builds both
// resolve to "production" here, which is correct for APNs but worth revisiting
// if that ever diverges.
//
// Request correlation (added 2026-07-10, diagnostic-log improvement pass): every
// call generates a fresh UUID, sends it as `X-Request-Id`, and the Worker echoes
// it into its own Workers Logs (autohop-relay wrangler.jsonc `observability`).
// Deliberately NOT a shared mutable "lastRequestID" property — under concurrent
// calls that would race; instead every success return and every RelayError case
// carries its own ID, generated fresh per-call and threaded through immutably.
public final class RelayClient {
    public static let shared = RelayClient()

    private let baseURL = URL(string: "https://autohop-relay.kevin-453.workers.dev")!
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static var bundleEnv: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public var isRegistered: Bool { RelayCredentialsStore.load() != nil }

    // MARK: - POST /v1/register (iOS — StoreKit JWS proves entitlement)

    @discardableResult
    public func register(jws: String, apnsToken: String, syncGroupId: String? = nil) async throws -> (entitlement: RelayEntitlement, requestID: String) {
        struct Body: Encodable {
            let jws: String
            let apnsToken: String
            let platform: String
            let bundleEnv: String
            let syncGroupId: String?
        }
        let body = Body(jws: jws, apnsToken: apnsToken, platform: "ios", bundleEnv: Self.bundleEnv, syncGroupId: syncGroupId)
        let (response, requestID): (RelayRegisterResponse, String) = try await send(path: "/v1/register", body: body, authenticated: false)
        RelayCredentialsStore.save(.init(deviceId: response.deviceId, deviceSecret: response.deviceSecret))
        return (response.entitlement, requestID)
    }

    // MARK: - POST /v1/register-paired (tvOS — no purchase of its own)

    /// tvOS has no StoreKit purchase of its own (§14.1 tvOS-gating is still
    /// undecided) — trust is derived server-side from an ALREADY-registered
    /// device sharing this same `syncGroupId` (Glossary §1: the anonymous
    /// per-USER CloudKit record id, identical on iPhone and its paired TV)
    /// having an active/grace subscription. `syncGroupId` is NOT optional here
    /// (unlike register()'s) — it's the entire trust mechanism for this call;
    /// callers must resolve it (CKContainer.fetchUserRecordID()) before calling.
    @discardableResult
    public func registerPaired(syncGroupId: String, apnsToken: String) async throws -> (entitlement: RelayEntitlement, requestID: String) {
        struct Body: Encodable {
            let syncGroupId: String
            let apnsToken: String
            let platform: String
            let bundleEnv: String
        }
        let body = Body(syncGroupId: syncGroupId, apnsToken: apnsToken, platform: "tvos", bundleEnv: Self.bundleEnv)
        let (response, requestID): (RelayRegisterResponse, String) = try await send(path: "/v1/register-paired", body: body, authenticated: false)
        RelayCredentialsStore.save(.init(deviceId: response.deviceId, deviceSecret: response.deviceSecret))
        return (response.entitlement, requestID)
    }

    // MARK: - POST /v1/unregister

    @discardableResult
    public func unregister() async throws -> String {
        let requestID = try await sendEmptyBody(path: "/v1/unregister")
        RelayCredentialsStore.clear()
        return requestID
    }

    // MARK: - POST /v1/feeds

    /// Sends the full subscribed-feed set. Idempotent — safe to call on every
    /// register and every subscription-list change (§4.3). iOS only (tvOS has
    /// no on-device downloads for the relay to wake it for).
    @discardableResult
    public func setFeeds(_ urls: [URL]) async throws -> (response: RelayFeedsResponse, requestID: String) {
        struct Body: Encodable { let set: [String] }
        let body = Body(set: urls.map(\.absoluteString))
        let (response, requestID): (RelayFeedsResponse, String) = try await send(path: "/v1/feeds", body: body, authenticated: true)
        return (response, requestID)
    }

    /// Delta variant for a single subscribe/unsubscribe (avoids resending the
    /// whole library on every change).
    @discardableResult
    public func updateFeeds(add: [URL] = [], remove: [URL] = []) async throws -> (response: RelayFeedsResponse, requestID: String) {
        struct Body: Encodable { let add: [String]; let remove: [String] }
        let body = Body(add: add.map(\.absoluteString), remove: remove.map(\.absoluteString))
        let (response, requestID): (RelayFeedsResponse, String) = try await send(path: "/v1/feeds", body: body, authenticated: true)
        return (response, requestID)
    }

    // MARK: - POST /v1/heartbeat

    @discardableResult
    public func heartbeat(apnsToken: String? = nil, syncGroupId: String? = nil) async throws -> (entitlement: RelayEntitlement, requestID: String) {
        struct Body: Encodable { let apnsToken: String?; let syncGroupId: String? }
        struct Response: Decodable { let entitlement: RelayEntitlement }
        let body = Body(apnsToken: apnsToken, syncGroupId: syncGroupId)
        let (response, requestID): (Response, String) = try await send(path: "/v1/heartbeat", body: body, authenticated: true)
        return (response.entitlement, requestID)
    }

    // MARK: - POST /v1/sync-nudge

    /// Asks the relay to push a silent "sync-nudge" to every OTHER device sharing
    /// this device's syncGroupId — the iPhone↔tvOS iCloud-lag mitigation (§4.4).
    @discardableResult
    public func syncNudge() async throws -> String {
        try await sendEmptyBody(path: "/v1/sync-nudge")
    }

    // MARK: - Transport

    private func send<Body: Encodable, Response: Decodable>(
        path: String, body: Body, authenticated: Bool
    ) async throws -> (Response, String) {
        let requestID = UUID().uuidString
        let bodyData = try encoder.encode(body)
        let request = try buildRequest(path: path, bodyData: bodyData, authenticated: authenticated, requestID: requestID)
        let (data, response) = try await performing(request, requestID: requestID)
        try Self.checkStatus(response, data: data, requestID: requestID)
        do {
            return (try decoder.decode(Response.self, from: data), requestID)
        } catch {
            throw RelayError.transport(requestID: requestID, underlying: error)
        }
    }

    /// POST with no request body (unregister, sync-nudge) — always authenticated.
    /// Returns the requestID so callers CAN log it, without forcing every caller to.
    @discardableResult
    private func sendEmptyBody(path: String) async throws -> String {
        let requestID = UUID().uuidString
        let request = try buildRequest(path: path, bodyData: nil, authenticated: true, requestID: requestID)
        let (data, response) = try await performing(request, requestID: requestID)
        try Self.checkStatus(response, data: data, requestID: requestID)
        return requestID
    }

    private func buildRequest(path: String, bodyData: Data?, authenticated: Bool, requestID: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        // A relay request must never monopolize a silent-push/background-task
        // budget. URLSession's shared default is much longer than the useful
        // execution window, so fail promptly and let the caller's circuit
        // breaker retry after pressure subsides.
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
        request.httpBody = bodyData
        if authenticated {
            guard let credentials = RelayCredentialsStore.load() else { throw RelayError.notRegistered }
            request.setValue("Bearer \(credentials.deviceId).\(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func performing(_ request: URLRequest, requestID: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw RelayError.transport(requestID: requestID, underlying: error)
        }
    }

    private static func checkStatus(_ response: URLResponse, data: Data, requestID: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        if let envelope = try? JSONDecoder().decode(RelayErrorEnvelope.self, from: data) {
            throw RelayError.server(
                requestID: requestID,
                code: envelope.error.code,
                message: envelope.error.message,
                retryAfter: envelope.error.retryAfter
            )
        }
        throw RelayError.http(requestID: requestID, status: http.statusCode)
    }
}
