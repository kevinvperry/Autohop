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
