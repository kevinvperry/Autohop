import CloudKit
import CryptoKit
import Foundation
import TVServices
import AutohopCore

// AI CONTEXT — Main-app publication owner for dynamic Top Shelf. It
// generation-owns async artwork preparation, coalesces bursts, atomically
// replaces the App Group materialized view, and only then asks tvOS to reload.
// It receives immutable Home projections and never changes queue/history state.
// Publication fails closed on CloudKit identity: scope is a SHA-256 user-record
// hash, and identity failure/change clears prior shared content.

struct TVTopShelfPublisherDiagnostics: Equatable {
    var phase = "Not requested"
    var lastReason = "None"
    var candidateItems = 0
    var lastGeneration: Int64?
    var lastPublishMilliseconds: Int?
    var lastErrorCode: String?
    var consecutiveFailures = 0
    var suppressedRequests = 0
    var retryAfterSeconds: Int?
    var artworkDiskCacheItems = 0
    var artworkNetworkItems = 0
    var artworkPlaceholderItems = 0
}

struct TVTopShelfHealthDiagnostics: Equatable {
    var publisher: TVTopShelfPublisherDiagnostics
    var appGroupAvailable: Bool
    var containerRootProbe: String
    var libraryCachesProbe: String
    var manifestState: String
    var manifestGeneration: Int64?
    var manifestItems: Int
    var manifestAgeSeconds: Int?
    var extensionOutcome: String
    var extensionAgeSeconds: Int?
    var extensionLoadMilliseconds: Int?
}

@MainActor
final class TVTopShelfSnapshotPublisher {
    private let storage: TVTopShelfSharedStorage
    private let defaults: UserDefaults?
    private let accountScopeProvider: @Sendable () async throws -> String
    private var scheduledTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var lastCandidate: TVTopShelfSnapshotCandidate?
    private var hasObservedCandidate = false
    private var preparedArtworkCache: [String: (sourceURL: URL?, artwork: TVTopShelfPreparedArtwork)] = [:]
    private var consecutiveFailures = 0
    private var retryNotBefore: Date?
    private var writeProbe: TVTopShelfWriteProbe
    private(set) var diagnostics = TVTopShelfPublisherDiagnostics()

    init(
        storage: TVTopShelfSharedStorage = .init(),
        defaults: UserDefaults? = UserDefaults(suiteName: TVTopShelfSharedConfiguration.appGroupIdentifier),
        accountScopeProvider: @escaping @Sendable () async throws -> String = {
            let recordID = try await CKContainer(identifier: "iCloud.com.kevinperry.autohop").userRecordID()
            let digest = SHA256.hash(data: Data(recordID.recordName.utf8))
            return "ck:" + digest.map { String(format: "%02x", $0) }.joined()
        }
    ) {
        self.storage = storage
        self.defaults = defaults
        self.accountScopeProvider = accountScopeProvider
        self.writeProbe = storage.probeWriteAccess()
        AppLogger.shared.info("tv.topShelf.storageProbe", "Probed shared Top Shelf storage", metadata: [
            "containerAvailable": "\(writeProbe.containerAvailable)",
            "containerRoot": writeProbe.containerRoot,
            "libraryCaches": writeProbe.libraryCaches
        ], alwaysPersist: true)
    }

    func schedule(candidate: TVTopShelfSnapshotCandidate?, reason: String) {
        // AI CONTEXT — The first nil candidate is meaningful: it clears a
        // snapshot left by an earlier process/account even though
        // `lastCandidate` also begins nil in this process.
        if hasObservedCandidate, candidate == lastCandidate { return }
        if let retryNotBefore, retryNotBefore > Date() {
            diagnostics.suppressedRequests += 1
            diagnostics.retryAfterSeconds = max(1, Int(retryNotBefore.timeIntervalSinceNow.rounded(.up)))
            diagnostics.phase = "Paused after storage failure"
            return
        }
        hasObservedCandidate = true
        diagnostics.phase = "Scheduled"
        diagnostics.lastReason = reason
        diagnostics.candidateItems = candidate?.sections.reduce(0) { $0 + $1.items.count } ?? 0
        diagnostics.lastErrorCode = nil
        AppLogger.shared.info("tv.topShelf.publishScheduled", "Scheduled Top Shelf publication", metadata: [
            "candidateItems": "\(diagnostics.candidateItems)",
            "reason": reason
        ])
        requestGeneration &+= 1
        let owned = requestGeneration
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !Task.isCancelled, owned == self.requestGeneration else { return }
            await self.publish(candidate: candidate, ownedGeneration: owned, reason: reason)
        }
    }

    func publishImmediately(candidate: TVTopShelfSnapshotCandidate?, reason: String) async {
        retryNotBefore = nil
        writeProbe = storage.probeWriteAccess()
        hasObservedCandidate = true
        diagnostics.phase = "Publishing immediately"
        diagnostics.lastReason = reason
        diagnostics.candidateItems = candidate?.sections.reduce(0) { $0 + $1.items.count } ?? 0
        diagnostics.lastErrorCode = nil
        requestGeneration &+= 1
        scheduledTask?.cancel()
        await publish(candidate: candidate, ownedGeneration: requestGeneration, reason: reason)
    }

    private func publish(
        candidate: TVTopShelfSnapshotCandidate?,
        ownedGeneration: UInt64,
        reason: String
    ) async {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard ownedGeneration == requestGeneration else { return }
        guard let candidate else {
            do {
                try storage.removeManifest()
                lastCandidate = nil
                diagnostics.phase = "No eligible episodes"
                diagnostics.lastPublishMilliseconds = elapsedMilliseconds(since: startedAt)
                TVTopShelfContentProvider.topShelfContentDidChange()
                AppLogger.shared.info("tv.topShelf.cleared", "Cleared dynamic Top Shelf presentation", metadata: ["reason": reason])
            } catch {
                diagnostics.phase = "Clear failed"
                diagnostics.lastErrorCode = errorCode(error)
                AppLogger.shared.warning("tv.topShelf.publishFailed", "Could not clear Top Shelf presentation", metadata: ["reason": reason])
            }
            return
        }

        diagnostics.phase = "Preparing artwork"

        let nextGeneration = Int64(defaults?.integer(forKey: "topShelfGeneration") ?? 0) + 1
        let accountScope: String
        do {
            accountScope = try await resolvedAccountScope()
        } catch {
            // Account identity is a privacy boundary. Never retain content
            // whose ownership cannot be established for the current process.
            try? storage.removeManifest()
            diagnostics.phase = "Waiting for iCloud account"
            diagnostics.lastErrorCode = "accountScopeUnavailable"
            diagnostics.lastPublishMilliseconds = elapsedMilliseconds(since: startedAt)
            TVTopShelfContentProvider.topShelfContentDidChange()
            return
        }
        guard ownedGeneration == requestGeneration, !Task.isCancelled else { return }
        if let previous = defaults?.string(forKey: "topShelfAccountScope"),
           previous.hasPrefix("ck:"), previous != accountScope {
            // A real account transition must fail closed. Clear the old
            // manifest and wait for the new account's CloudKit prime to drive
            // a fresh candidate rather than relabelling old titles.
            defaults?.set(accountScope, forKey: "topShelfAccountScope")
            defaults?.set(0, forKey: "topShelfGeneration")
            try? storage.removeManifest()
            lastCandidate = nil
            preparedArtworkCache.removeAll()
            diagnostics.phase = "Account changed — awaiting refresh"
            diagnostics.lastErrorCode = nil
            diagnostics.lastPublishMilliseconds = elapsedMilliseconds(since: startedAt)
            TVTopShelfContentProvider.topShelfContentDidChange()
            return
        }
        // This also migrates the former random installation UUID. That legacy
        // value never represented an account and is safe to replace in place.
        defaults?.set(accountScope, forKey: "topShelfAccountScope")
        var preparedByID: [String: TVTopShelfPreparedArtwork] = [:]
        let items = candidate.sections.flatMap(\.items)
        for chunkStart in stride(from: 0, to: items.count, by: 2) {
            guard ownedGeneration == requestGeneration, !Task.isCancelled else { return }
            let chunk = Array(items[chunkStart..<min(chunkStart + 2, items.count)])
            await withTaskGroup(of: (String, TVTopShelfPreparedArtwork).self) { group in
                for item in chunk {
                    if let cached = preparedArtworkCache[item.stableID], cached.sourceURL == item.artworkURL {
                        preparedByID[item.stableID] = cached.artwork
                        continue
                    }
                    group.addTask {
                        (item.stableID, await TVTopShelfArtworkPreparer.prepare(
                            sourceURL: item.artworkURL,
                            stableID: item.stableID
                        ))
                    }
                }
                for await (id, prepared) in group {
                    preparedByID[id] = prepared
                    if let source = items.first(where: { $0.stableID == id })?.artworkURL {
                        preparedArtworkCache[id] = (source, prepared)
                    } else {
                        preparedArtworkCache[id] = (nil, prepared)
                    }
                }
            }
        }
        guard ownedGeneration == requestGeneration, !Task.isCancelled else { return }

        let sections = candidate.sections.map { section in
            TVTopShelfSnapshot.Section(
                kind: section.kind,
                title: section.title,
                items: section.items.compactMap { item in
                    guard let art = preparedByID[item.stableID] else { return nil }
                    return .init(
                        id: item.stableID,
                        subscriptionID: item.subscriptionID,
                        episodeKey: item.episodeKey,
                        episodeTitle: item.episodeTitle,
                        podcastTitle: item.podcastTitle,
                        artworkFilename1x: art.filename1x,
                        artworkFilename2x: art.filename2x,
                        playbackProgress: item.playbackProgress,
                        expiresAt: item.expiresAt
                    )
                }
            )
        }.filter { !$0.items.isEmpty }
        guard !sections.isEmpty else {
            diagnostics.phase = "No renderable artwork"
            diagnostics.lastErrorCode = "noRenderableArtwork"
            diagnostics.lastPublishMilliseconds = elapsedMilliseconds(since: startedAt)
            AppLogger.shared.warning("tv.topShelf.publishRejected", "Top Shelf candidate produced no renderable artwork", metadata: [
                "candidateItems": "\(diagnostics.candidateItems)",
                "reason": reason
            ], alwaysPersist: true)
            return
        }
        let snapshot = TVTopShelfSnapshot(
            generation: nextGeneration,
            publishedAt: Date(),
            accountScope: accountScope,
            sections: sections
        )
        let artwork = preparedByID.values.reduce(into: [String: Data]()) { result, art in
            result[art.filename1x] = art.data1x
            result[art.filename2x] = art.data2x
        }
        diagnostics.artworkDiskCacheItems = preparedByID.values.filter { $0.source == .tvDiskCache }.count
        diagnostics.artworkNetworkItems = preparedByID.values.filter { $0.source == .network }.count
        diagnostics.artworkPlaceholderItems = preparedByID.values.filter { $0.source == .placeholder }.count
        do {
            diagnostics.phase = "Writing shared snapshot"
            try storage.write(snapshot, artwork: artwork)
            guard ownedGeneration == requestGeneration else { return }
            defaults?.set(nextGeneration, forKey: "topShelfGeneration")
            lastCandidate = candidate
            consecutiveFailures = 0
            retryNotBefore = nil
            diagnostics.consecutiveFailures = 0
            diagnostics.retryAfterSeconds = nil
            let liveIDs = Set(items.map(\.stableID))
            preparedArtworkCache = preparedArtworkCache.filter { liveIDs.contains($0.key) }
            diagnostics.phase = "Published"
            diagnostics.lastGeneration = nextGeneration
            diagnostics.lastPublishMilliseconds = elapsedMilliseconds(since: startedAt)
            diagnostics.lastErrorCode = nil
            TVTopShelfContentProvider.topShelfContentDidChange()
            AppLogger.shared.info("tv.topShelf.publishSucceeded", "Published dynamic Top Shelf presentation", metadata: [
                "generation": "\(nextGeneration)",
                "sections": "\(sections.count)",
                "items": "\(sections.reduce(0) { $0 + $1.items.count })",
                "artworkDiskCache": "\(diagnostics.artworkDiskCacheItems)",
                "artworkNetwork": "\(diagnostics.artworkNetworkItems)",
                "artworkPlaceholder": "\(diagnostics.artworkPlaceholderItems)",
                "ms": "\(diagnostics.lastPublishMilliseconds ?? 0)",
                "reason": reason
            ], alwaysPersist: true)
        } catch {
            consecutiveFailures += 1
            diagnostics.consecutiveFailures = consecutiveFailures
            if consecutiveFailures >= 3 {
                retryNotBefore = Date().addingTimeInterval(15 * 60)
                diagnostics.retryAfterSeconds = 15 * 60
                diagnostics.phase = "Paused after storage failure"
            } else {
                diagnostics.phase = "Publish failed"
            }
            diagnostics.lastErrorCode = errorCode(error)
            diagnostics.lastPublishMilliseconds = elapsedMilliseconds(since: startedAt)
            AppLogger.shared.warning("tv.topShelf.publishFailed", "Could not publish Top Shelf presentation", metadata: [
                "reason": reason,
                "errorCode": diagnostics.lastErrorCode ?? "unknown",
                "consecutiveFailures": "\(consecutiveFailures)",
                "ms": "\(diagnostics.lastPublishMilliseconds ?? 0)"
            ], alwaysPersist: true)
        }
    }

    func healthDiagnostics(now: Date = Date()) -> TVTopShelfHealthDiagnostics {
        let snapshotResult: Result<TVTopShelfSnapshot?, Error> = Result { try storage.read(now: now) }
        let manifestState: String
        let snapshot: TVTopShelfSnapshot?
        switch snapshotResult {
        case .success(let value):
            snapshot = value
            manifestState = value == nil ? "Missing" : "Valid"
        case .failure(let error):
            snapshot = nil
            manifestState = "Invalid (\(errorCode(error)))"
        }
        let extensionRecord = storage.readExtensionDiagnostic()
        return TVTopShelfHealthDiagnostics(
            publisher: diagnostics,
            appGroupAvailable: storage.hasAvailableContainer(),
            containerRootProbe: writeProbe.containerRoot,
            libraryCachesProbe: writeProbe.libraryCaches,
            manifestState: manifestState,
            manifestGeneration: snapshot?.generation,
            manifestItems: snapshot?.sections.reduce(0) { $0 + $1.items.count } ?? 0,
            manifestAgeSeconds: snapshot.map { max(0, Int(now.timeIntervalSince($0.publishedAt))) },
            extensionOutcome: extensionRecord?.outcome.rawValue ?? "Never recorded",
            extensionAgeSeconds: extensionRecord.map { max(0, Int(now.timeIntervalSince($0.recordedAt))) },
            extensionLoadMilliseconds: extensionRecord?.loadMilliseconds
        )
    }

    private func resolvedAccountScope() async throws -> String {
        let scope = try await accountScopeProvider()
        guard scope.hasPrefix("ck:"), scope.count > 3 else {
            throw TVTopShelfAccountScopeError.invalidScope
        }
        return scope
    }


    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - start) * 1_000))
    }

    private func errorCode(_ error: Error) -> String {
        if let error = error as? TVTopShelfStorageError { return error.diagnosticCode }
        if let error = error as? TVTopShelfSnapshotError {
            switch error {
            case .appGroupUnavailable: return "appGroupUnavailable"
            case .encodedSnapshotTooLarge: return "snapshotTooLarge"
            case .invalidArtworkFilename: return "invalidArtworkFilename"
            case .invalidSnapshot: return "invalidSnapshot"
            case .unsupportedSchemaVersion: return "unsupportedSchema"
            }
        }
        return String(describing: type(of: error))
    }
}

private enum TVTopShelfAccountScopeError: Error {
    case invalidScope
}
