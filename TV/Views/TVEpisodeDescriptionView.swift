import SwiftUI
import AutohopCore

// AI CONTEXT — One shared Apple TV presentation for full episode show notes.
// Episode lists raise this through their standard long-press context menu;
// audio and native-video players expose an explicit Description control. The
// reader is intentionally read-only and receives an already-resolved Episode:
// it never fetches a feed, owns playback, or introduces a second sync model.

struct TVEpisodeDescriptionItem: Identifiable, Equatable {
    let episode: Episode
    let podcastTitle: String?
    var id: UUID { episode.id }
}

struct TVEpisodeDescriptionView: View {
    let item: TVEpisodeDescriptionItem
    let resolveEpisode: (Episode) async -> Episode
    let onDismiss: () -> Void
    @State private var resolvedEpisode: Episode
    @State private var isResolving = false

    init(
        item: TVEpisodeDescriptionItem,
        resolveEpisode: @escaping (Episode) async -> Episode,
        onDismiss: @escaping () -> Void
    ) {
        self.item = item
        self.resolveEpisode = resolveEpisode
        self.onDismiss = onDismiss
        _resolvedEpisode = State(initialValue: item.episode)
    }

    private var descriptionText: String {
        TVEpisodeDescriptionText.plainText(from: resolvedEpisode.description)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 30) {
                        Text("Episode Description")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Done", action: onDismiss)
                            .buttonStyle(.borderedProminent)
                    }

                    Text(resolvedEpisode.title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    if let podcastTitle = item.podcastTitle,
                       !podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(podcastTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    if isResolving {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Loading the publisher's episode description…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else if descriptionText.isEmpty {
                        ContentUnavailableView(
                            "Description unavailable",
                            systemImage: "text.page.slash",
                            description: Text("This publisher did not include episode notes in the podcast feed.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        Text(descriptionText)
                            .font(.callout)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 1_520, alignment: .leading)
                .padding(.horizontal, 70)
                .padding(.vertical, 55)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onDismiss)
        .task(id: item.id) {
            guard !TVEpisodeDescriptionText.hasMeaningfulDescription(resolvedEpisode) else {
                return
            }
            isResolving = true
            resolvedEpisode = await resolveEpisode(resolvedEpisode)
            isResolving = false
        }
    }
}

extension View {
    func tvEpisodeDescriptionSheet(
        item: Binding<TVEpisodeDescriptionItem?>,
        resolveEpisode: @escaping (Episode) async -> Episode
    ) -> some View {
        fullScreenCover(item: item) { presentedItem in
            TVEpisodeDescriptionView(
                item: presentedItem,
                resolveEpisode: resolveEpisode,
                onDismiss: { item.wrappedValue = nil }
            )
        }
    }
}

enum TVEpisodeDescriptionText {
    /// Compact queue/history payloads from older builds sometimes put the
    /// episode title into the description slot. Treat that as missing notes so
    /// the shared sheet asks the publisher feed for the real summary.
    static func hasMeaningfulDescription(_ episode: Episode) -> Bool {
        let description = plainText(from: episode.description)
        guard !description.isEmpty else { return false }
        return normalized(description) != normalized(episode.title)
    }

    /// RSS descriptions frequently contain HTML. tvOS needs a stable reading
    /// surface rather than WebKit-backed layout, so preserve paragraph/list
    /// boundaries, strip tags and decode common/numeric entities synchronously.
    static func plainText(from source: String?) -> String {
        guard var text = source, !text.isEmpty else { return "" }
        text = text.replacingOccurrences(
            of: #"(?i)<\s*(br|/p|/div|/li|/h[1-6])\s*/?>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)<\s*li(?:\s[^>]*)?>"#,
            with: "\n• ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )

        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”",
            "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
            "&bull;": "•", "&middot;": "·", "&copy;": "©", "&reg;": "®",
            "&trade;": "™", "&laquo;": "«", "&raquo;": "»"
        ]
        // Two passes also decodes common double-escaped publisher text such as
        // `&amp;rsquo;` without involving a WebKit view.
        for _ in 0..<2 {
            for (entity, replacement) in entities {
                text = text.replacingOccurrences(of: entity, with: replacement)
            }
        }
        text = decodeNumericEntities(in: text)
        text = text.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func decodeNumericEntities(in source: String) -> String {
        let pattern = #"&#(x[0-9A-Fa-f]+|[0-9]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        for match in regex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ).reversed() {
            guard let range = Range(match.range, in: source),
                  let valueRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            let token = String(source[valueRange])
            let value = token.lowercased().hasPrefix("x")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token, radix: 10)
            if let value, let scalar = UnicodeScalar(value) {
                result.replaceSubrange(range, with: String(scalar))
            }
        }
        return result
    }
}
