// AI CONTEXT — SmokeTests/main.swift (RSSParserSmoke executable, `swift run
// RSSParserSmoke`). CLI smoke test: parses the bundled sample feed via
// Tests/RSSParserSmokeTest.run and fatalErrors on any assertion failure.
import Foundation
import AutohopCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

let fixtureURL = Bundle.module.url(
    forResource: "ABCBreakfastSampleFeed",
    withExtension: "xml",
    subdirectory: "Fixtures"
)

guard let fixtureURL else {
    fatalError("Missing ABCBreakfastSampleFeed.xml fixture")
}

let data = try Data(contentsOf: fixtureURL)
let feed = try RSSParser().parse(data: data)

require(feed.title == "774 ABC Melbourne Breakfast", "Unexpected feed title")
require(feed.author == "774 ABC Radio Melbourne", "Unexpected feed author")

guard let episode = feed.latestEpisode else {
    fatalError("Missing latest episode")
}

require(episode.title == "Breakfast - Friday, 29th May 2026", "Unexpected episode title")
require(episode.audioURL?.absoluteString == "https://example.com/audio/abc-breakfast-2026-05-29.aac", "Unexpected audio URL")
require(episode.durationSeconds == 8_700, "Unexpected duration")
require(episode.fileSizeBytes == 210_763_776, "Unexpected file size")
require(episode.externalChaptersURL?.absoluteString == "https://example.com/chapters/abc-breakfast-2026-05-29.json", "Unexpected external chapters URL")
require(episode.chapters.count == 5, "Unexpected chapter count")
require(episode.chapters[1].title == "774 ABC Breakfast 5:35am-6:00am", "Unexpected chapter title")
require(episode.chapters[1].startSeconds == 50, "Unexpected chapter start time")

let threeAWFixtureURL = Bundle.module.url(
    forResource: "ThreeAWMelbourneNewsSampleFeed",
    withExtension: "xml",
    subdirectory: "Fixtures"
)

guard let threeAWFixtureURL else {
    fatalError("Missing ThreeAWMelbourneNewsSampleFeed.xml fixture")
}

let threeAWFeed = try RSSParser().parse(data: Data(contentsOf: threeAWFixtureURL))
let threeAWEpisode = threeAWFeed.latestEpisode
require(threeAWFeed.title == "3AW Melbourne News", "Unexpected 3AW feed title")
require(threeAWEpisode?.audioURL?.absoluteString == "https://pdst.fm/e/traffic.omny.fm/audio.mp3?utm_source=Podcast&in_playlist=e2540967", "Unexpected 3AW audio URL")
require(threeAWEpisode?.artworkURL?.absoluteString == "https://www.omnycontent.com/image.jpg?t=1673225975&size=Large", "Unexpected 3AW artwork URL")

print("RSSParserSmoke passed: \(feed.title) / \(episode.title) / \(episode.chapters.count) chapters")
