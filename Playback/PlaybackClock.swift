import Combine
import Foundation

// AI CONTEXT — Playback/PlaybackClock.swift
//
// PURPOSE:
// Narrow MainActor observable for Autohop's high-frequency playback position.
// PlaybackCoordinator owns this leaf; AppState exposes `currentPlayerTime` only
// for platform/test compatibility. PlayerView and MiniPlayerBar observe this
// object directly so the engine's 2 Hz callback does not invalidate unrelated
// domain observers.
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
// - Keep this observable separate from broad application/domain observations.
// - Do not add playback policy or engine ownership here.
// - PlaybackCoordinator is the routine writer.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: TimeInterval = 0
}
