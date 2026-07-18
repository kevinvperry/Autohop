import Combine
import Foundation

// AI CONTEXT — Downloads/DownloadProgressModel.swift
//
// PURPOSE:
// Narrow MainActor observable containing per-episode download fractions. AppState
// owns this leaf through decomposition Stage 5 and retains `downloadProgress`
// as a compatibility proxy. Episode-list surfaces observe this model directly so
// transfer progress does not invalidate unrelated AppState views.
//
// CONCURRENCY:
// MainActor-only. DownloadManager callbacks must hop to MainActor before writes.
//
// PERSISTENCE / EVENTS:
// Fractions are transient UI state. DownloadActivityStore and SubscriptionStore
// remain the durable transfer/activity authorities. This type publishes only
// actual dictionary assignments and performs no disk, network, queue, or sync
// work.
//
// INVARIANTS:
// - Values are fractional progress in 0.0...1.0 keyed by Episode UUID.
// - Existing AppState coalescing decides when an update is significant.
// - Do not add scheduling, retry, activity, or completion policy here.
@MainActor
final class DownloadProgressModel: ObservableObject {
    @Published var progress: [UUID: Double] = [:]
}
