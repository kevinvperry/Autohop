import Combine
import Foundation
import Security
import UserNotifications

// AI CONTEXT — Podcast Replay composition/workflow owner. Subscription Replay
// journals are the durable outbox; flush before scheduling transfer. Only the
// designated installation assigns slots; followers download the same reservations.
// Settings edits synchronise through AutoArchiveSettings and never change owner.
// Calendar days/times are additive; unchanged drafts preserve the live nextDue,
// including overdue work. Episode Limit edits use the store and reconcile here.
// Binge reservations react to durable successful-start events, not calendar time.
// Foreground timer is advisory; existing background drains also reconcile due work.
// Queue order is logical, download availability local. Never trigger Play Instant.
@MainActor
final class PodcastReplayCoordinator: ObservableObject {
    var refreshCatalogue: ((Subscription) async -> Void)?
    private var lastCatalogueAttempt: [UUID: Date] = [:]
    @Published var notificationSubscriptionID: UUID?
    let ownerID: String
    private let store: SubscriptionStore
    private let downloads: AutoDownloadIntentWorkflow
    private var observation: AnyCancellable?
    private var wakeTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var running = false
    private var needsRun = false

    init(store: SubscriptionStore, downloads: AutoDownloadIntentWorkflow) {
        self.store = store; self.downloads = downloads
        ownerID = Self.installationID()
    }
    func start() {
        guard observation == nil else { return }
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.requestReconciliation() }
        }
        downloads.reconcileReplay = { [weak self] in await self?.reconcile() }
        NotificationService.shared.onPodcastReplay = { [weak self] sub, session, action in
            guard let self else { return }
            if action == "replayKeep" || action == "replayDisable" {
                self.decide(subscriptionID: sub, sessionID: session, keep: action == "replayKeep")
            }
            self.notificationSubscriptionID = sub
        }
        requestReconciliation()
    }
    func requestReconciliation() {
        if running { needsRun = true; return }
        requestTask?.cancel()
        requestTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }
    func configure(subscription: Subscription, start: Episode, first: Date, days: Int, notify: Bool,
                   calendarSchedule: PodcastReplay.CalendarSchedule? = nil, scheduleChanged: Bool = true, bingeMode: Bool = false) {
        var replay: PodcastReplay
        if let existing = subscription.autoArchiveSettings.replay, existing.enabled {
            replay = existing
            if scheduleChanged {
                replay.firstRelease = first; replay.everyDays = max(1, days)
                replay.calendarSchedule = calendarSchedule
                replay.nextDue = calendarSchedule?.nextDate(onOrAfter: first, timeZoneID: replay.timeZoneID) ?? first
                replay.progressVersion += 1
            }
            replay.edit()
        } else {
            replay = PodcastReplay(start: start, firstRelease: first, everyDays: days, ownerID: ownerID)
        }
        if subscription.autoArchiveSettings.replay?.enabled != true {
            replay.calendarSchedule = calendarSchedule
            replay.nextDue = calendarSchedule?.nextDate(onOrAfter: first, timeZoneID: replay.timeZoneID) ?? first
        }
        if replay.isBinge && !bingeMode {
            // Resuming scheduled mode starts at the next real slot, not at
            // accumulated calendar debt from the time spent binging.
            replay.nextDue = replay.calendarSchedule?.nextDate(onOrAfter: max(first, Date()), timeZoneID: replay.timeZoneID) ?? max(first, Date())
            replay.progressVersion += 1
        }
        replay.bingeMode = bingeMode
        replay.notifyCaughtUp = notify
        store.updatePodcastReplay(subscriptionID: subscription.id, replay: replay)
        requestReconciliation()
    }
    func decide(subscriptionID: UUID, sessionID: UUID, keep: Bool) {
        guard var replay = store.subscription(id: subscriptionID)?.autoArchiveSettings.replay,
              replay.sessionID == sessionID, replay.enabled else { return }
        if keep { replay.keptSchedule = true } else { replay.enabled = false }
        replay.edit()
        store.updatePodcastReplay(subscriptionID: subscriptionID, replay: replay)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["replay.\(sessionID)"])
        requestReconciliation()
    }
    func reconcile() async {
        guard !running else { needsRun = true; return }
        running = true
        defer {
            running = false
            if needsRun { needsRun = false; requestReconciliation() }
        }
        var nextWake = Date().addingTimeInterval(3600)
        for original in store.subscriptions {
            guard original.browseDate == nil, !original.excludeFromAutoFeedRefresh,
                  var replay = original.autoArchiveSettings.replay, replay.enabled else { continue }
            for release in replay.outstanding {
                if let episode = original.episodes.first(where: { $0.audioURL == release.episode.audioURL }),
                   episode.playedState == .played || episode.playedState == .archived,
                   (episode.lastPlayedAt ?? .distantPast) >= (release.reservedAt ?? replay.createdAt) {
                    store.resolvePodcastReplay(subscriptionID: original.id, episode: episode)
                }
            }
            replay = store.subscription(id: original.id)?.autoArchiveSettings.replay ?? replay
            let needsMetadata = replay.outstanding.contains { release in
                guard let episode = original.episodes.first(where: { $0.audioURL == release.episode.audioURL }) else { return true }
                return original.downloadFilterSettings.descriptionEnabled && episode.description == nil
            }
            if needsMetadata, Date().timeIntervalSince(lastCatalogueAttempt[original.id] ?? .distantPast) > 300 {
                lastCatalogueAttempt[original.id] = Date()
                await refreshCatalogue?(original)
                needsRun = true
                continue
            }
            if replay.ownerID == ownerID, replay.caughtUp(in: original), !replay.confirmedCaughtUp(in: original),
               Date().timeIntervalSince(lastCatalogueAttempt[original.id] ?? .distantPast) > 300 {
                lastCatalogueAttempt[original.id] = Date()
                await refreshCatalogue?(original)
                needsRun = true
                continue
            }
            if replay.ownerID == ownerID {
                // A failure holds the sequence for retry, not silent skipping.
                let failed = replay.outstanding.contains { release in
                    original.episodes.first { $0.audioURL == release.episode.audioURL }?.downloadState == .failed
                }
                if !failed { replay.reserve(in: original, now: Date()) }
                store.updatePodcastReplay(subscriptionID: original.id, replay: replay)
            }
            guard await store.flushPendingSaves(),
                  let current = store.subscription(id: original.id),
                  let committed = current.autoArchiveSettings.replay, committed.enabled,
                  committed.sessionID == replay.sessionID else { continue }
            if !committed.isBinge { nextWake = min(nextWake, max(committed.nextDue, Date().addingTimeInterval(60))) }
            // Materialise shared releases locally before dispatching the outbox.
            store.updatePodcastReplay(subscriptionID: current.id, replay: committed)
            let candidates = current.replayQueueEpisodes.filter {
                $0.downloadState == .notDownloaded || $0.downloadState == .failed
            }
            if !candidates.isEmpty {
                downloads.schedule(episodes: candidates, subscriptionID: current.id,
                    podcastTitle: current.title, refreshUpNextAfterMerge: true,
                    detectionContext: "podcastReplay", sceneActive: true,
                    batteryState: "replay", detectedAt: Date(), sceneActivationSequence: 0)
            }
            if committed.ownerID == ownerID, committed.confirmedCaughtUp(in: current), !committed.promptIssued {
                var updated = committed; updated.promptIssued = true
                store.updatePodcastReplay(subscriptionID: current.id, replay: updated)
                if await store.flushPendingSaves(), updated.notifyCaughtUp {
                    await notifyCaughtUp(subscription: current, replay: updated)
                }
            }
        }
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, nextWake.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }
    private func notifyCaughtUp(subscription: Subscription, replay: PodcastReplay) async {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "You're caught up with \(subscription.title)"
        content.body = "Keep your Podcast Replay schedule or return to automatic downloads of new episodes. Open Podcast Replay to choose."
        content.userInfo = ["replaySubscriptionID": subscription.id.uuidString, "replaySessionID": replay.sessionID.uuidString]
        content.categoryIdentifier = "podcastReplay"
        content.sound = .default
        try? await centre.add(UNNotificationRequest(identifier: "replay.\(replay.sessionID)", content: content, trigger: nil))
    }
    private static func installationID() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.autohop.replay.owner", kSecAttrAccount as String: "installation"]
        var result: CFTypeRef?
        var read = query; read[kSecReturnData as String] = true
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString
        var add = query; add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            // Do not create a durable schedule from an identity that cannot survive restart.
            return "unavailable"
        }
        return id
    }
}
