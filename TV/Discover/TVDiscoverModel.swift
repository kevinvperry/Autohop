import Foundation
import Observation
import AutohopCore

// AI CONTEXT — TV/Discover/TVDiscoverModel.swift
// Main-actor page state for the TV Discover tab. It owns no SubscriptionStore,
// QueueModel or CloudSyncEngine reference. Storefront is local to Apple TV and
// a generation guard prevents an older country request replacing newer state.

@MainActor
@Observable
final class TVDiscoverModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var landing = TVDiscoverLanding.empty
    var selectedStorefront: PodcastChartStorefront {
        didSet {
            UserDefaults.standard.set(selectedStorefront.code, forKey: Self.storefrontKey)
        }
    }

    let storefronts = ApplePodcastChartsProvider.storefronts
    let mutationPolicy = TVDiscoverMutationPolicy()

    private let repository: TVDiscoverRepository
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private static let storefrontKey = "com.autohop.tv.discover.storefront"

    init(repository: TVDiscoverRepository = TVDiscoverRepository()) {
        self.repository = repository
        let saved = UserDefaults.standard.string(forKey: Self.storefrontKey)
        selectedStorefront = ApplePodcastChartsProvider.storefronts.first(where: { $0.code == saved })
            ?? ApplePodcastChartsProvider.deviceStorefront
    }

    func loadIfNeeded() {
        guard phase == .idle else { return }
        reload()
    }

    func selectStorefront(_ storefront: PodcastChartStorefront) {
        guard storefront != selectedStorefront else { return }
        selectedStorefront = storefront
        reload()
    }

    func reload() {
        generation += 1
        let requestGeneration = generation
        let country = selectedStorefront.code
        loadTask?.cancel()
        phase = .loading
        let started = ContinuousClock.now

        AppLogger.shared.info("tv.discover.phaseChanged", "Discover loading", metadata: [
            "phase": "loading",
            "storefront": country,
            "generation": "\(requestGeneration)"
        ], alwaysPersist: true)

        loadTask = Task {
            do {
                let result = try await repository.landing(countryCode: country)
                guard !Task.isCancelled, requestGeneration == generation else { return }
                landing = result
                phase = .loaded
                let elapsed = started.duration(to: .now)
                AppLogger.shared.info("tv.discover.phaseChanged", "Discover loaded", metadata: [
                    "phase": "loaded",
                    "storefront": country,
                    "generation": "\(requestGeneration)",
                    "episodes": "\(result.topEpisodes.count)",
                    "shows": "\(result.topShows.count)",
                    "shelves": "\(result.categoryShelves.count)",
                    "durationMs": "\(elapsed.components.seconds * 1_000 + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000))"
                ], alwaysPersist: true)
            } catch is CancellationError {
                AppLogger.shared.info("tv.discover.requestCancelled", "Discover request cancelled", metadata: [
                    "storefront": country,
                    "generation": "\(requestGeneration)"
                ], alwaysPersist: true)
            } catch {
                guard requestGeneration == generation else { return }
                phase = .failed("Discover could not be updated. Check your connection and try again.")
                AppLogger.shared.warning("tv.discover.phaseChanged", "Discover failed", metadata: [
                    "phase": "failed",
                    "storefront": country,
                    "generation": "\(requestGeneration)",
                    "error": String(describing: type(of: error))
                ], alwaysPersist: true)
            }
        }
    }
}

