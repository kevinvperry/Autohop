import Foundation
import AutohopCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("autohop-download-source-\(UUID().uuidString).aac")
try Data("audio-fixture".utf8).write(to: sourceURL)

var episode = Episode(
    subscriptionID: UUID(),
    guid: "episode-1",
    title: "Fixture Episode",
    audioURL: URL(string: "https://example.com/audio/fixture.aac")!
)

let downloadDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("autohop-download-manager-smoke-\(UUID().uuidString)", isDirectory: true)
let manager = DownloadManager(downloadDirectory: downloadDirectory)
let storedURL = try manager.storeDownloadedFile(from: sourceURL, episode: episode)

require(FileManager.default.fileExists(atPath: storedURL.path), "Expected stored file to exist")
require(storedURL.pathExtension == "aac", "Expected stored file extension to match audio URL")
require(FileManager.default.fileExists(atPath: sourceURL.path) == false, "Expected source file to move")

episode.localFileURL = storedURL
try await manager.deleteLocalFile(for: episode)

require(FileManager.default.fileExists(atPath: storedURL.path) == false, "Expected stored file to be deleted")
try? FileManager.default.removeItem(at: downloadDirectory)

print("DownloadManagerSmoke passed: stored and deleted managed episode file")
