import Foundation

// AI CONTEXT — Per-request URLSession metrics collector. FeedService's process
// memory samples bracket an `await` and therefore cannot attribute every byte to
// the request. These transaction metrics provide the missing wire/protocol/
// redirect evidence without changing the production fetch path. The lock is
// required because URLSession chooses the delegate callback queue.
private final class FeedTaskMetricsCollector: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: URLSessionTaskMetrics?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collected = metrics
        lock.unlock()
    }

    func snapshot() -> URLSessionTaskMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
import Darwin.Mach

// AI CONTEXT — Feeds/FeedService.swift
// Network layer for fetching + parsing one RSS feed. Two entry points:
//  - refresh(): unconditional GET, full parse (manual pull-to-refresh). Sends no
//    validators, so a 304 can't legitimately occur; if a misbehaving server
//    returns one anyway it surfaces as FeedServiceError.unexpectedNotModified
//    (B7) rather than the old misleading .missingAudioEnclosure.
//  - refreshIfModified(): HTTP conditional GET using stored ETag/Last-Modified
//    (FeedValidators, persisted in Subscription.refreshStats) — the Release
//    Radar fast path; a 304 returns .notModified with zero parse cost.
// Converts ParsedFeed → FeedRefreshResult with Episode values; AppState then
// merges via SubscriptionStore. 25 s request timeout. Episode limit param
// caps parse work (50 for normal refresh, nil for full history load). Each
// synchronous parse/conversion runs inside an autorelease pool so Foundation/XML
// temporaries are reclaimed between feeds during large manual refresh cycles.
protocol FeedServicing {
    func refresh(feedURL: URL, subscriptionID: UUID, episodeLimit: Int?) async throws -> FeedRefreshResult
    func refreshIfModified(
        feedURL: URL,
        subscriptionID: UUID,
        episodeLimit: Int?,
        validators: FeedValidators?
    ) async throws -> FeedRefreshOutcome
}

/// HTTP cache validators carried between fetches of the same feed.
struct FeedValidators: Sendable, Equatable {
    var etag: String?
    var lastModified: String?
}

enum FeedRefreshOutcome {
    /// Server returned 304 — feed unchanged, nothing was downloaded or parsed.
    case notModified
    case updated(FeedRefreshResult, FeedValidators)
}

struct FeedRefreshResult {
    var subscriptionTitle: String
    var description: String?
    var author: String?
    var artworkURL: URL?
    var categories: [String]
    var isExplicit: Bool?
    var latestEpisode: Episode
    var episodes: [Episode]
}

final class FeedService: FeedServicing {
    private struct ParseMemorySample {
        var footprintMB: Int
        var residentMB: Int
    }

    private static func memorySample() -> ParseMemorySample {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4
        let basicResult = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(basicCount)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &basicCount
                )
            }
        }
        let resident = basicResult == KERN_SUCCESS
            ? Int(basic.resident_size / 1_048_576) : 0
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
        ) / 4
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(vmCount)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &vmCount
                )
            }
        }
        return ParseMemorySample(
            footprintMB: vmResult == KERN_SUCCESS
                ? Int(vm.phys_footprint / 1_048_576) : resident,
            residentMB: resident
        )
    }

    private static func logMemoryStage(
        _ stage: String,
        before: ParseMemorySample,
        after: ParseMemorySample,
        feedURL: URL,
        sourceBytes: Int
    ) {
        let footprintDelta = after.footprintMB - before.footprintMB
        let residentDelta = after.residentMB - before.residentMB
        guard sourceBytes >= 1_024 * 1_024
                || abs(footprintDelta) >= 25
                || after.footprintMB >= 300 else { return }
        AppLogger.shared.info(
            "feed.parseMemoryStage",
            "Measured feed fetch/parse memory substage",
            metadata: [
                "stage": stage,
                "host": feedURL.host ?? "unknown",
                "sourceBytes": "\(sourceBytes)",
                "footprintBeforeMB": "\(before.footprintMB)",
                "footprintAfterMB": "\(after.footprintMB)",
                "footprintDeltaMB": "\(footprintDelta)",
                "residentBeforeMB": "\(before.residentMB)",
                "residentAfterMB": "\(after.residentMB)",
                "residentDeltaMB": "\(residentDelta)"
            ],
            alwaysPersist: abs(footprintDelta) >= 100
        )
    }

    private static func logNetworkMetrics(
        _ metrics: URLSessionTaskMetrics?,
        response: URLResponse,
        dataBytes: Int,
        feedURL: URL,
        memoryBefore: ParseMemorySample,
        memoryAfter: ParseMemorySample
    ) {
        let transactions = metrics?.transactionMetrics ?? []
        let wireResponseBytes = transactions.reduce(Int64(0)) {
            $0 + $1.countOfResponseBodyBytesReceived
        }
        let protocols = Array(Set(transactions.compactMap {
            $0.networkProtocolName
        })).sorted().joined(separator: ",")
        let fetchTypes = Array(Set(transactions.map {
            String($0.resourceFetchType.rawValue)
        })).sorted().joined(separator: ",")
        let footprintDelta = memoryAfter.footprintMB - memoryBefore.footprintMB
        let residentDelta = memoryAfter.residentMB - memoryBefore.residentMB
        guard dataBytes >= 1_024 * 1_024
                || abs(footprintDelta) >= 25
                || abs(residentDelta) >= 25 else { return }
        let http = response as? HTTPURLResponse
        AppLogger.shared.info(
            "feed.networkResponseMetrics",
            "Measured feed response materialisation and URL transaction",
            metadata: [
                "host": feedURL.host ?? "unknown",
                "dataBytes": "\(dataBytes)",
                "wireResponseBytes": "\(wireResponseBytes)",
                "expectedContentLength": "\(response.expectedContentLength)",
                "contentEncoding": http?.value(
                    forHTTPHeaderField: "Content-Encoding"
                ) ?? "none",
                "contentType": response.mimeType ?? "unknown",
                "redirectCount": "\(metrics?.redirectCount ?? 0)",
                "transactionCount": "\(transactions.count)",
                "networkProtocols": protocols.isEmpty ? "unknown" : protocols,
                "resourceFetchTypes": fetchTypes.isEmpty ? "unknown" : fetchTypes,
                "taskDurationMs": String(
                    format: "%.1f",
                    (metrics?.taskInterval.duration ?? 0) * 1_000
                ),
                "footprintDeltaMB": "\(footprintDelta)",
                "residentDeltaMB": "\(residentDelta)"
            ],
            alwaysPersist: abs(footprintDelta) >= 100
                || abs(residentDelta) >= 100
        )
    }
    private let chapterService: ChapterServicing
    private let parser: RSSParser
    private let session: URLSession
    private let requestTimeoutSeconds: TimeInterval
    private let maxFeedResponseBytes: Int

    init(
        chapterService: ChapterServicing,
        parser: RSSParser = RSSParser(),
        session: URLSession? = nil,
        requestTimeoutSeconds: TimeInterval = 25,
        maxFeedResponseBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.chapterService = chapterService
        self.parser = parser
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxFeedResponseBytes = maxFeedResponseBytes
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = requestTimeoutSeconds
            configuration.timeoutIntervalForResource = requestTimeoutSeconds + 5
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func refresh(feedURL: URL, subscriptionID: UUID, episodeLimit: Int? = 50) async throws -> FeedRefreshResult {
        switch try await refreshIfModified(
            feedURL: feedURL,
            subscriptionID: subscriptionID,
            episodeLimit: episodeLimit,
            validators: nil
        ) {
        case .notModified:
            // Can't happen without validators, but a misbehaving server could
            // send 304 anyway — surface it distinctly rather than as a misleading
            // missing-enclosure error.
            throw FeedServiceError.unexpectedNotModified
        case .updated(let result, _):
            return result
        }
    }

    func refreshIfModified(
        feedURL: URL,
        subscriptionID: UUID,
        episodeLimit: Int? = 50,
        validators: FeedValidators?
    ) async throws -> FeedRefreshOutcome {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 25
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let beforeNetwork = Self.memorySample()
        let requestStartedAt = Date()
        let metricsCollector = FeedTaskMetricsCollector()
        try Task.checkCancellation()
        let (data, response) = try await fetchResponse(
            for: request,
            metricsCollector: metricsCollector
        )
        try Task.checkCancellation()
        let requestWallClockSeconds = Date().timeIntervalSince(requestStartedAt)
        if requestWallClockSeconds > 35 {
            AppLogger.shared.warning(
                "feed.requestDeadlineExceeded",
                "Discarded a feed response delivered after its absolute ownership window",
                metadata: [
                    "host": feedURL.host ?? "unknown",
                    "elapsedSeconds":
                        String(format: "%.1f", requestWallClockSeconds),
                    "deadlineSeconds": "35"
                ],
                alwaysPersist: true
            )
            throw FeedServiceError.timedOut
        }
        let afterNetwork = Self.memorySample()
        Self.logMemoryStage(
            "networkData",
            before: beforeNetwork,
            after: afterNetwork,
            feedURL: feedURL,
            sourceBytes: data.count
        )
        Self.logNetworkMetrics(
            metricsCollector.snapshot(),
            response: response,
            dataBytes: data.count,
            feedURL: feedURL,
            memoryBefore: beforeNetwork,
            memoryAfter: afterNetwork
        )

        var newValidators = FeedValidators()
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304 {
                return .notModified
            }
            // Reject error responses (404/500/captive-portal HTML, etc.) instead of parsing the
            // body as a feed. 304 is handled above; everything else must be a success status.
            try HTTPResponseValidation.validate(http)
            newValidators.etag = http.value(forHTTPHeaderField: "ETag")
            newValidators.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        }
        if response.expectedContentLength > Int64(maxFeedResponseBytes)
            || data.count > maxFeedResponseBytes {
            AppLogger.shared.warning(
                "feed.responseTooLarge",
                "Feed response exceeded the safe in-memory parsing limit",
                metadata: [
                    "host": feedURL.host ?? "unknown",
                    "responseBytes": "\(data.count)",
                    "contentLength": "\(response.expectedContentLength)",
                    "limitBytes": "\(maxFeedResponseBytes)"
                ],
                alwaysPersist: true
            )
            throw FeedServiceError.responseTooLarge
        }
        let needsAmpersandRepair = RSSParser.containsBareAmpersand(in: data)
        if data.count >= 5 * 1_024 * 1_024 || needsAmpersandRepair {
            AppLogger.shared.info(
                "feed.responseDiagnostics",
                "Recorded large or repair-required feed response",
                metadata: [
                    "host": feedURL.host ?? "unknown",
                    "responseBytes": "\(data.count)",
                    "contentLength": "\(response.expectedContentLength)",
                    "episodeLimit": episodeLimit.map(String.init) ?? "all",
                    "conditionalRequest": "\(validators != nil)",
                    "bareAmpersandRepair": "\(needsAmpersandRepair)"
                ],
                alwaysPersist: true
            )
        }

        let result = try parseResult(
            data: data,
            subscriptionID: subscriptionID,
            episodeLimit: episodeLimit,
            feedURL: feedURL
        )
        return .updated(result, newValidators)
    }

    /// TWiT feeds repeatedly retained hundreds of megabytes across the
    /// `URLSession.data(for:)` boundary despite 3–4 MB response bodies. The
    /// mechanism is inside the networking/materialisation boundary and is not
    /// explained by MIME type, gzip, redirects, or XML parsing. Downloading to
    /// a temporary file and mapping that file provides a production A/B path
    /// that avoids returning an in-memory response buffer. Other hosts retain
    /// the established data-task path until diagnostics prove a wider benefit.
    /// Both URLSession async APIs inherit parent cancellation directly; do not
    /// wrap them in a throwing task group, because structured-group teardown can
    /// wait for an uncooperative child after a BGTask has already cancelled.
    private func fetchResponse(
        for request: URLRequest,
        metricsCollector: FeedTaskMetricsCollector
    ) async throws -> (Data, URLResponse) {
        if request.url?.host?.lowercased() == "twit.memberfulcontent.com" {
            let (temporaryURL, response) = try await session.download(
                for: request,
                delegate: metricsCollector
            )
            try Task.checkCancellation()
            let data = try Data(
                contentsOf: temporaryURL,
                options: [.mappedIfSafe, .uncached]
            )
            AppLogger.shared.info(
                "feed.fileBackedResponse",
                "Mapped host-protected feed response from URLSession download file",
                metadata: [
                    "host": request.url?.host ?? "unknown",
                    "dataBytes": "\(data.count)",
                    "storage": "downloadTask.mappedIfSafe"
                ],
                alwaysPersist: true
            )
            return (data, response)
        }
        return try await session.data(
            for: request,
            delegate: metricsCollector
        )
    }

    private func parseResult(
        data: Data,
        subscriptionID: UUID,
        episodeLimit: Int?,
        feedURL: URL
    ) throws -> FeedRefreshResult {
        try autoreleasepool {
            let beforeParser = Self.memorySample()
            let parsed = try parser.parseWithDiagnostics(
                data: data,
                maxEpisodes: episodeLimit
            )
            let afterParser = Self.memorySample()
            Self.logMemoryStage(
                "xmlParser",
                before: beforeParser,
                after: afterParser,
                feedURL: feedURL,
                sourceBytes: data.count
            )
            let parsedFeed = parsed.feed
            let diagnostics = parsed.diagnostics
            if diagnostics.repairedAmpersands > 0
                || diagnostics.truncatedElements > 0
                || diagnostics.sourceBytes >= 1_024 * 1_024 {
                AppLogger.shared.info(
                    "feed.parseDiagnostics",
                    "Recorded bounded RSS parser work",
                    metadata: [
                        "host": feedURL.host ?? "unknown",
                        "sourceBytes": "\(diagnostics.sourceBytes)",
                        "repairedBytes": "\(diagnostics.repairedBytes)",
                        "repairGrowthBytes":
                            "\(diagnostics.repairedBytes - diagnostics.sourceBytes)",
                        "repairedAmpersands": "\(diagnostics.repairedAmpersands)",
                        "durationMs":
                            String(
                                format: "%.1f",
                                diagnostics.durationMilliseconds
                            ),
                        "characterCallbacks": "\(diagnostics.characterCallbacks)",
                        "deliveredCharacters": "\(diagnostics.deliveredCharacters)",
                        "retainedCharacters": "\(diagnostics.retainedCharacters)",
                        "discardedCharacters": "\(diagnostics.discardedCharacters)",
                        "largestRetainedElement":
                            diagnostics.largestRetainedElement,
                        "largestRetainedElementCharacters":
                            "\(diagnostics.largestRetainedElementCharacters)",
                        "largestDeliveredElement":
                            diagnostics.largestDeliveredElement,
                        "largestDeliveredElementCharacters":
                            "\(diagnostics.largestDeliveredElementCharacters)",
                        "descriptionElements":
                            "\(diagnostics.descriptionElements)",
                        "contentEncodedElements":
                            "\(diagnostics.contentEncodedElements)",
                        "truncatedElements": "\(diagnostics.truncatedElements)"
                    ],
                    alwaysPersist: diagnostics.repairedAmpersands > 0
                        || diagnostics.truncatedElements > 0
                )
            }

            let playableEpisodes = parsedFeed.episodes.compactMap { parsedEpisode -> Episode? in
                guard let audioURL = parsedEpisode.audioURL else { return nil }
                return Self.episode(from: parsedEpisode, subscriptionID: subscriptionID, audioURL: audioURL, feedArtworkURL: parsedFeed.artworkURL)
            }
            let afterModels = Self.memorySample()
            Self.logMemoryStage(
                "modelMaterialization",
                before: afterParser,
                after: afterModels,
                feedURL: feedURL,
                sourceBytes: data.count
            )

            guard let latestEpisode = playableEpisodes.first else {
                throw FeedServiceError.missingAudioEnclosure
            }

            return FeedRefreshResult(
                subscriptionTitle: parsedFeed.title,
                description: parsedFeed.description,
                author: parsedFeed.author,
                artworkURL: parsedFeed.artworkURL,
                categories: parsedFeed.categories,
                isExplicit: parsedFeed.isExplicit,
                latestEpisode: latestEpisode,
                episodes: playableEpisodes
            )
        }
    }

    private static func episode(
        from parsedEpisode: ParsedEpisode,
        subscriptionID: UUID,
        audioURL: URL,
        feedArtworkURL: URL?
    ) -> Episode {
        let episodeID = UUID()
        let chapters = parsedEpisode.chapters.map { p in
            Chapter(
                id: UUID(),
                episodeID: episodeID,
                position: p.position,
                title: p.title,
                startSeconds: p.startSeconds,
                durationSeconds: p.durationSeconds,
                source: p.source
            )
        }

        var episode = Episode(
            id: episodeID,
            subscriptionID: subscriptionID,
            guid: parsedEpisode.guid,
            title: parsedEpisode.title,
            audioURL: audioURL,
            mediaKind: parsedEpisode.mediaKind,
            chapters: chapters
        )
        episode.description = parsedEpisode.description
        episode.subtitle = parsedEpisode.subtitle
        episode.author = parsedEpisode.author
        episode.publishedAt = parsedEpisode.publishedAt
        episode.durationSeconds = parsedEpisode.durationSeconds
        episode.artworkURL = parsedEpisode.artworkURL ?? feedArtworkURL
        episode.fileSizeBytes = parsedEpisode.fileSizeBytes
        episode.isExplicit = parsedEpisode.isExplicit
        episode.externalChaptersURL = parsedEpisode.externalChaptersURL
        episode.episodeLink = parsedEpisode.episodeLink
        return episode
    }

}

enum FeedServiceError: Error {
    case invalidFeed
    case missingAudioEnclosure
    case timedOut
    case responseTooLarge
    /// A server returned 304 Not Modified even though `refresh()` sent no
    /// validators (so it can't legitimately happen) — surfaced distinctly rather
    /// than as a misleading `missingAudioEnclosure`.
    case unexpectedNotModified
}
