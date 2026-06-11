import SwiftUI
import Charts

// MARK: - StatsView

struct StatsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        StatsContentView(
            store: appState.listeningStatsStore,
            historyStore: appState.listeningHistoryStore
        )
    }
}

private enum StatsRange: String, CaseIterable, Identifiable {
    case days30 = "30 Days"
    case days90 = "90 Days"
    case year = "1 Year"
    case allTime = "All Time"

    var id: String { rawValue }

    var period: StatsPeriod {
        switch self {
        case .days30: return .last(days: 30)
        case .days90: return .last(days: 90)
        case .year: return .last(days: 365)
        case .allTime: return .lifetime
        }
    }
}

private struct StatsContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: ListeningStatsStore
    @ObservedObject var historyStore: ListeningHistoryStore
    @State private var range: StatsRange = .days30
    @State private var driftShowToUnsubscribe: ShowEngagement?
    @State private var showDriftUnsubscribeConfirm = false
    /// Comma-joined subscription UUIDs the user muted from the drifting list.
    @AppStorage("stats.hiddenDriftShowIDs") private var hiddenDriftShowIDsRaw: String = ""

    var body: some View {
        let summary = store.summary(for: range.period)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                rangeSelector

                heroCard(summary)

                if range == .days30 || range == .days90 {
                    heatmapSection(summary)
                } else {
                    trendSection(summary)
                }

                clockSection(summary)
                topShowsSection(summary)
                driftingShowsSection
                timeSavedSection(summary)

                privacyFooter
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ReturnToPlayerButton()
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Unsubscribe from \(driftShowToUnsubscribe?.title ?? "this podcast")?",
            isPresented: $showDriftUnsubscribeConfirm,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                if let show = driftShowToUnsubscribe {
                    appState.subscriptionStore.remove(subscriptionID: show.subscriptionID)
                }
                driftShowToUnsubscribe = nil
            }
        } message: {
            Text("Your settings for this podcast will be deleted. Downloaded episodes are not removed.")
        }
    }

    // MARK: - Range selector

    private var rangeSelector: some View {
        StatsRangeSelector(range: $range)
    }

    // MARK: - Hero card

    private func heroCard(_ summary: ListeningStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(formattedLongDuration(summary.wallClockSeconds))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.purple)
                    .contentTransition(.numericText())
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(alignment: .top, spacing: 12) {
                heroStat(
                    value: formattedLongDuration(summary.totalTimeSaved),
                    label: "saved by Autohop",
                    tint: .teal
                )
                heroStat(
                    value: "\(summary.episodesCompleted)",
                    label: "episodes finished",
                    tint: .primary
                )
                heroStat(
                    value: streakLabel(store.currentStreakDays),
                    label: "current streak",
                    tint: .primary
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var heroSubtitle: String {
        switch range {
        case .allTime:
            return "Time listened since \(store.startedAt.formatted(date: .abbreviated, time: .omitted))"
        default:
            return "Time listened"
        }
    }

    private func heroStat(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func streakLabel(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    // MARK: - Heatmap (30/90 days)

    private func heatmapSection(_ summary: ListeningStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening Heatmap", icon: "calendar")

            VStack(alignment: .leading, spacing: 10) {
                HeatmapGrid(days: summary.days)
                    .frame(maxWidth: .infinity)

                if let busiest = busiestDay(summary) {
                    Text("Busiest day: \(busiest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func busiestDay(_ summary: ListeningStatsSummary) -> String? {
        guard let top = summary.days.max(by: { $0.wallClockSeconds < $1.wallClockSeconds }),
              top.wallClockSeconds > 0,
              let date = statsDayDate(from: top.dayKey)
        else { return nil }
        let name = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        return "\(name) · \(formattedLongDuration(top.wallClockSeconds))"
    }

    // MARK: - Monthly trend (1 year / all time)

    private func trendSection(_ summary: ListeningStatsSummary) -> some View {
        let months = monthTotals(summary)

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening Over Time", icon: "chart.bar")

            VStack(alignment: .leading, spacing: 10) {
                if months.allSatisfy({ $0.seconds == 0 }) {
                    emptyCardText("No listening recorded yet")
                } else {
                    Chart(months, id: \.month) { item in
                        BarMark(
                            x: .value("Month", item.month, unit: .month),
                            y: .value("Hours", item.seconds / 3600)
                        )
                        .foregroundStyle(Color.purple)
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) {
                            AxisValueLabel(format: .dateTime.month(.narrow))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                            AxisValueLabel {
                                if let hours = value.as(Double.self) {
                                    Text("\(Int(hours))h")
                                }
                            }
                            .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(height: 170)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func monthTotals(_ summary: ListeningStatsSummary) -> [(month: Date, seconds: TimeInterval)] {
        var totals: [Date: TimeInterval] = [:]
        let calendar = Calendar.current
        for day in summary.days {
            guard let date = statsDayDate(from: day.dayKey),
                  let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            else { continue }
            totals[month, default: 0] += day.wallClockSeconds
        }
        return totals.sorted { $0.key < $1.key }.map { (month: $0.key, seconds: $0.value) }
    }

    // MARK: - Listening clock

    private func clockSection(_ summary: ListeningStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening Clock", icon: "clock")

            VStack(spacing: 10) {
                if summary.hourSeconds.allSatisfy({ $0 == 0 }) {
                    emptyCardText("No listening in this period yet")
                } else {
                    ListeningClockDial(hourSeconds: summary.hourSeconds)
                        .frame(height: 230)

                    if let peak = peakHourLabel(summary) {
                        Text("Peak listening: \(peak)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func peakHourLabel(_ summary: ListeningStatsSummary) -> String? {
        guard let maxSeconds = summary.hourSeconds.max(), maxSeconds > 0,
              let hour = summary.hourSeconds.firstIndex(of: maxSeconds)
        else { return nil }
        return "\(hourName(hour))–\(hourName((hour + 1) % 24))"
    }

    private func hourName(_ hour: Int) -> String {
        switch hour {
        case 0: return "12am"
        case 1...11: return "\(hour)am"
        case 12: return "12pm"
        default: return "\(hour - 12)pm"
        }
    }

    // MARK: - Top shows

    private func topShowsSection(_ summary: ListeningStatsSummary) -> some View {
        let shows = summary.topShows(titles: store.showTitles, limit: 8)
        let maxSeconds = shows.first?.seconds ?? 0
        let totalShows = summary.perShowSeconds.values.filter { $0 > 0 }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Top Shows", icon: "trophy")
                Spacer()
                if totalShows > shows.count {
                    NavigationLink {
                        TopShowsListView(store: store, range: range)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Show All")
                                .font(.footnote.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                }
            }

            if shows.isEmpty || maxSeconds == 0 {
                emptyCardText("No listening in this period yet")
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                        TopShowRow(rank: index + 1, show: show, maxSeconds: maxSeconds, movement: nil)

                        if show.id != shows.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                                .padding(.leading, 70)
                        }
                    }
                }
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Drifting shows

    private var hiddenDriftShowIDs: Set<UUID> {
        Set(hiddenDriftShowIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// "Shows You're Drifting From" — 30/90 days only: the 500-entry history cap
    /// silently truncates longer ranges, and a year-old struggle isn't actionable.
    @ViewBuilder
    private var driftingShowsSection: some View {
        if range == .days30 || range == .days90,
           case .last(let days) = range.period {
            let calendar = Calendar.current
            let since = calendar.date(
                byAdding: .day,
                value: -(days - 1),
                to: calendar.startOfDay(for: Date())
            ) ?? Date()
            // Unsubscribed shows are excluded — drift from a show you already left is resolved.
            let shows = ShowEngagementAnalyzer.strugglingShows(
                entries: historyStore.entries,
                since: since,
                excluding: hiddenDriftShowIDs
            ).filter { appState.subscriptionStore.subscription(id: $0.subscriptionID) != nil }

            if !shows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("Shows You're Drifting From", icon: "zzz")

                    VStack(spacing: 0) {
                        ForEach(shows) { show in
                            driftingShowRow(show)

                            if show.id != shows.last?.id {
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                                    .padding(.leading, 70)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 6) {
                        completionLegend
                        Text("Based on how recent episodes ended. Tap a show for its settings; long-press for options.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func driftingShowRow(_ show: ShowEngagement) -> some View {
        NavigationLink {
            SubscriptionSettingsView(subscriptionID: show.subscriptionID)
        } label: {
            HStack(spacing: 12) {
                StatsShowArtwork(subscriptionID: show.subscriptionID.uuidString)

                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(ShowEngagementAnalyzer.label(for: show))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    CompletionBar(
                        completed: show.completed,
                        partial: show.abandoned,
                        untouched: show.archivedUnplayed
                    )
                }

                Spacer(minLength: 8)

                Text("\(show.completed)/\(show.totalResolved)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                hideDriftShow(show.subscriptionID)
            } label: {
                Label("Hide From This List", systemImage: "eye.slash")
            }
            Button(role: .destructive) {
                driftShowToUnsubscribe = show
                showDriftUnsubscribeConfirm = true
            } label: {
                Label("Unsubscribe", systemImage: "trash")
            }
        }
    }

    private func hideDriftShow(_ subscriptionID: UUID) {
        var ids = hiddenDriftShowIDs
        ids.insert(subscriptionID)
        hiddenDriftShowIDsRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private var completionLegend: some View {
        HStack(spacing: 12) {
            legendDot(color: .teal, label: "Finished")
            legendDot(color: .orange, label: "Stopped partway")
            legendDot(color: Color.white.opacity(0.25), label: "Archived unplayed")
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Time saved breakdown

    private func timeSavedSection(_ summary: ListeningStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Time Saved By", icon: "bolt")

            VStack(spacing: 0) {
                timeSavedRow(icon: "gauge.with.needle", label: "Variable Speed", seconds: summary.timeSavedVariableSpeed)
                cardDivider
                timeSavedRow(icon: "scissors", label: "Trim Silence", seconds: summary.timeSavedTrimSilence)
                cardDivider
                timeSavedRow(icon: "arrow.uturn.forward", label: "Skipping", seconds: summary.timeSavedManualSkip)
                cardDivider
                timeSavedRow(icon: "forward.end", label: "Auto Skipping", seconds: summary.timeSavedAutoSkip)
                cardDivider

                HStack {
                    Text("Total")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(formattedLongDuration(summary.totalTimeSaved))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.purple)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func timeSavedRow(icon: String, label: String, seconds: TimeInterval) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(formattedLongDuration(seconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var cardDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.leading, 14)
    }

    // MARK: - Shared bits

    private func sectionHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func emptyCardText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var privacyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.caption)
            Text("Your listening stats never leave this device.")
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

// MARK: - Range selector

private struct StatsRangeSelector: View {
    @Binding var range: StatsRange

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StatsRange.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { range = item }
                } label: {
                    Text(item.rawValue)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            range == item ? Color.purple : Color.white.opacity(0.08),
                            in: Capsule()
                        )
                        .foregroundStyle(range == item ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Top show row

/// Rank change against the previous period of the same length.
private enum RankMovement {
    case up(Int)
    case down(Int)
    case new
}

private struct TopShowRow: View {
    let rank: Int
    let show: (id: String, title: String, seconds: TimeInterval)
    let maxSeconds: TimeInterval
    let movement: RankMovement?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)

            StatsShowArtwork(subscriptionID: show.id)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(show.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let movement {
                        movementBadge(movement)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(Color.purple)
                            .frame(width: geo.size.width * (show.seconds / maxSeconds))
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 8)

            Text(formattedLongDuration(show.seconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func movementBadge(_ movement: RankMovement) -> some View {
        switch movement {
        case .up(let places):
            Text("▲\(places)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.teal)
        case .down(let places):
            Text("▼\(places)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
        case .new:
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.purple)
        }
    }

}

// MARK: - Show artwork (44 pt, shared by stats rows)

private struct StatsShowArtwork: View {
    @EnvironmentObject private var appState: AppState
    let subscriptionID: String

    var body: some View {
        let subscription = UUID(uuidString: subscriptionID)
            .flatMap { appState.subscriptionStore.subscription(id: $0) }

        CachedArtworkImage(url: subscription?.artworkURL) {
            ZStack {
                LinearGradient(
                    colors: [Color.purple.opacity(0.35), Color.black.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Completion bar

/// Horizontal stacked bar of episode outcomes for one show:
/// teal = finished, orange = stopped partway, dim = archived unplayed.
private struct CompletionBar: View {
    let completed: Int
    let partial: Int
    let untouched: Int

    var body: some View {
        let total = max(completed + partial + untouched, 1)

        GeometryReader { geo in
            HStack(spacing: 1) {
                segment(.teal, count: completed, total: total, width: geo.size.width)
                segment(.orange, count: partial, total: total, width: geo.size.width)
                segment(Color.white.opacity(0.25), count: untouched, total: total, width: geo.size.width)
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private func segment(_ color: Color, count: Int, total: Int, width: CGFloat) -> some View {
        if count > 0 {
            Rectangle()
                .fill(color)
                .frame(width: max(width * CGFloat(count) / CGFloat(total) - 1, 3))
        }
    }
}

// MARK: - Top shows full list (Top 50)

private struct TopShowsListView: View {
    @ObservedObject var store: ListeningStatsStore
    @State var range: StatsRange

    var body: some View {
        let summary = store.summary(for: range.period)
        let shows = summary.topShows(titles: store.showTitles, limit: 50)
        let maxSeconds = shows.first?.seconds ?? 0
        let movements = rankMovements(currentShows: shows)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatsRangeSelector(range: $range)

                if shows.isEmpty || maxSeconds == 0 {
                    Text("No listening in this period yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                            TopShowRow(
                                rank: index + 1,
                                show: show,
                                maxSeconds: maxSeconds,
                                movement: movements?[show.id]
                            )

                            if show.id != shows.last?.id {
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                                    .padding(.leading, 70)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    if movements != nil {
                        Text("▲▼ rank change vs. the previous \(range.rawValue.lowercased())")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Top Shows")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    /// Movement per show ID against the previous period of the same length.
    /// nil when there is no previous period to compare (All Time).
    private func rankMovements(
        currentShows: [(id: String, title: String, seconds: TimeInterval)]
    ) -> [String: RankMovement]? {
        guard let previousSeconds = store.previousPeriodShowSeconds(for: range.period) else { return nil }

        // Rank across all shows from the previous window, not just its top 50,
        // so a show climbing from #60 reads as a rise rather than NEW.
        let previousRanks: [String: Int] = Dictionary(
            uniqueKeysWithValues: previousSeconds
                .filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
                .enumerated()
                .map { ($0.element.key, $0.offset + 1) }
        )

        var movements: [String: RankMovement] = [:]
        for (index, show) in currentShows.enumerated() {
            let currentRank = index + 1
            guard let previousRank = previousRanks[show.id] else {
                movements[show.id] = .new
                continue
            }
            if previousRank > currentRank {
                movements[show.id] = .up(previousRank - currentRank)
            } else if previousRank < currentRank {
                movements[show.id] = .down(currentRank - previousRank)
            }
        }
        return movements
    }
}

// MARK: - Heatmap grid

/// GitHub-style contribution grid: columns are weeks, rows are weekdays,
/// purple intensity scales with that day's listening time.
private struct HeatmapGrid: View {
    let days: [DayStats]

    private struct Cell: Identifiable {
        let id: Int
        let seconds: TimeInterval?
    }

    var body: some View {
        let weeks = weekColumns()
        let cellSize: CGFloat = weeks.count <= 7 ? 30 : 19
        let spacing: CGFloat = weeks.count <= 7 ? 4 : 3
        let maxSeconds = days.map(\.wallClockSeconds).max() ?? 0

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: spacing) {
                    ForEach(week) { cell in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color(for: cell.seconds, maxSeconds: maxSeconds))
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
    }

    private func color(for seconds: TimeInterval?, maxSeconds: TimeInterval) -> Color {
        guard let seconds else { return Color.clear }
        guard seconds > 0, maxSeconds > 0 else { return Color.white.opacity(0.06) }
        // sqrt lifts short days into visibility instead of vanishing next to long ones.
        let intensity = sqrt(seconds / maxSeconds)
        return Color.purple.opacity(0.25 + 0.75 * intensity)
    }

    /// Days chunked into weekday-aligned week columns; nil-padded at the edges.
    private func weekColumns() -> [[Cell]] {
        let calendar = Calendar.current
        var cells: [TimeInterval?] = []

        if let firstKey = days.first?.dayKey, let firstDate = statsDayDate(from: firstKey) {
            let weekday = calendar.component(.weekday, from: firstDate)
            let leadingPad = (weekday - calendar.firstWeekday + 7) % 7
            cells.append(contentsOf: Array(repeating: nil, count: leadingPad))
        }
        cells.append(contentsOf: days.map { $0.wallClockSeconds })
        while cells.count % 7 != 0 {
            cells.append(nil)
        }

        return stride(from: 0, to: cells.count, by: 7).map { start in
            (start..<min(start + 7, cells.count)).map { Cell(id: $0, seconds: cells[$0]) }
        }
    }
}

// MARK: - Listening clock dial

/// 24-hour rose chart: midnight at the top, noon at the bottom, each hour a
/// wedge whose radius scales with listening time in that hour.
private struct ListeningClockDial: View {
    let hourSeconds: [TimeInterval]

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) / 2 - 4
                let maxValue = hourSeconds.max() ?? 0

                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - maxRadius, y: center.y - maxRadius,
                        width: maxRadius * 2, height: maxRadius * 2
                    )),
                    with: .color(.white.opacity(0.08)),
                    lineWidth: 1
                )
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - maxRadius / 2, y: center.y - maxRadius / 2,
                        width: maxRadius, height: maxRadius
                    )),
                    with: .color(.white.opacity(0.08)),
                    lineWidth: 1
                )

                guard maxValue > 0 else { return }

                for hour in 0..<24 {
                    let fraction = hourSeconds[hour] / maxValue
                    guard fraction > 0 else { continue }
                    let radius = 5 + (maxRadius - 5) * sqrt(fraction)
                    let start = Angle.degrees(Double(hour) / 24 * 360 - 90 + 1)
                    let end = Angle.degrees(Double(hour + 1) / 24 * 360 - 90 - 1)

                    var wedge = Path()
                    wedge.move(to: center)
                    wedge.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(.purple.opacity(0.9)))
                }
            }
            .padding(18)

            VStack {
                Text("12am")
                Spacer()
                Text("12pm")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            HStack {
                Text("6pm")
                Spacer()
                Text("6am")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Helpers

private func statsDayDate(from key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

private func formattedLongDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let days = totalSeconds / 86400
    let hours = (totalSeconds % 86400) / 3600
    let minutes = (totalSeconds % 3600) / 60

    if days > 0 {
        if hours > 0 { return "\(days)d \(hours)h" }
        return "\(days)d"
    }
    if hours > 0 {
        if minutes > 0 { return "\(hours)h \(minutes)m" }
        return "\(hours)h"
    }
    if minutes > 0 { return "\(minutes)m" }
    return "\(totalSeconds % 60)s"
}
