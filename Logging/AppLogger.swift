import Foundation

// AI CONTEXT — Logging/AppLogger.swift
// Singleton diagnostic logger writing structured lines (ISO8601 timestamp,
// level, event key, message, key=value metadata) to autohop-diagnostic.log on
// a serial queue, capped at ~1 MB with truncation. isEnabled mirrors the
// hidden Diagnostics toggle (Settings → About → tap version 5×); when off,
// writes are no-ops. Read by DiagnosticLogView. Event keys are dot-namespaced
// ("background.schedule", "download.stalled", ...) — grep-friendly.
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var lastUpdated = Date()
    var isEnabled: Bool = false

    let logFileURL: URL

    private let queue = DispatchQueue(label: "com.autohop.diagnostic-log")
    private let fileManager: FileManager
    private let maxFileSizeBytes = 1_000_000
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

    func info(_ event: String, _ message: String, metadata: [String: String] = [:]) {
        write(level: "INFO", event: event, message: message, metadata: metadata)
    }

    func warning(_ event: String, _ message: String, metadata: [String: String] = [:]) {
        write(level: "WARN", event: event, message: message, metadata: metadata)
    }

    func error(_ event: String, _ message: String, metadata: [String: String] = [:]) {
        write(level: "ERROR", event: event, message: message, metadata: metadata)
    }

    func contents() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }

    func redactedContents() -> String {
        Self.redactSensitiveText(contents())
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
            try? self.fileManager.removeItem(at: self.logFileURL)
            let resetLine = "\(self.dateFormatter.string(from: Date())) [INFO] log.cleared: Diagnostic log history cleared\n"
            try? self.fileManager.createDirectory(at: self.logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? resetLine.data(using: .utf8)?.write(to: self.logFileURL, options: [.atomic])
            DispatchQueue.main.async {
                self.lastUpdated = Date()
            }
        }
    }

    private func write(level: String, event: String, message: String, metadata: [String: String]) {
        guard isEnabled else { return }
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
            if let data = line.data(using: .utf8) {
                if self.fileManager.fileExists(atPath: self.logFileURL.path),
                   let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                    defer { try? handle.close() }
                    do {
                        try handle.seekToEnd()
                    } catch {
                        return
                    }
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: self.logFileURL, options: [.atomic])
                }
            }
            DispatchQueue.main.async {
                self.lastUpdated = Date()
            }
        }
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let size = ((try? fileManager.attributesOfItem(atPath: logFileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size + incomingBytes > maxFileSizeBytes else { return }

        let archivedURL = logFileURL.deletingPathExtension().appendingPathExtension("previous.log")
        try? fileManager.removeItem(at: archivedURL)
        try? fileManager.moveItem(at: logFileURL, to: archivedURL)
    }

    static func redactSensitiveText(_ text: String) -> String {
        var redacted = text
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(https?://[^\s?]+)\?[^\s]+"#,
            with: "$1?[redacted]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)((?:auth|token|access_token|api_key|apikey|key|signature|sig|expires|policy|x-amz-signature)=)[^\s&]+"#,
            with: "$1[redacted]",
            options: .regularExpression
        )
        return redacted
    }
}
