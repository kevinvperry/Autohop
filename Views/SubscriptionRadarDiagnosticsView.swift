import SwiftUI

// AI CONTEXT — Views/SubscriptionRadarDiagnosticsView.swift (pushed from Settings
// → Release Radar → Feed Refresh Schedule → Diagnostics). Read-only diagnostic
// screen exposing the filter-eligible inputs Release Radar derives for ONE
// subscription and WHY it classified the way it did, so misclassifications can
// be understood and smarter fixes designed. Shows:
//   • Classification — learned profile kind + confidence + reason + learned window,
//     including observed spread so widened/over-narrow Radar windows are visible.
//   • Why-not-daily / why-not-weekly — each row mirrors a real FeedScheduleProfiler
//     guard, with this feed's actual value vs the threshold and a pass/fail mark.
//   • Learning signal — reliable vs total observations, date-quality breakdown,
//     median gap, time-of-day centre/spread, dominant weekday + ratio, weekday counts.
//   • Weekday watch tiers — each weekday's publish probability mapped to its Stage-2
//     intensity (Full / Light / Skip via FeedRefreshScheduling.watchTier) — plus the
//     most recent eligible observations.
// Everything is computed on demand via RefreshStats.releaseRadarDiagnostics(
// downloadFilterSettings:) (FeedScheduleProfiler.diagnostics) — the SAME helpers
// the classifier uses, so the numbers match what Radar acts on. Episodes skipped
// by Download Feed Filters are intentionally excluded. Nothing here is persisted or
// mutated. Dark App Settings styling. See FEATURES.md §17 (Release Radar) + PAGES.md.

struct SubscriptionRadarDiagnosticsView: View {
    let subscriptionID: UUID
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    private var subscription: Subscription? {
        subscriptionStore.subscription(id: subscriptionID)
    }

    private var rowBackground: Color { Color.white.opacity(0.08) }

    var body: some View {
        Group {
            if let sub = subscription {
                content(for: sub)
            } else {
                ContentUnavailableView("Subscription Not Found", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .navigationTitle("Release Radar Data")
        .responsiveInlineNavigationTitle("Release Radar Data")
        .responsiveListSizing()
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func content(for sub: Subscription) -> some View {
        let diag = sub.refreshStats.releaseRadarDiagnostics(downloadFilterSettings: sub.downloadFilterSettings)
        Form {
            classificationSection(diag)
            gatesSection("Why not Daily", checks: diag.dailyChecks)
            gatesSection("Why not Weekly", checks: diag.weeklyChecks)
            signalSection(diag)
            weekdaySection(diag)
            observationsSection(sub)
        }
    }

    private func classificationSection(_ diag: FeedScheduleDiagnostics) -> some View {
        Section("Classification") {
            LabeledContent("Profile") {
                Text(diag.profile.categoryLabel).foregroundStyle(.purple).bold()
            }
            LabeledContent("Confidence") {
                Text("\(percent(diag.profile.confidence))").foregroundStyle(.secondary).monospacedDigit()
            }
            if let window = diag.profile.releaseWindow {
                LabeledContent("Learned window") {
                    Text(windowLabel(window))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(diag.profile.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(rowBackground)
    }

    private func gatesSection(_ title: String, checks: [FeedScheduleDiagnostics.GateCheck]) -> some View {
        Section(title) {
            ForEach(checks, id: \.label) { check in
                HStack(spacing: 10) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? .green : .red)
                    Text(check.label)
                    Spacer()
                    Text(check.detail).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    private func signalSection(_ diag: FeedScheduleDiagnostics) -> some View {
        Section("Learning signal") {
            LabeledContent("Reliable dates") {
                Text("\(diag.reliableDateCount) of \(diag.observationCount)").foregroundStyle(.secondary).monospacedDigit()
            }
            if let median = diag.medianIntervalSeconds {
                LabeledContent("Median gap") { Text(gapText(median)).foregroundStyle(.secondary) }
            }
            if let center = diag.timeOfDayCenterMinute, let spread = diag.timeOfDaySpreadMinutes {
                LabeledContent("Typical time") {
                    Text("\(clock(center)) · spread \(spread) min").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let dominant = diag.dominantWeekday {
                LabeledContent("Dominant weekday") {
                    Text("\(weekdayName(dominant)) · \(percent(diag.dominantWeekdayRatio))").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Distinct weekdays") {
                Text("\(diag.distinctWeekdays) (\(diag.distinctBusinessWeekdays) business)").foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(diag.qualityBreakdown.keys.sorted(), id: \.self) { key in
                LabeledContent("Date quality · \(key)") {
                    Text("\(diag.qualityBreakdown[key] ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    private func weekdaySection(_ diag: FeedScheduleDiagnostics) -> some View {
        Section {
            ForEach(1...7, id: \.self) { weekday in
                let probability = diag.weekdayProbabilities[weekday] ?? 0
                let count = diag.weekdayHistogram[weekday] ?? 0
                let tier = FeedRefreshScheduling.watchTier(forProbability: probability, onWeekday: weekday, in: diag.profile)
                HStack(spacing: 10) {
                    Text(weekdayName(weekday)).frame(width: 40, alignment: .leading)
                    Text("\(count) ep").font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Text("\(Int((probability * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    tierBadge(tier)
                }
            }
        } header: {
            Text("Weekday watch tiers")
        } footer: {
            Text("Full = watched closely in the learned window · Light = an occasional check · Skip = not watched.")
        }
        .listRowBackground(rowBackground)
    }

    @ViewBuilder
    private func tierBadge(_ tier: FeedWatchTier) -> some View {
        let color: Color = tier == .full ? .green : (tier == .light ? .yellow : Color(white: 0.5))
        Text(tierLabel(tier))
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    private func tierLabel(_ tier: FeedWatchTier) -> String {
        switch tier {
        case .full:  return "Full"
        case .light: return "Light"
        case .skip:  return "Skip"
        }
    }

    private func observationsSection(_ sub: Subscription) -> some View {
        let all = sub.refreshStats.releaseObservations(includedBy: sub.downloadFilterSettings)
        let recent = all
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(25)
        return Section("Recent eligible observations (\(all.count))") {
            if recent.isEmpty {
                Text("No eligible release observations recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(recent), id: \.episodeKey) { observation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(observation.publishedAt.map { fullStamp($0) } ?? "No publish date")
                            .font(.subheadline)
                        Text("\(observation.dateQuality.rawValue) · \(observation.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    // MARK: - Formatting

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func windowLabel(_ window: FeedScheduleWindow) -> String {
        var text = "\(clock(window.startMinuteOfDay))–\(clock(window.endMinuteOfDay))"
        if let spread = window.observedSpreadMinutes {
            text += " · spread \(spread) min"
        }
        return text
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols // index 0 = Sunday
        let index = (weekday - 1) % 7
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }

    private func gapText(_ seconds: TimeInterval) -> String {
        let days = seconds / 86_400
        if days >= 1 { return String(format: "%.1f days", days) }
        let hours = seconds / 3_600
        if hours >= 1 { return String(format: "%.1f hours", hours) }
        return "\(Int(seconds / 60)) min"
    }

    private func fullStamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
    }
}
