import SwiftUI

// AI CONTEXT — Views/FeedRefreshScheduleView.swift ("Feed Refresh Schedule" page,
// reached from a visible row in SettingsView's Release Radar section). A read-only
// diagnostic table of every ACTIVE subscription (browseDate == nil &&
// !excludeFromAutoFeedRefresh — Inactive subs are excluded) and the Release Radar
// schedule the auto feed-refresh uses for it: learned profile kind + confidence,
// current window state, the recurring "when it WILL look" pattern, the next concrete
// expected window (+ countdown), the in-window recheck interval, and a plain note on
// when it WON'T actively watch. Data comes from AppState.releaseRadarSchedule(for:)
// — the same FeedScheduleProfile + FeedRefreshPrediction the scheduler itself uses.
// Rows are grouped by behaviour, by publish frequency (Watching now / soon / Hourly /
// Daily – Multiple Episodes / Daily / Several Times a Week / Weekly / Still learning);
// within each group they're sorted ALPHABETICALLY by title so a feed
// is easy to find. Section headers use the DESIGN.md `Section-Heading` (bold title3 +
// secondary count) with extra `.listSectionSpacing` between groups. Computed once on
// appear (and on pull-to-refresh) into @State so the body stays cheap. Each row has a
// "Diagnostics" button → SubscriptionRadarDiagnosticsView (the per-feed Release Radar
// Data screen) and a "Rebuild Prediction" button →
// AppState.rebuildReleasePrediction (learning-only: fetches the last 100 episodes into
// the Release Radar learner WITHOUT merging episodes into the library/queue; episodes
// skipped by Download Feed Filters are excluded from the learner), then recomputes
// the table so the row reflects the stronger profile (and may move to a new
// behaviour group). A toolbar export button
// (ShareLink) writes a plain-text diagnostic dump of EVERY active subscription — the
// same data as the per-subscription "Release Radar Data" screen — to a temp .txt for
// sharing/submitting for offline trend analysis. The export includes each learned
// window plus observed spread so over-narrow/widened Radar windows can be audited
// without raw log parsing (see releaseRadarReportText at file end; regenerated
// alongside `entries`). NavRules: pushed page, brand
// back chevron, MiniPlayerBar docked. NOTE: the local behaviour enum is named
// `Behaviour`, NOT `Group`, so it doesn't shadow SwiftUI.Group used in the body.
struct FeedRefreshScheduleView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [Entry] = []
    @State private var generatedAt = Date()
    @State private var rebuildingIDs: Set<UUID> = []
    @State private var resultMessage: String?
    /// Temp .txt holding the full diagnostic dump for every active subscription,
    /// regenerated alongside `entries`; shared via the toolbar export button.
    @State private var exportURL: URL?

    // MARK: - Model

    private struct Entry: Identifiable {
        let id: UUID
        let title: String
        let profile: FeedScheduleProfile
        let prediction: FeedRefreshPrediction
        let behaviour: Behaviour
    }

    private enum Behaviour: Int, CaseIterable {
        case watchingNow, watchingSoon, hourly, dailyMultiple, daily, severalTimesWeek, weekly, learning

        var title: String {
            switch self {
            case .watchingNow:      return "Watching Now"
            case .watchingSoon:     return "Watching Soon"
            case .hourly:           return "Hourly"
            case .dailyMultiple:    return "Daily – Multiple Episodes"
            case .daily:            return "Daily"
            case .severalTimesWeek: return "Several Times a Week"
            case .weekly:           return "Weekly"
            case .learning:         return "Still Learning"
            }
        }

        var footer: String {
            switch self {
            case .watchingNow:      return "Inside (or just past) the expected release window — checked frequently right now."
            case .watchingSoon:     return "The expected window is approaching — Radar will start checking frequently shortly."
            case .hourly:           return "Publishes near-hourly. Watched around each learned minute mark; only sparse checks between."
            case .dailyMultiple:    return "Publishes several episodes per day on most days. Watched through the daily release window."
            case .daily:            return "Publishes about one episode per day. Watched around the learned time of day; broad safety checks otherwise."
            case .severalTimesWeek: return "Publishes one episode on a few set days each week. Watched around those days; broad safety checks otherwise."
            case .weekly:           return "Publishes weekly. Watched around the learned day and time; about once a day otherwise."
            case .learning:         return "Not enough data yet to predict a window — checked on a light fallback cadence until a pattern emerges."
            }
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Active Subscriptions", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Subscribe to a podcast (and keep it active) to see when Release Radar checks its feed.")
                }
            } else {
                List {
                    overviewSection
                    ForEach(Behaviour.allCases, id: \.self) { behaviour in
                        let group = entries
                            .filter { $0.behaviour == behaviour }
                            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                        if !group.isEmpty {
                            Section {
                                ForEach(group) { row($0) }
                            } header: {
                                // Section-Heading (DESIGN.md): bold title3 label + secondary count.
                                HStack(spacing: 6) {
                                    Text(behaviour.title)
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text("\(group.count)")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .textCase(nil)
                            } footer: {
                                Text(behaviour.footer)
                            }
                        }
                    }
                }
                .listSectionSpacing(28)
            }
        }
        .navigationTitle("Feed Refresh Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left.circle.fill") }.accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export diagnostic report")
                }
            }
        }
        .miniPlayerBar()
        .preferredColorScheme(.dark)
        .onAppear { rebuildEntries() }
        .refreshable {
            // Real feed refresh (same as the Subscriptions refresh-all) so the diagnostic
            // reflects freshly-fetched feeds and any newly-learned observations — then
            // recompute the table. Awaited, so the pull-to-refresh spinner stays until done.
            await appState.refreshAllSubscriptions(includeBackoffFeeds: true)
            rebuildEntries()
        }
        .overlay(alignment: .bottom) {
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 76)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Section {
            Text("When Autohop's Release Radar **will** and **won't** check each active show for new episodes. It watches a feed closely only inside its learned window and does a light check otherwise — so new episodes are caught fast without wasteful polling. Inactive subscriptions and episodes skipped by Download Feed Filters are excluded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } footer: {
            Text("Updated \(generatedAt.formatted(date: .omitted, time: .shortened)) · \(entries.count) active show\(entries.count == 1 ? "" : "s"). Pull to refresh.")
        }
    }

    // MARK: - Row

    private func row(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 6) {
                pill(entry.profile.categoryLabel, tint: .purple)
                pill(stateLabel(entry.prediction.state), tint: stateTint(entry.prediction.state))
                if entry.profile.confidence > 0 {
                    Text("\(Int((entry.profile.confidence * 100).rounded()))% confident")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            field("Watches", patternLabel(entry))
            field("Next window", nextWindowLabel(entry))
            field("Recheck", recheckLabel(entry))
            field("Otherwise", offWindowLabel(entry))

            HStack(spacing: 8) {
                NavigationLink {
                    SubscriptionRadarDiagnosticsView(subscriptionID: entry.id)
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.purple)

                Spacer()

                Button {
                    rebuildPrediction(entry)
                } label: {
                    if rebuildingIDs.contains(entry.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Rebuilding…")
                        }
                    } else {
                        Label("Rebuild Prediction", systemImage: "wand.and.stars")
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(rebuildingIDs.contains(entry.id))
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func field(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Labels

    private func stateLabel(_ state: FeedRefreshWindowState) -> String {
        switch state {
        case .learning:           return "Learning"
        case .unreliableDates:    return "Dates unreliable"
        case .randomSurveillance: return "Light watch"
        case .quiet:              return "Quiet"
        case .preWindow:          return "Window soon"
        case .activeWindow:       return "Watching now"
        case .missedRelease:      return "Overdue"
        case .fallback:           return "Fallback"
        }
    }

    private func stateTint(_ state: FeedRefreshWindowState) -> Color {
        switch state {
        case .activeWindow, .missedRelease: return .green
        case .preWindow:                    return .orange
        case .quiet, .fallback:             return .teal
        case .learning, .unreliableDates, .randomSurveillance: return .gray
        }
    }

    /// The recurring pattern — the plain-English "when it WILL look".
    private func patternLabel(_ entry: Entry) -> String {
        let p = entry.profile
        switch p.kind {
        case .hourly:
            if let m = p.typicalMinuteOfHour { return "Every hour around :\(pad(m))" }
            return "Roughly every hour"
        case .rollingBulletin:
            if let mins = p.typicalMinutesOfHour, !mins.isEmpty {
                return "Every hour at " + mins.sorted().map { ":\(pad($0))" }.joined(separator: ", ")
            }
            if let m = p.typicalMinuteOfHour { return "Every hour around :\(pad(m))" }
            return "Several times an hour"
        case .dailyWeekdays, .multiSlot:
            if let t = p.typicalMinuteOfDay { return "\(weekdaysLabel(p.activeWeekdays)) around \(timeLabel(t))" }
            return weekdaysLabel(p.activeWeekdays)
        case .weekly:
            if let t = p.typicalMinuteOfDay { return "\(weekdaysLabel(p.activeWeekdays)) around \(timeLabel(t))" }
            return "Weekly"
        case .burst:
            if let w = p.burstWindow {
                return "\(weekdaysLabel(w.activeWeekdays)) \(timeLabel(w.startMinuteOfDay))–\(timeLabel(w.endMinuteOfDay))"
            }
            return "In bursts"
        case .learning, .unreliableDates, .random:
            return "No set pattern yet"
        }
    }

    /// The next concrete expected window (+ countdown), or the next check when there's no
    /// window. A passed window (missedRelease/fallback) reads "… — missed; next check …"
    /// rather than a misleading "(now)".
    private func nextWindowLabel(_ entry: Entry) -> String {
        let pr = entry.prediction
        guard let start = pr.expectedWindowStart else {
            return "Next check \(countdown(to: pr.nextDueAt))"
        }
        let window = pr.expectedWindowEnd
            .map { "\(relativeDayTime(start))–\($0.formatted(.dateTime.hour().minute()))" }
            ?? relativeDayTime(start)
        // missedRelease / fallback windows are in the PAST — don't show "(now)"; surface
        // that the expected episode is late and when Radar next checks.
        if pr.state == .missedRelease || pr.state == .fallback {
            return "\(window) — missed; next check \(countdown(to: pr.nextDueAt))"
        }
        return "\(window) (\(countdown(to: start)))"
    }

    private func recheckLabel(_ entry: Entry) -> String {
        guard let r = entry.prediction.recheckInterval else { return "Light periodic check" }
        let mins = Int((r / 60).rounded())
        return mins <= 1 ? "Every minute while watching" : "Every \(mins) min while watching"
    }

    /// When it WON'T actively watch.
    private func offWindowLabel(_ entry: Entry) -> String {
        switch entry.profile.kind {
        case .hourly, .rollingBulletin:
            return "Between windows: only sparse checks"
        case .multiSlot, .burst:
            return "Between windows: broad safety checks"
        case .dailyWeekdays:
            return "Outside the window: broad safety checks about twice a day"
        case .weekly:
            return "Outside the window: broad safety checks about once a day"
        case .learning, .unreliableDates, .random:
            return "Light periodic checks while learning"
        }
    }

    // MARK: - Formatting helpers

    private func pad(_ n: Int) -> String { String(format: "%02d", n) }

    private func timeLabel(_ minuteOfDay: Int) -> String {
        let comps = DateComponents(hour: (minuteOfDay / 60) % 24, minute: minuteOfDay % 60)
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }

    private func weekdaysLabel(_ days: [Int]) -> String {
        let set = Set(days)
        if set.isEmpty || set.count == 7 { return "Daily" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols   // index 0 = Sunday
        return days.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }.joined(separator: ", ")
    }

    private func relativeDayTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    private func countdown(to date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        if seconds < 86_400 { return "in \(Int(seconds / 3600))h" }
        return "in \(Int(seconds / 86_400))d"
    }

    // MARK: - Build

    private func rebuildEntries() {
        let now = Date()
        let active = subscriptionStore.subscriptions
            .filter { $0.browseDate == nil && !$0.excludeFromAutoFeedRefresh }
        entries = active
            .map { sub -> Entry in
                let snapshot = appState.releaseRadarSchedule(for: sub, now: now)
                return Entry(
                    id: sub.id,
                    title: sub.title,
                    profile: snapshot.profile,
                    prediction: snapshot.prediction,
                    behaviour: behaviour(profile: snapshot.profile, prediction: snapshot.prediction)
                )
            }
            .sorted { $0.prediction.nextDueAt < $1.prediction.nextDueAt }
        generatedAt = now
        exportURL = writeReleaseRadarReport(for: active, generatedAt: now)
    }

    /// Learning-only "Rebuild Prediction": fetches the last 100 episodes and feeds
    /// filter-eligible publish dates into Release Radar's learner (no episodes are
    /// added to the library), then recomputes the table so the row reflects the
    /// stronger profile — and may visibly move to a new behaviour group once a
    /// pattern is learned.
    private func rebuildPrediction(_ entry: Entry) {
        guard !rebuildingIDs.contains(entry.id),
              let subscription = subscriptionStore.subscription(id: entry.id) else { return }
        rebuildingIDs.insert(entry.id)
        Task {
            let count = await appState.rebuildReleasePrediction(for: subscription, episodeLimit: 100)
            rebuildingIDs.remove(entry.id)
            rebuildEntries()
            withAnimation {
                if let count {
                    resultMessage = "“\(entry.title)” — learned from \(count) eligible episode\(count == 1 ? "" : "s")."
                } else {
                    resultMessage = "“\(entry.title)” — couldn't fetch the feed."
                }
            }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation { resultMessage = nil }
        }
    }

    private func behaviour(profile: FeedScheduleProfile, prediction: FeedRefreshPrediction) -> Behaviour {
        switch prediction.state {
        case .activeWindow, .missedRelease: return .watchingNow
        case .preWindow:                    return .watchingSoon
        default:                            break
        }
        switch profile.kind {
        case .hourly, .rollingBulletin:                     return .hourly
        case .burst:                                        return .dailyMultiple
        case .multiSlot:                                    return .severalTimesWeek
        case .dailyWeekdays:                                return .daily
        case .weekly:                                       return .weekly
        case .learning, .unreliableDates, .random:          return .learning
        }
    }
}

// MARK: - Diagnostic export
//
// Builds a plain-text dump of the SAME data the per-subscription "Release Radar Data"
// screen shows (RefreshStats.releaseRadarDiagnostics), for EVERY active subscription,
// so the whole picture can be exported and submitted for offline trend analysis. Pure
// string formatting + a temp-file write; no mutation, no network. Kept out of the view
// struct as file-private free functions.

private func writeReleaseRadarReport(for subscriptions: [Subscription], generatedAt: Date) -> URL? {
    let text = releaseRadarReportText(for: subscriptions, generatedAt: generatedAt)
    let stamp = ISO8601DateFormatter().string(from: generatedAt).replacingOccurrences(of: ":", with: "-")
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("autohop-release-radar-\(stamp).txt")
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}

private func releaseRadarReportText(
    for subscriptions: [Subscription],
    generatedAt: Date,
    calendar: Calendar = .current
) -> String {
    var out = "AUTOHOP — RELEASE RADAR DIAGNOSTIC EXPORT\n"
    out += "Generated: \(generatedAt.formatted(.dateTime.year().month().day().hour().minute())) (device local time)\n"
    out += "Active subscriptions: \(subscriptions.count)\n"
    // Read on the main actor (backgroundRefreshStatus is a UIApplication API);
    // the export is always user-initiated from the view, so we're on main here.
    let backgroundRefreshStatus = MainActor.assumeIsolated {
        BackgroundTaskCoordinator.backgroundRefreshStatusLabel
    }
    out += "Background App Refresh: \(backgroundRefreshStatus)\n"
    out += "Weekday counts run Sun→Sat. Times are device-local 24h. Spread = observed publish-time range.\n"
    out += "Cadence (median gap, active days) uses the most recent ~25 observations so a stale back-catalogue can't skew the class; weekday counts below are all-history.\n"
    out += String(repeating: "=", count: 64) + "\n\n"

    let ordered = subscriptions.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    for (index, sub) in ordered.enumerated() {
        let observations = sub.refreshStats.releaseObservations(includedBy: sub.downloadFilterSettings)
        let d = sub.refreshStats.releaseRadarDiagnostics(
            downloadFilterSettings: sub.downloadFilterSettings,
            calendar: calendar
        )
        out += "[\(index + 1)] \(sub.title)\n"
        out += "  Feed: \(sub.feedURL.absoluteString)\n"
        if sub.downloadFilterSettings.hasActiveFilters {
            out += "  Download Feed Filters: active; skipped episodes excluded from learner/export\n"
        }
        out += "  Classification: \(d.profile.categoryLabel) · \(reportPercent(d.profile.confidence)) confidence\n"
        out += "  Reason: \(d.profile.reason)\n"
        if let window = d.profile.releaseWindow {
            out += "  Learned window: \(reportWindow(window))\n"
        }
        out += "  Observations: \(d.observationCount) total · \(d.reliableDateCount) reliable\n"
        let quality = d.qualityBreakdown.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        out += "  Date quality: \(quality.isEmpty ? "—" : quality)\n"
        out += "  Median gap: \(d.medianIntervalSeconds.map(reportGap) ?? "—")\n"
        if let center = d.timeOfDayCenterMinute, let spread = d.timeOfDaySpreadMinutes {
            out += "  Typical time: \(reportClock(center)) · spread \(spread) min\n"
        }
        if let dominant = d.dominantWeekday {
            out += "  Dominant weekday: \(reportWeekday(dominant, calendar)) · \(reportPercent(d.dominantWeekdayRatio))\n"
        }
        out += "  Distinct weekdays: \(d.distinctWeekdays) (\(d.distinctBusinessWeekdays) business)\n"
        out += "  Weekday counts: " + (1...7).map { "\(reportWeekday($0, calendar)) \(d.weekdayHistogram[$0] ?? 0)" }.joined(separator: " · ") + "\n"
        out += "  Watch tiers: " + (1...7).map { weekday in
            let probability = d.weekdayProbabilities[weekday] ?? 0
            let tier = FeedRefreshScheduling.watchTier(forProbability: probability, onWeekday: weekday, in: d.profile)
            return "\(reportWeekday(weekday, calendar)) \(Int((probability * 100).rounded()))% \(tier.rawValue)"
        }.joined(separator: " · ") + "\n"
        out += "  Why not Daily:  " + reportGateLine(d.dailyChecks) + "\n"
        out += "  Why not Weekly: " + reportGateLine(d.weeklyChecks) + "\n"
        let recent = observations
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(20)
        out += "  Recent eligible observations (showing \(recent.count) of \(observations.count)):\n"
        for observation in recent {
            let stamp = observation.publishedAt
                .map { $0.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated).hour().minute()) } ?? "no-date"
            out += "    \(stamp)  [\(observation.dateQuality.rawValue)]  \(observation.title)\n"
        }
        out += String(repeating: "-", count: 64) + "\n\n"
    }
    return out
}

private func reportGateLine(_ checks: [FeedScheduleDiagnostics.GateCheck]) -> String {
    checks.map { "\($0.passed ? "✓" : "✗") \($0.label) (\($0.detail))" }.joined(separator: "  ·  ")
}

private func reportPercent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

private func reportClock(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
}

private func reportWindow(_ window: FeedScheduleWindow) -> String {
    var text = "\(reportClock(window.startMinuteOfDay))–\(reportClock(window.endMinuteOfDay))"
    if let spread = window.observedSpreadMinutes {
        text += " · observed spread \(spread) min"
    }
    return text
}

private func reportWeekday(_ weekday: Int, _ calendar: Calendar) -> String {
    let symbols = calendar.shortWeekdaySymbols // index 0 = Sunday
    let index = (weekday - 1) % 7
    return symbols.indices.contains(index) ? symbols[index] : "?"
}

private func reportGap(_ seconds: TimeInterval) -> String {
    let days = seconds / 86_400
    if days >= 1 { return String(format: "%.1f days", days) }
    let hours = seconds / 3_600
    if hours >= 1 { return String(format: "%.1f hours", hours) }
    return "\(Int(seconds / 60)) min"
}
