import SwiftUI
import Observation
import AutohopCore

// AI CONTEXT — TV/Views/TVSearchView.swift
// Phase 5 product decision: browse/play only. Search uses the public iTunes
// Search API after a 400 ms debounce; selecting a result loads a bounded feed
// preview for playback. It never creates a local subscription and cannot push
// subscription or priority changes to the authoritative iPhone library.
struct TVSearchView: View {
    let model: TVAppModel
    @State private var searchModel = TVSearchModel()

    var body: some View {
        // No fixed heading (display-bug fix 2026-07-04: fixed headings had
        // scrolled content sliding behind them on tvOS) — the search-role tab
        // plus the system search field is self-describing.
        content
            .searchable(text: $searchModel.query, prompt: "Podcast name")
            .onChange(of: searchModel.query) { _, newValue in
                searchModel.queryChanged(newValue)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch searchModel.phase {
        case .idle:
            ContentUnavailableView(
                "Find a podcast",
                systemImage: "magnifyingglass",
                description: Text("Search by name to add a podcast to this Apple TV. Manage your synced subscriptions on iPhone.")
            )
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView.search
        case .failed(let message):
            ContentUnavailableView(
                "Search Failed",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
        case .results(let results):
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 40)], spacing: 40) {
                    ForEach(results) { result in
                        TVSearchResultCard(
                            result: result,
                            state: .notSubscribed,
                            onSubscribe: {}
                        )
                    }
                }
                .padding(.horizontal, 64)
                .padding(.bottom, 48)
            }
        }
    }

}

/// TVCard-SearchResult pattern (DESIGN.md): square artwork + title/author,
/// with a Subscribe button whose label reflects subscribeState.
struct TVSearchResultCard: View {
    let result: PodcastSearchResult
    let state: TVSearchModel.SubscribeState
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVArtworkImage(url: result.artworkURL)
                .aspectRatio(1, contentMode: .fit)
            Text(result.title)
                .font(.headline)
                .lineLimit(2)
            Text(result.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Label("Manage on iPhone", systemImage: "iphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .notSubscribed:
            Text("Add to This Apple TV")
        case .subscribing:
            Label("Subscribing…", systemImage: "hourglass")
        case .subscribed:
            Label("Subscribed", systemImage: "checkmark")
        case .failed:
            Label("Retry", systemImage: "arrow.clockwise")
        }
    }
}

/// Search state + per-result subscribe status, owned by the view (Phase 4).
/// Kept small and view-local rather than folded into TVAppModel — search is
/// transient UI state, not library truth.
@MainActor
@Observable
final class TVSearchModel {
    enum Phase {
        case idle, loading, results([PodcastSearchResult]), empty, failed(String)
    }

    enum SubscribeState: Equatable {
        case notSubscribed, subscribing, subscribed, failed
    }

    var query = ""
    private(set) var phase: Phase = .idle
    private var subscribeStates: [Int: SubscribeState] = [:]

    private let service = PodcastSearchService()
    private var searchTask: Task<Void, Never>?

    func subscribeState(for result: PodcastSearchResult) -> SubscribeState {
        subscribeStates[result.id] ?? .notSubscribed
    }

    func setSubscribing(_ result: PodcastSearchResult) {
        subscribeStates[result.id] = .subscribing
    }

    func setSubscribed(_ result: PodcastSearchResult) {
        subscribeStates[result.id] = .subscribed
    }

    func setSubscribeFailed(_ result: PodcastSearchResult, message: String) {
        subscribeStates[result.id] = .failed
    }

    func queryChanged(_ newValue: String) {
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ term: String) async {
        phase = .loading
        do {
            let results = try await service.search(query: term)
            guard !Task.isCancelled else { return }
            phase = results.isEmpty ? .empty : .results(results)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            phase = .failed("Search failed. Check your connection and try again.")
        }
    }
}
