import SwiftUI

// AI CONTEXT — Views/EpisodeBadges.swift. Shared presentation components for
// episode rows/detail:
//   • Video/Explicit indicators (small icon-only variants for dense lists;
//     glass text pills remain for large detail headers)
//   • EpisodeStatusKind + EpisodeStatusPill (colour-coded state capsule; each
//     page supplies its own statusKind(for:) resolver; includes Skipped for
//     not-downloaded episodes currently excluded by Download Feed Filters)
//   • glassCard(cornerRadius:highlighted:) View modifier (glass content-card
//     surface; `highlighted` applies the same purple tint as glassCapsule for
//     accent-action surfaces such as Discover's rail-trailing "See All" tile)
// Pure presentation; shared across episode lists, preview, queue, and detail pages.

// MARK: - Video Pill (small)
//
// Icon-only TV indicator shown in dense episode rows. Deliberately has no glass,
// background, or capsule padding; callers own placement and spacing.

struct VideoPillSmall: View {
    var body: some View {
        Image(systemName: "tv.fill")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(minWidth: 14, minHeight: 14)
            .accessibilityLabel("Video episode")
    }
}

// MARK: - Video Pill (large)
//
// "Video" text pill — large counterpart to VideoPillSmall, used in detail headers.

struct VideoPillLarge: View {
    var body: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "tv.fill")
            Text("Video")
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label.glassEffect(in: Capsule())
        } else {
            label.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Explicit Pill (large)
//
// "Explicit" text pill used in detail headers for explicit shows/episodes.

struct ExplicitPillLarge: View {
    var body: some View {
        let label = HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 11, height: 11)
                Text("E")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black)
            }
            Text("Explicit")
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label.glassEffect(in: Capsule())
        } else {
            label.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Explicit Pill Small
//
// Icon-only "E in a square" indicator — small counterpart to ExplicitPillLarge,
// styled like the iTunes explicit badge with no surrounding material or capsule.

struct ExplicitPillSmall: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 11, height: 11)
            Text("E")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(minWidth: 14, minHeight: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Explicit episode")
    }
}

// MARK: - Episode Status Pill
//
// Colour-coded capsule communicating episode state at a glance. Shared across the
// Priority (PodcastsView), Podcast Detail, and Individual Subscription pages — each
// view computes its own `EpisodeStatusKind` via a local `statusKind(for:)` helper.
// `.inactive` is used on the Priority page only.

enum EpisodeStatusKind {
    case unplayed, queued, partiallyPlayed, nowPlaying, played, archived, inactive, skipped

    var label: String {
        switch self {
        case .unplayed:        return "Unplayed"
        case .queued:          return "Queued"
        case .partiallyPlayed: return "Paused"
        case .nowPlaying:      return "Playing"
        case .played:          return "Played"
        case .archived:        return "Archived"
        case .inactive:        return "Inactive"
        case .skipped:         return "Skipped"
        }
    }

    var color: Color {
        switch self {
        case .unplayed:        return Color.gray
        case .queued:          return Color.teal
        case .partiallyPlayed: return Color.yellow
        case .nowPlaying:      return Color.green
        case .played:          return Color.blue
        case .archived:        return Color.purple
        case .inactive:        return Color.orange
        case .skipped:         return Color(white: 0.42)
        }
    }
}

struct EpisodeStatusPill: View {
    let kind: EpisodeStatusKind

    var body: some View {
        let label = Text(kind.label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

        if #available(iOS 26, *) {
            label
                .background(kind.color.opacity(0.45), in: Capsule())
                .glassEffect(in: Capsule())
        } else {
            label
                .background(kind.color.opacity(0.82), in: Capsule())
        }
    }
}

// MARK: - Glass Card
//
// Shared rounded-rect card surface used by content cards (episode list on the
// Podcast Detail page, episode description on the Individual Episode page).
// iOS 26+ uses real glass; iOS 17–25 falls back to `.ultraThinMaterial`.

extension View {
    /// `highlighted: true` adds the same purple tint `glassCapsule` uses, for a
    /// rounded-rect surface that must read as an accent action rather than a
    /// neutral content card (Discover's rail-trailing "See All" tile).
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat, highlighted: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if highlighted {
                self.glassEffect(.regular.tint(.purple), in: RoundedRectangle(cornerRadius: cornerRadius))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            if highlighted {
                // Matches glassCapsule's fallback exactly. No clipShape here —
                // it would shave the 1 pt stroke in half at the edge.
                self
                    .background(Color.purple.opacity(0.22), in: RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.purple.opacity(0.35), lineWidth: 1))
            } else {
                self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
    }

    /// Glass capsule pill. `highlighted: true` adds a purple tint — used for
    /// category chips, rank badges, and any purple-accent pill surface.
    @ViewBuilder
    func glassCapsule(highlighted: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if highlighted {
                self.glassEffect(.regular.tint(.purple), in: Capsule())
            } else {
                self.glassEffect(in: Capsule())
            }
        } else {
            if highlighted {
                self
                    .background(Color.purple.opacity(0.22), in: Capsule())
                    .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 1))
            } else {
                self.background(Color.white.opacity(0.08), in: Capsule())
            }
        }
    }
}

// MARK: - Meta card date formatting
//
// The Player Details + Podcast Settings meta-card grid splits a single publishedAt
// into TWO complementary cards:
//   • "Published" → relativePublishedDateLabel — which DAY (Today / Yesterday /
//     "N Days Ago" up to 6 / then exact date).
//   • "Released"  → relativeReleasedLabel — the TIME (relative under 24h, actual
//     clock time at 24h+).
// relativePublishedLabel below is a SEPARATE, time-tiered formatter used by every
// episode LIST (Queue / Discover / Podcast Detail / etc.) for consistency — do NOT
// conflate it with the meta-card "Published" formatter (that's why a same-day
// episode reads "11 hours ago" in a list but "Today" on the Published card).

/// Canonical tiered relative label used across every episode list AND point-in-time
/// timestamp (publish dates, plus the Downloads page's downloaded/archived times) so
/// they all read the same as the Subscriptions page:
/// "Just now" / "15 mins ago" (< 1h) / "2 hours ago" (< 24h) / "Yesterday" /
/// "N days ago" (2–6 days) / an abbreviated exact date for anything older (year shown
/// only when it isn't the current year, e.g. "12 Jun" / "28 Dec 2024"). For day-BUCKET
/// grouping (History headers, the "Published" meta-card) use relativePublishedDateLabel.
func relativePublishedLabel(_ date: Date) -> String {
    let now = Date()
    let elapsed = now.timeIntervalSince(date)
    let calendar = Calendar.current

    if elapsed < 60 { return "Just now" }
    if elapsed < 3600 {
        let mins = Int(elapsed / 60)
        return "\(mins) min\(mins == 1 ? "" : "s") ago"
    }
    if elapsed < 86_400 {
        let hours = Int(elapsed / 3600)
        return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    }
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)
    ).day ?? 0
    if days == 1 { return "Yesterday" }
    if (2...6).contains(days) { return "\(days) days ago" }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    return sameYear
        ? date.formatted(.dateTime.day().month(.abbreviated))
        : date.formatted(.dateTime.day().month(.abbreviated).year())
}

/// Date-bucketed publish label for the "Published" META CARD (Player Details +
/// Podcast Settings). Distinct from relativePublishedLabel above (the shared
/// episode-LIST formatter, which is time-tiered and shows "11 hours ago" for a
/// same-day episode). This answers "which day?": Today / Yesterday / "N Days Ago"
/// up to 6 days / then an abbreviated exact date (year only when not the current
/// year, e.g. "12 Jun" / "28 Dec 2024").
func relativePublishedDateLabel(_ date: Date) -> String {
    let now = Date()
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)
    ).day ?? 0
    if (2...6).contains(days) { return "\(days) Days Ago" }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    return sameYear
        ? date.formatted(.dateTime.day().month(.abbreviated))
        : date.formatted(.dateTime.day().month(.abbreviated).year())
}

/// Release-TIME label for the "Released" meta card. Under 24h: relative elapsed
/// time ("Just now" / "10 minutes ago" / "2 hours ago"). 24h or older: the actual
/// clock time of release ("6:54 AM") — the time-of-day complement to the
/// date-bucketed "Published" card (relativePublishedDateLabel).
func relativeReleasedLabel(_ date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 60 { return "Just now" }
    if elapsed < 3600 {
        let mins = Int(elapsed / 60)
        return "\(mins) minute\(mins == 1 ? "" : "s") ago"
    }
    if elapsed < 86_400 {
        let hours = Int(elapsed / 3600)
        return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    }
    return date.formatted(.dateTime.hour().minute())
}

/// "Distributed" meta card value (added 2026-07-11, Kevin's request; pill
/// title renamed from "Released Day" same day): the full weekday name the
/// episode was released on, in the user's local timezone/calendar
/// (`.formatted(.dateTime.weekday(.wide))` uses `Calendar.current` / the
/// system locale, same as every other date formatting call in this file — no
/// separate timezone handling needed). A standalone THIRD meta card alongside
/// "Published"/"Released" — deliberately not folded into either existing
/// label, since Kevin asked to leave those two untouched.
func releasedWeekdayLabel(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.wide))
}
