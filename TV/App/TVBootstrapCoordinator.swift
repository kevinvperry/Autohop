import Foundation
import Observation

// AI CONTEXT — Owns root launch state independently of library/queue/playback
// observations. TVAppModel drives the existing bootstrap workflow through this
// state owner while extraction preserves the proven launch sequencing.

@MainActor
@Observable
final class TVBootstrapCoordinator {
    enum State: Equatable {
        case loading(message: String)
        case ready
        case empty
        case recoverableFailure(message: String)
    }

    var state: State = .loading(message: "Loading your library…")
    var didBootstrap = false

    var statusText: String {
        switch state {
        case .loading(let message), .recoverableFailure(let message): message
        case .ready: "Ready"
        case .empty: "No library yet"
        }
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }
}
