import Combine
import Foundation

// AI CONTEXT — Playback/PlaybackClock.swift
//
// PURPOSE:
// Narrow MainActor observable for Autohop's high-frequency playback position.
// AppState owns this leaf during decomposition Stages 0–2 and exposes
// `currentPlayerTime` as a compatibility proxy. PlayerView and MiniPlayerBar
// observe this object directly so the engine's 2 Hz time callback does not
// invalidate every AppState observer.
//
// CONCURRENCY:
// MainActor-only. Playback callbacks must hop to MainActor before assigning time.
//
// PERSISTENCE / EVENTS:
// This object is an in-memory UI projection only. PlaybackPositionStore remains
// the durable source for resume data. Publishing `time` must never perform disk,
// network, queue, history, Stats, or sync work.
//
// INVARIANTS:
// - Keep this observable separate from AppState's broad objectWillChange stream.
// - Do not add playback policy or engine ownership here.
// - Preserve the existing `time` API until PlaybackCoordinator migration.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: TimeInterval = 0
}
