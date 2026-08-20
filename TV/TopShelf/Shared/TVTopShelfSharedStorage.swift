import Foundation

// AI CONTEXT — Sole filesystem boundary shared by the tvOS app and Top Shelf
// extension. The app writes complete generations; the extension only reads.
// Manifest replacement is atomic, artwork names are basenames, and resolved
// URLs remain inside Library/Caches/TVTopShelf. Manifest replacement is the
// commit point; pruning afterward is best-effort and cannot roll it back.
// Regenerable Top Shelf material
// belongs in Caches; a dual-location probe distinguishes a bad path from an
// ineffective signed App Group entitlement on physical Apple TV hardware.

enum TVTopShelfSharedConfiguration {
    static let appGroupIdentifier = "group.com.kevinperry.autohop"
    static let directoryName = "TVTopShelf"
    static let manifestFilename = "current.json"
    static let placeholderFilename = "autohop-top-shelf-placeholder.jpg"
}

// AI CONTEXT — Operation-labelled storage failures cross the otherwise opaque
// App Group boundary. Diagnostics deliberately retain only Foundation's domain,
// numeric code and the failed operation; paths and content never enter logs.
struct TVTopShelfStorageError: Error {
    enum Operation: String { case createCaches, createRoot, replaceGeneration, createGeneration, writeArtwork, encodeManifest, writeManifest }
    let operation: Operation
    let domain: String
    let code: Int

    init(_ operation: Operation, underlying error: Error) {
        let value = error as NSError
        self.operation = operation
        self.domain = value.domain
        self.code = value.code
    }

    var diagnosticCode: String { "\(operation.rawValue):\(domain):\(code)" }
}

struct TVTopShelfWriteProbe: Equatable {
    var containerAvailable: Bool
    var containerRoot: String
    var libraryCaches: String
}

struct TVTopShelfSharedStorage {
    private let fileManager: FileManager
    private let containerURL: URL?

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = TVTopShelfSharedConfiguration.appGroupIdentifier
    ) {
        self.fileManager = fileManager
        self.containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    init(containerURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.containerURL = containerURL
    }

    func read(now: Date = Date()) throws -> TVTopShelfSnapshot? {
        let url = try manifestURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= TVTopShelfSnapshot.maximumEncodedBytes else {
            throw TVTopShelfSnapshotError.encodedSnapshotTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TVTopShelfSnapshot.self, from: data).validated(now: now)
    }

    func write(
        _ snapshot: TVTopShelfSnapshot,
        artwork: [String: Data]
    ) throws {
        let snapshot = try snapshot.validated(now: snapshot.publishedAt)
        let root = try rootDirectory()
        do { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw TVTopShelfStorageError(.createRoot, underlying: error) }
        let generation = try generationDirectory(snapshot.generation)
        if fileManager.fileExists(atPath: generation.path) {
            do { try fileManager.removeItem(at: generation) }
            catch { throw TVTopShelfStorageError(.replaceGeneration, underlying: error) }
        }
        do { try fileManager.createDirectory(at: generation, withIntermediateDirectories: true) }
        catch { throw TVTopShelfStorageError(.createGeneration, underlying: error) }

        let referenced = Set(snapshot.sections.flatMap(\.items).flatMap {
            [$0.artworkFilename1x, $0.artworkFilename2x].compactMap { $0 }
        })
        guard referenced.isSubset(of: Set(artwork.keys)) else {
            try? fileManager.removeItem(at: generation)
            throw TVTopShelfSnapshotError.invalidArtworkFilename
        }
        do {
            for filename in referenced {
                guard let data = artwork[filename] else { continue }
                let destination = try containedArtworkURL(
                    generation: snapshot.generation,
                    filename: filename
                )
                // Generation directories are immutable and invisible until the
                // manifest commits, so a second atomic temporary-file dance is
                // unnecessary and has proven less reliable in App Group stores.
                do { try data.write(to: destination) }
                catch { throw TVTopShelfStorageError(.writeArtwork, underlying: error) }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let encoded: Data
            do { encoded = try encoder.encode(snapshot) }
            catch { throw TVTopShelfStorageError(.encodeManifest, underlying: error) }
            guard encoded.count <= TVTopShelfSnapshot.maximumEncodedBytes else {
                throw TVTopShelfSnapshotError.encodedSnapshotTooLarge
            }
            do { try encoded.write(to: manifestURL(), options: [.atomic]) }
            catch { throw TVTopShelfStorageError(.writeManifest, underlying: error) }
        } catch {
            try? fileManager.removeItem(at: generation)
            throw error
        }
        // The manifest is now committed and may already be visible to the
        // extension. Old-generation cleanup is best effort: a prune failure
        // must never roll back artwork referenced by the live manifest.
        try? removeOldGenerations(keeping: [snapshot.generation, max(0, snapshot.generation - 1)])
    }

    func removeManifest() throws {
        let manifest = try manifestURL()
        if fileManager.fileExists(atPath: manifest.path) {
            try fileManager.removeItem(at: manifest)
        }
    }

    func artworkURL(generation: Int64, filename: String) throws -> URL {
        try containedArtworkURL(generation: generation, filename: filename)
    }

    func hasAvailableContainer() -> Bool { containerURL != nil }

    /// Performs tiny create/write/remove operations and returns only operation
    /// outcomes—never filesystem paths or user content.
    func probeWriteAccess() -> TVTopShelfWriteProbe {
        guard let container = try? resolvedContainerURL() else {
            return .init(containerAvailable: false, containerRoot: "Unavailable", libraryCaches: "Unavailable")
        }
        return .init(
            containerAvailable: true,
            containerRoot: probeWrite(in: container),
            libraryCaches: probeWrite(in: container.appendingPathComponent("Library/Caches", isDirectory: true), createDirectory: true)
        )
    }

    func readExtensionDiagnostic() -> TVTopShelfExtensionDiagnostic? {
        guard let url = try? extensionDiagnosticURL(),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= TVTopShelfExtensionDiagnostic.maximumEncodedBytes
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(TVTopShelfExtensionDiagnostic.self, from: data)
    }

    /// The extension's only write path. Operational scalars are kept separate
    /// from the immutable presentation manifest so a diagnostic failure cannot
    /// corrupt or invalidate dynamic content.
    func writeExtensionDiagnostic(_ diagnostic: TVTopShelfExtensionDiagnostic) throws {
        let root = try rootDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(diagnostic)
        guard data.count <= TVTopShelfExtensionDiagnostic.maximumEncodedBytes else {
            throw TVTopShelfSnapshotError.encodedSnapshotTooLarge
        }
        try data.write(to: extensionDiagnosticURL(), options: [.atomic])
    }

    private func resolvedContainerURL() throws -> URL {
        guard let containerURL else { throw TVTopShelfSnapshotError.appGroupUnavailable }
        return containerURL.standardizedFileURL
    }

    private func rootDirectory() throws -> URL {
        let caches = try resolvedContainerURL().appendingPathComponent("Library/Caches", isDirectory: true)
        do { try fileManager.createDirectory(at: caches, withIntermediateDirectories: true) }
        catch { throw TVTopShelfStorageError(.createCaches, underlying: error) }
        return caches.appendingPathComponent(
            TVTopShelfSharedConfiguration.directoryName,
            isDirectory: true
        ).standardizedFileURL
    }

    private func probeWrite(in directory: URL, createDirectory: Bool = false) -> String {
        do {
            if createDirectory { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
            let probe = directory.appendingPathComponent(".autohop-write-probe-\(UUID().uuidString)")
            try Data([0x41]).write(to: probe, options: [.atomic])
            try fileManager.removeItem(at: probe)
            return "Writable"
        } catch {
            let value = error as NSError
            return "Denied:\(value.domain):\(value.code)"
        }
    }

    private func manifestURL() throws -> URL {
        try rootDirectory().appendingPathComponent(
            TVTopShelfSharedConfiguration.manifestFilename,
            isDirectory: false
        )
    }

    private func extensionDiagnosticURL() throws -> URL {
        try rootDirectory().appendingPathComponent(
            TVTopShelfExtensionDiagnostic.filename,
            isDirectory: false
        )
    }

    private func generationDirectory(_ generation: Int64) throws -> URL {
        try rootDirectory().appendingPathComponent("generation-\(generation)", isDirectory: true)
    }

    private func containedArtworkURL(generation: Int64, filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains(".."), !filename.contains("/"), !filename.contains("\\")
        else { throw TVTopShelfSnapshotError.invalidArtworkFilename }
        let directory = try generationDirectory(generation).standardizedFileURL
        let candidate = directory.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else {
            throw TVTopShelfSnapshotError.invalidArtworkFilename
        }
        return candidate
    }

    private func removeOldGenerations(keeping generations: Set<Int64>) throws {
        let root = try rootDirectory()
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children where child.lastPathComponent.hasPrefix("generation-") {
            let value = Int64(child.lastPathComponent.dropFirst("generation-".count))
            if value.map({ !generations.contains($0) }) ?? true {
                try? fileManager.removeItem(at: child)
            }
        }
    }
}
