// AI CONTEXT — Navigation compatibility, 20 September 2026 (PodcastReplayView.swift).
// PURPOSE: Prevent duplicate native/custom Back controls reported on iOS 27.
// COLLABORATOR: RootView.swift owns appNavigationBackButton: native Back on iOS
// 27+, branded ambient dismiss on older systems. Do not add a second leading Back
// or mutate the outer path; preserve the nearest parent and existing mini-player.
// SCOPE: Both Replay and its Starting Episode picker use this policy.
// EVIDENCE: Docs/IOS27_NAVIGATION_BACK_AUDIT.md and NavigationChromeTests.

import SwiftUI
import UserNotifications

// AI CONTEXT — Podcast Replay setup/manage UI, Version 1.7 (2026-09-13).
// Uses the existing glassCard, purple settings tint, adaptive Form sizing,
// SettingsRowLabel and navigation/mini-player conventions. Numbered setup cards
// explain episode selection, calendar scheduling and a conditional preview.
// Schedule drafts commit only on Save; Episode Limit writes immediately to the
// same store setting used by Podcast Settings. Daily/Weekdays/Choose Days and
// multiple times use the shared calendar policy. Preserve live nextDue until
// the user edits cadence/date/time; old test schedules adopt the new controls. Do not reintroduce a
// device acknowledgement gate: show concise update/sync and fixed-owner guidance.
// Date controls and previews use the stored zone, not the viewing device's zone.
// Binge Mode hides pace controls, seeds one matching episode and prefetches one
// successor on a successful start. The playing episode is excluded from its
// Episode Limit count; existing Up Next priority and manual pins are unchanged.
struct PodcastReplayView: View {
    let subscriptionID: UUID
    var startingEpisodeID: UUID? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: SubscriptionStore
    @EnvironmentObject private var replayCoordinator: PodcastReplayCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var first = Date().addingTimeInterval(3600)
    private enum Pace: String, CaseIterable { case daily = "Daily", weekdays = "Weekdays", chosen = "Choose Days" }
    private struct ReleaseTime: Identifiable {
        let id = UUID()
        var minute: Int
    }
    @State private var pace: Pace = .daily
    @State private var chosenDays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var times: [ReleaseTime] = [.init(minute: 360)]
    @State private var scheduleChanged = false
    @State private var notify = true
    @State private var bingeMode = false
    @State private var loaded = false
    @State private var refreshing = false

    private var subscription: Subscription? { store.subscription(id: subscriptionID) }
    private var activeReplay: PodcastReplay? { subscription?.autoArchiveSettings.replay.flatMap { $0.enabled ? $0 : nil } }
    private var selectedEpisode: Episode? {
        subscription?.episodes.first { $0.id == selectedID } ?? activeReplay?.start
    }
    private var scheduleTimeZone: TimeZone {
        TimeZone(identifier: activeReplay?.timeZoneID ?? TimeZone.current.identifier) ?? .current
    }

    var body: some View {
        Group {
            if let sub = subscription {
                Form {
                    introduction(sub)
                    if let replay = activeReplay { currentSchedule(sub, replay: replay) }
                    startingPoint(sub)
                    bingeSettings
                    if !bingeMode { schedule }
                    preview(sub)
                    listeningRules(sub)
                    notifications
                    saveSection(sub)
                }
                .responsiveListSizing()
                .listSectionSpacing(AdaptiveLayoutMetrics.settingsSectionSpacing)
            } else {
                ContentUnavailableView("Subscription Not Found", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Podcast Replay")
        .responsiveInlineNavigationTitle("Podcast Replay")
        .appNavigationBackButton()
        .miniPlayerBar(subscriptionID: subscriptionID)
        .task {
            guard !loaded, let sub = subscription else { return }
            // Populate the draft immediately; a slow RSS refresh must not leave
            // a blank editor or overwrite a choice made while the fetch runs.
            loaded = true
            selectedID = startingEpisodeID ?? activeReplay?.start.id ?? sub.episodes.min { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }?.id
            if let replay = activeReplay {
                first = replay.nextDue; notify = replay.notifyCaughtUp; bingeMode = replay.isBinge
                if let calendar = replay.calendarSchedule {
                    chosenDays = Set(calendar.weekdays)
                    pace = calendar.weekdays == Array(1...7) ? .daily : (calendar.weekdays == [2, 3, 4, 5, 6] ? .weekdays : .chosen)
                    times = calendar.minutes.map { ReleaseTime(minute: $0) }
                } else {
                    pace = replay.everyDays == 7 ? .chosen : .daily
                    chosenDays = [localCalendar.component(.weekday, from: first)]
                    times = [ReleaseTime(minute: minuteOfDay(first))]
                    scheduleChanged = true
                }
            } else {
                times = [ReleaseTime(minute: minuteOfDay(first))]
            }
            refreshing = true
            await appState.refreshSubscription(sub, episodeLimit: nil)
            refreshing = false
        }
    }

    private func introduction(_ sub: Subscription) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 30, weight: .semibold)).foregroundStyle(.purple)
                        .accessibilityHidden(true)
                    Spacer()
                    if activeReplay != nil { EpisodeStatusPill(kind: .replay) }
                }
                Text("Start earlier.\nListen at your pace.")
                    .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text(sub.title).font(.headline).foregroundStyle(.secondary)
                Text("Turn this podcast’s back catalogue into your own listening schedule. Choose where to begin, and Autohop brings the next episodes into Up Next for you.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.35), lineWidth: 1))
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    private func currentSchedule(_ sub: Subscription, replay: PodcastReplay) -> some View {
        card("Your Replay", explanation: "Your schedule stays on while it waits for a release time or room in Up Next.") {
            Label(status(sub), systemImage: "clock.arrow.circlepath")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Episodes waiting to be finished", value: "\(replay.outstanding.count)")
            if replay.confirmedCaughtUp(in: sub), !replay.keptSchedule {
                Divider()
                Text("You’re caught up! Keep this schedule for future episodes, or turn Replay off to return to normal new-episode downloads.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Keep Schedule") {
                    replayCoordinator.decide(subscriptionID: sub.id, sessionID: replay.sessionID, keep: true)
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private func startingPoint(_ sub: Subscription) -> some View {
        card("Choose your starting point", step: "1", explanation: "Pick an earlier episode to begin with. Matching episodes follow in release order, oldest first.") {
            if let ep = selectedEpisode {
                HStack(alignment: .center, spacing: 14) {
                    CachedArtworkImage(url: ep.artworkURL, fallbackURL: sub.artworkURL, targetSize: CGSize(width: 64, height: 64)) {
                        Image(systemName: "waveform").foregroundStyle(.purple)
                    }
                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ep.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let date = ep.publishedAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if activeReplay == nil {
                NavigationLink {
                    PodcastReplayEpisodePicker(subscriptionID: sub.id, selection: $selectedID)
                } label: {
                    SettingsRowLabel(title: selectedEpisode == nil ? "Choose an Episode" : "Change Starting Episode", systemImage: "magnifyingglass")
                }
                if refreshing { ProgressView("Checking for more episodes…").font(.caption) }
                Text("Choose from episodes still available in the publisher’s feed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This is where your current Replay began. To start somewhere else, turn Replay off below, then choose another episode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedDays: [Int] {
        switch pace {
        case .daily: return Array(1...7)
        case .weekdays: return [2, 3, 4, 5, 6]
        case .chosen: return chosenDays.sorted()
        }
    }
    private var calendarDraft: PodcastReplay.CalendarSchedule? {
        return .init(weekdays: selectedDays, minutes: times.map(\.minute))
    }
    private var validSchedule: Bool {
        bingeMode || (calendarDraft != nil && Set(times.map(\.minute)).count == times.count)
    }
    private var releaseBoundary: Date {
        if !scheduleChanged, let replay = activeReplay { return replay.nextDue }
        return localCalendar.startOfDay(for: first)
    }
    private var nextDraftRelease: Date {
        if !scheduleChanged, let replay = activeReplay { return replay.nextDue }
        return calendarDraft?.nextDate(onOrAfter: releaseBoundary, timeZoneID: scheduleTimeZone.identifier) ?? first
    }
    private var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = scheduleTimeZone
        return calendar
    }
    private func minuteOfDay(_ date: Date) -> Int {
        localCalendar.component(.hour, from: date) * 60 + localCalendar.component(.minute, from: date)
    }
    private func timeDate(_ minute: Int) -> Date {
        // Use a neutral day for time-only editing so a DST gap on the selected
        // start date cannot silently change the user's recurring wall-clock time.
        localCalendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: minute / 60, minute: minute % 60))!
    }
    private var daySummary: String {
        switch pace {
        case .daily: return "every day"
        case .weekdays: return "Monday to Friday"
        case .chosen: return [2, 3, 4, 5, 6, 7, 1].filter { chosenDays.contains($0) }
            .map { localCalendar.weekdaySymbols[$0 - 1] }.joined(separator: ", ")
        }
    }
    private var bingeSettings: some View {
        card("Binge Mode", explanation: "Keep the next episode ready whenever you start listening.") {
            Toggle(isOn: $bingeMode) {
                SettingsRowLabel(title: "Binge Mode", systemImage: "play.rectangle.on.rectangle")
            }
            Text("Your first matching episode downloads when you enable Replay. Starting it downloads the next matching episode, ready for later. Your existing Up Next priority order still applies.")
                .font(.caption).foregroundStyle(.secondary)
            if bingeMode {
                Text("No schedule needed. With Episode Limit set to 1, keep one upcoming episode as well as the episode you’ve started.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var schedule: some View {
        card("Set your pace", step: "2", explanation: "Choose the days and times you’d like the next episode added to Up Next. Replay waits when your Episode Limit is reached.") {
            Picker("Release days", selection: Binding(get: { pace }, set: { pace = $0; scheduleChanged = true })) {
                ForEach([Pace.daily, .weekdays, .chosen], id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if pace == .chosen {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Button {
                            if chosenDays.contains(day) {
                                if chosenDays.count > 1 { chosenDays.remove(day) }
                            } else { chosenDays.insert(day) }
                            scheduleChanged = true
                        } label: {
                            Text(localCalendar.shortWeekdaySymbols[day - 1])
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(chosenDays.contains(day) ? Color.white : Color.primary)
                                .background(chosenDays.contains(day) ? Color.purple : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(localCalendar.weekdaySymbols[day - 1])
                            .accessibilityAddTraits(chosenDays.contains(day) ? [.isSelected] : [])
                            .accessibilityHint("Select at least one release day")
                    }
                }
            }
            Divider()
            DatePicker(selection: Binding(get: { first }, set: { first = $0; scheduleChanged = true }), displayedComponents: .date) {
                SettingsRowLabel(title: activeReplay == nil ? "Start date" : "Continue from", systemImage: "calendar")
            }.environment(\.timeZone, scheduleTimeZone)
            ForEach($times) { $time in
                HStack {
                    DatePicker(selection: Binding(get: { timeDate(time.minute) }, set: { time.minute = minuteOfDay($0); scheduleChanged = true }), displayedComponents: .hourAndMinute) {
                        SettingsRowLabel(title: "Release time", systemImage: "clock")
                    }.environment(\.timeZone, scheduleTimeZone)
                    if times.count > 1 {
                        Button { times.removeAll { $0.id == time.id }; scheduleChanged = true } label: {
                            Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain).foregroundStyle(.purple)
                            .accessibilityLabel("Remove release at \(releaseTime(timeDate(time.minute)))")
                    }
                }
            }
            Button {
                let used = Set(times.map(\.minute))
                let candidate = ((times.last?.minute ?? 360) + 60) % 1440
                if let minute = (0..<1440).map({ (candidate + $0) % 1440 }).first(where: { !used.contains($0) }) {
                    times.append(ReleaseTime(minute: minute)); scheduleChanged = true
                }
            } label: { Label("Add another time", systemImage: "plus.circle") }
                .disabled(times.count >= 1440)
            Text("One episode at each time, on every selected day. Add another time if you listen more than once a day.")
                .font(.caption).foregroundStyle(.secondary)
            if validSchedule {
                Label("One episode at \(times.map(\.minute).sorted().map { releaseTime(timeDate($0)) }.joined(separator: ", ")) · \(daySummary)", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.purple)
                Text("\(activeReplay == nil ? "First" : "Next") release: \(releaseDate(nextDraftRelease)) at \(releaseTime(nextDraftRelease))")
                    .font(.subheadline)
            } else {
                Text("Choose a different time for each release.").font(.caption).foregroundStyle(.orange)
            }
            Text("Time zone: \(scheduleTimeZone.identifier.replacingOccurrences(of: "_", with: " ")). Releases may arrive later if Autohop cannot run in the background or connect to the internet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func preview(_ sub: Subscription) -> some View {
        card("See what’s coming", step: bingeMode ? "2" : "3", explanation: bingeMode ? "The next matching episodes in release order. Binge Mode prepares one ahead as you listen; Up Next decides what plays next." : "A preview of the next matching episodes. These dates assume there is room in Up Next.") {
            if !validSchedule {
                Text("Choose different release times to see the preview.").foregroundStyle(.secondary)
            } else if let ep = selectedEpisode {
                episodePreview(sub, episode: ep)
            } else {
                Label("Choose a starting episode to see your preview.", systemImage: "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func episodePreview(_ sub: Subscription, episode: Episode) -> some View {
        var plan = activeReplay ?? PodcastReplay(start: episode, firstRelease: first, everyDays: 1, ownerID: replayCoordinator.ownerID)
        plan.firstRelease = first; plan.nextDue = nextDraftRelease; plan.everyDays = 1
        plan.calendarSchedule = calendarDraft
        let matches = Array(plan.matchingCandidates(in: sub).prefix(3))
        let next = nextDraftRelease
        let dates = [next, plan.nextDate(after: next), plan.nextDate(after: plan.nextDate(after: next))]
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, ep in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.purple)
                        .frame(width: 28, height: 28).background(Color.purple.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ep.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(bingeMode ? (index == 0 ? (activeReplay == nil ? "Downloads when you enable Replay" : "Next to prepare when there is room") : "Prepares when the previous episode starts") : "Planned · \(releaseDate(dates[index])) at \(releaseTime(dates[index]))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if matches.isEmpty {
                Text("No matching episodes are available yet. Check your starting point and Feed Filters, or wait for the publisher to add more.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if plan.hasUnknownDuration(in: sub) {
                Text("Some episodes still need duration information. Replay waits at those episodes when a duration filter needs it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if activeReplay == nil, !sub.downloadFilterSettings.evaluation(for: episode).isIncluded {
                Text("Your starting episode does not match the Feed Filters. Replay begins with the next matching episode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func listeningRules(_ sub: Subscription) -> some View {
        card("Make room for listening", explanation: "Replay works with this podcast’s existing settings. You do not need to create separate rules.") {
            Picker(selection: Binding(
                get: { subscription?.autoArchiveSettings.episodeLimit ?? sub.autoArchiveSettings.episodeLimit },
                set: { limit in
                    guard var settings = subscription?.autoArchiveSettings else { return }
                    settings.episodeLimit = limit
                    store.updateAutoArchiveSettings(subscriptionID: subscriptionID, settings: settings)
                }
            )) {
                ForEach(AutoArchiveSettings.EpisodeLimit.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                SettingsRowLabel(title: "Episode Limit", systemImage: "archivebox")
            }.pickerStyle(.menu)
            Text(bingeMode ? "Changes save immediately and also appear in Podcast Settings. In Binge Mode, the episode you’ve started does not use an upcoming-episode place. Replay prepares at most one unstarted episode ahead." : "Changes save immediately and also appear in Podcast Settings. This limits episodes waiting to be finished, not episodes per day.")
                .font(.caption).foregroundStyle(.secondary)
            Text(bingeMode ? "Starting an episode makes room to prepare the next one. If other downloads fill the limit, finish or archive one to free a place." : "When the limit is reached, new releases wait. Finish or manually archive an episode to free a place. An overdue episode can then be added straight away.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            NavigationLink { DownloadFiltersView(subscriptionID: sub.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    SettingsRowLabel(title: "Download Feed Filters", systemImage: "line.3.horizontal.decrease.circle")
                    Text(sub.downloadFilterSettings.hasActiveFilters ? "Your current filters apply to Replay." : "No filters set — all episodes can be included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notifications: some View {
        card("Know when you’re caught up", explanation: "After you finish the available matching episodes, choose whether to keep this schedule or return to normal new-episode downloads.") {
            Toggle(isOn: $notify) {
                SettingsRowLabel(title: "Caught-up notification", systemImage: "bell.badge")
            }
            Text("The choice is always available here, even if notifications are off.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveSection(_ sub: Subscription) -> some View {
        card(activeReplay == nil ? "Ready to Replay?" : "Save your changes", explanation: "While Replay is on, normal automatic downloads of newly published episodes are paused. You can still download any episode manually.") {
            Text("For the best Replay experience, keep Autohop up to date on all your devices. With iCloud Sync enabled, your Replay settings and Up Next queue sync automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text("New episodes are scheduled by the device where you enabled Replay. Keep using Autohop on that device so it can add new releases.")
                .font(.caption).foregroundStyle(.secondary)
            Button(action: { save(sub) }) {
                Label(activeReplay == nil ? "Enable Podcast Replay" : "Save Changes", systemImage: "arrow.counterclockwise")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!validSchedule || selectedEpisode == nil || replayCoordinator.ownerID == "unavailable" || sub.browseDate != nil)
            if replayCoordinator.ownerID == "unavailable" {
                Text("Autohop cannot save this device’s scheduling identity right now. Reopen the app and try again.").font(.caption).foregroundStyle(.secondary)
            }
            if let replay = activeReplay {
                Divider()
                Button("Turn Off Podcast Replay", role: .destructive) {
                    replayCoordinator.decide(subscriptionID: sub.id, sessionID: replay.sessionID, keep: false)
                }.buttonStyle(.bordered).controlSize(.large)
                Text("Returns to normal automatic downloads. Episodes already downloaded remain available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(_ title: String, step: String? = nil, explanation: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    if let step {
                        Text(step).font(.caption.bold()).foregroundStyle(.purple)
                            .frame(width: 26, height: 26).background(Color.purple.opacity(0.16), in: Circle())
                            .accessibilityHidden(true)
                    }
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                }
                Text(explanation).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    private func releaseDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: scheduleTimeZone))
    }
    private func releaseTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: scheduleTimeZone))
    }
    private func save(_ sub: Subscription) {
        guard validSchedule, let ep = selectedEpisode, let current = subscription else { return }
        replayCoordinator.configure(subscription: current, start: ep, first: releaseBoundary, days: 1, notify: notify,
                                    calendarSchedule: calendarDraft, scheduleChanged: scheduleChanged, bingeMode: bingeMode)
        if notify { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } }
        dismiss()
    }
    private func status(_ sub: Subscription) -> String {
        guard let replay = activeReplay else { return "" }
        if sub.excludeFromAutoFeedRefresh { return "Paused while this podcast is inactive" }
        if replay.outstanding.isEmpty, replay.hasUnknownDuration(in: sub) { return "Waiting for episode information" }
        if replay.caughtUp(in: sub), !replay.confirmedCaughtUp(in: sub) { return "Checking for newer matching episodes" }
        if replay.confirmedCaughtUp(in: sub) { return replay.keptSchedule ? "Waiting for the next matching episode" : "You’re caught up" }
        if sub.replayQueueEpisodes.contains(where: { $0.downloadState == .failed }) { return "Waiting to retry a download" }
        let limit = sub.autoArchiveSettings.episodeLimit.rawValue
        if replay.isBinge {
            if replay.outstanding.contains(where: { $0.startedAt == nil }) { return "Ready to prepare the next episode when you start listening" }
            return "Preparing the next matching episode when there is room"
        }
        if limit > 0 && replay.outstanding.count >= limit { return "Waiting for space in Up Next" }
        return "Next release: \(releaseDate(replay.nextDue)) at \(releaseTime(replay.nextDue))"
    }
}

// AI CONTEXT — Search is local to the available catalogue, not Discover. A
// full-row button commits a real episode ID and returns to the draft editor.
// No schedule or playback mutation occurs here. Match the app's dark/purple
// navigation, adaptive list sizing and mini-player coverage on this pushed page.
private struct PodcastReplayEpisodePicker: View {
    let subscriptionID: UUID
    @Binding var selection: UUID?
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var episodes: [Episode] {
        (store.subscription(id: subscriptionID)?.episodes ?? [])
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.publishedAt ?? .distantPast, $0.audioURL.absoluteString) < ($1.publishedAt ?? .distantPast, $1.audioURL.absoluteString) }
    }
    var body: some View {
        List {
            Section {
                ForEach(episodes) { episode in
                    Button {
                        selection = episode.id
                        dismiss()
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: selection == episode.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.purple).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(episode.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                if let date = episode.publishedAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == episode.id ? [.isSelected] : [])
                }
            } header: { Text("Oldest to newest") }
        }
        .overlay { if episodes.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: "Find an episode in this podcast")
        .responsiveListSizing().scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea()).tint(.purple).preferredColorScheme(.dark)
        .navigationTitle("Starting Episode").responsiveInlineNavigationTitle("Starting Episode")
        .appNavigationBackButton()
        .miniPlayerBar(subscriptionID: subscriptionID)
    }
}
