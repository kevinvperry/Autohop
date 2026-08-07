import SwiftUI
import AutohopCore

// AI CONTEXT — One shared Apple TV presentation for full episode show notes.
// Episode lists raise this through their standard long-press context menu;
// audio and native-video players expose an explicit Description control. The
// sheet is intentionally read-only and receives an already-resolved Episode:
// it never fetches a feed, owns playback, or introduces a second sync model.

struct TVEpisodeDescriptionItem: Identifiable, Equatable {
    let episode: Episode
    let podcastTitle: String?
    var id: UUID { episode.id }
}

struct TVEpisodeDescriptionView: View {
    let item: TVEpisodeDescriptionItem
    @Environment(\.dismiss) private var dismiss

    private var descriptionText: String {
        TVEpisodeDescriptionText.plainText(from: item.episode.description)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(item.episode.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    if let podcastTitle = item.podcastTitle,
                       !podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(podcastTitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    if descriptionText.isEmpty {
                        ContentUnavailableView(
                            "Description unavailable",
                            systemImage: "text.page.slash",
                            description: Text("This publisher did not include episode notes in the podcast feed.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        Text(descriptionText)
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 1_250, alignment: .leading)
                .padding(.horizontal, 90)
                .padding(.vertical, 70)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Episode Description")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

extension View {
    func tvEpisodeDescriptionSheet(
        item: Binding<TVEpisodeDescriptionItem?>
    ) -> some View {
        sheet(item: item) { TVEpisodeDescriptionView(item: $0) }
    }
}

enum TVEpisodeDescriptionText {
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
            "&ndash;": "–", "&mdash;": "—", "&hellip;": "…"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
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
