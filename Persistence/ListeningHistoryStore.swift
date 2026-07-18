import Combine
import Foundation

// AI CONTEXT — Persistence/ListeningHistoryStore.swift
//
// PURPOSE / OWNERSHIP:
// Persists the per-episode listening log to Application Support/Autohop/
// listening-history.json. This already-independent store moved verbatim from the
// bottom of App/AppState.swift during decomposition Stage 2. AppState remains its
// orchestration owner until Stage 3 introduces HistoryStatsCoordinator.
//
// IDENTITY / FORMAT:
// Entries are keyed by subscription-scoped episode GUID/URL (`historyKey`) so a
// re-fetched episode merges into one row without colliding across feeds. The JSON
// path, Codable payload, 500-entry cap, sorting, repair behavior, batching, and
// sync-row writes are unchanged by the move.
//
// CONCURRENCY:
// MainActor-only. Playback ticks call `recordProgress`; remote CloudKit changes
// call `applyRemote`. Both serialize through MainActor. This store owns no Task
// and must not create a second history writer.
//
// PERSISTENCE / SYNC:
// Tick samples accumulate in memory and become one entry mutation/sort/sync marker
// per 30-second batch. Routine diagnostics are summarized at most every five
// minutes. `save()` and terminal `mark()` flush the buffer first, preserving
// pause/background/completion durability. `syncDatabase` is the existing
// CloudKit projection adapter supplied by AppState.
//
// INVARIANTS / PROHIBITED RESPONSIBILITIES:
// - A later Auto Archive storage cleanup cannot replace an existing Played,
//   naturally finished, or marked-played listening outcome.
// - Remote history remains whole-entry LWW by `lastListenedAt`.
// - The UI's >=60-second presentation threshold does not belong here.
// - Do not add Stats, queue, playback-engine, archive-rule, or sync-lifecycle
//   orchestration. Those move through later approved stages.
@MainActor
final class ListeningHistoryStore: ObservableObject {
    @Published private(set) var entries: [ListeningHistoryEntry] = []

    private var lastSavedAt: Date?
    private let maxEntries = 500
    private let progressFlushInterval: TimeInterval = 30
    private var lastProgressFlushAt: Date?
    private var lastProgressDiagnosticAt: Date?
    private let progressDiagnosticInterval: TimeInterval = 5 * 60

    /// Latest metadata plus accumulated wall-clock listening for one episode.
    /// Playback normally has only one pending key; the dictionary makes an episode
    /// switch safe even if its final lifecycle checkpoint arrives asynchronously.
    private struct PendingProgress {
        var episode: Episode
        var podcastTitle: String
        var artworkURL: URL?
        var listenedSeconds: TimeInterval
        var positionSeconds: TimeInterval
        var durationSeconds: TimeInterval?
        var lastListenedAt: Date
    }
    private var pendingProgress: [String: PendingProgress] = [:]
    /// Record store for cross-device history sync; set by AppState. nil = no sync.
    var syncDatabase: AutohopDatabase?

    private static let fileURL: URL? = {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/listening-history.json")
    }()

    init() {
        load()
    }

    var totalListeningSeconds: TimeInterval {
        entries.reduce(0) { $0 + $1.listenedSeconds }
    }

    func recordProgress(
        episode: Episode,
        podcastTitle: String,
        artworkURL: URL?,
        listenedSeconds: TimeInterval,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?
    ) {
        let key = historyKey(for: episode)
        let now = Date()

        if var pending = pendingProgress[key] {
            pending.episode = episode
            pending.podcastTitle = podcastTitle
            pending.artworkURL = artworkURL
            pending.listenedSeconds += listenedSeconds
            pending.positionSeconds = positionSeconds
            pending.durationSeconds = durationSeconds ?? episode.durationSeconds
            pending.lastListenedAt = now
            pendingProgress[key] = pending
        } else {
            pendingProgress[key] = PendingProgress(
                episode: episode,
                podcastTitle: podcastTitle,
                artworkURL: artworkURL,
                listenedSeconds: listenedSeconds,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds ?? episode.durationSeconds,
                lastListenedAt: now
            )
        }

        guard lastProgressFlushAt.map({ now.timeIntervalSince($0) >= progressFlushInterval }) ?? true else {
            return
        }
        flushPendingProgress(reason: "playbackBatch")
    }

    /// Applies all buffered tick samples as a single published array mutation.
    /// This is the expensive boundary: lookup/update, one final sort, one sync-row
    /// marker per affected episode, and at most one throttled JSON save.
    private func flushPendingProgress(reason: String) {
        guard !pendingProgress.isEmpty else { return }
        let pending = pendingProgress
        pendingProgress.removeAll(keepingCapacity: true)
        lastProgressFlushAt = Date()

        for (key, progress) in pending {
            let episode = progress.episode
            if let index = entries.firstIndex(where: { $0.id == key }) {
                entries[index].episodeID = episode.id
                entries[index].episodeTitle = episode.title
                entries[index].podcastTitle = progress.podcastTitle
                entries[index].artworkURL = progress.artworkURL
                entries[index].publishedAt = episode.publishedAt
                entries[index].durationSeconds = progress.durationSeconds
                entries[index].listenedSeconds += progress.listenedSeconds
                entries[index].lastPositionSeconds = progress.positionSeconds
                entries[index].lastListenedAt = progress.lastListenedAt
                // Status remains unchanged: only mark() owns completion state.
            } else {
                entries.append(ListeningHistoryEntry(
                    id: key,
                    subscriptionID: episode.subscriptionID,
                    episodeID: episode.id,
                    episodeTitle: episode.title,
                    podcastTitle: progress.podcastTitle,
                    artworkURL: progress.artworkURL,
                    publishedAt: episode.publishedAt,
                    durationSeconds: progress.durationSeconds,
                    listenedSeconds: progress.listenedSeconds,
                    lastPositionSeconds: progress.positionSeconds,
                    lastListenedAt: progress.lastListenedAt,
                    status: .listened
                ))
            }
        }

        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        for key in pending.keys { recordPending(id: key) }
        let now = Date()
        let routineSummaryDue = lastProgressDiagnosticAt.map({ now.timeIntervalSince($0) >= progressDiagnosticInterval }) ?? true
        if reason != "playbackBatch" || routineSummaryDue {
            lastProgressDiagnosticAt = now
            AppLogger.shared.info("history.progressFlush", "Applied coalesced listening-history progress", metadata: [
                "reason": reason,
                "episodeCount": "\(pending.count)",
                "listenedSeconds": String(format: "%.1f", pending.values.reduce(0) { $0 + $1.listenedSeconds })
            ])
        }
        if reason == "playbackBatch" {
            saveThrottled()
        }
    }

    func mark(
        episode: Episode,
        podcastTitle: String,
        artworkURL: URL?,
        status: ListeningHistoryStatus,
        completionKind: CompletionKind? = nil,
        positionSeconds: TimeInterval? = nil
    ) {
        let key = historyKey(for: episode)
        // Completion must include every tick accumulated since the last batch.
        flushPendingProgress(reason: "mark")
        let now = Date()
        let epDuration = episode.durationSeconds
        let pct: Double? = {
            guard let pos = positionSeconds, let dur = epDuration, dur > 0 else { return nil }
            return min(pos / dur, 1.0)
        }()

        if let index = entries.firstIndex(where: { $0.id == key }) {
            // AI CONTEXT — Auto Archive's After Played pass runs after playback
            // completion and changes the library row to Archived. It is not a new
            // listening outcome. Preserve both modern CompletionKind events and
            // legacy Played entries so the UI continues to say Completed.
            let existing = entries[index]
            if completionKind == .autoArchived,
               existing.status == .played
                || existing.completionKind == .finishedNaturally
                || existing.completionKind == .markedPlayed {
                AppLogger.shared.info("history.autoArchivePreservedCompletion", "Preserved completed history event during automatic storage cleanup", metadata: [
                    "episode": episode.title,
                    "existingKind": existing.completionKind?.rawValue ?? "legacyPlayed"
                ])
                return
            }
            entries[index].status = status
            entries[index].podcastTitle = podcastTitle
            entries[index].artworkURL = artworkURL
            entries[index].lastListenedAt = now
            entries[index].completionKind = completionKind
            if let pos = positionSeconds {
                entries[index].listenedDurationSeconds = pos
                entries[index].lastPositionSeconds = pos
            }
            if let dur = epDuration {
                entries[index].episodeDurationSeconds = dur
            }
            entries[index].completionPercent = pct
        } else {
            let pos = positionSeconds ?? 0
            entries.append(ListeningHistoryEntry(
                id: key,
                subscriptionID: episode.subscriptionID,
                episodeID: episode.id,
                episodeTitle: episode.title,
                podcastTitle: podcastTitle,
                artworkURL: artworkURL,
                publishedAt: episode.publishedAt,
                durationSeconds: epDuration,
                listenedSeconds: 0,
                lastPositionSeconds: pos,
                lastListenedAt: now,
                status: status,
                completionKind: completionKind,
                completionPercent: pct,
                listenedDurationSeconds: positionSeconds,
                episodeDurationSeconds: epDuration
            ))
        }
        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        recordPending(id: key)
        save()
    }

    /// Records a changed entry as pending for cross-device sync.
    private func recordPending(id: String) {
        guard let syncDatabase, let entry = entries.first(where: { $0.id == id }) else { return }
        do {
            try syncDatabase.recordHistoryEntry(entry)
        } catch {
            // A swallowed failure here means the entry saved locally but the
            // outgoing CloudKit row was never queued — log so a "history didn't
            // sync" report leaves a trace (alwaysPersist survives the Diagnostics
            // toggle being off).
            AppLogger.shared.error("sync.historyMarkerFailed", "Failed to record pending history entry for sync", metadata: [
                "entryID": id,
                "error": String(describing: error)
            ], alwaysPersist: true)
        }
    }

    /// Merges a remote history entry with record-level last-write-wins
    /// (the entry with the newer `lastListenedAt` wins the whole record).
    @MainActor
    func applyRemote(_ remote: ListeningHistoryEntry) {
        // Resolve local buffered ticks before record-level LWW compares timestamps.
        flushPendingProgress(reason: "remoteMerge")
        var normalizedRemote = remote
        normalizedRemote.repairAutoArchiveOverwriteIfClearlyCompleted()
        if let index = entries.firstIndex(where: { $0.id == normalizedRemote.id }) {
            guard normalizedRemote.lastListenedAt > entries[index].lastListenedAt else { return } // local newer — keep, stays pending
            entries[index] = normalizedRemote
        } else {
            entries.append(normalizedRemote)
        }
        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        try? syncDatabase?.saveSyncedHistoryEntry(normalizedRemote) // clean — don't re-push
        save()
    }

    func save() {
        // Lifecycle checkpoints call save(), so make buffered progress durable and
        // sync-visible before encoding. flushPendingProgress may call saveThrottled;
        // lastProgressFlushAt prevents recursion because the buffer is already empty.
        flushPendingProgress(reason: "save")
        guard let url = Self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic])
            lastSavedAt = Date()
        } catch {
            AppLogger.shared.warning("history.saveFailed", "Could not save listening history", metadata: [
                "error": String(describing: error)
            ])
        }
    }

    private func saveThrottled() {
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 10 {
            return
        }
        save()
    }

    private func load() {
        guard let url = Self.fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loadedEntries = try? JSONDecoder().decode([ListeningHistoryEntry].self, from: data)
        else { return }
        var repairedCount = 0
        entries = loadedEntries.map { entry in
            var normalized = entry
            if normalized.repairAutoArchiveOverwriteIfClearlyCompleted() {
                repairedCount += 1
            }
            return normalized
        }.sorted { $0.lastListenedAt > $1.lastListenedAt }
        if repairedCount > 0 {
            AppLogger.shared.info("history.autoArchiveRepair", "Repaired completed history events overwritten by automatic storage cleanup", metadata: [
                "entryCount": "\(repairedCount)"
            ])
            save()
        }
    }

    private func historyKey(for episode: Episode) -> String {
        let subscriptionPrefix = episode.subscriptionID.uuidString
        let trimmedGUID = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGUID.isEmpty {
            return "\(subscriptionPrefix)|guid:\(trimmedGUID)"
        }
        if let publishedAt = episode.publishedAt {
            return "\(subscriptionPrefix)|title-date:\(episode.title.lowercased())|\(Int(publishedAt.timeIntervalSince1970))"
        }
        return "\(subscriptionPrefix)|title-url:\(episode.title.lowercased())|\(episode.audioURL.absoluteString)"
    }
}
