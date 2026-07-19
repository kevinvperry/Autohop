import Combine
import Foundation

// AI CONTEXT — App/OnboardingCoordinator.swift
//
// PURPOSE / OWNERSHIP:
// Stage 5 owner of first-run classification, real-subscription counting,
// existing-user reconciliation, the first-subscription milestone, coach-mark
// policy, and transient onboarding toast state.
//
// DEPENDENCIES / OUTPUT:
// Reads SubscriptionStore membership and mutates the existing persisted
// AppSettings flags through SettingsStoring. `installRoutingOutput(to:)` owns
// the typed first-subscription route and temporarily posts the legacy
// notification for un-migrated observers; AppState does not install the
// callback body.
//
// INVARIANTS:
// - Browse previews never count as subscriptions.
// - Existing users are reconciled false→true only and never see Welcome again.
// - Exactly one deliberate first subscription emits the milestone; bulk imports
//   set the flag silently.
// - One tip at a time, never after seen, maximum three per process session.
// - No navigation path, playback, queue, download, feed, or sync work belongs
//   here.
enum OnboardingOutput: Equatable {
    case firstSubscription(UUID)
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published var activeTip: OnboardingTip?
    @Published var toast: String?

    var onOutput: ((OnboardingOutput) -> Void)?

    private let subscriptionStore: SubscriptionStore
    private let settingsStore: SettingsStoring
    private let logger: AppLogger
    private var tipsShownThisSession = 0
    private let maxTipsPerSession = 3
    private var cancellables = Set<AnyCancellable>()
    private var milestoneTask: Task<Void, Never>?
    private weak var routingCoordinator: AppRoutingCoordinator?

    init(
        subscriptionStore: SubscriptionStore,
        settingsStore: SettingsStoring,
        logger: AppLogger = .shared
    ) {
        self.subscriptionStore = subscriptionStore
        self.settingsStore = settingsStore
        self.logger = logger

        subscriptionStore.membershipDidChange
            .sink { [weak self] in self?.scheduleFirstSubscriptionMilestoneCheck() }
            .store(in: &cancellables)
    }

    var realSubscriptionCount: Int {
        subscriptionStore.subscriptions.filter { $0.browseDate == nil }.count
    }

    var isFirstRunNoSubscriptions: Bool {
        !settingsStore.appSettings.hasCompletedWelcome && realSubscriptionCount == 0
    }

    /// Installs the production routing destination while retaining `onOutput`
    /// as a focused test-observation seam.
    func installRoutingOutput(to routingCoordinator: AppRoutingCoordinator) {
        self.routingCoordinator = routingCoordinator
    }

    func reconcileExistingUser() {
        guard realSubscriptionCount > 0,
              !settingsStore.appSettings.hasCompletedWelcome
        else { return }
        settingsStore.appSettings.hasCompletedWelcome = true
        settingsStore.appSettings.hasSubscribedFirstShow = true
        settingsStore.appSettings.hasPlayedFirstEpisode = true
        logger.info("onboarding.reconcile", "Existing user with subscriptions marked onboarded")
    }

    func checkFirstSubscriptionMilestone() {
        guard !settingsStore.appSettings.hasSubscribedFirstShow else { return }
        let realSubscriptions = subscriptionStore.subscriptions.filter { $0.browseDate == nil }
        guard !realSubscriptions.isEmpty else { return }
        settingsStore.appSettings.hasSubscribedFirstShow = true
        if realSubscriptions.count == 1 {
            let output = OnboardingOutput.firstSubscription(realSubscriptions[0].id)
            route(output)
            onOutput?(output)
        }
    }

    private func route(_ output: OnboardingOutput) {
        switch output {
        case .firstSubscription(let subscriptionID):
            routingCoordinator?.send(.presentFirstSubscription(subscriptionID))
            NotificationCenter.default.post(
                name: .autohopFirstSubscription,
                object: subscriptionID
            )
        }
    }

    private func scheduleFirstSubscriptionMilestoneCheck() {
        milestoneTask?.cancel()
        milestoneTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.checkFirstSubscriptionMilestone()
        }
    }

    func requestTip(_ tip: OnboardingTip) {
        guard activeTip == nil,
              !tip.isSeen,
              tipsShownThisSession < maxTipsPerSession
        else { return }
        activeTip = tip
    }

    func dismissActiveTip() {
        guard let tip = activeTip else { return }
        tip.markSeen()
        tipsShownThisSession += 1
        activeTip = nil
    }
}
