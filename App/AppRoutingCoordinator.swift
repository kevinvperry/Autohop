import Combine
import Foundation

// AI CONTEXT — App/AppRoutingCoordinator.swift
//
// PURPOSE / OWNERSHIP:
// Stage 5 typed command source for main-stack presentation. RootView deliberately
// retains its local SwiftUI NavigationPath; this coordinator owns commands and
// launch-route decisions, not SwiftUI navigation state.
//
// LEGACY ADAPTER:
// Existing Menu, mini-player, notification, and Settings producers still post
// NotificationCenter names. `startLegacyNotificationAdapter()` translates those
// posts into typed commands exactly once. New coordinators emit typed commands
// directly. The adapter can be removed only after all producers migrate.
//
// INVARIANTS:
// - PlayerView remains the permanent root.
// - Commands never touch playback or recreate application services.
// - Discover launch preserves Player → Subscriptions → Discover.
// - Stats commands preserve an optional ListeningRecapPeriod.
// - No generic event bus or service lookup is introduced.
enum AppRouteCommand: Equatable {
    case returnToPlayer
    case openDiscover
    case openStats(ListeningRecapPeriod?)
    case openSubscriptions
    case presentWelcome
    case presentFirstSubscription(UUID)
}

@MainActor
final class AppRoutingCoordinator {
    let commands = PassthroughSubject<AppRouteCommand, Never>()

    private var legacyObservers: [NSObjectProtocol] = []
    private var legacyAdapterStarted = false

    func send(_ command: AppRouteCommand) {
        commands.send(command)
    }

    func launchCommand(
        isFirstRun: Bool,
        launchScreen: LaunchScreen
    ) -> AppRouteCommand? {
        if isFirstRun { return .presentWelcome }
        switch launchScreen {
        case .player: return nil
        case .subscriptions: return .openSubscriptions
        case .discover: return .openDiscover
        }
    }

    func welcomeCompleted(_ outcome: WelcomeOutcome) -> AppRouteCommand {
        switch outcome {
        case .findShows: return .openDiscover
        case .importedSubscriptions, .skip: return .openSubscriptions
        }
    }

    func startLegacyNotificationAdapter(center: NotificationCenter = .default) {
        guard !legacyAdapterStarted else { return }
        legacyAdapterStarted = true
        legacyObservers = [
            center.addObserver(
                forName: .autohopReturnToPlayer,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.send(.returnToPlayer) }
            },
            center.addObserver(
                forName: .autohopOpenDiscover,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.send(.openDiscover) }
            },
            center.addObserver(
                forName: .autohopOpenStats,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let period = note.object as? ListeningRecapPeriod
                Task { @MainActor in self?.send(.openStats(period)) }
            },
            center.addObserver(
                forName: .autohopOpenSubscriptions,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.send(.openSubscriptions) }
            }
        ]
    }

    deinit {
        for observer in legacyObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
