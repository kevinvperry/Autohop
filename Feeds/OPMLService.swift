import Foundation

public protocol OPMLServicing {
    func importSubscriptions(from fileURL: URL, existingFeedURLs: Set<URL>) async throws -> [URL]
    func exportSubscriptions(_ subscriptions: [Subscription]) throws -> Data
}

public final class OPMLService: OPMLServicing {
    public init() {}

    public func importSubscriptions(from fileURL: URL, existingFeedURLs: Set<URL>) async throws -> [URL] {
        let data = try Data(contentsOf: fileURL)
        let parser = OPMLParser(existingFeedURLs: existingFeedURLs)
        return try parser.parse(data: data)
    }

    public func exportSubscriptions(_ subscriptions: [Subscription]) throws -> Data {
        let sortedSubscriptions = subscriptions.sorted { $0.priorityRank < $1.priorityRank }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Autohop Subscriptions</title>
          </head>
          <body>

        """

        for subscription in sortedSubscriptions {
            xml += """
                <outline text="\(escape(subscription.title))" title="\(escape(subscription.title))" type="rss" xmlUrl="\(escape(subscription.feedURL.absoluteString))"/>

            """
        }

        xml += """
          </body>
        </opml>

        """

        guard let data = xml.data(using: .utf8) else {
            throw OPMLError.invalidDocument
        }
        return data
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum OPMLError: Error {
    case invalidDocument
}

private final class OPMLParser: NSObject, XMLParserDelegate {
    private let existingFeedURLs: Set<URL>
    private var importedFeedURLs: Set<URL> = []

    init(existingFeedURLs: Set<URL>) {
        self.existingFeedURLs = existingFeedURLs
    }

    func parse(data: Data) throws -> [URL] {
        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse() else {
            throw OPMLError.invalidDocument
        }

        return importedFeedURLs.sorted { lhs, rhs in
            lhs.absoluteString.localizedCaseInsensitiveCompare(rhs.absoluteString) == .orderedAscending
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "outline",
              let rawURL = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"],
              let url = URL(string: rawURL),
              existingFeedURLs.contains(url) == false
        else {
            return
        }

        importedFeedURLs.insert(url)
    }
}
