import Foundation

// AI CONTEXT — Feeds/HTTPResponseValidation.swift
// Shared HTTP response gate for the app's network clients (feed refresh, iTunes
// search/charts/lookup, preview feed, external chapters, notification artwork).
// These clients used to parse/attach whatever body came back regardless of the
// HTTP status, so a 404/500 HTML error or captive-portal page could be treated as
// valid data. This validates the status once, in one place. Lives in AutohopCore
// so it is unit-testable and reusable from the app target.

public enum HTTPResponseError: Error, Equatable {
    /// A non-success HTTP status was returned (e.g. 404, 500).
    case unacceptableStatus(Int)
}

public enum HTTPResponseValidation {
    /// Throws `HTTPResponseError.unacceptableStatus` when `response` is a non-success HTTP
    /// response. `304 Not Modified` is accepted so conditional-GET callers can handle it
    /// themselves. A non-HTTP response (no `HTTPURLResponse`) passes — there is nothing to check.
    public static func validate(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 304 { return }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPResponseError.unacceptableStatus(http.statusCode)
        }
    }

    /// Convenience for `try?`-style call sites: returns `true` when the response is acceptable.
    public static func isAcceptable(_ response: URLResponse?) -> Bool {
        (try? validate(response)) != nil
    }
}
