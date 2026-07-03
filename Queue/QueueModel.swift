import Foundation

// AI CONTEXT — Queue/QueueModel.swift
// Phase 0 of Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md (§4.2 move 2): the pure,
// platform-neutral Priority Stack composition — base ordering (QueueService)
// plus the Play Next / Play Last pin overrides that previously lived only in
// AppState.orderedQueueWithOverrides(). AppState now delegates here (its
// memoization + pin persistence + invalidation signals stay in AppState);
// tvOS/watch compose their queues from this same logic so ordering can never
// drift between surfaces. PIN SEMANTICS (must match the historical AppState
// behavior exactly): pins referencing episodes not in the base queue are
// ignored; Play Next pins move to the FRONT in pin order; Play Last pins
// append to the END in pin order; everything else keeps base order. Headless
// tests: Tests/QueueModelTests.swift.

/// The user's manual queue overrides: Play Next pins (front, in order) and
/// Play Last pins (end, in order). Persisted by the app layer (queue-pins.json
/// on iOS); this type is just the value shape the ordering logic consumes.
public struct QueuePins: Codable, Equatable {
    public var playNextIDs: [UUID]
    public var playLastIDs: [UUID]

    public init(playNextIDs: [UUID] = [], playLastIDs: [UUID] = []) {
        self.playNextIDs = playNextIDs
        self.playLastIDs = playLastIDs
    }

    public var isEmpty: Bool { playNextIDs.isEmpty && playLastIDs.isEmpty }
}

public enum QueueModel {
    /// Full Priority Stack: QueueService base ordering with pins applied.
    public static func downloadedQueue(
        from subscriptions: [Subscription],
        pins: QueuePins,
        queueService: QueueServicing = QueueService()
    ) -> [Episode] {
        applyPins(queueService.downloadedQueue(from: subscriptions), pins: pins)
    }

    /// Applies Play Next / Play Last pins to an already-ordered base queue.
    /// Exact port of AppState.orderedQueueWithOverrides() — see header for the
    /// pin semantics contract.
    public static func applyPins(_ baseQueue: [Episode], pins: QueuePins) -> [Episode] {
        guard !pins.isEmpty else { return baseQueue }

        let availableIDs = Set(baseQueue.map(\.id))
        let validOverrideIDs = pins.playNextIDs.filter { availableIDs.contains($0) }
        let validDemotedIDs = pins.playLastIDs.filter { availableIDs.contains($0) }
        guard !validOverrideIDs.isEmpty || !validDemotedIDs.isEmpty else { return baseQueue }

        let specialIDs = Set(validOverrideIDs).union(Set(validDemotedIDs))
        let overrideEpisodes = validOverrideIDs.compactMap { id in baseQueue.first { $0.id == id } }
        let demotedEpisodes = validDemotedIDs.compactMap { id in baseQueue.first { $0.id == id } }

        var ordered = baseQueue.filter { !specialIDs.contains($0.id) }
        ordered.insert(contentsOf: overrideEpisodes, at: 0)
        ordered.append(contentsOf: demotedEpisodes)
        return ordered
    }
}
