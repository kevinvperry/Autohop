import Foundation

// AI CONTEXT — Persistence/PlaybackPositionStore.swift
// Playback-position persistence, extracted from AppState (deep-scan
// AH-2026-06-28-02, first carve of the AppState split). Owns the saved-position
// file (Application Support/Autohop/playback-position.json), the authoritative
// in-memory cache (P2: loaded once, write-through — loops over the queue never
// re-read/re-decode the file), the subscription-scoped episode position keys,
// and the resume-time normalization rules. AppState keeps thin same-named
// delegating wrappers (savePlaybackPosition / savedPlaybackTime /
// clearPlaybackPosition / restorePlaybackPosition orchestration) so playback
// call sites are unchanged; the 10 s tick-throttle also stays in AppState.
// ON-DISK COMPAT: SavedPlaybackPosition's properties MUST keep the exact names
// of AppState's old private SavedPosition (episodeID, subscriptionID,
// episodeKey, timeSeconds, updatedAt) — same synthesized JSON keys. The two
// legacy decode fallbacks ([UUID: Position] map and a single bare Position)
// are preserved. The file is marked available-after-first-unlock
// (LockedDeviceFileAccess) so CarPlay can show progress while the phone is
// locked. Positions are keyed by subscriptionID|guid (falling back to
// title+date, then title+URL for feeds without GUIDs) so a re-fetched episode
// with a regenerated UUID still resumes; lookups also try the bare episode-UUID
// key for pre-key-migration files. Headless-tested in
// Tests/PlaybackPositionStoreTests.swift.

/// One saved position. Property names are load-bearing (JSON keys) — see header.
public struct SavedPlaybackPosition: Codable, Equatable {
    public var episodeID: UUID
    public var subscriptionID: UUID
    public var episodeKey: String?
    public var timeSeconds: TimeInterval
    public var updatedAt: Date?

    public init(episodeID: UUID, subscriptionID: UUID, episodeKey: String?, timeSeconds: TimeInterval, updatedAt: Date?) {
        self.episodeID = episodeID
        self.subscriptionID = subscriptionID
        self.episodeKey = episodeKey
        self.timeSeconds = timeSeconds
        self.updatedAt = updatedAt
    }
}

@MainActor
public final class PlaybackPositionStore {
    public typealias Positions = [String: SavedPlaybackPosition]

    private let fileURL: URL?
    /// Authoritative in-memory copy (P2). nil = not yet loaded. The store is
    /// @MainActor and the sole owner of the file, so it never goes stale.
    private var cache: Positions?

    /// Production store at Application Support/Autohop/playback-position.json.
    public convenience init() {
        let url = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Autohop/playback-position.json")
        self.init(fileURL: url)
    }

    /// Custom URLs are for tests; production callers use `init()`.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    // MARK: - Keys and time rules (pure)

    /// Stable position identity for an episode: subscription-scoped GUID, falling
    /// back to title+publish-date, then title+audio-URL for GUID-less feeds. The
    /// local episode UUID is NOT used (it regenerates when a feed re-materialises).
    /// nonisolated: pure — also called from nonisolated core contexts
    /// (QueueModel.resolvedQueue).
    public nonisolated static func key(for episode: Episode) -> String {
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

    public nonisolated static func clampedTime(_ seconds: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = max(0, seconds.isFinite ? seconds : 0)
        guard let duration, duration.isFinite, duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }

    /// A resume time within 2 s of the end (or non-positive/non-finite) counts as
    /// "finished" and normalizes to 0 so the episode restarts rather than
    /// resuming into the outro.
    public nonisolated static func normalizedResumeTime(_ seconds: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard let duration, duration.isFinite, duration > 0 else { return seconds }
        let clamped = clampedTime(seconds, duration: duration)
        return clamped >= max(0, duration - 2) ? 0 : clamped
    }

    // MARK: - Reads

    /// Normalized resume time for an episode; 0 = start from the beginning.
    /// Tries the stable key first, then the legacy bare-UUID key, and requires
    /// the stored subscription to match (GUIDs can collide across feeds).
    public func savedTime(for episode: Episode) -> TimeInterval {
        let all = positions()
        guard let position = all[Self.key(for: episode)] ?? all[episode.id.uuidString],
              position.subscriptionID == episode.subscriptionID
        else { return 0 }
        return Self.normalizedResumeTime(position.timeSeconds, duration: episode.durationSeconds)
    }

    /// The most recently updated saved position among `episodes`, with its
    /// normalized resume time. Returns nil when nothing (usefully) resumes.
    /// The caller validates app-level constraints (still downloaded, file
    /// present) before acting on it.
    public func bestRestoreCandidate(in episodes: [Episode]) -> (episode: Episode, position: SavedPlaybackPosition)? {
        let all = positions()
        return episodes
            .compactMap { episode -> (Episode, SavedPlaybackPosition)? in
                let saved = all[Self.key(for: episode)] ?? all[episode.id.uuidString]
                guard let saved else { return nil }
                return (episode, saved)
            }
            .max { lhs, rhs in
                switch (lhs.1.updatedAt, rhs.1.updatedAt) {
                case let (left?, right?):
                    return left < right
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case (nil, nil):
                    return lhs.1.timeSeconds < rhs.1.timeSeconds
                }
            }
            .map { (episode: $0.0, position: $0.1) }
    }

    // MARK: - Writes

    /// Saves the position for an episode. A time that normalizes to 0 (finished
    /// or invalid) CLEARS the stored position instead — matching the historical
    /// AppState behavior. Also drops any legacy bare-UUID entry for the episode.
    public func save(episode: Episode, timeSeconds: TimeInterval, updatedAt: Date = Date()) {
        guard Self.normalizedResumeTime(timeSeconds, duration: episode.durationSeconds) > 0 else {
            clear(for: episode)
            return
        }
        var all = positions()
        let episodeKey = Self.key(for: episode)
        all[episodeKey] = SavedPlaybackPosition(
            episodeID: episode.id,
            subscriptionID: episode.subscriptionID,
            episodeKey: episodeKey,
            timeSeconds: timeSeconds,
            updatedAt: updatedAt
        )
        all.removeValue(forKey: episode.id.uuidString)
        write(all)
    }

    public func clear(for episode: Episode) {
        var all = positions()
        all.removeValue(forKey: Self.key(for: episode))
        all.removeValue(forKey: episode.id.uuidString)
        write(all)
    }

    public func clear(episodeID: UUID) {
        var all = positions()
        all.removeValue(forKey: episodeID.uuidString)
        write(all)
    }

    // MARK: - Cache + disk

    /// Returns the positions, loading from disk once and caching the result.
    private func positions() -> Positions {
        if let cache { return cache }
        let loaded = loadFromDisk()
        cache = loaded
        return loaded
    }

    private func loadFromDisk() -> Positions {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return [:] }

        LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: fileURL)
        if let positions = try? JSONDecoder().decode(Positions.self, from: data) {
            return positions
        }
        if let legacyPositions = try? JSONDecoder().decode([UUID: SavedPlaybackPosition].self, from: data) {
            return Dictionary(uniqueKeysWithValues: legacyPositions.map { ($0.key.uuidString, $0.value) })
        }
        if let legacyPosition = try? JSONDecoder().decode(SavedPlaybackPosition.self, from: data) {
            return [legacyPosition.episodeID.uuidString: legacyPosition]
        }
        return [:]
    }

    /// Updates the cache and writes through to disk atomically; removes the file
    /// when empty. Single source of truth for position writes.
    private func write(_ positions: Positions) {
        cache = positions
        guard let fileURL else { return }
        if positions.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(positions) else { return }
        try? LockedDeviceFileAccess.writeDataAtomically(data, to: fileURL)
    }
}
