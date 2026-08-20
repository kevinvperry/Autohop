import Foundation
import TVServices

// AI CONTEXT — Deterministic mapping from a validated shared snapshot to
// modern TVTopShelfSectionedContent. Poster geometry fits four branded cards
// across the shelf; card images themselves carry the purple backdrop because
// TVServices offers no static-background layer for dynamic sectioned content.

enum TopShelfContentFactory {
    static func makeContent(
        snapshot: TVTopShelfSnapshot,
        expectedAccountScope: String,
        artworkURL: (String) throws -> URL
    ) -> TVTopShelfSectionedContent? {
        guard snapshot.accountScope == expectedAccountScope else { return nil }
        let collections = snapshot.sections.compactMap { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            let items = section.items.compactMap { source -> TVTopShelfSectionedItem? in
                guard let playURL = TVTopShelfDeepLink.url(
                    action: "play",
                    subscriptionID: source.subscriptionID,
                    episodeKey: source.episodeKey
                ), let image1x = try? artworkURL(source.artworkFilename1x)
                else { return nil }
                let item = TVTopShelfSectionedItem(identifier: source.id)
                item.title = source.episodeTitle + " — " + source.podcastTitle
                item.imageShape = .poster
                item.setImageURL(image1x, for: .screenScale1x)
                if let filename2x = source.artworkFilename2x,
                   let image2x = try? artworkURL(filename2x) {
                    item.setImageURL(image2x, for: .screenScale2x)
                } else {
                    item.setImageURL(image1x, for: .screenScale2x)
                }
                if let progress = source.playbackProgress {
                    item.playbackProgress = min(max(progress, 0), 1)
                }
                item.expirationDate = source.expiresAt
                // Select invokes displayAction while the remote Play/Pause
                // button invokes playAction. Both must honour the shelf's
                // lean-back promise and immediately start/resume playback.
                item.displayAction = TVTopShelfAction(url: playURL)
                item.playAction = TVTopShelfAction(url: playURL)
                return item
            }
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }
        return collections.isEmpty ? nil : TVTopShelfSectionedContent(sections: collections)
    }
}

enum TVTopShelfDeepLink {
    static func url(action: String, subscriptionID: UUID, episodeKey: String) -> URL? {
        guard action == "episode" || action == "play" else { return nil }
        var components = URLComponents()
        components.scheme = "autohop"
        components.host = "tv"
        components.path = "/" + action
        components.queryItems = [
            URLQueryItem(name: "subscriptionID", value: subscriptionID.uuidString),
            URLQueryItem(name: "episodeKey", value: episodeKey)
        ]
        return components.url
    }
}
