import Combine
import Foundation

// AI CONTEXT — Persistence/SettingsStore.swift
// Trivial persistence wrapper for the global AppSettings value: every didSet
// writes settings.json atomically to Application Support/Autohop/ with
// available-after-first-unlock protection so CarPlay can read Shared Listening
// state while the phone is locked. Injected into AppState as SettingsStoring
// (protocol exists for test substitution). Per-podcast settings do NOT live here
// — they're on Subscription in SubscriptionStore.
protocol SettingsStoring: AnyObject {
    var appSettings: AppSettings { get set }
    var appSettingsPublisher: AnyPublisher<AppSettings, Never> { get }
}

extension SettingsStoring {
    /// Test doubles and non-observable stores receive a stable initial snapshot.
    /// Production SettingsStore overrides this with its live @Published stream.
    var appSettingsPublisher: AnyPublisher<AppSettings, Never> {
        Just(appSettings).eraseToAnyPublisher()
    }
}

final class SettingsStore: ObservableObject, SettingsStoring {
    @Published var appSettings: AppSettings = .default {
        didSet { save() }
    }

    var appSettingsPublisher: AnyPublisher<AppSettings, Never> {
        $appSettings.eraseToAnyPublisher()
    }

    init() {
        load()
    }

    private struct Stored: Codable {
        var appSettings: AppSettings
    }

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }

        LockedDeviceFileAccess.applyToCarPlayCriticalFile(at: url)
        appSettings = stored.appSettings
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(Stored(appSettings: appSettings))
            try LockedDeviceFileAccess.writeDataAtomically(data, to: url)
        } catch {
            // In-memory state remains usable, but the change won't survive a
            // relaunch — log so a setting that silently reverts (e.g. iCloud sync
            // on/off) leaves a trace.
            AppLogger.shared.warning("settings.saveFailed", "Could not persist app settings", metadata: [
                "error": String(describing: error)
            ])
        }
    }

    private var fileURL: URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("Autohop/settings.json")
    }
}
