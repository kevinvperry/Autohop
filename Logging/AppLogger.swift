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
// "download.stalled", "sync.pushFailed", ...) — grep-friendly.
// WRITE MECHANISM (P4): a single append FileHandle is held open for the serial
// queue's lifetime (lazy appendHandle()) and reused per line instead of paying
// open+seek+close per entry. It is closed via closeHandle() before rotateIfNeeded
// moves the file and before clear() removes it, so the next write reopens the
// fresh log; all handle access stays on `queue`, so no lock is required. If
// opening succeeds but seek-to-end fails, appendHandle() closes the handle and
// returns nil rather than risking a write at the wrong offset.
// PUBLIC logging surface since tvOS Phase 1: the TV target imports AutohopCore
// as a library and must reach the shared diagnostic log. Internals stay internal.
public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()

    @Published private(set) var lastUpdated = Date()
    var isEnabled: Bool = false

    let logFileURL: URL

    private let queue = DispatchQueue(label: "com.autohop.diagnostic-log")
    /// Append handle held open for the queue's lifetime so a burst of log lines
    /// doesn't pay open+seek+close per entry (P4). Touched only on `queue`; closed
    /// and reopened lazily across rotation/clear. nil = not currently open.
    private var fileHandle: FileHandle?
    private let fileManager: FileManager
    private let maxFileSizeBytes = 5_000_000
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = (appSupport ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Autohop", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        logFileURL = directory.appendingPathComponent("autohop-diagnostic.log")
    }

    public func info(_ event: String, _ message: String, metadata: [String: String] = [:]) {
        write(level: "INFO", event: event, message: message, metadata: metadata)
    }

    public func warning(_ event: String, _ message: String, metadata: [String: String] = [:]) {
        write(level: "WARN", event: event, message: message, metadata: metadata)
    }

    /// - Parameter alwaysPersist: when true, the entry is written even if the
    ///   Diagnostics toggle is off. Reserve for errors a user would need a trace
    ///   of after the fact (e.g. iCloud sync failures). The file stays capped and
    ///   rotated, so these can't grow unbounded.
    public func error(_ event: String, _ message: String, metadata: [String: String] = [:], alwaysPersist: Bool = false) {
        write(level: "ERROR", event: event, message: message, metadata: metadata, force: alwaysPersist)
    }

    /// The single rotated (older) log segment produced by `rotateIfNeeded`. Defined
    /// once here so the rotation and the export always agree on the path.
    private var archivedLogFileURL: URL {
        logFileURL.deletingPathExtension().appendingPathExtension("previous.log")
    }

    /// Current log segment only — cheap, used by the live in-app viewer.
    func contents() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }

    /// The rotated (older) segment followed by the current one, oldest first, so a
    /// manual export spans the last two rotations rather than only the tail left after
    /// a mid-session rotation. The live viewer deliberately stays on `contents()` to
    /// avoid reading up to two full segments on every update.
    func combinedContents() -> String {
        let previous = (try? String(contentsOf: archivedLogFileURL, encoding: .utf8)) ?? ""
        let current = contents()
        if previous.isEmpty { return current }
        if current.isEmpty { return previous }
        let joiner = previous.hasSuffix("\n") ? "" : "\n"
        return previous + joiner + current
    }

    func redactedContents() -> String {
        Self.redactSensitiveText(combinedContents())
    }

    func redactedExportURL() -> URL {
        let exportURL = fileManager.temporaryDirectory.appendingPathComponent("autohop-diagnostic-redacted.log")
        let text = redactedContents()
        try? text.data(using: .utf8)?.write(to: exportURL, options: [.atomic])
        return exportURL
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
        queue.async { [weak self] in
            guard let self else { return }
            self.closeHandle()
            try? self.fileManager.removeItem(at: self.logFileURL)
            // Also drop the rotated segment, otherwise it would resurface in the next
            // export (which now stitches .previous.log + current) despite the clear.
            try? self.fileManager.removeItem(at: self.archivedLogFileURL)
            let resetLine = "\(self.dateFormatter.string(from: Date())) [INFO] log.cleared: Diagnostic log history cleared\n"
            try? self.fileManager.createDirectory(at: self.logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? resetLine.data(using: .utf8)?.write(to: self.logFileURL, options: [.atomic])
            DispatchQueue.main.async {
                self.lastUpdated = Date()
            }
        }
    }

    private func write(level: String, event: String, message: String, metadata: [String: String], force: Bool = false) {
        guard isEnabled || force else { return }
        let timestamp = dateFormatter.string(from: Date())
        let metadataText = metadata.isEmpty
            ? ""
            : " " + metadata
                .sorted { $0.key < $1.key }
                .map { key, value in
                    let oneLineValue = value.replacingOccurrences(of: "\n", with: " ")
                    return "\(key)=\(Self.redactSensitiveText(oneLineValue))"
                }
                .joined(separator: " ")
        let cleanMessage = Self.redactSensitiveText(message.replacingOccurrences(of: "\n", with: " "))
        let line = "\(timestamp) [\(level)] \(event): \(cleanMessage)\(metadataText)\n"

        queue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeeded(incomingBytes: line.utf8.count)
            if let data = line.data(using: .utf8), let handle = self.appendHandle() {
                try? handle.write(contentsOf: data)
            }
            DispatchQueue.main.async {
                self.lastUpdated = Date()
            }
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
            try handle.seekToEnd()
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
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let size = ((try? fileManager.attributesOfItem(atPath: logFileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size + incomingBytes > maxFileSizeBytes else { return }

        // Release the handle before moving the file so the next append reopens the
        // fresh (post-rotation) log rather than writing into the archived copy.
        closeHandle()
        let archivedURL = archivedLogFileURL
        try? fileManager.removeItem(at: archivedURL)
        try? fileManager.moveItem(at: logFileURL, to: archivedURL)
    }

    static func redactSensitiveText(_ text: String) -> String {
        var redacted = text
        // Strip URL query strings (signed CDN tokens commonly live here).
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(https?://[^\s?#]+)\?[^\s#]*"#,
            with: "$1?[redacted]",
            options: .regularExpression
        )
        // Strip URL fragments too — credentials occasionally arrive after `#`.
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(https?://[^\s#]+)#[^\s]+"#,
            with: "$1#[redacted]",
            options: .regularExpression
        )
        // Redact `key=value` credentials anywhere (query params, metadata values). The list covers
        // the common credential keys including auth/cookie/jwt locations Codex flagged.
        redacted = redacted.replacingOccurrences(
            of: #"(?i)((?:authorization|auth|access_token|refresh_token|token|api_key|apikey|x-api-key|key|secret|password|passwd|signature|sig|expires|policy|x-amz-signature|cookie|set-cookie|jwt)=)[^\s&]+"#,
            with: "$1[redacted]",
            options: .regularExpression
        )
        // Redact bearer tokens in Authorization-style strings (`Bearer <token>`).
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]+=*"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        return redacted
    }
}
