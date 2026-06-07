import Foundation

protocol SettingsStoring: AnyObject {
    var appSettings: AppSettings { get set }
}

final class SettingsStore: ObservableObject, SettingsStoring {
    @Published var appSettings: AppSettings = .default {
        didSet { save() }
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

        appSettings = stored.appSettings
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(appSettings: appSettings))
            try data.write(to: url, options: [.atomic])
        } catch {
            // In-memory state remains usable.
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
