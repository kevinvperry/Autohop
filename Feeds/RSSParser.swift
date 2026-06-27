import Foundation

// AI CONTEXT — Feeds/RSSParser.swift
// XMLParser-based RSS/podcast feed parser → ParsedFeed/ParsedEpisode values.
// Handles itunes:* tags, enclosure media kind detection (audio vs video),
// duration formats, chapters (podcast:chapters external URL), explicit flags.
// pubDate → absolute Date via parseDate: ISO8601 then RFC822 formatters (numeric
// offsets + `zzz`), with a named-zone fallback table (GMT/AEST/BST/CET/JST/NZST…);
// genuinely ambiguous abbreviations (IST, CST) are deliberately omitted.
// maxEpisodes short-circuits parsing (didReachEpisodeLimit aborts the parse
// but is NOT an error). Pre-pass dataByEscapingBareAmpersands() repairs the
// most common real-world feed defect — unescaped "&" — by escaping any
// ampersand that doesn't start a known or numeric entity, since XMLParser
// hard-fails on bare ampersands. Pure logic, no networking; covered by
// Tests/RSSParserTests and the RSSParserSmoke target.
public final class RSSParser: NSObject {
    public override init() {}

    public func parse(data: Data, maxEpisodes: Int? = nil) throws -> ParsedFeed {
        let delegate = RSSParserDelegate(maxEpisodes: maxEpisodes)
        let parser = XMLParser(data: Self.dataByEscapingBareAmpersands(in: data))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() || delegate.didReachEpisodeLimit else {
            throw RSSParserError.invalidXML(parser.parserError)
        }

        return try delegate.buildFeed()
    }

    // Internal (not private) so the linear-time guarantee can be unit-tested directly without
    // routing a pathologically large single text node through XMLParser.
    static func dataByEscapingBareAmpersands(in data: Data) -> Data {
        let ampersand = UInt8(ascii: "&")
        // Fast path: nothing to repair.
        guard data.contains(ampersand) else { return data }

        let semicolon = UInt8(ascii: ";")
        let hash = UInt8(ascii: "#")
        let knownEntities: Set<[UInt8]> = [
            Array("amp".utf8), Array("lt".utf8), Array("gt".utf8),
            Array("quot".utf8), Array("apos".utf8)
        ]
        // Longest thing we treat as an entity name: a numeric ref like "#x10FFFF" (8) or the named
        // entities (≤4). A bounded look-ahead keeps the whole pass O(n).
        //
        // This works on UTF-8 BYTES, not Swift `Character`s, deliberately: the previous version
        // mutated the source String with removeSubrange on every ampersand (O(n²)); iterating it as
        // a `Character` collection instead is also pathologically slow on large feeds (grapheme
        // breaking + index arithmetic per scalar). Byte indexing is O(1) with tiny constants, and
        // ASCII `&`/`;`/`#` can't appear inside a multi-byte UTF-8 sequence, so byte scanning is safe.
        let maxEntityNameLength = 9

        let bytes = [UInt8](data)
        let count = bytes.count
        let ampReplacement = Array("&amp;".utf8)
        var output = [UInt8]()
        output.reserveCapacity(count + 16)

        var i = 0
        while i < count {
            let byte = bytes[i]
            guard byte == ampersand else {
                output.append(byte)
                i += 1
                continue
            }

            // Look ahead a bounded distance for the terminating ';'.
            let limit = min(count, i + 1 + maxEntityNameLength)
            var semicolonIndex = -1
            var j = i + 1
            while j < limit {
                if bytes[j] == semicolon { semicolonIndex = j; break }
                j += 1
            }
            if semicolonIndex >= 0 {
                let entity = Array(bytes[(i + 1)..<semicolonIndex])
                if entity.first == hash || knownEntities.contains(entity) {
                    output.append(ampersand) // already a valid entity — leave it intact
                    i += 1
                    continue
                }
            }

            output.append(contentsOf: ampReplacement)
            i += 1
        }

        return Data(output)
    }
}

enum RSSParserError: Error, LocalizedError {
    case invalidXML(Error?)
    case missingChannelTitle

    var errorDescription: String? {
        switch self {
        case .invalidXML:
            return "The podcast feed could not be read."
        case .missingChannelTitle:
            return "The podcast feed is missing a title."
        }
    }
}

private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    private let maxEpisodes: Int?
    private var elementStack: [String] = []
    private var textBuffer = ""
    private var channelTitle: String?
    private var channelDescription: String?
    private var channelAuthor: String?
    private var channelArtworkURL: URL?
    private var channelCategories: [String] = []
    private var channelIsExplicit: Bool?
    private var currentItem: EpisodeAccumulator?
    private var items: [EpisodeAccumulator] = []
    private var chapterPosition = 0
    private(set) var didReachEpisodeLimit = false

    init(maxEpisodes: Int?) {
        self.maxEpisodes = maxEpisodes
        super.init()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        elementStack.append(name)
        textBuffer = ""

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "item", local: "item") {
            currentItem = EpisodeAccumulator()
            chapterPosition = 0
        }

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "itunes:image", local: "image", namespace: "http://www.itunes.com/dtds/podcast-1.0.dtd"),
           let href = attributeDict["href"],
           let url = Self.url(from: href) {
            if currentItem != nil {
                currentItem?.artworkURL = url
            } else {
                channelArtworkURL = url
            }
        }

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "itunes:category", local: "category", namespace: "http://www.itunes.com/dtds/podcast-1.0.dtd"),
           currentItem == nil,
           let text = attributeDict["text"], !text.isEmpty,
           !channelCategories.contains(text) {
            channelCategories.append(text)
        }

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "enclosure", local: "enclosure"),
           currentItem != nil {
            captureMediaURL(attributes: attributeDict)
        }

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "media:content", local: "content", namespace: "http://search.yahoo.com/mrss/"),
           currentItem != nil {
            captureMediaURL(attributes: attributeDict)
        }

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "podcast:chapters", local: "chapters", namespace: "https://podcastindex.org/namespace/1.0"),
           currentItem != nil {
            currentItem?.externalChaptersURL = attributeDict["url"].flatMap(Self.url(from:))
        }

        if Self.matches(name, localName: elementName, namespaceURI: namespaceURI, qualified: "psc:chapter", local: "chapter", namespace: "http://podlove.org/simple-chapters"),
           currentItem != nil {
            chapterPosition += 1
            guard let title = attributeDict["title"],
                  let start = attributeDict["start"],
                  let startSeconds = Self.parseTimecode(start)
            else {
                return
            }
            let durationSeconds = attributeDict["duration"].flatMap(Self.parseTimecode)
            let chapter = ParsedChapter(
                position: chapterPosition,
                title: Self.decodingEntities(title),
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                source: .pscChapters
            )
            currentItem?.chapters.append(chapter)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            _ = elementStack.popLast()
            textBuffer = ""
        }

        if currentItem != nil {
            captureItemText(name: name, text: text)
        } else {
            captureChannelText(name: name, text: text)
        }

        if name == "item", let item = currentItem {
            items.append(item)
            currentItem = nil
            if let maxEpisodes, items.count >= maxEpisodes {
                didReachEpisodeLimit = true
                parser.abortParsing()
            }
        }
    }

    func buildFeed() throws -> ParsedFeed {
        guard let channelTitle else {
            throw RSSParserError.missingChannelTitle
        }

        return ParsedFeed(
            title: channelTitle,
            description: channelDescription,
            author: channelAuthor,
            artworkURL: channelArtworkURL,
            categories: channelCategories,
            isExplicit: channelIsExplicit,
            latestEpisode: items.first?.parsedEpisode,
            episodes: items.map(\.parsedEpisode)
        )
    }

    private func captureChannelText(name: String, text: String) {
        guard !text.isEmpty else { return }

        switch name {
        case "title":
            if channelTitle == nil {
                channelTitle = Self.decodingEntities(text)
            }
        case "description":
            if channelDescription == nil {
                channelDescription = Self.decodingEntities(text)
            }
        case "itunes:summary":
            if channelDescription == nil {
                channelDescription = Self.decodingEntities(text)
            }
        case "itunes:author", "author":
            if channelAuthor == nil {
                channelAuthor = Self.decodingEntities(text)
            }
        case "itunes:explicit":
            if channelIsExplicit == nil {
                channelIsExplicit = Self.parseExplicit(text)
            }
        default:
            break
        }
    }

    private func captureItemText(name: String, text: String) {
        guard !text.isEmpty else { return }

        switch name {
        case "guid":
            currentItem?.guid = text
        case "link":
            // Episode web page (show-notes/permalink). Some feeds repeat <link>
            // inside <item> for atom:link alternates — keep the first usable one.
            if currentItem?.episodeLink == nil, let url = Self.url(from: text),
               url.scheme == "http" || url.scheme == "https" {
                currentItem?.episodeLink = url
            }
        case "title":
            currentItem?.title = Self.decodingEntities(text)
        case "description", "content:encoded":
            if currentItem?.description == nil {
                currentItem?.description = Self.decodingEntities(text)
            }
        case "itunes:subtitle":
            currentItem?.subtitle = Self.decodingEntities(text)
        case "itunes:author", "author":
            currentItem?.author = Self.decodingEntities(text)
        case "pubDate":
            currentItem?.publishedAt = Self.parseDate(text)
        case "itunes:duration", "duration":
            currentItem?.durationSeconds = Self.parseDuration(text)
        case "itunes:explicit":
            currentItem?.isExplicit = Self.parseExplicit(text)
        default:
            break
        }
    }

    private func captureMediaURL(attributes: [String: String]) {
        guard let rawURL = attributes["url"],
              let url = Self.url(from: rawURL)
        else { return }

        let type = attributes["type"]?.lowercased() ?? ""
        if let playableKind = Self.playableMediaKind(for: url, mimeType: type) {
            if currentItem?.audioURL == nil {
                currentItem?.audioURL = url
                currentItem?.mediaKind = playableKind
            }
            // Capture the byte size from whichever playable element provides it
            // for the chosen URL — <enclosure> is authoritative and carries the
            // length, while a <media:content> for the same file often omits it
            // (and may appear first). Ignore zero/absent lengths (e.g. an image
            // enclosure with length="0").
            if currentItem?.audioURL == url, currentItem?.fileSizeBytes == nil,
               let length = attributes["length"].flatMap(Int64.init), length > 0 {
                currentItem?.fileSizeBytes = length
            }
        } else if Self.isImageURL(url, mimeType: type), currentItem?.artworkURL == nil {
            currentItem?.artworkURL = url
        }
    }

    private static func url(from value: String) -> URL? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("&amp;") {
            normalized = normalized.replacingOccurrences(of: "&amp;", with: "&")
        }
        return URL(string: normalized)
    }

    private static func isAudioURL(_ url: URL, mimeType: String) -> Bool {
        if mimeType.hasPrefix("audio/") { return true }
        let ext = url.pathExtension.lowercased()
        return ["aac", "aiff", "flac", "m4a", "m4b", "mp3", "oga", "ogg", "wav"].contains(ext)
    }

    private static func isVideoURL(_ url: URL, mimeType: String) -> Bool {
        if mimeType.hasPrefix("video/") { return true }
        let ext = url.pathExtension.lowercased()
        return ["m4v", "mov", "mp4"].contains(ext)
    }

    private static func playableMediaKind(for url: URL, mimeType: String) -> EpisodeMediaKind? {
        if isAudioURL(url, mimeType: mimeType) {
            return .audio
        }
        if isVideoURL(url, mimeType: mimeType) {
            return .video
        }
        return nil
    }

    private static func isImageURL(_ url: URL, mimeType: String) -> Bool {
        if mimeType.hasPrefix("image/") { return true }
        let ext = url.pathExtension.lowercased()
        return ["gif", "jpeg", "jpg", "png", "webp"].contains(ext)
    }

    // DateFormatter / ISO8601DateFormatter allocation is expensive, and parseDate
    // runs once per episode — negligible for a 50-item refresh but costly on a
    // full-history load (hundreds of episodes). Cache them as statics. We use one
    // fixed formatter per format string (never mutating dateFormat) so the cache
    // is safe to share across concurrent feed parses.

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let rfc822DateFormatters: [DateFormatter] = {
        let formats = [
            "E, d MMM yyyy HH:mm:ss Z",
            "E, d MMM yyyy HH:mm:ss zzz",
            "E, dd MMM yyyy HH:mm:ss Z",
            "E, dd MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = isoFormatterWithFractionalSeconds.date(from: trimmed) {
            return date
        }
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        for formatter in rfc822DateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        if let normalized = dateByReplacingTimezoneAbbreviation(in: trimmed) {
            for formatter in rfc822DateFormatters {
                if let date = formatter.date(from: normalized) {
                    return date
                }
            }
        }

        return nil
    }

    private static func dateByReplacingTimezoneAbbreviation(in value: String) -> String? {
        let parts = value.split(separator: " ")
        guard let timezone = parts.last.map(String.init) else { return nil }

        let offsets = [
            "UT": "+0000",
            "UTC": "+0000",
            "GMT": "+0000",
            "EST": "-0500",
            "EDT": "-0400",
            "CST": "-0600",
            "CDT": "-0500",
            "MST": "-0700",
            "MDT": "-0600",
            "PST": "-0800",
            "PDT": "-0700",
            "AEST": "+1000",
            "AEDT": "+1100",
            "ACST": "+0930",
            "ACDT": "+1030",
            "AWST": "+0800",
            // Europe
            "BST": "+0100",   // British Summer Time (the dominant feed use of "BST")
            "WET": "+0000",
            "WEST": "+0100",
            "CET": "+0100",
            "CEST": "+0200",
            "EET": "+0200",
            "EEST": "+0300",
            // Asia / Pacific / Africa
            "JST": "+0900",
            "KST": "+0900",
            "HKT": "+0800",
            "SGT": "+0800",
            "SAST": "+0200",
            "NZST": "+1200",
            "NZDT": "+1300"
            // NOTE: ambiguous abbreviations (e.g. "IST" = India/Irish/Israel, "CST" =
            // US Central/China) are deliberately omitted — a wrong offset is worse than a
            // parse failure. Feeds overwhelmingly use numeric offsets (+HHMM) anyway.
        ]

        guard let offset = offsets[timezone.uppercased()] else { return nil }
        return String(value.dropLast(timezone.count)) + offset
    }

    private static func parseDuration(_ value: String) -> TimeInterval? {
        if let numeric = TimeInterval(value) {
            return validDuration(numeric)
        }
        return parseTimecode(value).flatMap(validDuration)
    }

    private static func validDuration(_ duration: TimeInterval) -> TimeInterval? {
        duration.isFinite && duration >= 0 ? duration : nil
    }

    /// Decodes HTML/XML character entities one pass. XMLParser already decodes a
    /// single layer of entities, so this exists to repair **double-encoded** feeds
    /// (e.g. Omny/Megaphone emitting `&amp;amp;`), which arrive here as a literal
    /// `&amp;`. A single pass turns that into `&` while leaving already-correct
    /// text untouched (no entities left to decode). Applied only to display fields
    /// (title/subtitle/author/description) — never to guid, dates, or URLs.
    static func decodingEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        result.reserveCapacity(string.count)
        var index = string.startIndex
        while index < string.endIndex {
            let char = string[index]
            if char == "&",
               let semicolon = string[index...].firstIndex(of: ";"),
               string.distance(from: index, to: semicolon) <= 12 {
                let entity = String(string[string.index(after: index)..<semicolon])
                if let decoded = decodeEntity(entity) {
                    result.append(decoded)
                    index = string.index(after: semicolon)
                    continue
                }
            }
            result.append(char)
            index = string.index(after: index)
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity.lowercased() {
        case "amp":  return "&"
        case "lt":   return "<"
        case "gt":   return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            // Numeric entities: &#39; (decimal) and &#x27; (hex).
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                guard let code = UInt32(entity.dropFirst(2), radix: 16),
                      let scalar = Unicode.Scalar(code) else { return nil }
                return Character(scalar)
            }
            if entity.hasPrefix("#") {
                guard let code = UInt32(entity.dropFirst(1)),
                      let scalar = Unicode.Scalar(code) else { return nil }
                return Character(scalar)
            }
            return nil
        }
    }

    private static func parseExplicit(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "explicit":
            return true
        case "no", "false", "clean":
            return false
        default:
            return nil
        }
    }

    private static func parseTimecode(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").map(String.init)
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count,
              numbers.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }

        switch numbers.count {
        case 3:
            return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        case 2:
            return numbers[0] * 60 + numbers[1]
        case 1:
            return numbers[0]
        default:
            return nil
        }
    }

    private static func matches(
        _ qualifiedName: String,
        localName: String,
        namespaceURI: String?,
        qualified: String,
        local: String,
        namespace: String? = nil
    ) -> Bool {
        if qualifiedName == qualified { return true }
        guard localName == local else { return false }
        guard let namespace else { return true }
        return namespaceURI == namespace || namespaceURI == nil
    }
}

private struct EpisodeAccumulator {
    var guid: String?
    var title: String?
    var description: String?
    var subtitle: String?
    var author: String?
    var publishedAt: Date?
    var durationSeconds: TimeInterval?
    var audioURL: URL?
    var episodeLink: URL?
    var mediaKind: EpisodeMediaKind = .audio
    var artworkURL: URL?
    var fileSizeBytes: Int64?
    var isExplicit: Bool?
    var chapters: [ParsedChapter] = []
    var externalChaptersURL: URL?

    var parsedEpisode: ParsedEpisode {
        ParsedEpisode(
            guid: guid ?? title ?? UUID().uuidString,
            title: title ?? "Untitled Episode",
            description: description,
            subtitle: subtitle,
            author: author,
            publishedAt: publishedAt,
            durationSeconds: durationSeconds,
            audioURL: audioURL,
            episodeLink: episodeLink,
            mediaKind: mediaKind,
            artworkURL: artworkURL,
            fileSizeBytes: fileSizeBytes,
            isExplicit: isExplicit,
            chapters: chapters,
            externalChaptersURL: externalChaptersURL
        )
    }
}
