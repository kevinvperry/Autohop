import SwiftUI

// AI CONTEXT — Views/AcknowledgementsView.swift ("Acknowledgements" page,
// Settings → About). Static open-source credits list — most importantly the
// Pocket Casts for iOS (Automattic, MPL-2.0) derivation notice, which must
// stay consistent with NOTICE and LICENSE-MPL-2.0.md.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private var cardBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return Color.white.opacity(0.08)
    }

    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }

    private var formPageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    var body: some View {
        List {
            Section {
                AcknowledgementRow(
                    name: "Pocket Casts for iOS",
                    author: "Automattic, Inc.",
                    licence: "Mozilla Public License, v. 2.0",
                    licenceURL: URL(string: "https://mozilla.org/MPL/2.0/"),
                    repoURL: URL(string: "https://github.com/Automattic/pocket-casts-ios"),
                    description: "The silence-trimming algorithm used in Autohop's audio engine (including RMS thresholds, gap detection, and fade logic) is ported from AudioReadTask.swift in the Pocket Casts iOS project. The vocal boost signal chain architecture is also based on Pocket Casts' EffectsPlayer.swift. The @Synced field-level dirty-tracking wrapper used by Autohop's cross-device sync is ported from Pocket Casts' ModifiedDate property wrapper."
                )
            } header: {
                Text("Open Source Components")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Autohop uses portions of the above open-source projects. Full licence texts are included with Autohop.")
                    if let autohopRepo = URL(string: "https://github.com/kevinvperry/Autohop") {
                        Text("As required by the MPL-2.0, the source code of Autohop's modified versions of the covered files (SilenceDetector.swift, SilenceGapAccounting.swift, PlaybackEngine.swift, and Synced.swift) is published here:")
                        Link(destination: autohopRepo) {
                            Label("github.com/kevinvperry/Autohop", systemImage: "arrow.up.right.square")
                                .font(.footnote.weight(.medium))
                        }
                        .tint(.purple)
                    }
                }
                .font(.footnote)
            }
            .listRowBackground(cardBackground)
        }
        .scrollContentBackground(formScrollBackground)
        .background(formPageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
            }
        }
        .miniPlayerBar()
    }
}

// MARK: - Row

private struct AcknowledgementRow: View {
    let name: String
    let author: String
    let licence: String
    let licenceURL: URL?
    let repoURL: URL?
    let description: String

    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.body.weight(.semibold))
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LicenceBadge(text: "MPL-2.0")
            }

            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                if let repoURL {
                    Link(destination: repoURL) {
                        Label("Source", systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.medium))
                    }
                }
                if let licenceURL {
                    Link(destination: licenceURL) {
                        Label("Licence", systemImage: "doc.text")
                            .font(.footnote.weight(.medium))
                    }
                }
            }
            .tint(.purple)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Licence badge

private struct LicenceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.18), in: Capsule())
            .foregroundStyle(.purple)
    }
}
