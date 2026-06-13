import SwiftUI

// AI CONTEXT — Views/SupportView.swift ("Support" / User Guide page, reached
// from the last item on the Menu sheet). Drill-down navigation: SupportView is
// a dark List of section rows (icon tile + title + one-line summary); tapping a
// row pushes SupportSectionView, which renders that section's SupportBlock list
// as native dark-themed components (paragraphs with Markdown bold, headings,
// bullet/numbered lists, tinted callouts, key-value & labelled tables, status
// pills, and Queue-style swipe-action cards). Content lives in
// SupportContent.swift (SupportGuide.sections) and MIRRORS the website Support
// page — edit both when support info changes. Pushed inside the Menu sheet's
// NavigationStack, so it uses the default back button like the other menu pages.

struct SupportView: View {
    var body: some View {
        List {
            Section {
                ForEach(SupportGuide.sections) { section in
                    NavigationLink {
                        SupportSectionView(section: section)
                    } label: {
                        SupportSectionRow(section: section)
                    }
                }
            } footer: {
                Text("Tap a topic to read the full guide. The same information is available at kevmarl.com.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerBar()
        .preferredColorScheme(.dark)
    }
}

// MARK: - List row

private struct SupportSectionRow: View {
    let section: SupportSection

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 38, height: 38)
                .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(section.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Section detail

private struct SupportSectionView: View {
    let section: SupportSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section header
                HStack(spacing: 12) {
                    Image(systemName: section.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.purple)
                        .frame(width: 44, height: 44)
                        .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
                    Text(section.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .padding(.bottom, 4)

                ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                    SupportBlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerBar()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Block renderer

private struct SupportBlockView: View {
    let block: SupportBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            SupportText(text)
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.75))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let text):
            Text(text)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("–")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.purple)
                        SupportText(item)
                            .font(.system(size: 15))
                            .foregroundStyle(Color(white: 0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .steps(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.purple)
                            .monospacedDigit()
                        SupportText(item)
                            .font(.system(size: 15))
                            .foregroundStyle(Color(white: 0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .callout(let style, let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(style.tint)
                SupportText(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(style.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.tint.opacity(0.3), lineWidth: 0.5))

        case .table(let headers, let rows):
            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    SupportTableRow(headers: headers, row: row)
                }
            }

        case .pills(let pills):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(pills) { pill in
                    HStack(spacing: 6) {
                        Circle().fill(pill.color).frame(width: 8, height: 8)
                        Text(pill.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.9))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(pill.color.opacity(0.18), in: Capsule())
                }
            }

        case .swipe(let rightTitle, let right, let leftTitle, let left):
            VStack(spacing: 10) {
                SupportSwipeCard(title: rightTitle, titleColor: Color(red: 0.09, green: 0.64, blue: 0.29), actions: right)
                SupportSwipeCard(title: leftTitle, titleColor: .purple, actions: left)
            }
        }
    }
}

// MARK: - Table row card

private struct SupportTableRow: View {
    let headers: [String]?
    let row: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SupportText(row.first ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(row.dropFirst().enumerated()), id: \.offset) { index, cell in
                if let headers, index + 1 < headers.count {
                    SupportText("**\(headers[index + 1]):** \(cell)")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SupportText(cell)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Swipe-action card

private struct SupportSwipeCard: View {
    let title: String
    let titleColor: Color
    let actions: [SupportSwipeAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(titleColor)

            ForEach(actions) { action in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(action.color).frame(width: 10, height: 10).padding(.top, 4)
                    SupportText("**\(action.label)** — \(action.detail)")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Markdown text helper

/// Renders a string with inline Markdown (**bold**) parsed at runtime.
private struct SupportText: View {
    private let attributed: AttributedString

    init(_ string: String) {
        attributed = (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }

    var body: some View {
        Text(attributed)
    }
}
