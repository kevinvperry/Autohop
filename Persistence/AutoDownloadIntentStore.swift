import Foundation

// AI CONTEXT — Persistence/AutoDownloadIntentStore.swift
// Durable "this episode should auto-download" intents — the fix for deep-scan
// AH-2026-06-28-01 (P1). PROBLEM: a BGAppRefreshTask discovers a new episode,
// but the media download is started by a fire-and-forget Task after the feed
// cycle returns; iOS can suspend/terminate the app right after
// setTaskCompleted, before the background-URLSession task is resumed. The
// in-memory intent (and the cap-overflow pendingDownloadQueue) is then lost —
// and because the refresh SUCCEEDED, Release Radar doesn't mark the feed due
// again until its next release window, so the episode can sit undownloaded
// until the user opens the app. That breaks the latest-episode-ASAP principle.
// FIX: AppState.scheduleAutoDownloadAfterRefresh records an intent here
// SYNCHRONOUSLY (write-through to disk) before spawning the download Task, and
// drains intents idempotently at launch, scene-foreground, and after both BG
// task refreshes (AppState.drainAutoDownloadIntents). An intent is removed only
// when its episode reaches a settled state — downloaded, played/archived,
// gone, filter-excluded, or superseded as the newest candidate
// (AppState.resolveAutoDownloadIntentIfSettled). Network-blocked or
// interrupted attempts KEEP the intent so the next drain retries.
// Storage: Application Support/Autohop/auto-download-intents.json, capped by
// age (7 days) and count (50, oldest dropped). Foundation-only on purpose:
// part of AutohopCore so the lifecycle is headless-testable
// (Tests/AutoDownloadIntentStoreTests.swift).

/// One durable auto-download intention, keyed by the local episode UUID.
public struct AutoDownloadIntent: Codable, Equatable {
    public let episodeID: UUID
    public let subscriptionID: UUID
    public let podcastTitle: String
    public let createdAt: Date

    public init(episodeID: UUID, subscriptionID: UUID, podcastTitle: String, createdAt: Date = Date()) {
        self.episodeID = episodeID
        self.subscriptionID = subscriptionID
        self.podcastTitle = podcastTitle
        self.createdAt = createdAt
    }
}

@MainActor
public final class AutoDownloadIntentStore {
    /// Intents older than this are dropped on load/record — after a week the
    /// normal refresh pipeline has long since re-evaluated the feed, so a stale
    /// intent is noise, not a recovery source.
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Hard cap on stored intents; oldest are dropped first. Generously above
    /// anything a real refresh cycle produces (background cap is 8 feeds).
    public static let maxCount = 50

    public private(set) var intents: [AutoDownloadIntent] = []
    private let fileURL: URL?

    /// Production store at Application Support/Autohop/auto-download-intents.json.
    public convenience init() {
        let url = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Autohop/auto-download-intents.json")
        self.init(fileURL: url)
    }

    /// Custom URLs are for tests; production callers use `init()`.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
        if prune() { save() }
    }

    public func contains(episodeID: UUID) -> Bool {
        intents.contains { $0.episodeID == episodeID }
    }

    /// Records (or refreshes) the intent for an episode. Write-through: the
    /// JSON is on disk before this returns, which is the whole point — it must
    /// beat a post-`setTaskCompleted` suspension.
    public func record(episodeID: UUID, subscriptionID: UUID, podcastTitle: String, now: Date = Date()) {
        intents.removeAll { $0.episodeID == episodeID }
        intents.append(AutoDownloadIntent(
            episodeID: episodeID,
            subscriptionID: subscriptionID,
            podcastTitle: podcastTitle,
            createdAt: now
        ))
        _ = prune(now: now)
        save()
    }

    /// Removes a settled intent. No-op when absent.
    public func remove(episodeID: UUID) {
        let before = intents.count
        intents.removeAll { $0.episodeID == episodeID }
        if intents.count != before { save() }
    }

    /// Drops expired intents and trims to the count cap (oldest first).
    /// Returns true when anything was removed.
    private func prune(now: Date = Date()) -> Bool {
        let before = intents.count
        intents.removeAll { now.timeIntervalSince($0.createdAt) > Self.maxAge }
        if intents.count > Self.maxCount {
            intents.sort { $0.createdAt < $1.createdAt }
            intents.removeFirst(intents.count - Self.maxCount)
        }
        return intents.count != before
    }

    private func load() {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AutoDownloadIntent].self, from: data)
        else { return }
        intents = decoded
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(intents)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // A failed save degrades to pre-fix behavior (intent lives only in
            // memory) — log so a "my episode never downloaded" report has a trace.
            AppLogger.shared.error("download.intentSaveFailed", "Could not persist auto-download intents", metadata: [
                "error": String(describing: error),
                "count": "\(intents.count)"
            ], alwaysPersist: true)
        }
    }
}
