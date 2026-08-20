import Foundation

// AI CONTEXT — Privacy-minimal operational heartbeat written by the Top Shelf
// extension after each system load request and read by the containing app's
// Diagnostics screen. It contains no titles, episode identities, URLs or user
// content. This bounded record is the extension's only write; it never mutates
// the presentation snapshot or any product/domain state.

struct TVTopShelfExtensionDiagnostic: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case dynamicContentReturned
        case appGroupUnavailable
        case sharedDefaultsUnavailable
        case accountScopeMissing
        case manifestMissing
        case manifestInvalid
        case accountScopeMismatch
        case noRenderableContent
    }

    static let maximumEncodedBytes = 4_096
    static let filename = "extension-status.json"

    let recordedAt: Date
    let outcome: Outcome
    let generation: Int64?
    let sectionCount: Int
    let itemCount: Int
    let loadMilliseconds: Int
    let detailCode: String?
}
