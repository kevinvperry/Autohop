import Foundation
import OSLog
import TVServices

// AI CONTEXT — Principal class of the com.apple.tv-top-shelf extension. It
// performs one bounded local snapshot read, verifies the shared install scope,
// maps content synchronously, and calls completion exactly once. Every failure
// intentionally returns nil so tvOS renders the static fallback artwork.

final class TopShelfContentProvider: TVTopShelfContentProvider {
    private let logger = Logger(subsystem: "com.kevinperry.autohop", category: "TopShelfExtension")

    override func loadTopShelfContent(
        completionHandler: @escaping ((any TVTopShelfContent)?) -> Void
    ) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let storage = TVTopShelfSharedStorage()
        guard storage.hasAvailableContainer() else {
            finish(.appGroupUnavailable, storage: storage, startedAt: startedAt, completionHandler: completionHandler)
            return
        }
        guard let defaults = UserDefaults(suiteName: TVTopShelfSharedConfiguration.appGroupIdentifier) else {
            finish(.sharedDefaultsUnavailable, storage: storage, startedAt: startedAt, completionHandler: completionHandler)
            return
        }
        guard let scope = defaults.string(forKey: "topShelfAccountScope"), !scope.isEmpty else {
            finish(.accountScopeMissing, storage: storage, startedAt: startedAt, completionHandler: completionHandler)
            return
        }
        let snapshot: TVTopShelfSnapshot
        do {
            guard let value = try storage.read() else {
                finish(.manifestMissing, storage: storage, startedAt: startedAt, completionHandler: completionHandler)
                return
            }
            snapshot = value
        } catch {
            finish(.manifestInvalid, detailCode: errorCode(error), storage: storage, startedAt: startedAt, completionHandler: completionHandler)
            return
        }
        guard snapshot.accountScope == scope else {
            finish(.accountScopeMismatch, snapshot: snapshot, storage: storage, startedAt: startedAt, completionHandler: completionHandler)
            return
        }
        let content = TopShelfContentFactory.makeContent(
            snapshot: snapshot,
            expectedAccountScope: scope,
            artworkURL: { filename in
                try storage.artworkURL(generation: snapshot.generation, filename: filename)
            }
        )
        let outcome: TVTopShelfExtensionDiagnostic.Outcome = content == nil
            ? .noRenderableContent
            : .dynamicContentReturned
        record(outcome, snapshot: snapshot, storage: storage, startedAt: startedAt)
        completionHandler(content)
    }

    private func finish(
        _ outcome: TVTopShelfExtensionDiagnostic.Outcome,
        detailCode: String? = nil,
        snapshot: TVTopShelfSnapshot? = nil,
        storage: TVTopShelfSharedStorage,
        startedAt: CFAbsoluteTime,
        completionHandler: @escaping ((any TVTopShelfContent)?) -> Void
    ) {
        record(outcome, detailCode: detailCode, snapshot: snapshot, storage: storage, startedAt: startedAt)
        completionHandler(nil)
    }

    private func record(
        _ outcome: TVTopShelfExtensionDiagnostic.Outcome,
        detailCode: String? = nil,
        snapshot: TVTopShelfSnapshot? = nil,
        storage: TVTopShelfSharedStorage,
        startedAt: CFAbsoluteTime
    ) {
        let elapsed = max(0, Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000))
        let diagnostic = TVTopShelfExtensionDiagnostic(
            recordedAt: Date(),
            outcome: outcome,
            generation: snapshot?.generation,
            sectionCount: snapshot?.sections.count ?? 0,
            itemCount: snapshot?.sections.reduce(0) { $0 + $1.items.count } ?? 0,
            loadMilliseconds: elapsed,
            detailCode: detailCode
        )
        do {
            try storage.writeExtensionDiagnostic(diagnostic)
        } catch {
            logger.error("Could not persist Top Shelf diagnostic outcome=\(outcome.rawValue, privacy: .public)")
        }
        logger.info("Top Shelf load outcome=\(outcome.rawValue, privacy: .public) items=\(diagnostic.itemCount, privacy: .public) ms=\(elapsed, privacy: .public)")
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
