//
//  RelayCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 10 exclusive owner of the optional Autohop Relay transport lifecycle:
//  APNs token receipt, entitlement-gated registration, canonical feed membership,
//  delta/full reconciliation, debounce/in-flight state, persisted circuit
//  breakers, sync nudge, CloudKit user identity, heartbeat, opaque feed mappings,
//  and silent-push classification.
//
//  ReleaseFeatures.relayService remains the authoritative compile-time/runtime
//  gate. Payload schemas, endpoint behavior, retry policy, UserDefaults keys,
//  v2 targeted refresh, and capped legacy fallback are unchanged. Store episode
//  mutations cannot create membership traffic because this coordinator consumes
//  SubscriptionStore.membershipDidChange rather than its broad publisher.
//

import CloudKit
import Combine
import Foundation

@MainActor
final class RelayCoordinator {
    typealias LegacyRefresh = @MainActor () async -> Bool
    typealias TargetedRefresh = @MainActor (Set<UUID>) async -> Bool
    typealias SyncPull = @MainActor () async -> Void

    let proStore: AutohopProStore

    private let subscriptionStore: SubscriptionStore
    private let client: RelayClient
    private let logger: AppLogger
    private var legacyRefresh: LegacyRefresh = { false }
    private var targetedRefresh: TargetedRefresh = { _ in false }
    private var syncPull: SyncPull = {}
    private var cancellables = Set<AnyCancellable>()

    private var apnsToken: String?
    private var registrationInFlight = false
    private var feedSyncDebounceTask: Task<Void, Never>?
    private var feedSyncInFlight = false
    private var feedSyncNeedsReconcile = false
    private var forceFullFeedSync = false
    private var observedFeedURLs = Set<String>()
    private var syncGroupID: String?
    private var syncNudgeDebounceTask: Task<Void, Never>?
    private var syncNudgeInFlight = false
    private var syncNudgeDirty = false
    private var started = false

    private static let acknowledgedFeedsKey = "com.autohop.relay.acknowledgedFeeds.v2"
    private static let feedFailureCountKey = "com.autohop.relay.feedSyncFailureCount.v2"
    private static let feedNextAttemptKey = "com.autohop.relay.feedSyncNextAttempt.v2"
    private static let nudgeFailureCountKey = "com.autohop.relay.nudgeFailureCount.v2"
    private static let nudgeNextAttemptKey = "com.autohop.relay.nudgeNextAttempt.v2"
    private static let nudgeLastSuccessKey = "com.autohop.relay.nudgeLastSuccess.v2"
    private static let nudgeMinimumInterval: TimeInterval = 5 * 60
    private static let lastHeartbeatKey = "com.autohop.relay.lastHeartbeatAt"
    private static let heartbeatInterval: TimeInterval = 24 * 3600

    init(
        subscriptionStore: SubscriptionStore,
        proStore: AutohopProStore? = nil,
        client: RelayClient? = nil,
        logger: AppLogger? = nil
    ) {
        self.subscriptionStore = subscriptionStore
        self.proStore = proStore ?? AutohopProStore(enabled: ReleaseFeatures.autohopPro)
        self.client = client ?? .shared
        self.logger = logger ?? .shared
        self.observedFeedURLs = Self.feedURLs(in: subscriptionStore.subscriptions)
    }

    func installWorkflows(
        refreshWorkflow: FeedRefreshCycleWorkflow,
        syncCoordinator: SyncCoordinator,
        legacyMaxSubscriptions: Int
    ) {
        legacyRefresh = { [weak refreshWorkflow] in
            await refreshWorkflow?.refresh(
                reason: "relay.legacy",
                trigger: .relayPush,
                executionContext: .relayPush,
                maxSubscriptions: legacyMaxSubscriptions,
                includeBackoffFeeds: false,
                onlyDueFeeds: true,
                joinActiveCycle: true
            ) ?? false
        }
        targetedRefresh = { [weak refreshWorkflow] targetIDs in
            await refreshWorkflow?.refresh(
                reason: "relay.targeted",
                trigger: .relayPush,
                executionContext: .relayPush,
                maxSubscriptions: targetIDs.count,
                includeBackoffFeeds: true,
                onlyDueFeeds: false,
                joinActiveCycle: true,
                targetSubscriptionIDs: targetIDs,
                refreshAfterJoiningActiveCycle: true
            ) ?? false
        }
        syncPull = { [weak syncCoordinator] in
            await syncCoordinator?.fetchAllNow(reason: "relay.syncNudge")
        }
    }

    func start() {
        guard ReleaseFeatures.relayService, !started else { return }
        started = true
        subscriptionStore.membershipDidChange
            .sink { [weak self] in self?.membershipChanged() }
            .store(in: &cancellables)
        proStore.$isPro
            .removeDuplicates()
            .sink { [weak self] isPro in
                Task { @MainActor in
                    guard let self else { return }
                    if isPro {
                        await self.registerIfPossible()
                    } else if self.client.isRegistered {
                        _ = try? await self.client.unregister()
                        self.clearFeedProtocolState()
                    }
                }
            }
            .store(in: &cancellables)
    }

    func tokenReceived(_ token: String) {
        guard ReleaseFeatures.relayService else { return }
        apnsToken = token
        Task { await registerIfPossible() }
    }

    func localChangesPushed() {
        guard ReleaseFeatures.relayService else { return }
        scheduleSyncNudge()
    }

    func sendHeartbeatIfDue() async {
        guard ReleaseFeatures.relayService,
              proStore.isPro,
              client.isRegistered else { return }
        let lastSent = UserDefaults.standard.double(forKey: Self.lastHeartbeatKey)
        guard Date().timeIntervalSince1970 - lastSent >= Self.heartbeatInterval else { return }
        do {
            let (entitlement, requestID) = try await client.heartbeat(
                apnsToken: apnsToken,
                syncGroupId: await resolveSyncGroupID()
            )
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastHeartbeatKey)
            logger.info("relay.heartbeatSent", "Autohop Relay heartbeat sent", metadata: [
                "requestID": requestID,
                "entitlementStatus": entitlement.status
            ])
            if entitlement.status != "active" && entitlement.status != "grace" {
                await proStore.refreshEntitlement()
            }
        } catch {
            logger.warning("relay.heartbeatFailed", "Autohop Relay heartbeat failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none"
            ])
        }
    }

    @discardableResult
    func handlePush(type: String, feedIDs: [String] = []) async -> Bool {
        guard ReleaseFeatures.relayService else { return false }
        switch type {
        case "feed-updated":
            guard !feedIDs.isEmpty else { return await legacyRefresh() }
            let mapping = RelayFeedMappingStore.urlStrings(for: feedIDs)
            if !mapping.unknown.isEmpty {
                forceFullFeedSync = true
                feedSyncNeedsReconcile = true
                scheduleFeedSync(after: 0)
                logger.warning("relay.pushUnknownFeedIDs", "Relay push contained unknown feed identities", metadata: [
                    "unknownCount": "\(mapping.unknown.count)",
                    "receivedCount": "\(feedIDs.count)"
                ])
            }
            let targetIDs = Set(subscriptionStore.subscriptions.compactMap { subscription -> UUID? in
                guard let canonical = RelayFeedURLCanonicalizer.string(for: subscription.feedURL),
                      mapping.known.contains(canonical) else { return nil }
                return subscription.id
            })
            guard !targetIDs.isEmpty else { return !mapping.unknown.isEmpty }
            return await targetedRefresh(targetIDs)
        case "sync-nudge":
            await syncPull()
            return true
        default:
            return false
        }
    }

    private func registerIfPossible() async {
        guard ReleaseFeatures.relayService,
              proStore.isPro,
              let token = apnsToken,
              let jws = proStore.latestTransactionJWS,
              !registrationInFlight else { return }
        registrationInFlight = true
        defer { registrationInFlight = false }
        let groupID = await resolveSyncGroupID()
        do {
            let (_, requestID) = try await client.register(
                jws: jws,
                apnsToken: token,
                syncGroupId: groupID
            )
            logger.info("relay.registered", "Registered device with Autohop Relay", metadata: [
                "requestID": requestID,
                "hasSyncGroupID": "\(groupID != nil)"
            ])
            forceFullFeedSync = true
            await syncFeedsIfRegistered()
        } catch {
            logger.warning("relay.registerFailed", "Autohop Relay registration failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none"
            ])
        }
    }

    private func membershipChanged() {
        let current = Self.feedURLs(in: subscriptionStore.subscriptions)
        guard current != observedFeedURLs else { return }
        observedFeedURLs = current
        feedSyncNeedsReconcile = true
        scheduleFeedSync()
    }

    private func scheduleFeedSync(after delay: TimeInterval = 2) {
        guard ReleaseFeatures.relayService else { return }
        feedSyncDebounceTask?.cancel()
        feedSyncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self else { return }
            self.feedSyncDebounceTask = nil
            await self.syncFeedsIfRegistered()
        }
    }

    private func syncFeedsIfRegistered() async {
        guard ReleaseFeatures.relayService, proStore.isPro, client.isRegistered else { return }
        if feedSyncInFlight {
            feedSyncNeedsReconcile = true
            return
        }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let nextAttempt = defaults.double(forKey: Self.feedNextAttemptKey)
        if nextAttempt > now {
            feedSyncNeedsReconcile = true
            scheduleFeedSync(after: nextAttempt - now)
            return
        }

        feedSyncInFlight = true
        feedSyncNeedsReconcile = false
        defer {
            feedSyncInFlight = false
            if feedSyncNeedsReconcile { scheduleFeedSync() }
        }

        let desired = Self.feedURLs(in: subscriptionStore.subscriptions)
        let hasBaseline = defaults.object(forKey: Self.acknowledgedFeedsKey) != nil
        let acknowledged = Set(defaults.stringArray(forKey: Self.acknowledgedFeedsKey) ?? [])
        let additions = desired.subtracting(acknowledged)
        let removals = acknowledged.subtracting(desired)
        let forceFull = forceFullFeedSync || !hasBaseline
            || additions.count > 100 || removals.count > 100
        if !forceFull, additions.isEmpty, removals.isEmpty { return }

        do {
            let result: (response: RelayFeedsResponse, requestID: String)
            if forceFull {
                result = try await client.setFeeds(Self.urls(from: desired))
            } else {
                result = try await client.updateFeeds(
                    add: Self.urls(from: additions),
                    remove: Self.urls(from: removals)
                )
            }
            let serverURLs: Set<String>
            if let descriptors = result.response.feeds {
                RelayFeedMappingStore.replace(with: descriptors)
                serverURLs = Set(descriptors.map(\.url))
            } else {
                serverURLs = desired
            }
            defaults.set(Array(serverURLs).sorted(), forKey: Self.acknowledgedFeedsKey)
            defaults.set(0, forKey: Self.feedFailureCountKey)
            defaults.removeObject(forKey: Self.feedNextAttemptKey)
            forceFullFeedSync = result.response.count != desired.count
            logger.info("relay.feedSyncSucceeded", "Autohop Relay feed sync succeeded", metadata: [
                "mode": forceFull ? "set" : "delta",
                "desiredCount": "\(desired.count)",
                "addedCount": "\(additions.count)",
                "removedCount": "\(removals.count)",
                "acknowledgedCount": "\(result.response.count)",
                "changedCount": "\(result.response.changed ?? -1)",
                "requestID": result.requestID
            ])
            if Self.feedURLs(in: subscriptionStore.subscriptions) != desired || forceFullFeedSync {
                feedSyncNeedsReconcile = true
            }
        } catch {
            let count = defaults.integer(forKey: Self.feedFailureCountKey) + 1
            defaults.set(count, forKey: Self.feedFailureCountKey)
            let delay = max(
                RelayRetryPolicy.delay(failureCount: count),
                (error as? RelayError)?.retryAfter ?? 0
            )
            defaults.set(now + delay, forKey: Self.feedNextAttemptKey)
            feedSyncNeedsReconcile = true
            logger.warning("relay.feedSyncFailed", "Autohop Relay feed sync failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none",
                "failureCount": "\(count)",
                "retryAfterSeconds": "\(Int(delay))"
            ])
        }
    }

    private func clearFeedProtocolState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.acknowledgedFeedsKey)
        defaults.removeObject(forKey: Self.feedFailureCountKey)
        defaults.removeObject(forKey: Self.feedNextAttemptKey)
        RelayFeedMappingStore.clear()
        forceFullFeedSync = false
        feedSyncNeedsReconcile = false
        feedSyncDebounceTask?.cancel()
        feedSyncDebounceTask = nil
    }

    private func resolveSyncGroupID() async -> String? {
        if let syncGroupID { return syncGroupID }
        let container = CKContainer(identifier: SyncCoordinator.cloudKitContainerID)
        let recordID: CKRecord.ID? = await withCheckedContinuation { continuation in
            container.fetchUserRecordID { recordID, _ in continuation.resume(returning: recordID) }
        }
        syncGroupID = recordID?.recordName
        return syncGroupID
    }

    private func scheduleSyncNudge() {
        syncNudgeDirty = true
        syncNudgeDebounceTask?.cancel()
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let earliest = max(
            now + 5,
            defaults.double(forKey: Self.nudgeNextAttemptKey),
            defaults.double(forKey: Self.nudgeLastSuccessKey) + Self.nudgeMinimumInterval
        )
        syncNudgeDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, earliest - Date().timeIntervalSince1970)))
            guard !Task.isCancelled, let self else { return }
            self.syncNudgeDebounceTask = nil
            await self.sendSyncNudge()
        }
    }

    private func sendSyncNudge() async {
        guard ReleaseFeatures.relayService,
              proStore.isPro,
              client.isRegistered,
              syncNudgeDirty else { return }
        if syncNudgeInFlight { return }
        syncNudgeInFlight = true
        syncNudgeDirty = false
        defer {
            syncNudgeInFlight = false
            if syncNudgeDirty { scheduleSyncNudge() }
        }
        let defaults = UserDefaults.standard
        do {
            let requestID = try await client.syncNudge()
            defaults.set(Date().timeIntervalSince1970, forKey: Self.nudgeLastSuccessKey)
            defaults.set(0, forKey: Self.nudgeFailureCountKey)
            defaults.removeObject(forKey: Self.nudgeNextAttemptKey)
            logger.info("relay.syncNudgeSent", "Autohop Relay sync-nudge sent", metadata: [
                "requestID": requestID
            ])
        } catch {
            let count = defaults.integer(forKey: Self.nudgeFailureCountKey) + 1
            defaults.set(count, forKey: Self.nudgeFailureCountKey)
            let delay = max(
                RelayRetryPolicy.delay(failureCount: count, base: 60, maximum: 30 * 60),
                (error as? RelayError)?.retryAfter ?? 0
            )
            defaults.set(Date().timeIntervalSince1970 + delay, forKey: Self.nudgeNextAttemptKey)
            syncNudgeDirty = true
            logger.warning("relay.syncNudgeFailed", "Autohop Relay sync-nudge failed", metadata: [
                "error": "\(error)",
                "requestID": (error as? RelayError)?.requestID ?? "none",
                "failureCount": "\(count)",
                "retryAfterSeconds": "\(Int(delay))"
            ])
        }
    }

    private static func feedURLs(in subscriptions: [Subscription]) -> Set<String> {
        Set(subscriptions.lazy
            .filter { $0.browseDate == nil }
            .compactMap { RelayFeedURLCanonicalizer.string(for: $0.feedURL) })
    }

    private static func urls(from strings: Set<String>) -> [URL] {
        strings.sorted().compactMap(URL.init(string:))
    }
}
