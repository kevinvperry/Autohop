import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// AI CONTEXT — Persistence/ListeningHistoryStore.swift
//
// PURPOSE / OWNERSHIP:
// Persists the per-episode listening log to Application Support/Autohop/
// listening-history.json. This already-independent store moved verbatim from the
// bottom of App/AppState.swift during decomposition Stage 2.
// HistoryStatsCoordinator has owned its iOS orchestration since Stage 3.
//
// IDENTITY / FORMAT:
// Entries are keyed by subscription-scoped episode GUID/URL (`historyKey`) so a
// re-fetched episode merges into one row without colliding across feeds. The JSON
// path, bounded retention, sorting, repair behavior, batching, and sync-row writes
// remain stable. The JSON payload now sits inside a checksummed versioned envelope.
//
// CONCURRENCY:
// MainActor-only. Rendered playback intervals call `recordProgress`; remote CloudKit changes
// call `applyRemote`. Both serialize through MainActor. This store owns no Task
// and must not create a second history writer.
//
// PERSISTENCE / SYNC:
// Rendered intervals accumulate in memory and become one entry mutation/sort/sync marker
// per 30-second batch. Routine diagnostics are summarized at most every five
// minutes. `save()` and terminal `mark()` flush the buffer first, preserving
// pause/background/completion durability. `syncDatabase` is the existing
// CloudKit projection adapter connected by AppStartupWorkflow through
// HistoryStatsCoordinator.
//
// INVARIANTS / PROHIBITED RESPONSIBILITIES:
// - A later Auto Archive storage cleanup cannot replace an existing Played,
//   naturally finished, or marked-played listening outcome.
// - Remote history uses recency for resume/navigation fields while accumulated
//   listening and terminal outcome evidence merge monotonically.
// - The UI's >=60-second presentation threshold does not belong here.
// - Do not add Stats, queue, playback-engine, archive-rule, or sync-lifecycle
//   orchestration. Those move through later approved stages.
@MainActor
final class ListeningHistoryStore: ObservableObject {
    @Published private(set) var entries: [ListeningHistoryEntry] = []
    private(set) var persistenceState: DurableStoreLoadState = .absent

    private var lastSavedAt: Date?
    // Stats uses history for outcome/cadence details that predate durable
    // per-show daily counters. Five hundred entries could represent only weeks
    // for a heavy listener and silently falsified yearly/lifetime show details.
    // Keep a generous bounded history while daily Stats remain the count source.
    private let maxEntries = 5_000
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
    /// Record store for cross-device history sync; connected by
    /// HistoryStatsCoordinator. nil = no sync.
    var syncDatabase: AutohopDatabase?

    private let fileURL: URL?
    private let protectedDataAvailable: () -> Bool
    private var protectedDataObserver: NSObjectProtocol?
    private var storageGenerationID = UUID().uuidString
    private var storageRevision: UInt64 = 0
    private static let storageSchemaVersion = 1

    private static let defaultFileURL: URL? = {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/listening-history.json")
    }()

    convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    /// Explicit location is a characterization-test seam. Production continues
    /// using the historical Application Support path through `init()`.
    convenience init(fileURL: URL?) {
        self.init(
            fileURL: fileURL,
            protectedDataAvailable: { Self.systemProtectedDataAvailable }
        )
    }

    init(fileURL: URL?, protectedDataAvailable: @escaping () -> Bool) {
        self.fileURL = fileURL
        self.protectedDataAvailable = protectedDataAvailable
        load()
    }

    private static var systemProtectedDataAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
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
                entries[index].streamURL = episode.audioURL
                entries[index].mediaKind = episode.mediaKind
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
                    streamURL: episode.audioURL,
                    mediaKind: episode.mediaKind,
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
        storageRevision &+= 1
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
            entries[index].streamURL = episode.audioURL
            entries[index].mediaKind = episode.mediaKind
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
                streamURL: episode.audioURL,
                mediaKind: episode.mediaKind,
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
        storageRevision &+= 1
        recordPending(id: key)
        save()
    }

    /// Records a changed entry as pending for cross-device sync.
    private func recordPending(id: String) {
        guard persistenceState.allowsPersistence else { return }
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

    /// Merges navigation state by recency while preserving monotonic listening
    /// totals and the strongest terminal outcome evidence.
    @discardableResult
    @MainActor
    func applyRemote(_ remote: ListeningHistoryEntry) -> ListeningHistoryEntry? {
        // Resolve local buffered ticks before the field-aware merge compares timestamps.
        flushPendingProgress(reason: "remoteMerge")
        var normalizedRemote = remote
        normalizedRemote.repairAutoArchiveOverwriteIfClearlyCompleted()
        var navigationUpdate: ListeningHistoryEntry?
        if let index = entries.firstIndex(where: { $0.id == normalizedRemote.id }) {
            let local = entries[index]
            let merged = local.mergedForSync(with: normalizedRemote)
            guard merged != local else { return nil }
            entries[index] = merged
            if normalizedRemote.lastListenedAt > local.lastListenedAt {
                navigationUpdate = merged
            }
            if merged == normalizedRemote {
                try? syncDatabase?.saveSyncedHistoryEntry(merged)
            } else {
                recordPending(id: merged.id)
            }
        } else {
            entries.append(normalizedRemote)
            navigationUpdate = normalizedRemote
            try? syncDatabase?.saveSyncedHistoryEntry(normalizedRemote)
        }
        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        storageRevision &+= 1
        save()
        return navigationUpdate
    }

    func save() {
        guard persistenceState.allowsPersistence else {
            AppLogger.shared.error(
                "history.saveBlocked",
                "Refused to overwrite listening history after an unsuccessful load",
                metadata: ["state": String(describing: persistenceState)],
                alwaysPersist: true
            )
            return
        }
        // Lifecycle checkpoints call save(), so make buffered progress durable and
        // sync-visible before encoding. flushPendingProgress may call saveThrottled;
        // lastProgressFlushAt prevents recursion because the buffer is already empty.
        flushPendingProgress(reason: "save")
        guard let url = fileURL else { return }
        do {
            if persistenceState != .recoveredFromBackup {
                try preserveLastKnownGoodPrimary(at: url)
            }
            let envelope = try IntegrityCheckedStoreEnvelope.make(
                payload: entries,
                schemaVersion: Self.storageSchemaVersion,
                generationID: storageGenerationID,
                revision: storageRevision,
                writerDeviceID: DeviceIdentity.current
            )
            let data = try IntegrityCheckedStoreEnvelope.encode(envelope)
            try LockedDeviceFileAccess.writeDataAtomically(data, to: url)
            lastSavedAt = Date()
            persistenceState = .loaded
        } catch {
            AppLogger.shared.error("history.saveFailed", "Could not save listening history", metadata: [
                "error": String(describing: error)
            ], alwaysPersist: true)
        }
    }

    private func saveThrottled() {
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 10 {
            return
        }
        save()
    }

    private struct LoadedSnapshot {
        let entries: [ListeningHistoryEntry]
        let generationID: String
        let revision: UInt64
    }

    private func load() {
        guard let url = fileURL else {
            persistenceState = .absent
            return
        }
        guard protectedDataAvailable() else {
            persistenceState = .temporarilyUnavailable
            installProtectedDataRetry()
            AppLogger.shared.error(
                "history.loadUnavailable",
                "Listening history is unavailable until protected data can be read",
                alwaysPersist: true
            )
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            if restoreFromBackup(for: url) { return }
            if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
                quarantinePrimary(at: backupURL)
                persistenceState = .corruptOrIncompatible
                AppLogger.shared.error(
                    "history.backupRejected",
                    "The primary history file is absent and its backup failed validation; writes are blocked",
                    alwaysPersist: true
                )
                return
            }
            persistenceState = .absent
            return
        }
        do {
            let encoded = try Data(contentsOf: url)
            let loaded = try decodeSnapshot(encoded)
            applyLoadedSnapshot(loaded, state: .loaded)
        } catch {
            if !protectedDataAvailable() {
                persistenceState = .temporarilyUnavailable
                installProtectedDataRetry()
                AppLogger.shared.error(
                    "history.loadUnavailable",
                    "Listening history became unavailable while loading",
                    metadata: ["error": String(describing: error)],
                    alwaysPersist: true
                )
                return
            }
            quarantinePrimary(at: url)
            if restoreFromBackup(for: url) { return }
            persistenceState = .corruptOrIncompatible
            AppLogger.shared.error(
                "history.loadRejected",
                "Listening history failed validation; writes are blocked and the original is preserved",
                metadata: ["error": String(describing: error)],
                alwaysPersist: true
            )
            return
        }
        repairLoadedEntriesIfNeeded()
    }

    private func decodeSnapshot(_ encoded: Data) throws -> LoadedSnapshot {
        do {
            let envelope = try IntegrityCheckedStoreEnvelope<[ListeningHistoryEntry]>.decode(encoded)
            let payload = try envelope.validated(expectedSchemaVersion: Self.storageSchemaVersion)
            guard payload.allSatisfy(\.isSemanticallyValid) else {
                throw IntegrityCheckedStoreEnvelope<[ListeningHistoryEntry]>.ValidationError.invalidMetadata
            }
            return LoadedSnapshot(
                entries: payload,
                generationID: envelope.generationID,
                revision: envelope.revision
            )
        } catch {
            if let legacy = try? JSONDecoder().decode([ListeningHistoryEntry].self, from: encoded),
               legacy.allSatisfy(\.isSemanticallyValid) {
                return LoadedSnapshot(entries: legacy, generationID: UUID().uuidString, revision: 0)
            }
            throw error
        }
    }

    private func applyLoadedSnapshot(_ loaded: LoadedSnapshot, state: DurableStoreLoadState) {
        entries = loaded.entries.sorted { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        storageGenerationID = loaded.generationID
        storageRevision = loaded.revision
        persistenceState = state
    }

    private var backupURL: URL? {
        fileURL?.deletingPathExtension().appendingPathExtension("backup.json")
    }

    private func restoreFromBackup(for primaryURL: URL) -> Bool {
        guard let backupURL,
              FileManager.default.fileExists(atPath: backupURL.path),
              let encoded = try? Data(contentsOf: backupURL),
              let loaded = try? decodeSnapshot(encoded) else { return false }
        applyLoadedSnapshot(loaded, state: .recoveredFromBackup)
        repairLoadedEntriesIfNeeded()
        AppLogger.shared.error(
            "history.backupRecovered",
            "Recovered listening history from the last-known-good backup",
            metadata: ["primary": primaryURL.lastPathComponent],
            alwaysPersist: true
        )
        save()
        return true
    }

    private func preserveLastKnownGoodPrimary(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // A read failure is not equivalent to an absent file. Abort the save so
        // a protection/permissions race cannot overwrite the only good copy.
        let existing = try Data(contentsOf: url)
        guard (try? decodeSnapshot(existing)) != nil else {
            quarantinePrimary(at: url, data: existing)
            return
        }
        guard let backupURL else { return }
        try LockedDeviceFileAccess.writeDataAtomically(existing, to: backupURL)
    }

    private func quarantinePrimary(at url: URL, data: Data? = nil) {
        guard let encoded = data ?? (try? Data(contentsOf: url)) else { return }
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
        )
        do {
            try LockedDeviceFileAccess.writeDataAtomically(encoded, to: quarantineURL)
            AppLogger.shared.error(
                "history.corruptPreserved",
                "Preserved an invalid listening history file for recovery",
                metadata: ["file": quarantineURL.lastPathComponent],
                alwaysPersist: true
            )
        } catch {
            AppLogger.shared.error(
                "history.corruptPreserveFailed",
                "Could not preserve an invalid listening history file",
                metadata: ["error": String(describing: error)],
                alwaysPersist: true
            )
        }
    }

    private func installProtectedDataRetry() {
        #if canImport(UIKit)
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryProtectedDataLoad() }
        }
        #endif
    }

    /// Internal test seam; production invokes it from the protected-data
    /// notification installed after an unavailable launch-time read.
    func retryProtectedDataLoad() {
        guard persistenceState == .temporarilyUnavailable,
              protectedDataAvailable() else { return }
        let deferredEntries = entries
        let deferredRevision = storageRevision
        load()
        guard persistenceState.allowsPersistence, deferredRevision > 0 else { return }
        mergeDeferredEntries(deferredEntries)
        storageRevision = max(storageRevision, deferredRevision) &+ 1
        for entry in deferredEntries {
            recordPending(id: entry.id)
        }
        save()
    }

    private func mergeDeferredEntries(_ deferredEntries: [ListeningHistoryEntry]) {
        for deferred in deferredEntries {
            if let index = entries.firstIndex(where: { $0.id == deferred.id }) {
                var merged = deferred.lastListenedAt >= entries[index].lastListenedAt
                    ? deferred
                    : entries[index]
                merged.listenedSeconds = entries[index].listenedSeconds + deferred.listenedSeconds
                entries[index] = merged
            } else {
                entries.append(deferred)
            }
        }
        entries.sort { $0.lastListenedAt > $1.lastListenedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    private func repairLoadedEntriesIfNeeded() {
        var repairedCount = 0
        entries = entries.map { entry in
            var normalized = entry
            if normalized.repairAutoArchiveOverwriteIfClearlyCompleted() {
                repairedCount += 1
            }
            return normalized
        }.sorted { $0.lastListenedAt > $1.lastListenedAt }
        if repairedCount > 0 {
            storageRevision &+= 1
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
