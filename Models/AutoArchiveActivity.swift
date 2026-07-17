import Foundation

// AI CONTEXT — Durable audit trail for automatic archive decisions. This is
// deliberately separate from ListeningHistoryEntry: an inactive episode may have
// zero listening time and therefore should not be invented as listening history,
// while users still need evidence that the automation ran and why. Records are
// device-local operational history, capped at 500 newest entries, and are written
// only after archiveEpisode completes for an automatic rule.

public enum AutoArchiveActivityRule: String, Codable, CaseIterable, Sendable {
    case afterPlaying
    case inactiveEpisodes
    case episodeLimit

    public var title: String {
        switch self {
        case .afterPlaying: return "After Playing"
        case .inactiveEpisodes: return "Inactive Episodes"
        case .episodeLimit: return "Episode Limit"
        }
    }
}

public struct AutoArchiveActivity: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var episodeID: UUID
    public var subscriptionID: UUID
    public var episodeTitle: String
    public var podcastTitle: String
    public var archivedAt: Date
    public var rule: AutoArchiveActivityRule
    public var configuredThreshold: String
    public var measuredAgeSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        episodeID: UUID,
        subscriptionID: UUID,
        episodeTitle: String,
        podcastTitle: String,
        archivedAt: Date,
        rule: AutoArchiveActivityRule,
        configuredThreshold: String,
        measuredAgeSeconds: TimeInterval
    ) {
        self.id = id
        self.episodeID = episodeID
        self.subscriptionID = subscriptionID
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.archivedAt = archivedAt
        self.rule = rule
        self.configuredThreshold = configuredThreshold
        self.measuredAgeSeconds = max(0, measuredAgeSeconds)
    }
}

@MainActor
public final class AutoArchiveActivityStore: ObservableObject {
    @Published public private(set) var entries: [AutoArchiveActivity] = []

    private let maxEntries = 500
    private let fileURL: URL?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.fileURL = support.appendingPathComponent("Autohop/auto-archive-activity.json")
        } else {
            self.fileURL = nil
        }
        load()
    }

    public func record(_ entry: AutoArchiveActivity) {
        entries.removeAll { $0.episodeID == entry.episodeID && $0.rule == entry.rule }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AutoArchiveActivity].self, from: data)
        else { return }
        entries = decoded.sorted { $0.archivedAt > $1.archivedAt }.prefix(maxEntries).map { $0 }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.warning("autoArchive.activitySaveFailed", "Could not save Auto Archive activity", metadata: [
                "error": String(describing: error)
            ])
        }
    }
}
