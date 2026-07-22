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
// - Widget URLs are parsed by WidgetDeepLinkParser; only typed validated
//   commands enter this stream. Episode identity is resolved by RootView
//   against the live store before navigation. One pending widget command is
//   retained until RootView consumes/acknowledges it, preventing a cold-launch
//   URL from being lost before the PassthroughSubject subscriber is installed.
// - No generic event bus or service lookup is introduced.
enum AppRouteCommand: Equatable {
    case returnToPlayer
    case openUpNext
    case openEpisode(WidgetEpisodeIdentity)
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
    private var pendingWidgetCommand: AppRouteCommand?

    func send(_ command: AppRouteCommand) {
        commands.send(command)
    }

    func handleWidgetURL(
        _ url: URL,
        parser: WidgetDeepLinkParser = WidgetDeepLinkParser()
    ) {
        switch parser.parse(url) {
        case .destination(let destination):
            let command: AppRouteCommand
            switch destination {
            case .player:
                command = .returnToPlayer
            case .upNext:
                command = .openUpNext
            case .discover:
                command = .openDiscover
            case .episode(let identity):
                command = .openEpisode(identity)
            }
            AppLogger.shared.info(
                "widget.routeAccepted",
                "Accepted widget navigation URL",
                metadata: ["route": String(describing: command)]
            )
            pendingWidgetCommand = command
            send(command)
        case .rejected:
            AppLogger.shared.warning(
                "widget.routeRejected",
                "Rejected malformed or unsupported widget navigation URL",
                metadata: [
                    "scheme": url.scheme ?? "none",
                    "host": url.host ?? "none"
                ],
                alwaysPersist: true
            )
        }
    }

    func consumePendingWidgetCommand() -> AppRouteCommand? {
        defer { pendingWidgetCommand = nil }
        return pendingWidgetCommand
    }

    func acknowledgeWidgetCommand(_ command: AppRouteCommand) {
        guard pendingWidgetCommand == command else { return }
        pendingWidgetCommand = nil
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
