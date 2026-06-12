// AI CONTEXT — OPMLSmokeTests/main.swift (OPMLSmoke executable). CLI smoke
// test for OPMLService import/export round-tripping; fatalErrors on failure.
import Foundation
import AutohopCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

guard let fixtureURL = Bundle.module.url(
    forResource: "SampleSubscriptions",
    withExtension: "opml",
    subdirectory: "Fixtures"
) else {
    fatalError("Missing SampleSubscriptions.opml")
}

let existing = Set([URL(string: "https://example.com/abc.xml")!])
let service = OPMLService()
let imported = try await service.importSubscriptions(from: fixtureURL, existingFeedURLs: existing)

require(imported.map(\.absoluteString) == [
    "https://example.com/acquired.xml",
    "https://example.com/zed.xml"
], "Unexpected imported feed URLs: \(imported)")

let subscription = Subscription(
    feedURL: URL(string: "https://example.com/acquired.xml")!,
    title: "Acquired",
    priorityRank: 1
)
let exported = try service.exportSubscriptions([subscription])
let exportedText = String(decoding: exported, as: UTF8.self)

require(exportedText.contains("<opml version=\"2.0\">"), "Missing OPML root")
require(exportedText.contains("xmlUrl=\"https://example.com/acquired.xml\""), "Missing exported feed URL")

print("OPMLSmoke passed: imported \(imported.count) new feeds and exported OPML")
