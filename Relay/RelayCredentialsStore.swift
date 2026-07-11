import Foundation
import Security

// AI CONTEXT — Relay/RelayCredentialsStore.swift
// Keychain-backed storage for the device_id/device_secret pair issued by
// POST /v1/register or /v1/register-paired (RELAY_TIER1_IMPLEMENTATION.md
// §4.2). These authenticate every subsequent relay call as `Authorization:
// Bearer <deviceId>.<deviceSecret>` (matches autohop-relay's src/auth.ts
// requireDevice regex exactly — do not change the "<id>.<secret>" separator
// without updating both sides).
// kSecAttrAccessibleAfterFirstUnlock: readable by background wakes (BGTask /
// push) after the device has been unlocked once since boot, but not before —
// matches the sensitivity of DownloadManager's own background-capable reads.
// SHARED WITH tvOS (moved into AutohopCore 2026-07-10, physically stays here —
// see RelayModels.swift's header for the mechanics). iOS and TV are separate
// apps with separate bundle IDs and therefore separate Keychains by default —
// no Keychain Sharing entitlement is set up, so each stores its OWN
// credentials under this same service/account string with zero collision risk.
public enum RelayCredentialsStore {
    private static let service = "com.kevinperry.autohop.relay"
    private static let account = "device-credentials"

    public struct Credentials: Codable {
        public let deviceId: String
        public let deviceSecret: String
        public init(deviceId: String, deviceSecret: String) {
            self.deviceId = deviceId
            self.deviceSecret = deviceSecret
        }
    }

    public static func load() -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
