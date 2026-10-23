import Foundation

/// Transport selection only: the canonical enclosure remains the episode identity.
public enum DownloadDelivery {
    case direct
    case luxembourg(endpoint: URL, token: String)

    public var isRelay: Bool {
        if case .luxembourg = self { return true }
        return false
    }

    public func request(for source: URL) throws -> URLRequest {
        switch self {
        case .direct:
            var request = URLRequest(url: source)
            PodcastUserAgent.identify(&request)
            return request
        case .luxembourg(let endpoint, let token):
            guard endpoint.scheme == "https", endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil,
                  !token.isEmpty, !token.contains("\r"), !token.contains("\n"),
                  token.utf8.count <= 512 else { throw RelayDownloadError.notConfigured }
            guard source.scheme == "https" || source.scheme == "http",
                  source.host != nil, source.user == nil, source.password == nil,
                  source.absoluteString.utf8.count <= 8_192 else {
                throw RelayDownloadError.ineligible
            }
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/audio"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Keep publisher URLs out of reverse-proxy access-log request lines.
            request.setValue(Data(source.absoluteString.utf8).base64EncodedString(), forHTTPHeaderField: "X-Autohop-Source")
            PodcastUserAgent.identify(&request)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }
    }

    public static func validateRelayResponse(_ response: URLResponse?, requestURL: URL? = nil) -> Bool {
        guard let response = response as? HTTPURLResponse,
              let requestURL, response.url == requestURL else { return false }
        return response.statusCode == 200
            && response.value(forHTTPHeaderField: "X-Autohop-Relay") == "lu-v1"
    }
}

public enum RelayDownloadError: Error, LocalizedError {
    case notConfigured, ineligible, unavailable, unsupported
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up the Luxembourg relay in App Settings before downloading with ad reduction."
        case .ineligible: return "This episode cannot be sent through the relay. Download it normally instead."
        case .unavailable: return "Ad-reduced download unavailable. Retry, or turn off ad reduction for this show to download normally."
        case .unsupported: return "This download service does not support ad reduction."
        }
    }
}

/// Saved next to the actual media, including completions delivered after app relaunch.
public struct DownloadDeliveryReceipt: Codable {
    public let method: String
    public let configurationVersion: Int
    public let completedAt: Date
    public static func url(for file: URL) -> URL { file.appendingPathExtension("delivery.json") }
    public static func read(for file: URL) -> DownloadDeliveryReceipt? {
        guard let data = try? Data(contentsOf: url(for: file)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func write(for file: URL, relay: Bool) throws {
        let receipt = Self(method: relay ? "luxembourg" : "direct", configurationVersion: 1, completedAt: Date())
        try JSONEncoder().encode(receipt).write(to: url(for: file), options: .atomic)
    }
}
