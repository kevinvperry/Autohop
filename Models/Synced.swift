// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Portions of this file are derived from Pocket Casts for iOS
// (https://github.com/Automattic/pocket-casts-ios), © Automattic, Inc.
// Used under the Mozilla Public License, v. 2.0.
//
// Specifically, the `Synced` property wrapper is ported from the `ModifiedDate`
// property wrapper in Modules/Sources/PocketCastsUtils/General/ModifiedDate.swift:
// the generic signature, the stored `value`/`modifiedAt` pair, and the
// change-detecting `wrappedValue` setter (`if value != newValue { modifiedAt =
// Date() }`) originate there. Autohop renames it and adds its own CloudKit
// last-write-wins helpers (`hasPendingChange`, `markClean`, `markDirty`,
// `mergedSyncedField`); Pocket Casts' SQLite Int→Bool decoder is omitted.

import Foundation

// AI CONTEXT — Models/Synced.swift  (LICENSE: MPL-2.0, see header)
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
// MERGE SAFETY: remote `modifiedAt == nil` means a CloudKit field was absent,
// not that its default value should overwrite local data. This protects the
// namespace migration from sparse remote records resetting per-podcast settings.
// ACKNOWLEDGMENT SAFETY: a successful CloudKit response may describe an older
// value than the current local projection when another edit happened in flight.
// markClean(ifAcknowledgedBy:) clears only an exact value+timestamp match.
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

    /// Clears this field only when the server acknowledgment describes the exact
    /// local version currently pending. A later local edit has a different value
    /// or timestamp and therefore remains dirty for the next push.
    @discardableResult
    public mutating func markClean(ifAcknowledgedBy acknowledged: Synced<Value>) -> Bool {
        guard let localStamp = modifiedAt,
              localStamp == acknowledged.modifiedAt,
              value == acknowledged.value
        else { return false }
        modifiedAt = nil
        return true
    }

    /// Force a dirty stamp — used when seeding a record that has never synced.
    public mutating func markDirty(at date: Date = Date()) { modifiedAt = date }
}

/// Field-level last-write-wins merge of one synced field. A remote field is
/// authoritative only when it carries a server timestamp; a nil remote stamp
/// means "field absent / no remote opinion" and must preserve the local value.
/// A non-nil local stamp wins only if strictly newer than the remote's;
/// otherwise the remote value is adopted clean.
public func mergedSyncedField<T>(local: Synced<T>, remote: Synced<T>) -> Synced<T> {
    guard let remoteStamp = remote.modifiedAt else { return local }
    if let localStamp = local.modifiedAt, localStamp > remoteStamp {
        return local
    }
    return Synced(wrappedValue: remote.value, modifiedAt: nil)
}
