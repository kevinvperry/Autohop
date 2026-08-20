import Foundation
import Observation

// AI CONTEXT — Offline, tvOS-only App Review demonstration domain. This file
// deliberately does not import AutohopCore and cannot access SubscriptionStore,
// CloudKit, ListeningStatsStore, SurvivalKitStore, or production queue/history
// writers. All mutations live in this resettable in-memory session and are
// discarded when Demo is exited. Bundled first-party media is resolved by name.
// Continue Listening includes only partial progress below the completion band.

enum TVDemoMediaKind: String, Equatable {
    case audio
    case video
}

struct TVDemoShow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let colorHex: UInt
    let priority: Int
    let episodes: [TVDemoEpisode]
}

struct TVDemoEpisode: Identifiable, Equatable {
    let id: UUID
    let showID: UUID
    let showTitle: String
    let title: String
    let summary: String
    let publishedAt: Date
    let duration: TimeInterval
    let mediaKind: TVDemoMediaKind
    let resourceName: String
    let resourceExtension: String

    var mediaURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }
}

struct TVDemoHistoryItem: Identifiable, Equatable {
    enum Status: String { case completed = "Completed"; case archived = "Archived" }
    let episode: TVDemoEpisode
    let status: Status
    let listenedAt: Date
    var id: UUID { episode.id }
}

@MainActor
@Observable
final class TVDemoSession {
    private(set) var shows: [TVDemoShow] = []
    private(set) var upNext: [TVDemoEpisode] = []
    private(set) var history: [TVDemoHistoryItem] = []
    private(set) var progressByEpisodeID: [UUID: TimeInterval] = [:]
    private(set) var archivedEpisodeIDs: Set<UUID> = []
    private(set) var generation = 0

    init() { reset() }

    var continueEpisode: TVDemoEpisode? {
        shows.flatMap(\.episodes).first {
            let progress = progressByEpisodeID[$0.id] ?? 0
            return progress > 0 && progress < $0.duration * 0.95
        }
    }

    func recordProgress(_ seconds: TimeInterval, for episode: TVDemoEpisode) {
        progressByEpisodeID[episode.id] = min(max(0, seconds), episode.duration)
    }

    func playNext(_ episode: TVDemoEpisode) {
        upNext.removeAll { $0.id == episode.id }
        upNext.insert(episode, at: 0)
    }

    func archive(_ episode: TVDemoEpisode) {
        archivedEpisodeIDs.insert(episode.id)
        upNext.removeAll { $0.id == episode.id }
        history.removeAll { $0.id == episode.id }
        history.insert(TVDemoHistoryItem(episode: episode, status: .archived, listenedAt: Date()), at: 0)
    }

    func markCompleted(_ episode: TVDemoEpisode) {
        progressByEpisodeID[episode.id] = episode.duration
        upNext.removeAll { $0.id == episode.id }
        history.removeAll { $0.id == episode.id }
        history.insert(TVDemoHistoryItem(episode: episode, status: .completed, listenedAt: Date()), at: 0)
    }

    func reset() {
        let fixture = Self.fixture()
        shows = fixture.shows
        upNext = fixture.upNext
        history = fixture.history
        progressByEpisodeID = fixture.progress
        archivedEpisodeIDs = []
        generation += 1
    }

    private static func fixture() -> (
        shows: [TVDemoShow],
        upNext: [TVDemoEpisode],
        history: [TVDemoHistoryItem],
        progress: [UUID: TimeInterval]
    ) {
        let now = Date()
        let showIDs = [
            UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "D0000000-0000-0000-0000-000000000004")!
        ]
        func episode(
            _ value: Int,
            show: Int,
            title: String,
            summary: String,
            age: TimeInterval,
            duration: TimeInterval,
            kind: TVDemoMediaKind = .audio
        ) -> TVDemoEpisode {
            TVDemoEpisode(
                id: UUID(uuidString: String(format: "D1000000-0000-0000-0000-%012d", value))!,
                showID: showIDs[show],
                showTitle: ["The Daily Brief", "Ideas in Motion", "Field Notes", "Screen Stories"][show],
                title: title,
                summary: summary,
                publishedAt: now.addingTimeInterval(-age),
                duration: duration,
                mediaKind: kind,
                resourceName: kind == .video ? "autohop-demo-video" : "autohop-demo-audio",
                resourceExtension: kind == .video ? "mov" : "wav"
            )
        }
        let episodes = [
            episode(1, show: 0, title: "Morning Edition: A Better Queue", summary: "A short demonstration of Autohop's priority-led listening flow.", age: 3_600, duration: 30),
            episode(2, show: 0, title: "Yesterday in Review", summary: "Resume an episode and watch progress remain inside this local demo.", age: 86_400, duration: 30),
            episode(3, show: 1, title: "Designing for the Living Room", summary: "How focus, distance and simple decisions shape a television interface.", age: 7_200, duration: 30),
            episode(4, show: 1, title: "The Useful Automation", summary: "Why good automation remains understandable and reversible.", age: 172_800, duration: 30),
            episode(5, show: 2, title: "Regional Signals", summary: "A field report from regional Australia.", age: 14_400, duration: 30),
            episode(6, show: 2, title: "A Quiet Hour", summary: "An audio example for speed, seek and resume controls.", age: 259_200, duration: 30),
            episode(7, show: 3, title: "Autohop on the Big Screen", summary: "A bundled video demonstration that works without a network connection.", age: 1_800, duration: 12, kind: .video),
            episode(8, show: 3, title: "Behind the Interface", summary: "A completed sample episode shown in History.", age: 345_600, duration: 30)
        ]
        let shows = [
            TVDemoShow(id: showIDs[0], title: "The Daily Brief", author: "Autohop Demo Studio", colorHex: 0x6633CC, priority: 1, episodes: Array(episodes[0...1])),
            TVDemoShow(id: showIDs[1], title: "Ideas in Motion", author: "Autohop Demo Studio", colorHex: 0x177E89, priority: 2, episodes: Array(episodes[2...3])),
            TVDemoShow(id: showIDs[2], title: "Field Notes", author: "Autohop Demo Studio", colorHex: 0xB65C27, priority: 3, episodes: Array(episodes[4...5])),
            TVDemoShow(id: showIDs[3], title: "Screen Stories", author: "Autohop Demo Studio", colorHex: 0xB42372, priority: 4, episodes: Array(episodes[6...7]))
        ]
        return (
            shows,
            [episodes[0], episodes[6], episodes[2], episodes[4]],
            [TVDemoHistoryItem(episode: episodes[7], status: .completed, listenedAt: now.addingTimeInterval(-86_400))],
            [episodes[1].id: 11]
        )
    }
}
