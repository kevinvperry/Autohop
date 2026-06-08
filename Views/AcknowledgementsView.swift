import SwiftUI

struct AcknowledgementsView: View {

    var body: some View {
        List {
            Section {
                AcknowledgementRow(
                    name: "Pocket Casts for iOS",
                    author: "Automattic, Inc.",
                    licence: "Mozilla Public License, v. 2.0",
                    licenceURL: URL(string: "https://mozilla.org/MPL/2.0/"),
                    repoURL: URL(string: "https://github.com/Automattic/pocket-casts-ios"),
                    description: "The silence-trimming algorithm used in Autohop's audio engine (including RMS thresholds, gap detection, and fade logic) is ported from AudioReadTask.swift in the Pocket Casts iOS project. The vocal boost signal chain architecture is also based on Pocket Casts' EffectsPlayer.swift."
                )
            } header: {
                Text("Open Source Components")
            } footer: {
                Text("Autohop uses portions of the above open-source projects. Full licence texts and source code for covered files are included with the Autohop source distribution.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ReturnToPlayerButton()
            }
        }
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
