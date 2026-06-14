import Foundation

// AI CONTEXT — Models/Synced.swift
// Field-level dirty-tracking primitive for cross-device sync (see SYNC_DESIGN.md,
// build step 2). Ported from Pocket Casts' `ModifiedDate` property wrapper.
// Wraps any Codable & Equatable value and auto-stamps `modifiedAt` whenever the
// value actually changes — so "what needs to sync" is simply "fields whose
// modifiedAt is non-nil". After a successful push the stamp is cleared
// (`markClean`); a freshly created local record that has never synced is stamped
// dirty (`markDirty`).
//
// IMPORTANT: this wrapper is used ONLY on the dedicated sync-state projections
// (EpisodeSyncState / SubscriptionSyncState), never on the domain Episode/
// Subscription models — those keep their plain Codable shape and on-disk format.
@propertyWrapper
public struct Synced<Value: Codable & Equatable>: Codable, Equatable {
    public private(set) var value: Value
    /// Non-nil when the value has been changed locally since the last sync.
    public private(set) var modifiedAt: Date?

    public init(wrappedValue: Value, modifiedAt: Date? = nil) {
        self.value = wrappedValue
        self.modifiedAt = modifiedAt
    }

    public var wrappedValue: Value {
        get { value }
        set {
            if value != newValue { modifiedAt = Date() }
            value = newValue
        }
    }

    public var projectedValue: Synced<Value> {
        get { self }
        set { self = newValue }
    }

    /// True when there is an unsynced local change.
    public var hasPendingChange: Bool { modifiedAt != nil }

    /// Clear the dirty stamp — call after the value has been pushed to the server.
    public mutating func markClean() { modifiedAt = nil }

    /// Force a dirty stamp — used when seeding a record that has never synced.
    public mutating func markDirty(at date: Date = Date()) { modifiedAt = date }
}

/// Field-level last-write-wins merge of one synced field. A non-nil local stamp
/// wins only if strictly newer than the remote's; otherwise the remote value is
/// adopted clean (nil stamp = "no local opinion", so the server is authoritative).
public func mergedSyncedField<T>(local: Synced<T>, remote: Synced<T>) -> Synced<T> {
    if let localStamp = local.modifiedAt, localStamp > (remote.modifiedAt ?? .distantPast) {
        return local
    }
    return Synced(wrappedValue: remote.value, modifiedAt: nil)
}
