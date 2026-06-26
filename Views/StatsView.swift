import SwiftUI
import Charts

// AI CONTEXT — Views/StatsView.swift ("Stats" page; full layout spec in
// FEATURES.md §12). Period selector — This Week / current month / current year /
// Lifetime — drives every section, all data from ListeningStatsStore.summary().
// The page opens in This Week (the `range` @State default; resets to it each open).
// A "This / Last" toggle (StatsRangeSelector, bound to `showingLast`) switches
// week/month/year to the previous concluded period (StatsPeriod.previous*); it's
// disabled for Lifetime. `isLast = showingLast && range.supportsLast`. Last mode
// re-labels the pills (Last Week / May / 2025), bounds the per-show history detail
// with sinceDate(last:)/untilDate(last:), and hides the present-tense "Drifting
// From" section. Everything else is summary-driven so it follows automatically.
// This toggle is the in-app surface the weekly/monthly/yearly Listening Recap
// notifications will deep-link into (Phase 2/3).
// "Shows You're Drifting From" only considers real active subscriptions:
// browse previews and Inactive podcasts (exclude-from-auto-refresh) are omitted
// because the user has intentionally paused feed attention for them.
// All but Lifetime are calendar-anchored and reset at the start of each period:
// This Week = Monday 00:00 → now (Monday-first, locale-independent); the month
// pill (dynamic label, e.g. "June") = 1st → now; the year pill ("2026") = Jan 1
// → now. Sections (top to bottom): hero card (time listened, time saved,
// episodes finished, streak), Top Shows (+ Show All page with rank-movement
// badges vs. the previous comparable period — prior week / calendar month /
// calendar year), "Shows You're Drifting From" (ShowEngagementAnalyzer, heatmap
// ranges only, omitted when empty), listening heatmap (This Week + current month,
// Monday-aligned columns) or monthly Swift Charts trend (year/Lifetime), 24-hour
// listening clock (Canvas rose chart), data-downloaded card (total bytes +
// episode count / average size, forward-only from June 2026), time-saved
// breakdown, privacy footer.
// Tapping a Top Shows or
// drifting-shows row expands a ShowStatsExpandedCard (per-show detail).
// All on-device data only. Show rows use 44 pt CachedArtworkImage thumbnails so
// stats-heavy lists share the same artwork cache variant as queues and settings.
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

private enum StatsRange: CaseIterable, Identifiable {
    case thisWeek
    case thisMonth
    case thisYear
    case lifetime

    var id: String {
        switch self {
        case .thisWeek:  return "thisWeek"
        case .thisMonth: return "thisMonth"
        case .thisYear:  return "thisYear"
        case .lifetime:  return "lifetime"
        }
    }

    /// Whether the This/Last toggle applies (everything except Lifetime).
    var supportsLast: Bool {
        switch self {
        case .thisWeek, .thisMonth, .thisYear: return true
        case .lifetime:                        return false
        }
    }

    /// Contextual labels for the This/Last bar. Nil for Lifetime (no bar).
    var thisLastLabels: (this: String, last: String)? {
        switch self {
        case .thisWeek:  return ("This Week", "Last Week")
        case .thisMonth: return ("This Month", "Last Month")
        case .thisYear:  return ("This Year", "Last Year")
        case .lifetime:  return nil
        }
    }

    /// Pill label, reflecting the current This/Last selection. Month and year are
    /// dynamic — current ("June" / "2026") or previous ("May" / "2025") in Last mode.
    func title(last: Bool) -> String {
        let calendar = Calendar.current
        switch self {
        case .thisWeek:
            return last ? "Last Week" : "This Week"
        case .thisMonth:
            let date = last ? (calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()) : Date()
            return date.formatted(.dateTime.month(.wide))
        case .thisYear:
            let date = last ? (calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()) : Date()
            return date.formatted(.dateTime.year())
        case .lifetime:
            return "Lifetime"
        }
    }

    /// Noun for the "rank change vs. the previous …" caption. Nil for Lifetime.
    var previousPeriodNoun: String? {
        switch self {
        case .thisWeek:  return "week"
        case .thisMonth: return "month"
        case .thisYear:  return "year"
        case .lifetime:  return nil
        }
    }

    func period(last: Bool) -> StatsPeriod {
        switch self {
        case .thisWeek:  return last ? .previousWeek  : .currentWeek
        case .thisMonth: return last ? .previousMonth : .currentMonth
        case .thisYear:  return last ? .previousYear  : .currentYear
        case .lifetime:  return .lifetime
        }
    }

    /// Day-cell heatmap ranges (week/month); year and lifetime use the trend chart.
    var usesHeatmap: Bool {
        switch self {
        case .thisWeek, .thisMonth: return true
        case .thisYear, .lifetime:  return false
        }
    }

    /// Inclusive start-of-day cutoff for history-based per-show stats. In Last mode
    /// this is the start of the *previous* period. Nil for Lifetime.
    func sinceDate(last: Bool) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .lifetime:
            return nil
        case .thisWeek:
            let start = Self.startOfWeek(for: Date(), calendar: calendar)
            return last ? calendar.date(byAdding: .day, value: -7, to: start) : start
        case .thisMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))
                ?? calendar.startOfDay(for: Date())
            return last ? calendar.date(byAdding: .month, value: -1, to: start) : start
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: Date()))
                ?? calendar.startOfDay(for: Date())
            return last ? calendar.date(byAdding: .year, value: -1, to: start) : start
        }
    }

    /// Exclusive upper bound for history-based per-show stats — only set in Last
    /// mode, where it's the start of the *current* period (so a concluded period
    /// doesn't bleed into the present).
    func untilDate(last: Bool) -> Date? {
        guard last else { return nil }
        let calendar = Calendar.current
        switch self {
        case .lifetime:  return nil
        case .thisWeek:  return Self.startOfWeek(for: Date(), calendar: calendar)
        case .thisMonth: return calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))
        case .thisYear:  return calendar.date(from: calendar.dateComponents([.year], from: Date()))
        }
    }

    /// Monday 00:00 of the week containing `date` (Monday-first, locale-independent).
    static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    }
}

private struct StatsContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: ListeningStatsStore
    @ObservedObject var historyStore: ListeningHistoryStore
    // Stats opens in This Week by default (showingLast = false ⇒ the current week,
    // not Last Week). Changing this default is the only thing that sets the initial
    // period — `range` is in-memory @State, so the page resets to it on every open.
    @State private var range: StatsRange = .thisWeek
    /// This/Last toggle — when true, show the previous concluded period. Ignored
    /// for Lifetime (see `isLast`). Deep-linked from the Listening Recap notifications.
    @State private var showingLast = false
    @State private var showRecaps = false
    @State private var driftShowToUnsubscribe: ShowEngagement?
    @State private var showDriftUnsubscribeConfirm = false
    /// Subscription UUID string of the Top Shows row expanded into a detail card.
    @State private var expandedTopShowID: String?
    /// Subscription UUID of the drifting-shows row expanded into a detail card.
    @State private var expandedDriftShowID: UUID?
    /// Comma-joined subscription UUIDs the user muted from the drifting list.
    @AppStorage("stats.hiddenDriftShowIDs") private var hiddenDriftShowIDsRaw: String = ""

    /// Whether the previous period has any listening to show.
    private var hasLastData: Bool {
        range.supportsLast && store.summary(for: range.period(last: true)).wallClockSeconds > 0
    }
    /// Effective Last state — only when supported AND there's data for it.
    private var isLast: Bool { showingLast && hasLastData }

    var body: some View {
        let summary = store.summary(for: range.period(last: isLast))

        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                rangeSelector

                heroCard(summary)

                topShowsSection(summary)
                driftingShowsSection(summary)

                if range.usesHeatmap {
                    heatmapSection(summary)
                } else {
                    trendSection(summary)
                }

                clockSection(summary)
                dataDownloadedSection(summary)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showRecaps = true
                } label: {
                    Image(systemName: "bell.badge")
                }
                .accessibilityLabel("Listening Recaps")
            }
        }
        .sheet(isPresented: $showRecaps) { RecapSettingsView() }
        .miniPlayerBar()
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
        StatsRangeSelector(range: $range, showingLast: $showingLast, canShowLast: hasLastData)
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
        .glassCard(cornerRadius: 16)
    }

    private var heroSubtitle: String {
        switch range {
        case .lifetime:
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

    // MARK: - Heatmap (This Week / current month)

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
            .glassCard(cornerRadius: 16)
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
            .glassCard(cornerRadius: 16)
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
            .glassCard(cornerRadius: 16)
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
                        TopShowsListView(store: store, historyStore: historyStore, range: range, showingLast: isLast)
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
                    .glassCard(cornerRadius: 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedTopShowID = expandedTopShowID == show.id ? nil : show.id
                            }
                        } label: {
                            TopShowRow(rank: index + 1, show: show, maxSeconds: maxSeconds, movement: nil)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expandedTopShowID == show.id {
                            ShowStatsExpandedCard(
                                detail: ShowPeriodDetail(
                                    subscriptionID: show.id,
                                    entries: historyStore.entries,
                                    summary: summary,
                                    since: range.sinceDate(last: isLast),
                                    until: range.untilDate(last: isLast)
                                ),
                                settingsSubscriptionID: nil
                            )
                        }

                        if show.id != shows.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                                .padding(.leading, 70)
                        }
                    }
                }
                .glassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Drifting shows

    private var hiddenDriftShowIDs: Set<UUID> {
        Set(hiddenDriftShowIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// "Shows You're Drifting From" — short ranges only: the 500-entry history cap
    /// silently truncates longer ranges, and a year-old struggle isn't actionable.
    @ViewBuilder
    private func driftingShowsSection(_ summary: ListeningStatsSummary) -> some View {
        // Present-tense signal ("shows you're drifting from") — only meaningful for
        // the current period, so it's hidden in Last mode.
        if !isLast, range.usesHeatmap, let since = range.sinceDate(last: false) {
            // Only real, actively-refreshed subscriptions qualify. Unsubscribed
            // shows are excluded (drift from a show you already left is resolved),
            // Inactive shows are intentionally paused, and invisible browse/preview
            // subscriptions (browseDate != nil) were never explicitly subscribed to.
            let shows = ShowEngagementAnalyzer.strugglingShows(
                entries: historyStore.entries,
                since: since,
                excluding: hiddenDriftShowIDs
            ).filter {
                guard let sub = appState.subscriptionStore.subscription(id: $0.subscriptionID) else { return false }
                return sub.browseDate == nil && !sub.excludeFromAutoFeedRefresh
            }

            if !shows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("Shows You're Drifting From", icon: "zzz")

                    VStack(spacing: 0) {
                        ForEach(shows) { show in
                            driftingShowRow(show)

                            if expandedDriftShowID == show.subscriptionID {
                                ShowStatsExpandedCard(
                                    detail: ShowPeriodDetail(
                                        subscriptionID: show.subscriptionID.uuidString,
                                        entries: historyStore.entries,
                                        summary: summary,
                                        since: since,
                                        until: nil
                                    ),
                                    settingsSubscriptionID: show.subscriptionID
                                )
                            }

                            if show.id != shows.last?.id {
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                                    .padding(.leading, 70)
                            }
                        }
                    }
                    .glassCard(cornerRadius: 16)

                    VStack(alignment: .leading, spacing: 6) {
                        completionLegend
                        Text("Based on how recent episodes ended. Tap a show for details; long-press for options.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func driftingShowRow(_ show: ShowEngagement) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedDriftShowID = expandedDriftShowID == show.subscriptionID ? nil : show.subscriptionID
            }
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
            .glassCard(cornerRadius: 16)
        }
    }

    // MARK: - Data downloaded

    private func dataDownloadedSection(_ summary: ListeningStatsSummary) -> some View {
        let buckets = downloadTotals(summary)
        let hasData = summary.bytesDownloaded > 0
        let hasChartData = buckets.contains { $0.bytes > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Data Downloaded", icon: "arrow.down.circle")

            VStack(alignment: .leading, spacing: 16) {
                // Headline total + episode/average mini-stats.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formattedBytes(summary.bytesDownloaded))
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.cyan)
                            .contentTransition(.numericText())
                        Text("total downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if hasData {
                        HStack(spacing: 18) {
                            downloadMiniStat(
                                "\(summary.episodesDownloaded)",
                                summary.episodesDownloaded == 1 ? "episode" : "episodes"
                            )
                            downloadMiniStat(
                                formattedBytes(summary.bytesDownloaded / Int64(max(summary.episodesDownloaded, 1))),
                                "avg each"
                            )
                        }
                    }
                }

                if hasData, hasChartData {
                    downloadChart(buckets)
                } else if !hasData {
                    Text("No episodes downloaded in this period")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
        }
    }

    private func downloadMiniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Download volume over time: per-day bars for short ranges, per-month for
    /// year/lifetime — mirrors the listening-trend bucketing, but in cyan.
    @ViewBuilder
    private func downloadChart(_ buckets: [(date: Date, bytes: Int64)]) -> some View {
        let unit: Calendar.Component = range.usesHeatmap ? .day : .month
        Chart(buckets, id: \.date) { item in
            BarMark(
                x: .value("Date", item.date, unit: unit),
                y: .value("Data", Double(item.bytes))
            )
            .foregroundStyle(Color.cyan.gradient)
            .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisValueLabel(
                    format: range.usesHeatmap ? .dateTime.day() : .dateTime.month(.narrow)
                )
                .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(formattedBytes(Int64(bytes)))
                    }
                }
                .foregroundStyle(Color.secondary)
            }
        }
        .frame(height: 150)
    }

    /// Bytes downloaded per time bucket (day for heatmap ranges, month otherwise).
    private func downloadTotals(_ summary: ListeningStatsSummary) -> [(date: Date, bytes: Int64)] {
        let calendar = Calendar.current
        if range.usesHeatmap {
            return summary.days.compactMap { day in
                guard let date = statsDayDate(from: day.dayKey) else { return nil }
                return (date: date, bytes: day.bytesDownloaded)
            }
        } else {
            var totals: [Date: Int64] = [:]
            for day in summary.days {
                guard let date = statsDayDate(from: day.dayKey),
                      let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date))
                else { continue }
                totals[month, default: 0] += day.bytesDownloaded
            }
            return totals.sorted { $0.key < $1.key }.map { (date: $0.key, bytes: $0.value) }
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
            Text("Your listening stats are private — kept on your device and your own iCloud, never sent to Autohop.")
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
    @Binding var showingLast: Bool
    /// Whether the previous period actually has data to show. The This/Last bar
    /// is hidden entirely when false (or on Lifetime), so we never offer an
    /// empty "Last" view.
    var canShowLast: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(StatsRange.allCases) { item in
                    pill(item)
                }
            }
            .frame(maxWidth: .infinity)

            // Distinct solid segmented bar (deliberately unlike the glass pills),
            // shown only when there's a previous period worth viewing.
            if range.supportsLast, canShowLast, let labels = range.thisLastLabels {
                thisLastBar(labels)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pill(_ item: StatsRange) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { range = item }
        } label: {
            // Pills always show the current-period label; the bar carries This/Last.
            let pill = Text(item.title(last: false))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(range == item ? Color.white : Color.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)

            // iOS glass; purple-tinted on the selected range.
            if #available(iOS 26, *) {
                if range == item {
                    pill.glassEffect(.regular.tint(.purple), in: Capsule())
                } else {
                    pill.glassEffect(in: Capsule())
                }
            } else {
                pill.background(
                    range == item ? Color.purple : Color.white.opacity(0.08),
                    in: Capsule()
                )
            }
        }
        .buttonStyle(.plain)
    }

    /// Solid two-segment bar — a sliding purple chip on a flat track. Content-width
    /// (narrow) and centered, visually separate from the glass period pills above.
    private func thisLastBar(_ labels: (this: String, last: String)) -> some View {
        HStack(spacing: 0) {
            barSegment(labels.this, active: !showingLast) { showingLast = false }
            barSegment(labels.last, active: showingLast)  { showingLast = true }
        }
        .padding(3)
        .background(Color.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        .fixedSize()
    }

    private func barSegment(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(active ? Color.purple : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
                .frame(width: 24, alignment: .center)

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

// MARK: - Per-show period detail

/// Per-show numbers for the expandable detail card, derived from listening
/// history entries (episode outcomes, cadence) plus the period summary (time
/// listened, per-show time saved). Time saved uses the tracked per-show value
/// when the period has any; days recorded before per-show tracking existed
/// fall back to apportioning the period total by listening share ("est.").
private struct ShowPeriodDetail {
    var seconds: TimeInterval = 0
    var episodesCompleted = 0
    var episodesAbandoned = 0
    var episodesTouched = 0
    var averageCompletionPercent: Double?
    var lastListenedAt: Date?
    var shareOfListening: Double = 0
    var timeSaved: TimeInterval = 0
    var timeSavedIsEstimate = false
    /// Median delay between an episode's release and the user's last listen to
    /// it — "how soon after release do I get to this show".
    var medianReleaseToListen: TimeInterval?

    init(
        subscriptionID: String,
        entries: [ListeningHistoryEntry],
        summary: ListeningStatsSummary,
        since: Date?,
        until: Date? = nil
    ) {
        var percents: [Double] = []
        var releaseDelays: [TimeInterval] = []
        for entry in entries where entry.subscriptionID.uuidString == subscriptionID {
            if let since, entry.lastListenedAt < since { continue }
            if let until, entry.lastListenedAt >= until { continue }
            episodesTouched += 1
            lastListenedAt = max(lastListenedAt ?? .distantPast, entry.lastListenedAt)
            if let percent = entry.completionPercent {
                percents.append(min(max(percent, 0), 1))
            }
            if let publishedAt = entry.publishedAt {
                let delay = entry.lastListenedAt.timeIntervalSince(publishedAt)
                // Negative delays are clock/feed-date noise, not time travel.
                if delay >= 0 { releaseDelays.append(delay) }
            }
            switch ShowEngagementAnalyzer.classify(entry) {
            case .completed: episodesCompleted += 1
            case .abandoned: episodesAbandoned += 1
            case .archivedUnplayed, nil: break
            }
        }
        if !percents.isEmpty {
            averageCompletionPercent = percents.reduce(0, +) / Double(percents.count)
        }
        if !releaseDelays.isEmpty {
            let sorted = releaseDelays.sorted()
            medianReleaseToListen = sorted[sorted.count / 2]
        }
        seconds = summary.perShowSeconds[subscriptionID] ?? 0
        if summary.wallClockSeconds > 0 {
            shareOfListening = seconds / summary.wallClockSeconds
        }
        // Tracked per-show savings exist for this period — use the real number.
        // A period made up entirely of pre-tracking days has an empty map; fall
        // back to apportioning the period total by listening share.
        if !summary.perShowTimeSaved.isEmpty {
            timeSaved = summary.perShowTimeSaved[subscriptionID] ?? 0
        } else {
            timeSaved = summary.totalTimeSaved * shareOfListening
            timeSavedIsEstimate = true
        }
    }
}

// MARK: - Expanded show card

/// Detail card revealed by tapping a Top Shows or drifting-shows row.
/// `settingsSubscriptionID` adds a "Podcast Settings" link (drift rows, which
/// previously navigated there on tap).
private struct ShowStatsExpandedCard: View {
    let detail: ShowPeriodDetail
    let settingsSubscriptionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 12
            ) {
                stat(value: "\(detail.episodesCompleted)", label: "episodes finished", tint: .teal)
                stat(
                    value: formattedLongDuration(detail.timeSaved),
                    label: detail.timeSavedIsEstimate ? "time saved (est.)" : "time saved",
                    tint: .teal
                )
                stat(value: percentLabel(detail.shareOfListening), label: "of all listening", tint: .primary)
                stat(
                    value: detail.averageCompletionPercent.map(percentLabel) ?? "—",
                    label: "avg. completion",
                    tint: .primary
                )
                stat(value: "\(detail.episodesAbandoned)", label: "stopped partway", tint: .orange)
                stat(
                    value: detail.lastListenedAt.map {
                        $0.formatted(.relative(presentation: .named))
                    } ?? "—",
                    label: "last listened",
                    tint: .primary
                )
                stat(
                    value: detail.medianReleaseToListen.map(cadenceLabel) ?? "—",
                    label: "typical wait after release",
                    tint: .primary
                )
            }

            if let settingsSubscriptionID {
                NavigationLink {
                    SubscriptionSettingsView(subscriptionID: settingsSubscriptionID)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.caption.weight(.semibold))
                        Text("Podcast Settings")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func stat(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func percentLabel(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Coarse release-to-listen delay: "under 1h", "~6h", "~3d".
    private func cadenceLabel(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "under 1h" }
        if seconds < 86400 { return "~\(Int((seconds / 3600).rounded()))h" }
        return "~\(Int((seconds / 86400).rounded()))d"
    }
}

// MARK: - Show artwork (44 pt, shared by stats rows)

private struct StatsShowArtwork: View {
    @EnvironmentObject private var appState: AppState
    let subscriptionID: String

    var body: some View {
        let subscription = UUID(uuidString: subscriptionID)
            .flatMap { appState.subscriptionStore.subscription(id: $0) }

        CachedArtworkImage(url: subscription?.artworkURL, targetSize: CGSize(width: 44, height: 44)) {
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
    @ObservedObject var historyStore: ListeningHistoryStore
    @State var range: StatsRange
    @State var showingLast: Bool
    @State private var expandedShowID: String?

    private var hasLastData: Bool {
        range.supportsLast && store.summary(for: range.period(last: true)).wallClockSeconds > 0
    }
    private var isLast: Bool { showingLast && hasLastData }

    var body: some View {
        let summary = store.summary(for: range.period(last: isLast))
        let shows = summary.topShows(titles: store.showTitles, limit: 50)
        let maxSeconds = shows.first?.seconds ?? 0
        let movements = rankMovements(currentShows: shows)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatsRangeSelector(range: $range, showingLast: $showingLast, canShowLast: hasLastData)

                if shows.isEmpty || maxSeconds == 0 {
                    Text("No listening in this period yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedShowID = expandedShowID == show.id ? nil : show.id
                                }
                            } label: {
                                TopShowRow(
                                    rank: index + 1,
                                    show: show,
                                    maxSeconds: maxSeconds,
                                    movement: movements?[show.id]
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if expandedShowID == show.id {
                                ShowStatsExpandedCard(
                                    detail: ShowPeriodDetail(
                                        subscriptionID: show.id,
                                        entries: historyStore.entries,
                                        summary: summary,
                                        since: range.sinceDate(last: isLast),
                                        until: range.untilDate(last: isLast)
                                    ),
                                    settingsSubscriptionID: nil
                                )
                            }

                            if show.id != shows.last?.id {
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                                    .padding(.leading, 70)
                            }
                        }
                    }
                    .glassCard(cornerRadius: 16)

                    if movements != nil {
                        Text("▲▼ rank change vs. the previous \(range.previousPeriodNoun ?? "period")")
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

    /// Movement per show ID against the previous comparable period.
    /// nil when there is no previous period to compare (Lifetime).
    private func rankMovements(
        currentShows: [(id: String, title: String, seconds: TimeInterval)]
    ) -> [String: RankMovement]? {
        guard let previousSeconds = store.previousPeriodShowSeconds(for: range.period(last: isLast)) else { return nil }

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
            // Columns are Monday-aligned (Monday = first day of the week),
            // independent of locale. Gregorian weekday: Sun=1 … Sat=7 → Monday=2.
            let weekday = calendar.component(.weekday, from: firstDate)
            let leadingPad = (weekday - 2 + 7) % 7
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

/// Human-readable data size using the file/decimal convention (e.g. "1.2 GB",
/// "45 MB") — matches how iOS reports cellular and storage usage.
private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
