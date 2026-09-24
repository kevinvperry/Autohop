import Foundation

// AI CONTEXT — Feeds/FeedPreviewViewModel.swift
// View model for AddFeedView (manual RSS URL entry): fetches and parses the
// typed URL into a ParsedFeed preview state machine (idle/loading/loaded/
// failed). Subscribe action is handled by the view via AppState/
// SubscriptionStore, not here. Editing clears the preview so the UI cannot save
// a previously parsed feed using a newly entered URL. Trim pasted whitespace.
@MainActor
final class FeedPreviewViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(ParsedFeed)
        case failed(String)
    }

    @Published var feedURLText = ""
    @Published private(set) var state: State = .idle
    @Published var saveMessage: String?

    private let parser: RSSParser
    private let session: URLSession

    init(parser: RSSParser = RSSParser(), session: URLSession = .shared) {
        self.parser = parser
        self.session = session
    }

    func clearPreview() {
        state = .idle
        saveMessage = nil
    }

    func previewFeed() async {
        saveMessage = nil

        guard let url = URL(string: feedURLText.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased()) else {
            state = .failed("Enter a valid RSS feed URL.")
            return
        }

        state = .loading

        do {
            let (data, _) = try await session.data(from: url)
            let feed = try parser.parse(data: data)
            state = .loaded(feed)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func previewFixture(data: Data) {
        saveMessage = nil

        do {
            let feed = try parser.parse(data: data)
            state = .loaded(feed)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var feedURL: URL? {
        URL(string: feedURLText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
