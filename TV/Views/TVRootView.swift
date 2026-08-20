import SwiftUI
import AutohopCore

// AI CONTEXT — Root tvOS state renderer and App Review access boundary.
// AutohopTVApp supplies a presentation deadline independent of bootstrap work:
// if local/sync work has not returned by then, this view exposes stable recovery
// instead of an indefinite splash while the owned work continues. Returning
// library evidence suppresses first-time setup through normal catch-up. Demo is
// a separate in-memory TVDemoSession and never enters TVAppModel persistence.
struct TVRootView: View {
    let model: TVAppModel
    let launchDeadlineReached: Bool
    let returningRecoveryDeadlineReached: Bool
    let pendingRouteCoordinator: TVPendingRouteCoordinator
    @State private var experience: Experience?

    private enum Experience: Equatable { case personalHome, personalDiscover, personalSettings, demo }

    var body: some View {
        Group {
            switch experience {
            case .demo:
                TVDemoRootView { experience = nil }
            case .personalHome:
                TVMainTabView(model: model, initialTab: .home, pendingRouteCoordinator: pendingRouteCoordinator)
            case .personalDiscover:
                TVMainTabView(model: model, initialTab: .discover, pendingRouteCoordinator: pendingRouteCoordinator)
            case .personalSettings:
                TVMainTabView(model: model, initialTab: .diagnostics, pendingRouteCoordinator: pendingRouteCoordinator)
            case nil:
                automaticExperience
            }
        }
        .onChange(of: experience) { oldValue, newValue in
            AppLogger.shared.info("tv.experience.changed", "Apple TV experience changed", metadata: [
                "from": experienceLabel(oldValue),
                "to": experienceLabel(newValue)
            ], alwaysPersist: newValue == .demo || oldValue == .demo)
        }
    }

    private func experienceLabel(_ value: Experience?) -> String {
        switch value {
        case .personalHome: return "personalHome"
        case .personalDiscover: return "personalDiscover"
        case .personalSettings: return "personalSettings"
        case .demo: return "demo"
        case nil: return "automatic"
        }
    }

    @ViewBuilder
    private var automaticExperience: some View {
        switch model.bootstrapCoordinator.state {
        case .loading(let message) where !shouldExposeSetup:
            TVLaunchLoadingView(statusText: message)
        case .empty where !shouldExposeSetup:
            TVLaunchLoadingView(statusText: "Refreshing your iCloud library…")
        case .loading:
            setupRequired(reason: "Autohop could not finish checking this Apple TV's local and iCloud library in time. You can continue now while it works in the background.")
        case .empty:
            setupRequired(reason: "No Autohop subscriptions were found in this Apple Account's private iCloud library.")
        case .recoverableFailure(let message):
            setupRequired(reason: message)
        case .ready:
            TVMainTabView(model: model, initialTab: .home, pendingRouteCoordinator: pendingRouteCoordinator)
        }
    }

    private var shouldExposeSetup: Bool {
        TVLaunchAccessPolicy.shouldExposeSetup(
            bootstrapState: model.bootstrapCoordinator.state,
            cleanInstallDeadlineReached: launchDeadlineReached,
            hasReturningLibraryEvidence: model.hasReturningLibraryEvidence,
            returningRecoveryDeadlineReached: returningRecoveryDeadlineReached
        )
    }

    private func setupRequired(reason: String) -> some View {
        TVSetupRequiredView(
            reason: reason,
            onDemo: { experience = .demo },
            onDiscover: { experience = .personalDiscover },
            onSettings: { experience = .personalSettings },
            onRetry: { await model.primeLibraryFromCloudSoon(reason: "tv.setupRetry") }
        )
    }
}

private struct TVSetupRequiredView: View {
    let reason: String
    let onDemo: () -> Void
    let onDiscover: () -> Void
    let onSettings: () -> Void
    let onRetry: () async -> Void
    @State private var isRetrying = false
    @State private var retryGeneration = 0
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable { case demo, discover, retry, settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Label("Set up Autohop on iPhone", systemImage: "iphone.and.arrow.forward")
                    .font(.largeTitle.bold())
                Text(reason).font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 15) {
                    Label("Install or open Autohop on iPhone.", systemImage: "1.circle.fill")
                    Label("Subscribe to podcasts and enable Settings → Sync → iCloud Sync.", systemImage: "2.circle.fill")
                    Label("Use the same Apple Account on iPhone and Apple TV, then check again.", systemImage: "3.circle.fill")
                }.font(.title3).padding(28).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 20) {
                    Button(action: onDemo) { Label("Explore Demo Library", systemImage: "sparkles.tv").frame(minWidth: 250) }
                        .buttonStyle(.borderedProminent).focused($focusedAction, equals: .demo)
                    Button(action: onDiscover) { Label("Open Discover", systemImage: "safari") }
                        .buttonStyle(.bordered).focused($focusedAction, equals: .discover)
                    Button(action: retry) { Label(isRetrying ? "Checking iCloud…" : "Check iCloud Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).disabled(isRetrying).focused($focusedAction, equals: .retry)
                    Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.bordered).focused($focusedAction, equals: .settings)
                }
                Text("Demo content is bundled with Autohop, works offline, and never writes to your private iCloud library or listening statistics.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 100).padding(.vertical, 80)
        }
        .background(TVBrandBackground())
        .defaultFocus($focusedAction, .demo)
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryGeneration += 1
        let ownedGeneration = retryGeneration
        Task { await onRetry() }
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard ownedGeneration == retryGeneration else { return }
            isRetrying = false
        }
    }
}
