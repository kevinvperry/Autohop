import Foundation

// AI CONTEXT — Logging/AppLogger.swift
// Singleton diagnostic logger writing structured lines (ISO8601 timestamp,
// level, event key, message, key=value metadata) to autohop-diagnostic.log on
// a serial queue, capped at ~5 MB then rotated to a single .previous.log segment
// (see rotateIfNeeded / archivedLogFileURL). A manual export (redactedContents →
// combinedContents) stitches .previous.log + the current file, oldest first, so it
// spans the last two rotations instead of only the post-rotation tail. This matters
// for overnight captures: a long background-audio session can rotate mid-session,
// and without the archived segment the export would hide the app.launch /
// background.launch markers that BACKGROUND_REFRESH_RESEARCH §9 relies on. isEnabled mirrors the
// hidden Diagnostics toggle (Settings → About → tap version 5×); when off,
// writes are no-ops — EXCEPT errors logged with alwaysPersist:true, which are
// always recorded (used by CloudSyncEngine so a sync failure that happens
// before a user enables diagnostics still leaves a trace). Read by
// DiagnosticLogView. Event keys are dot-namespaced ("background.schedule",
// "feed.cycleSummary", "download.watchdog", "sync.pushFailed", ...) — grep-friendly.
// WRITE MECHANISM (P4): a single append FileHandle is held open for the serial
// queue's lifetime (lazy appendHandle()) and reused per line instead of paying
// open+seek+close per entry. It is closed via closeHandle() before rotateIfNeeded
// moves the file and before clear() removes it, so the next write reopens the
// fresh log; all handle access stays on `queue`, so no lock is required. If
// opening succeeds but seek-to-end fails, appendHandle() closes the handle and
// returns nil rather than risking a write at the wrong offset.
// PERFORMANCE (2026-07-12/21): the enabled/verbosity gate runs before lazy
// metadata construction. Accepted metadata is captured on its owning caller,
// while timestamp formatting, sorting, redaction, optional console mirroring, and
// encoding run on the logger queue. Rotation uses an incrementally maintained byte count
// initialized when the handle opens, avoiding attributesOfItem on every line. The
// DiagnosticLogView's lastUpdated publication is trailing-edge coalesced to 1 Hz,
// preventing log bursts from dispatching hundreds of main-thread invalidations.
// LOG LEVELS / COST CONTROL (2026-07-21): `info` is the normal diagnostic tier;
// `verbose` is reserved for per-item traces such as individual 304 feed results.
// Metadata is an autoclosure and is evaluated only after the thread-safe enabled
// gate accepts the event, so disabled diagnostics do not build large dictionaries.
// A bounded pending queue drops routine bursts before they can retain unbounded
// metadata; the next accepted line reports the dropped count. Errors and forced
// lifecycle evidence bypass that routine limit. Scalar metadata avoids regex work,
// while all free-form/URL values still use the complete security redactor.
// PUBLIC logging surface since tvOS Phase 1: the TV target imports AutohopCore
// as a library and must reach the shared diagnostic log. Internals stay internal.
public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()

    @Published private(set) var lastUpdated = Date()
    private let stateLock = NSLock()
    private var enabledState = false
    private var verboseState = false
    private var consoleMirroringState = false
    private var pendingRoutineEntries = 0
    private var droppedRoutineEntries = 0
    private var totalDroppedRoutineEntries = 0
    private let maximumPendingRoutineEntries = 500

    var isEnabled: Bool {
        get { stateLock.withLock { enabledState } }
        set { setEnabled(newValue) }
    }

    var isVerboseEnabled: Bool {
        get { stateLock.withLock { verboseState } }
        set { setVerboseEnabled(newValue) }
    }

    /// Library-consumer switch (2026-07-11, TV diagnostics): `isEnabled` is
    /// internal (iOS sets it directly from the hidden Diagnostics toggle), but
    /// the TV target imports AutohopCore as a library and previously had NO
    /// way to turn logging on — every non-alwaysPersist TV log line was
    /// silently dropped. The TV enables logging unconditionally at TVAppModel
    /// init (the file is capped + rotated, and TV has no user-facing toggle).
    public func setEnabled(_ enabled: Bool) {
        stateLock.withLock { enabledState = enabled }
    }

    public func setVerboseEnabled(_ enabled: Bool) {
        stateLock.withLock { verboseState = enabled }
    }

    /// Debug-console output is deliberately independent from file diagnostics;
    /// leaving it off avoids Xcode console I/O distorting timing investigations.
    public func setConsoleMirroringEnabled(_ enabled: Bool) {
        stateLock.withLock { consoleMirroringState = enabled }
    }

    let logFileURL: URL

    private let queue = DispatchQueue(label: "com.autohop.diagnostic-log")
    /// Append handle held open for the queue's lifetime so a burst of log lines
    /// doesn't pay open+seek+close per entry (P4). Touched only on `queue`; closed
    /// and reopened lazily across rotation/clear. nil = not currently open.
    private var fileHandle: FileHandle?
    /// Exact current-segment size while the append handle is open. Queue-confined.
    private var currentFileSizeBytes: Int?
    /// A burst schedules only one trailing DiagnosticLogView refresh. Queue-confined.
    private var updatePublishScheduled = false
    private let updatePublishInterval: TimeInterval = 1
    private let fileManager: FileManager
    private let maxFileSizeBytes = 5_000_000
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// Precompiled once for the process. Values proven to be scalar skip these
    /// rules, but free-form strings still receive the complete conservative set.
    private static let redactionRules: [(NSRegularExpression, String)] = [
        (#"(?i)(https?://)[^/@\s]+@"#, "$1[redacted]@"),
        (#"(?i)(https?://[^\s?#]+)\?[^\s#]*"#, "$1?[redacted]"),
        (#"(?i)(https?://[^\s#]+)#[^\s]+"#, "$1#[redacted]"),
        (#"(?i)((?:authorization|auth|access_token|refresh_token|token|api_key|apikey|x-api-key|key|secret|password|passwd|signature|sig|expires|policy|x-amz-signature|cookie|set-cookie|jwt)=)[^\s&]+"#, "$1[redacted]"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]+=*"#, "Bearer [redacted]")
    ].compactMap { pattern, replacement in
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        return (expression, replacement)
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        #if os(tvOS)
        // Physical tvOS can return an Application Support URL while denying
        // directory creation there. Its temporary directory is writable but
        // omitted from Xcode's downloaded .xcappdata container. Caches is both
        // app-writable and container-exported (the TV databases already use
        // Library/Caches/Autohop), making it the reliable TV diagnostic home.
        let cacheRoot = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = (cacheRoot ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Autohop", isDirectory: true)
        #else
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = (appSupport ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Autohop", isDirectory: true)
        #endif
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        logFileURL = directory.appendingPathComponent("autohop-diagnostic.log")
    }

    /// - Parameter alwaysPersist: when true, the entry is written even if the
    ///   Diagnostics toggle is off. Reserve for events that happen before diagnostics
    ///   can be enabled and are needed after the fact — e.g. `app.launch`, which fires
    ///   in `didFinishLaunching` before AppState turns logging on, so without this it
    ///   is silently dropped on every launch.
    public func info(_ event: String, _ message: String, metadata: @autoclosure () -> [String: String] = [:], alwaysPersist: Bool = false) {
        write(level: "INFO", event: event, message: message, metadata: metadata, force: alwaysPersist)
    }

    public func verbose(_ event: String, _ message: String, metadata: @autoclosure () -> [String: String] = [:]) {
        write(level: "TRACE", event: event, message: message, metadata: metadata, requiresVerbose: true)
    }

    public func warning(_ event: String, _ message: String, metadata: @autoclosure () -> [String: String] = [:], alwaysPersist: Bool = false) {
        write(level: "WARN", event: event, message: message, metadata: metadata, force: alwaysPersist, important: true)
    }

    /// - Parameter alwaysPersist: when true, the entry is written even if the
    ///   Diagnostics toggle is off. Reserve for errors a user would need a trace
    ///   of after the fact (e.g. iCloud sync failures). The file stays capped and
    ///   rotated, so these can't grow unbounded.
    public func error(_ event: String, _ message: String, metadata: @autoclosure () -> [String: String] = [:], alwaysPersist: Bool = false) {
        write(level: "ERROR", event: event, message: message, metadata: metadata, force: alwaysPersist, important: true)
    }

    /// The single rotated (older) log segment produced by `rotateIfNeeded`. Defined
    /// once here so the rotation and the export always agree on the path.
    private var archivedLogFileURL: URL {
        logFileURL.deletingPathExtension().appendingPathExtension("previous.log")
    }

    /// Current log segment only — cheap, used by the live in-app viewer.
    func contents() -> String {
        queue.sync {
            try? fileHandle?.synchronize()
            return (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
        }
    }

    /// The rotated (older) segment followed by the current one, oldest first, so a
    /// manual export spans the last two rotations rather than only the tail left after
    /// a mid-session rotation. The live viewer deliberately stays on `contents()` to
    /// avoid reading up to two full segments on every update.
    func combinedContents() -> String {
        queue.sync {
            try? fileHandle?.synchronize()
            let previous = (try? String(contentsOf: archivedLogFileURL, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
            if previous.isEmpty { return current }
            if current.isEmpty { return previous }
            let joiner = previous.hasSuffix("\n") ? "" : "\n"
            return previous + joiner + current
        }
    }

    func redactedContents() -> String {
        let state = stateLock.withLock {
            (
                enabled: enabledState,
                verbose: verboseState,
                dropped: totalDroppedRoutineEntries
            )
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let header = "# Autohop Diagnostic Export version=\(version) build=\(build) normalEnabled=\(state.enabled) detailedRefreshTrace=\(state.verbose) routineEntriesDropped=\(state.dropped) exportedAt=\(dateFormatter.string(from: Date()))\n"
        return header + Self.redactSensitiveText(combinedContents())
    }

    public func redactedExportURL() -> URL {
        let exportURL = fileManager.temporaryDirectory.appendingPathComponent("autohop-diagnostic-redacted.log")
        let text = redactedContents()
        try? text.data(using: .utf8)?.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    /// Writes a diagnostic export to a caller-owned durable destination and
    /// propagates failures. `redactedExportURL()` is retained for share-sheet
    /// compatibility, but its historical best-effort temp write cannot explain
    /// an export failure to a television user.
    public func writeRedactedExport(to destination: URL) throws {
        let text = redactedContents()
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: destination, options: [.atomic])
    }

    /// Writes beside the live log in the exact directory already proven
    /// writable by this process. This avoids asking physical tvOS to create a
    /// second directory, which some device sandbox/container states reject.
    @discardableResult
    public func writeRedactedExportBesideLiveLog() throws -> URL {
        let destination = logFileURL.deletingLastPathComponent()
            .appendingPathComponent("autohop-tv-diagnostic-redacted.log")
        try writeRedactedExport(to: destination)
        return destination
    }

    func recentLines(limit: Int) -> [String] {
        let text = contents()
        guard !text.isEmpty else { return [] }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .map(String.init)
    }

    func clear() {
        stateLock.withLock {
            droppedRoutineEntries = 0
            totalDroppedRoutineEntries = 0
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.closeHandle()
            self.currentFileSizeBytes = nil
            try? self.fileManager.removeItem(at: self.logFileURL)
            // Also drop the rotated segment, otherwise it would resurface in the next
            // export (which now stitches .previous.log + current) despite the clear.
            try? self.fileManager.removeItem(at: self.archivedLogFileURL)
            let resetLine = "\(self.dateFormatter.string(from: Date())) [INFO] log.cleared: Diagnostic log history cleared\n"
            try? self.fileManager.createDirectory(at: self.logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? resetLine.data(using: .utf8)?.write(to: self.logFileURL, options: [.atomic])
            self.scheduleLastUpdatedPublication()
        }
    }

    private func write(
        level: String,
        event: String,
        message: String,
        metadata: () -> [String: String],
        force: Bool = false,
        requiresVerbose: Bool = false,
        important: Bool = false
    ) {
        let admission: (accepted: Bool, dropped: Int) = stateLock.withLock {
            guard enabledState || force else { return (false, 0) }
            guard !requiresVerbose || verboseState else { return (false, 0) }
            if !important && !force && pendingRoutineEntries >= maximumPendingRoutineEntries {
                droppedRoutineEntries += 1
                totalDroppedRoutineEntries += 1
                return (false, 0)
            }
            if !important && !force { pendingRoutineEntries += 1 }
            let dropped = droppedRoutineEntries
            droppedRoutineEntries = 0
            return (true, dropped)
        }
        guard admission.accepted else { return }
        let capturedMetadata = metadata()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                if !important && !force {
                    self.stateLock.withLock {
                        self.pendingRoutineEntries = max(0, self.pendingRoutineEntries - 1)
                    }
                }
            }
            if admission.dropped > 0 {
                self.appendFormattedLine(
                    level: "WARN",
                    event: "log.entriesDropped",
                    message: "Routine diagnostic entries were dropped under logging backpressure",
                    metadata: ["count": "\(admission.dropped)"]
                )
            }
            self.appendFormattedLine(
                level: level,
                event: event,
                message: message,
                metadata: capturedMetadata
            )
            // Xcode's physical-tvOS container download can snapshot an open
            // file before buffered bytes are materialised. Force only the
            // sparse important/always-persist evidence (lifecycle, failures,
            // Play Next stages), not routine high-volume diagnostics.
            if important || force {
                try? self.fileHandle?.synchronize()
            }
            self.scheduleLastUpdatedPublication()
        }
    }

    private func appendFormattedLine(
        level: String,
        event: String,
        message: String,
        metadata: [String: String]
    ) {
            let timestamp = self.dateFormatter.string(from: Date())
            let metadataText = metadata.isEmpty
                ? ""
                : " " + metadata.sorted { $0.key < $1.key }.map { key, value in
                    return "\(Self.normalized(key, limit: 80))=\(Self.redactedMetadataValue(value, key: key))"
                }.joined(separator: " ")
            let cleanMessage = Self.redactSensitiveText(Self.normalized(message, limit: 2_048))
            var line = "\(timestamp) [\(level)] \(Self.normalized(event, limit: 120)): \(cleanMessage)\(metadataText)\n"
            if line.utf8.count > 16_384 {
                line = String(line.prefix(16_360)) + " [truncated]\n"
            }

            #if DEBUG
            if stateLock.withLock({ consoleMirroringState }) {
                print(line, terminator: "")
            }
            #endif

            guard let data = line.data(using: .utf8) else { return }
            self.rotateIfNeeded(incomingBytes: data.count)
            if let handle = self.appendHandle() {
                do {
                    try handle.write(contentsOf: data)
                    self.currentFileSizeBytes = (self.currentFileSizeBytes ?? 0) + data.count
                } catch {
                    // Drop this diagnostic rather than recursively logging a logger failure.
                }
            }
    }

    /// Coalesces a burst into one trailing main-thread notification so the live log
    /// viewer eventually sees the final line without waking SwiftUI for every line.
    private func scheduleLastUpdatedPublication() {
        guard !updatePublishScheduled else { return }
        updatePublishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + updatePublishInterval) { [weak self] in
            guard let self else { return }
            self.lastUpdated = Date()
            self.queue.async { self.updatePublishScheduled = false }
        }
    }

    /// Returns the shared append handle, opening it (and creating the log file if
    /// absent) once and reusing it thereafter. MUST be called only on `queue`.
    private func appendHandle() -> FileHandle? {
        if let fileHandle { return fileHandle }
        if !fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return nil }
        do {
            let offset = try handle.seekToEnd()
            currentFileSizeBytes = Int(offset)
        } catch {
            try? handle.close()
            return nil
        }
        fileHandle = handle
        return handle
    }

    /// Closes and clears the append handle so the next write reopens the file.
    /// MUST be called only on `queue` (before moving/removing the log file).
    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFileSizeBytes = nil
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        // appendHandle() initializes the byte count from seekToEnd once per segment.
        // No filesystem metadata lookup occurs on the steady-state per-line path.
        if currentFileSizeBytes == nil { _ = appendHandle() }
        let size = currentFileSizeBytes ?? 0
        guard size + incomingBytes > maxFileSizeBytes else { return }

        // Release the handle before moving the file so the next append reopens the
        // fresh (post-rotation) log rather than writing into the archived copy.
        closeHandle()
        let archivedURL = archivedLogFileURL
        try? fileManager.removeItem(at: archivedURL)
        try? fileManager.moveItem(at: logFileURL, to: archivedURL)
        currentFileSizeBytes = 0
    }

    static func redactSensitiveText(_ text: String) -> String {
        var redacted = text
        for (expression, replacement) in redactionRules {
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: replacement
            )
        }
        return redacted
    }

    private static func redactedMetadataValue(_ value: String, key: String) -> String {
        let normalizedValue = normalized(value, limit: 4_096)
        if isSafeScalar(normalizedValue) { return normalizedValue }
        return redactSensitiveText(normalizedValue)
    }

    private static func isSafeScalar(_ value: String) -> Bool {
        if ["true", "false", "none", "unknown", "available", "unavailable"].contains(value.lowercased()) {
            return true
        }
        guard !value.isEmpty else { return true }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789.+-").contains($0)
        }
    }

    private static func normalized(_ text: String, limit: Int) -> String {
        let flattened = text.unicodeScalars.map { scalar -> Character in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value < 0x20 {
                return " "
            }
            return Character(scalar)
        }
        return String(flattened.prefix(limit))
    }
}
