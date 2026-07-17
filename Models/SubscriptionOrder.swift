import Foundation

// AI CONTEXT — Models/SubscriptionOrder.swift
// Atomic cross-device representation of the Subscriptions page Priority Stack.
// Subscription.priorityRank remains the local, derived queue-sorting value, but
// CloudKit synchronizes THIS one whole-list value so a reorder cannot arrive as
// a mixture of independent per-subscription rank generations. Only real
// subscriptions are included (browseDate == nil); active IDs come first and
// Inactive IDs remain at the bottom. `generationID` identifies the exact local
// version sent so a delayed CloudKit acknowledgment can clear only that version,
// never a newer reorder. `updatedAt` provides whole-record LWW, sourceDeviceID is
// diagnostic, and schemaVersion leaves room for a future ordering migration.
public struct SubscriptionOrderState: Codable, Equatable, Sendable {
    public var orderedSubscriptionIDs: [UUID]
    public var generationID: UUID
    public var updatedAt: Date
    public var sourceDeviceID: String
    public var schemaVersion: Int

    public init(
        orderedSubscriptionIDs: [UUID],
        generationID: UUID = UUID(),
        updatedAt: Date = Date(),
        sourceDeviceID: String = DeviceIdentity.current,
        schemaVersion: Int = 1
    ) {
        self.orderedSubscriptionIDs = orderedSubscriptionIDs
        self.generationID = generationID
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
        self.schemaVersion = schemaVersion
    }
}
