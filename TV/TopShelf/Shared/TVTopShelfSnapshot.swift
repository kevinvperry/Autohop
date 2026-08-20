import Foundation

// AI CONTEXT — Foundation-only dynamic Top Shelf presentation schema compiled
// by both the tvOS app and its TVServices extension. This is a disposable,
// privacy-minimal materialized view: never add CloudKit records, feed/stream
// URLs, descriptions, statistics, credentials, or production model objects.

enum TVTopShelfSectionKind: String, Codable, Equatable, Sendable {
    case currentlyPlaying
    case continueListening
    case upNext
}

struct TVTopShelfSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 128 * 1024
    static let maximumSections = 2
    static let maximumItems = 10
    static let freshnessInterval: TimeInterval = 30 * 24 * 60 * 60

    let schemaVersion: Int
    let generation: Int64
    let publishedAt: Date
    let accountScope: String
    let sections: [Section]

    init(
        schemaVersion: Int = currentSchemaVersion,
        generation: Int64,
        publishedAt: Date,
        accountScope: String,
        sections: [Section]
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.publishedAt = publishedAt
        self.accountScope = accountScope
        self.sections = sections
    }

    struct Section: Codable, Equatable, Sendable {
        let kind: TVTopShelfSectionKind
        let title: String
        let items: [Item]
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let subscriptionID: UUID
        let episodeKey: String
        let episodeTitle: String
        let podcastTitle: String
        let artworkFilename1x: String
        let artworkFilename2x: String?
        let playbackProgress: Double?
        let expiresAt: Date?
    }

    func validated(now: Date = Date()) throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TVTopShelfSnapshotError.unsupportedSchemaVersion(schemaVersion)
        }
        guard generation >= 0,
              !accountScope.isEmpty,
              accountScope.count <= 128,
              publishedAt <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(publishedAt) <= Self.freshnessInterval,
              (1...Self.maximumSections).contains(sections.count),
              sections.reduce(0, { $0 + $1.items.count }) <= Self.maximumItems
        else { throw TVTopShelfSnapshotError.invalidSnapshot }

        var sectionKinds = Set<TVTopShelfSectionKind>()
        var itemIDs = Set<String>()
        for section in sections {
            guard sectionKinds.insert(section.kind).inserted,
                  !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.title.count <= 80,
                  !section.items.isEmpty
            else { throw TVTopShelfSnapshotError.invalidSnapshot }
            for item in section.items {
                guard itemIDs.insert(item.id).inserted,
                      !item.id.isEmpty, item.id.count <= 128,
                      !item.episodeKey.isEmpty, item.episodeKey.count <= 4_096,
                      !item.episodeTitle.isEmpty, item.episodeTitle.count <= 500,
                      !item.podcastTitle.isEmpty, item.podcastTitle.count <= 300,
                      Self.isBasename(item.artworkFilename1x),
                      item.artworkFilename2x.map(Self.isBasename) ?? true,
                      item.playbackProgress.map({ $0.isFinite && (0...1).contains($0) }) ?? true
                else { throw TVTopShelfSnapshotError.invalidSnapshot }
            }
        }
        return self
    }

    private static func isBasename(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 180 && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("..") && !value.contains("/") && !value.contains("\\")
    }
}

enum TVTopShelfSnapshotError: Error, Equatable {
    case appGroupUnavailable
    case unsupportedSchemaVersion(Int)
    case encodedSnapshotTooLarge
    case invalidSnapshot
    case invalidArtworkFilename
}
