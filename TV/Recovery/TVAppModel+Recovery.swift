import Combine
import CloudKit
import Foundation
import AutohopCore

// AI CONTEXT — Purge recovery and targeted subscription materialisation. Extracted from TVAppModel without changing
// product policy; this extension is tvOS-only and coordinated through focused
// observable state owners defined in TVAppFeatureModels.swift. Survival-kit
// mutations must schedule, never directly execute, Library projection refresh.

extension TVAppModel {
    // MARK: - Purge recovery (T2)

    func rebuildMissingSubscriptions(from kit: SubscriptionSurvivalKit) async {
        let missing = kit.entries
            .filter { subscriptionStore.subscription(id: $0.subscriptionID) == nil }
            .sorted { $0.priorityRank < $1.priorityRank }
        guard !missing.isEmpty else { return }
        statusText = "Rebuilding your library…"
        for entry in missing {
            let succeeded = await materializeFeed(
                url: entry.feedURL,
                subscriptionID: entry.subscriptionID,
                priorityRank: entry.priorityRank
            )
            if !succeeded { scheduleMaterializationRetry(entry) }
        }
    }

    /// Fetch + parse a feed and recreate its subscription with a PRESERVED id.
    /// Failures are retained in the survival kit and owned by the bounded retry
    /// worker below; an unchanged CloudKit record is not assumed to reappear.
    @discardableResult
    func materializeFeed(url: URL, subscriptionID: UUID, priorityRank: Int?) async -> Bool {
        do {
            var request = URLRequest(url: url)
            PodcastUserAgent.identify(&request)
            let (data, _) = try await URLSession.shared.data(for: request)
            // Parse OFF the main actor (2026-07-11 nav-stall fix): this runs
            // in a @MainActor context, so a bare parse() of each of 113 feeds
            // during a purge rebuild serially blocked the main thread — one
            // ingredient of the "focus feels stuck, then jumps" remote lag.
            let parsed = try await Task.detached(priority: .userInitiated) {
                try RSSParser().parse(data: data, maxEpisodes: 50)
            }.value
            subscriptionStore.materialize(
                parsedFeed: parsed,
                feedURL: url,
                subscriptionID: subscriptionID,
                priorityRank: priorityRank
            )
            materializationAttempts[subscriptionID] = nil
            materializationRetryTasks[subscriptionID]?.cancel()
            materializationRetryTasks[subscriptionID] = nil
            saveSurvivalKit()
            return true
        } catch {
            AppLogger.shared.warning("tv.materializeFailed", "Could not fetch a feed during TV bootstrap", metadata: [
                "url": url.absoluteString,
                "error": String(describing: error)
            ], alwaysPersist: true)
            return false
        }
    }

    /// Records a remote identity before touching the network. This is the
    /// missing durability edge in the former implementation: CloudKit may not
    /// resend an unchanged record after a one-off RSS failure.
    func rememberMaterializationCandidate(_ entry: SurvivalKitEntry) {
        var kit = survivalKitStore.load() ?? SubscriptionSurvivalKit(entries: [], iCloudSyncEnabled: true)
        if let index = kit.entries.firstIndex(where: { $0.subscriptionID == entry.subscriptionID }) {
            kit.entries[index] = entry
        } else {
            kit.entries.append(entry)
        }
        kit.entries.sort { $0.priorityRank < $1.priorityRank }
        survivalKitStore.save(kit)
        libraryProjectionExplicitlyInvalidated = true
        scheduleLibraryRefresh()
    }

    func forgetMaterializationCandidate(id: UUID) {
        guard var kit = survivalKitStore.load() else { return }
        kit.entries.removeAll { $0.subscriptionID == id }
        survivalKitStore.save(kit)
        materializationAttempts[id] = nil
        materializationRetryTasks[id]?.cancel()
        materializationRetryTasks[id] = nil
        libraryProjectionExplicitlyInvalidated = true
        scheduleLibraryRefresh()
    }

    /// Retries indefinitely with a capped delay while the app remains alive.
    /// The survival kit re-establishes the loop after relaunch. Only one worker
    /// may own a subscription ID, preventing retry storms on repeated sync
    /// callbacks or manual refreshes.
    func scheduleMaterializationRetry(_ entry: SurvivalKitEntry, immediate: Bool = false) {
        rememberMaterializationCandidate(entry)
        guard subscriptionStore.subscription(id: entry.subscriptionID) == nil,
              materializationRetryTasks[entry.subscriptionID] == nil else { return }
        materializationRetryTasks[entry.subscriptionID] = Task { [weak self] in
            guard let self else { return }
            var runImmediately = immediate
            while !Task.isCancelled,
                  self.subscriptionStore.subscription(id: entry.subscriptionID) == nil {
                if self.subscriptionStore.syncedSubscriptionWantsMembership(id: entry.subscriptionID) == false {
                    self.forgetMaterializationCandidate(id: entry.subscriptionID)
                    break
                }
                let attempt = (self.materializationAttempts[entry.subscriptionID] ?? 0) + 1
                self.materializationAttempts[entry.subscriptionID] = attempt
                if !runImmediately {
                    let delays: [TimeInterval] = [5, 30, 120, 300, 900]
                    try? await Task.sleep(for: .seconds(delays[min(attempt - 1, delays.count - 1)]))
                }
                runImmediately = false
                guard !Task.isCancelled else { break }
                let succeeded = await self.materializeFeed(
                    url: entry.feedURL,
                    subscriptionID: entry.subscriptionID,
                    priorityRank: entry.priorityRank
                )
                if succeeded { break }
                AppLogger.shared.info("tv.materializeRetryScheduled", "Subscription materialisation remains pending", metadata: [
                    "subscriptionID": entry.subscriptionID.uuidString,
                    "attempt": "\(attempt)"
                ], alwaysPersist: true)
            }
            self.materializationRetryTasks[entry.subscriptionID] = nil
        }
    }

    func retryPendingMaterializationsNow() {
        let realIDs = Set(subscriptionStore.subscriptions.filter { $0.browseDate == nil }.map(\.id))
        for entry in survivalKitStore.load()?.entries ?? [] where !realIDs.contains(entry.subscriptionID) {
            if subscriptionStore.syncedSubscriptionWantsMembership(id: entry.subscriptionID) == false {
                forgetMaterializationCandidate(id: entry.subscriptionID)
                continue
            }
            materializationRetryTasks[entry.subscriptionID]?.cancel()
            materializationRetryTasks[entry.subscriptionID] = nil
            scheduleMaterializationRetry(entry, immediate: true)
        }
    }

}
