import XCTest
import AutohopCore
@testable import AutohopTV

// AI CONTEXT — Regression coverage for tvOS Discover Phases 0–2. These tests
// prove the browse-only authority boundary and the repository's bounded eager
// loading without making live Apple network requests.

final class TVDiscoverFoundationTests: XCTestCase {
    func testMutationPolicyExposesNoLibraryOrQueueAuthority() {
        let policy = TVDiscoverMutationPolicy()
        XCTAssertFalse(policy.canChangeSubscriptions)
        XCTAssertFalse(policy.canChangePriority)
        XCTAssertFalse(policy.canChangeQueue)
        XCTAssertFalse(policy.canArchiveCatalogueEpisodes)
    }

    func testLandingLoadsOnlyFourEagerCategoryShelves() async throws {
        let provider = FakeChartsProvider(categoryCount: 7, notableCount: 4)
        let repository = TVDiscoverRepository(charts: provider)

        let landing = try await repository.landing(countryCode: "au")
        let requestedCategoryIDs = await provider.requestedCategoryIDs()

        XCTAssertEqual(landing.categoryShelves.count, 4)
        XCTAssertEqual(requestedCategoryIDs, [1, 2, 3, 4])
        XCTAssertEqual(landing.newAndNotable.count, 4)
    }

    func testNewAndNotableIsHiddenWhenEditorialMinimumIsNotMet() async throws {
        let provider = FakeChartsProvider(categoryCount: 1, notableCount: 2)
        let repository = TVDiscoverRepository(charts: provider)

        let landing = try await repository.landing(countryCode: "au")

        XCTAssertTrue(landing.newAndNotable.isEmpty)
    }
}

private actor FakeChartsProvider: PodcastChartsProviding {
    let categoryCount: Int
    let notableCount: Int
    private var requestedCategories: [Int] = []

    init(categoryCount: Int, notableCount: Int) {
        self.categoryCount = categoryCount
        self.notableCount = notableCount
    }

    func topShows(countryCode: String, limit: Int) async throws -> [PodcastChartShow] {
        [show(id: "top")]
    }

    func topEpisodes(countryCode: String, limit: Int) async throws -> [PodcastChartEpisode] {
        [PodcastChartEpisode(id: "episode", rank: 1, title: "Episode", showTitle: "Show", artworkURL: nil, releaseDate: nil, collectionID: "show")]
    }

    func newAndNotable(countryCode: String, limit: Int) async throws -> [PodcastChartShow] {
        (0..<notableCount).map { show(id: "notable-\($0)") }
    }

    func shows(countryCode: String, categoryID: Int, limit: Int) async throws -> [PodcastChartShow] {
        requestedCategories.append(categoryID)
        return [show(id: "category-\(categoryID)")]
    }

    func categories(countryCode: String) async -> [PodcastChartCategory] {
        (1...categoryCount).map { PodcastChartCategory(id: $0, name: "Category \($0)") }
    }

    func resolveShow(id: String, countryCode: String) async throws -> PodcastSearchResult? {
        nil
    }

    func requestedCategoryIDs() -> [Int] { requestedCategories }

    private func show(id: String) -> PodcastChartShow {
        PodcastChartShow(id: id, rank: 1, title: "Show", publisher: "Publisher", artworkURL: nil, genre: "Genre")
    }
}
