// AI CONTEXT — App/DesktopCommands.swift
// PURPOSE: Semantic Mac/iPad command catalogue, menu builder, availability policy
// COLLABORATORS: AppDelegate, DesktopHostingController, AppState and existing workflows.
// INVARIANTS: Each command has a distinct Objective-C selector; validation cannot
// require a UICommand sender or propertyList. Never bootstrap services to build menus.
// Use visible page selection, guard modal/editing/busy states, and revalidate actions.
// Transport and library mutations reuse existing workflows; speeds match preferences.

import UIKit

/// Shared semantic catalogue for UIKit's Mac/iPad menu bar and shortcut reference.
/// Menu construction never creates application services.
enum DesktopDestination: Hashable {
    case player, subscriptions, discover, search, upNext, history, stats, downloads
    case settings, importSubscriptions, exportSubscriptions, addFeed, sleepSchedule
    case sleepTimer, audioControls, support, shortcuts, acknowledgements
    case show(UUID), showSettings(UUID)
}

enum DesktopCommand: String, CaseIterable {
    case settings, addFeed, importSubscriptions, exportSubscriptions, search
    case player, subscriptions, discover, upNext, history, stats, downloads, back
    case playPause, skipBack, skipForward, nextEpisode, previousChapter, nextChapter
    case speed100, speed110, speed120, speed130, speed140, speed150, speed160, speed170
    case speed180, speed190, speed200, speed210, speed220, speed230, speed240, speed250
    case audioControls, sleepTimer, sleepSchedule
    case openShow, showSettings, toggleSubscription, refreshShow, refreshAll, download, playNext, playLast, archive
    case support, shortcuts, acknowledgements

    // Mac's menu bridge can validate with a nil/non-UICommand sender. The
    // selector must identify the action before UIKit supplies command metadata.
    var selector: Selector { NSSelectorFromString("desktop_" + rawValue + ":") }

    init?(selector: Selector) {
        guard let command = Self.allCases.first(where: { $0.selector == selector }) else { return nil }
        self = command
    }

    var title: String {
        switch self {
        case .settings: return "Settings…"
        case .addFeed: return "Add RSS Feed…"
        case .importSubscriptions: return "Import Subscriptions…"
        case .exportSubscriptions: return "Export Subscriptions…"
        case .search: return "Find Podcasts…"
        case .player: return "Player"
        case .subscriptions: return "Subscriptions"
        case .discover: return "Discover"
        case .upNext: return "Up Next"
        case .history: return "Listening History"
        case .stats: return "Stats"
        case .downloads: return "Downloads"
        case .back: return "Back"
        case .playPause: return "Play/Pause"
        case .skipBack: return "Skip Back"
        case .skipForward: return "Skip Forward"
        case .nextEpisode: return "Next Episode"
        case .previousChapter: return "Previous Chapter"
        case .nextChapter: return "Next Chapter"
        case .audioControls: return "Audio Controls…"
        case .sleepTimer: return "Sleep Timer…"
        case .sleepSchedule: return "Sleep Schedule…"
        case .openShow: return "Open Show"
        case .showSettings: return "Show Settings…"
        case .toggleSubscription: return "Subscribe/Unsubscribe…"
        case .refreshShow: return "Refresh Show"
        case .refreshAll: return "Refresh All Shows"
        case .download: return "Download Episode"
        case .playNext: return "Play Next"
        case .playLast: return "Play Last"
        case .archive: return "Archive Episode…"
        case .support: return "Autohop Help"
        case .shortcuts: return "Keyboard Shortcuts"
        case .acknowledgements: return "Acknowledgements"
        default: return PlaybackPreference.speedLabel(speed ?? 1)
        }
    }

    var speed: Double? {
        guard rawValue.hasPrefix("speed"), let hundredths = Double(rawValue.dropFirst(5)) else { return nil }
        return hundredths / 100
    }

    var destination: DesktopDestination? {
        switch self {
        case .settings: return .settings
        case .addFeed: return .addFeed
        case .importSubscriptions: return .importSubscriptions
        case .exportSubscriptions: return .exportSubscriptions
        case .search: return .search
        case .player: return .player
        case .subscriptions: return .subscriptions
        case .discover: return .discover
        case .upNext: return .upNext
        case .history: return .history
        case .stats: return .stats
        case .downloads: return .downloads
        case .audioControls: return .audioControls
        case .sleepTimer: return .sleepTimer
        case .sleepSchedule: return .sleepSchedule
        case .support: return .support
        case .shortcuts: return .shortcuts
        case .acknowledgements: return .acknowledgements
        default: return nil
        }
    }

    var key: (String, UIKeyModifierFlags)? {
        switch self {
        case .settings: return (",", .command)
        case .addFeed: return ("n", .command)
        case .importSubscriptions: return ("i", [.command, .shift])
        case .exportSubscriptions: return ("e", [.command, .shift])
        case .search: return ("f", .command)
        case .player: return ("1", .command)
        case .subscriptions: return ("2", .command)
        case .discover: return ("3", .command)
        case .upNext: return ("4", .command)
        case .history: return ("5", .command)
        case .stats: return ("6", .command)
        case .downloads: return ("7", .command)
        case .back: return ("[", .command)
        case .playPause: return ("\r", .command)
        case .skipBack: return (UIKeyCommand.inputLeftArrow, .command)
        case .skipForward: return (UIKeyCommand.inputRightArrow, .command)
        case .previousChapter: return (UIKeyCommand.inputLeftArrow, [.command, .alternate])
        case .nextChapter: return (UIKeyCommand.inputRightArrow, [.command, .alternate])
        case .nextEpisode: return (UIKeyCommand.inputRightArrow, [.command, .shift])
        case .refreshShow: return ("r", .command)
        case .refreshAll: return ("r", [.command, .shift])
        default: return nil
        }
    }

    var shortcutLabel: String? {
        guard let (key, modifiers) = key else { return nil }
        let symbol: String
        switch key {
        case UIKeyCommand.inputLeftArrow: symbol = "←"
        case UIKeyCommand.inputRightArrow: symbol = "→"
        case "\r": symbol = "Return"
        default: symbol = key.uppercased()
        }
        return (modifiers.contains(.command) ? "⌘" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.alternate) ? "⌥" : "") + symbol
    }
}

@MainActor
enum DesktopMenuBuilder {
    private(set) static var installedCommands = Set<DesktopCommand>()

    static func configure() {
        if #available(iOS 26.0, *) {
            let configuration = UIMainMenuSystem.Configuration()
            configuration.newScenePreference = .removed
            configuration.documentPreference = .removed
            configuration.printingPreference = .removed
            configuration.textFormattingPreference = .removed
            configuration.findingPreference = .removed
            UIMainMenuSystem.shared.setBuildConfiguration(configuration) { builder in
                build(builder)
            }
        }
        // Older runtimes call the app delegate/hosting controller buildMenu override.
    }

    static func build(_ builder: UIMenuBuilder) {
        guard builder.system == .main,
              builder.menu(for: UIMenu.Identifier("autohop.playback")) == nil else { return }
        defer {
            installedCommands = Set(DesktopCommand.allCases.filter {
                builder.command(for: $0.selector, propertyList: $0.rawValue) != nil
            })
        }
        // Keep system Edit, Window, Hide, Quit and About handling intact.
        builder.remove(menu: .newScene)
        builder.remove(menu: .print)
        builder.remove(menu: .format)
        builder.remove(menu: .preferences)
        builder.insertSibling(group([.settings]), afterMenu: .about)
        builder.insertChild(group([.addFeed, .importSubscriptions, .exportSubscriptions]), atStartOfMenu: .file)
        builder.insertChild(group([.search]), atEndOfMenu: .edit)
        builder.insertChild(group([.player, .subscriptions, .discover, .upNext, .history, .stats, .downloads, .back]), atStartOfMenu: .view)
        let speed = UIMenu(title: "Playback Speed", children: DesktopCommand.allCases.filter { $0.speed != nil }.map(item))
        let playback = UIMenu(title: "Playback", identifier: UIMenu.Identifier("autohop.playback"), children: [
            group([.playPause, .skipBack, .skipForward, .nextEpisode]),
            group([.previousChapter, .nextChapter]), speed,
            group([.audioControls, .sleepTimer, .sleepSchedule])
        ])
        builder.insertSibling(playback, afterMenu: .view)
        builder.insertSibling(UIMenu(title: "Podcast", identifier: UIMenu.Identifier("autohop.podcast"), children: [
            group([.openShow, .showSettings, .toggleSubscription, .refreshShow, .refreshAll]),
            group([.download, .playNext, .playLast, .archive])
        ]), afterMenu: playback.identifier)
        builder.insertChild(group([.support, .shortcuts, .acknowledgements]), atStartOfMenu: .help)
    }

    private static func group(_ commands: [DesktopCommand]) -> UIMenu {
        UIMenu(title: "", options: .displayInline, children: commands.map(item))
    }

    static func item(_ command: DesktopCommand) -> UICommand {
        if let (input, modifiers) = command.key {
            return UIKeyCommand(title: command.title, action: command.selector,
                                input: input, modifierFlags: modifiers, propertyList: command.rawValue)
        }
        return UICommand(title: command.title, action: command.selector, propertyList: command.rawValue)
    }
}

/// Pure availability policy also exercised without bootstrapping the app.
struct DesktopCommandAvailability {
    var hasEpisode = false
    var hasQueue = false
    var hasShow = false
    var hasRealShow = false
    var hasSelectedEpisode = false
    var canDownload = false
    var selectedEpisodeBusy = false
    var canGoBack = false
    var hasPreviousChapter = false
    var hasNextChapter = false
    var hasSubscriptions = false
    var modal = false
    var editing = false
    var transportBusy = false
    var libraryBusy = false
    var importing = false

    func allows(_ command: DesktopCommand) -> Bool {
        if command.destination != nil {
            guard !modal else { return false }
            if command == .audioControls { return hasEpisode }
            if command == .importSubscriptions { return !importing }
            if command == .exportSubscriptions { return hasSubscriptions && !importing }
            return true
        }
        if command.speed != nil { return hasEpisode && !transportBusy }
        switch command {
        case .back: return canGoBack && !editing
        case .playPause: return (hasEpisode || hasQueue) && !transportBusy && !editing
        case .skipBack, .skipForward, .nextEpisode: return hasEpisode && !transportBusy && !editing
        case .previousChapter: return hasEpisode && hasPreviousChapter && !transportBusy && !editing
        case .nextChapter: return hasEpisode && hasNextChapter && !transportBusy && !editing
        case .openShow: return hasShow && !modal
        case .showSettings: return hasRealShow && !modal
        case .toggleSubscription: return hasShow && !modal && !libraryBusy
        case .refreshShow: return hasShow && !libraryBusy
        case .refreshAll: return hasSubscriptions && !libraryBusy
        case .download: return hasSelectedEpisode && canDownload && !libraryBusy
        case .playNext, .playLast: return hasSelectedEpisode && !selectedEpisodeBusy && !libraryBusy
        case .archive: return hasSelectedEpisode && !libraryBusy && !modal && !transportBusy
        default: return false
        }
    }
}

@MainActor
final class DesktopCommandHandler {
    private weak var appState: AppState?
    private var transportBusy = false
    private var libraryBusy = false

    init(appState: AppState) { self.appState = appState }

    private var selectedShow: Subscription? {
        guard let id = DesktopFocus.context?.subscriptionID else { return nil }
        return appState?.subscriptionStore.subscription(id: id)
    }
    private var selectedEpisode: Episode? {
        guard let id = DesktopFocus.context?.episodeID, let show = selectedShow else { return nil }
        return show.episodes.first(where: { $0.id == id }) ?? (show.latestEpisode?.id == id ? show.latestEpisode : nil)
    }

    func allows(_ command: DesktopCommand) -> Bool {
        guard let app = appState, DesktopFocus.window != nil else { return false }
        let playback = app.playbackCoordinator
        let show = selectedShow
        var state = DesktopCommandAvailability()
        state.hasEpisode = playback.currentEpisode != nil
        state.hasQueue = app.queueCoordinator.nextPlayableEpisode != nil
        state.hasShow = show != nil
        state.hasRealShow = show?.browseDate == nil && show != nil
        state.hasSelectedEpisode = selectedEpisode != nil
        state.canDownload = selectedEpisode?.downloadState == .notDownloaded || selectedEpisode?.downloadState == .failed
        state.selectedEpisodeBusy = selectedEpisode?.downloadState == .queued || selectedEpisode?.downloadState == .downloading
        state.canGoBack = DesktopFocus.context?.back != nil
        state.hasPreviousChapter = playback.previousChapterTarget != nil
        state.hasNextChapter = playback.nextChapterTarget != nil
        state.hasSubscriptions = app.subscriptionStore.subscriptions.contains { $0.browseDate == nil }
        state.modal = DesktopFocus.hasModal
        state.editing = DesktopFocus.isEditing
        state.transportBusy = transportBusy
        state.libraryBusy = libraryBusy
        state.importing = app.subscriptionImportCoordinator.progress != nil
        return state.allows(command)
    }

    func validate(_ item: UICommand, command: DesktopCommand) {
        item.attributes = allows(command) ? [] : [.disabled]
        guard let app = appState else { return }
        let settings = app.settingsCoordinator.appSettings
        switch command {
        case .toggleSubscription: item.title = selectedShow?.browseDate == nil ? "Unsubscribe…" : "Subscribe"
        case .playPause: item.title = app.playbackCoordinator.isPlaying ? "Pause" : "Play"
        case .skipBack: item.title = "Skip Back \(Int(settings.skipBackSeconds)) Seconds"
        case .skipForward: item.title = "Skip Forward \(Int(settings.skipForwardSeconds)) Seconds"
        default: break
        }
        if let speed = command.speed,
           let episode = app.playbackCoordinator.currentEpisode,
           let show = app.subscriptionStore.subscription(id: episode.subscriptionID) {
            item.state = abs(show.playbackPreference.speed - speed) < 0.001 ? .on : .off
        }
    }

    func perform(_ command: DesktopCommand) {
        guard allows(command), let app = appState else { return }
        if let destination = command.destination {
            app.routingCoordinator.send(.openDesktop(destination))
            return
        }
        if let speed = command.speed {
            app.setPlaybackSpeedForCurrentEpisode(speed)
            UIMenuSystem.main.setNeedsRevalidate()
            return
        }
        let settings = app.settingsCoordinator.appSettings
        switch command {
        case .back: DesktopFocus.context?.back?()
        case .playPause: transport { await app.togglePlayPause() }
        case .skipBack: app.seek(to: max(0, app.playbackClock.time - settings.skipBackSeconds))
        case .skipForward: transport { app.skipForward(seconds: settings.skipForwardSeconds) }
        case .nextEpisode: transport { await app.advanceEpisodeFromDesktopCommand() }
        case .previousChapter: app.navigateToPreviousChapter()
        case .nextChapter: app.navigateToNextChapter()
        case .openShow:
            if let show = selectedShow { app.routingCoordinator.send(.openDesktop(.show(show.id))) }
        case .showSettings:
            if let show = selectedShow { app.routingCoordinator.send(.openDesktop(.showSettings(show.id))) }
        case .toggleSubscription:
            guard let show = selectedShow else { return }
            if show.browseDate != nil {
                app.subscriptionStore.activateAndMoveToTop(subscriptionID: show.id)
            } else {
                let alert = UIAlertController(title: "Unsubscribe from \(show.title)?", message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Unsubscribe", style: .destructive) { [weak app] _ in
                    guard let app, let current = app.subscriptionStore.subscription(id: show.id), current.browseDate == nil else { return }
                    app.subscriptionStore.remove(subscriptionID: current.id)
                    UIMenuSystem.main.setNeedsRevalidate()
                })
                DesktopFocus.visibleController(DesktopFocus.window?.rootViewController)?.present(alert, animated: true)
            }
        case .refreshAll: library { await app.refreshAllSubscriptions() }
        case .refreshShow:
            if let show = selectedShow { library { await app.refreshSubscription(show) } }
        case .download:
            if let episode = selectedEpisode { library { await app.downloadEpisodeForQueue(episode) } }
        case .playNext, .playLast:
            if let episode = selectedEpisode {
                library {
                    if episode.downloadState != .downloaded { await app.downloadEpisodeForQueue(episode) }
                    guard let updated = app.subscriptionStore.episode(subscriptionID: episode.subscriptionID, episodeID: episode.id) else { return }
                    if command == .playNext { app.playEpisodeNext(updated) }
                    else { app.playEpisodeLast(updated) }
                }
            }
        case .archive:
            guard let episode = selectedEpisode else { return }
            let alert = UIAlertController(title: "Archive Episode?", message: episode.title, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Archive", style: .destructive) { [weak self, weak app] _ in
                guard let self, let app,
                      let current = app.subscriptionStore.episode(subscriptionID: episode.subscriptionID, episodeID: episode.id) else { return }
                self.library { await app.archiveEpisode(current) }
            })
            DesktopFocus.visibleController(DesktopFocus.window?.rootViewController)?.present(alert, animated: true)
        default: break
        }
        UIMenuSystem.main.setNeedsRevalidate()
    }

    private func transport(_ action: @escaping @MainActor () async -> Void) {
        guard !transportBusy else { return }
        transportBusy = true
        Task {
            await action()
            // Coalesce rapid transport invocations while the transition settles.
            try? await Task.sleep(for: .milliseconds(350))
            transportBusy = false
            UIMenuSystem.main.setNeedsRevalidate()
        }
    }
    private func library(_ action: @escaping @MainActor () async -> Void) {
        guard !libraryBusy else { return }
        libraryBusy = true
        Task {
            await action()
            libraryBusy = false
            UIMenuSystem.main.setNeedsRevalidate()
        }
    }
}
