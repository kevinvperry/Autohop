import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/OPMLDocument.swift. Trivial FileDocument wrapper so
// SettingsView/MenuSheetView can hand OPMLService.export data to
// SwiftUI's .fileExporter (default name autohop-subscriptions.opml).

/// A SwiftUI FileDocument wrapping OPML export data for use with .fileExporter.
struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }

    var data: Data

    init(_ data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
