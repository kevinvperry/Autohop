// AI CONTEXT — Tests/RSSParserSmokeTest.swift. Shared assertion body used by
// the RSSParserSmoke executable: parses a sample feed and precondition-checks
// titles, episode fields, and media kinds.
import Foundation
@testable import AutohopCore

enum RSSParserSmokeTest {
    static func run(sampleXML: Data) throws -> ParsedFeed {
        let feed = try RSSParser().parse(data: sampleXML)

        precondition(feed.title == "774 ABC Melbourne Breakfast")
        precondition(feed.latestEpisode?.title == "Breakfast - Friday, 29th May 2026")
        precondition(feed.latestEpisode?.audioURL != nil)
        precondition(feed.latestEpisode?.chapters.count == 5)

        return feed
    }
}
