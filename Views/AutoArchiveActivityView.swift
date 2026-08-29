import SwiftUI

// AI CONTEXT — Auto Archive Activity is the user-visible audit surface for
// automatic archive decisions, including never-listened inactive episodes that
// correctly do not qualify for Listening History. Data comes from the durable,
// device-local AutoArchiveActivityStore and is newest-first. Each row must expose
// all decision evidence: episode, podcast, exact archive timestamp, rule,
// configured threshold, and measured age when the rule fired. The inner card
// stack uses adaptivePageContent so its readable width and screen-edge gutter
// respond to the offered container while the ScrollView and background remain
// full width.

struct AutoArchiveActivityView: View {
    @EnvironmentObject private var activityStore: AutoArchiveActivityStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if activityStore.entries.isEmpty {
                    ContentUnavailableView(
                        "No Auto Archive Activity",
                        systemImage: "archivebox",
                        description: Text("Automatic archive decisions will appear here after a rule archives an episode.")
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(activityStore.entries) { entry in
                        AutoArchiveActivityRow(entry: entry)
                    }
                }
            }
            .padding(.vertical, 18)
            .episodeListPageWidth()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Auto Archive Activity")
        .responsiveInlineNavigationTitle("Auto Archive Activity")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationBackButton()
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
    }
}

private struct AutoArchiveActivityRow: View {
    @Environment(\.adaptiveViewportWidth) private var viewportWidth
    let entry: AutoArchiveActivity

    var body: some View {
        let metrics = AdaptiveListRowMetrics(containerWidth: viewportWidth)
        VStack(alignment: .leading, spacing: max(10, metrics.rowSpacing)) {
            Text(entry.episodeTitle)
                .font(.system(size: metrics.primaryFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.podcastTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().overlay(Color.white.opacity(0.12))

            activityField("Archived", value: entry.archivedAt.formatted(date: .abbreviated, time: .shortened))
            activityField("Rule", value: entry.rule.title)
            activityField("Configured threshold", value: entry.configuredThreshold)
            activityField("Measured age", value: Self.duration(entry.measuredAgeSeconds))
        }
        .padding(16 + metrics.verticalPadding - 6)
        .glassCard(cornerRadius: 16)
    }

    private func activityField(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
