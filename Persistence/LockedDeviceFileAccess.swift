import CryptoKit
import Foundation

// ============================================================================
// AI CONTEXT - Persistence/LockedDeviceFileAccess.swift
//
// PURPOSE: Central file-protection helper for state CarPlay must read or mutate
// while the iPhone is locked after first unlock: downloaded media, artwork cache
// files, playback position, queue pins, settings, and the subscription database.
//
// POLICY: Use completeUntilFirstUserAuthentication on iOS/watchOS. This keeps
// data protected before the device has been unlocked after boot, while allowing
// ordinary locked-screen CarPlay playback/queue/archive flows to keep working
// once the user has mounted the phone for the day. On platforms without iOS data
// protection, the helper only performs the filesystem operation.
// ============================================================================

enum LockedDeviceFileAccess {
    static func createDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        applyProtectionIfAvailable(at: url, fileManager: fileManager)
    }

    static func writeDataAtomically(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try createDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        try data.write(to: url, options: [.atomic])
        applyProtectionIfAvailable(at: url, fileManager: fileManager)
    }

    static func applyToCarPlayCriticalFile(at url: URL, fileManager: FileManager = .default) {
        applyProtectionIfAvailable(at: url, fileManager: fileManager)
    }

    static func applyToSQLiteStore(at url: URL, fileManager: FileManager = .default) {
        applyProtectionIfAvailable(at: url, fileManager: fileManager)
        applyProtectionIfAvailable(at: URL(fileURLWithPath: url.path + "-wal"), fileManager: fileManager)
        applyProtectionIfAvailable(at: URL(fileURLWithPath: url.path + "-shm"), fileManager: fileManager)
    }

    private static func applyProtectionIfAvailable(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        #if os(iOS) || os(watchOS)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            AppLogger.shared.warning("storage.fileProtection", "Could not update file protection", metadata: [
                "file": url.lastPathComponent,
                "error": String(describing: error)
            ])
        }
        #endif
    }
}

/// Shared persistence envelope for small, user-authored JSON stores. The
/// checksum catches truncation and accidental payload/schema drift before a
/// caller replaces its in-memory state. `generationID` and `revision` are also
/// recovery metadata: future reconciliation can compare snapshots without
/// guessing from file modification dates.
struct IntegrityCheckedStoreEnvelope<Payload: Codable>: Codable {
    let schemaVersion: Int
    let generationID: String
    let revision: UInt64
    let writerDeviceID: String
    let updatedAt: Date
    let payload: Payload
    let checksum: String

    private struct ChecksumMaterial: Codable {
        let schemaVersion: Int
        let generationID: String
        let revision: UInt64
        let writerDeviceID: String
        let updatedAt: Date
        let payload: Payload
    }

    enum ValidationError: Error {
        case unsupportedSchema(Int)
        case invalidMetadata
        case checksumMismatch
    }

    static func make(
        payload: Payload,
        schemaVersion: Int,
        generationID: String,
        revision: UInt64,
        writerDeviceID: String,
        updatedAt: Date = Date()
    ) throws -> Self {
        let material = ChecksumMaterial(
            schemaVersion: schemaVersion,
            generationID: generationID,
            revision: revision,
            writerDeviceID: writerDeviceID,
            updatedAt: updatedAt,
            payload: payload
        )
        return Self(
            schemaVersion: schemaVersion,
            generationID: generationID,
            revision: revision,
            writerDeviceID: writerDeviceID,
            updatedAt: updatedAt,
            payload: payload,
            checksum: try checksum(for: material)
        )
    }

    func validated(expectedSchemaVersion: Int) throws -> Payload {
        guard schemaVersion == expectedSchemaVersion else {
            throw ValidationError.unsupportedSchema(schemaVersion)
        }
        guard !generationID.isEmpty, !writerDeviceID.isEmpty else {
            throw ValidationError.invalidMetadata
        }
        let material = ChecksumMaterial(
            schemaVersion: schemaVersion,
            generationID: generationID,
            revision: revision,
            writerDeviceID: writerDeviceID,
            updatedAt: updatedAt,
            payload: payload
        )
        let expectedChecksum = try Self.checksum(for: material)
        guard checksum == expectedChecksum else {
            throw ValidationError.checksumMismatch
        }
        return payload
    }

    static func encode(_ envelope: Self) throws -> Data {
        try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> Self {
        try decoder.decode(Self.self, from: data)
    }

    private static func checksum(for material: ChecksumMaterial) throws -> String {
        let data = try encoder.encode(material)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

enum DurableStoreLoadState: Equatable {
    case absent
    case loaded
    case recoveredFromBackup
    case temporarilyUnavailable
    case corruptOrIncompatible

    var allowsPersistence: Bool {
        switch self {
        case .absent, .loaded, .recoveredFromBackup:
            return true
        case .temporarilyUnavailable, .corruptOrIncompatible:
            return false
        }
    }
}

/// Canonical SHA-256 used by the stats file, SQLite projection and CloudKit
/// record. Keeping one implementation prevents three stores from disagreeing
/// merely because their encoders used different key ordering or date formats.
enum DurablePayloadFingerprint {
    static func make<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
