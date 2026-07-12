import Foundation

// AI CONTEXT — Models/PlaybackPreference.swift
// Per-podcast audio settings stored on Subscription.playbackPreference and
// consumed by PlaybackEngine: speed (1.0–2.5x), start/end skip seconds (real
// file time), VocalBoostLevel (off/light/standard/strong — selects which stages
// of the high-pass→dynamics→limiter chain are active), TrimSilenceAmount
// (off/low/medium/high — selects SilenceDetector tuning).
// Any non-off boost or trim forces the AVAudioEngine playback path; video
// episodes ignore both and always use AVPlayer.
//
// DEFAULTS — read carefully, there are two distinct notions:
//  - `PlaybackPreference.default` = 1.0x / vocalBoost .off / trim .off. This is
//    what a NEW subscription is seeded with (via AppSettings.defaultPlayback
//    Preference, which itself defaults to .default).
//  - Pre-existing users were moved to 1.6x / Strong / Low by ONE-SHOT migrations
//    in AppState.bootstrap (playbackSpeed160Migrated / vocalBoostLevelMigrated /
//    trimSilenceLowDefaultMigrated). Those are not "the default" — they are a
//    historical migration of already-subscribed shows.
// The member-wise init's vocalBoostLevel default, init(from:)'s missing-key
// fallback, and `.default` all now agree on .off (ASSESSMENT.md B3, resolved
// 2026-06-18). The legacy `vocalBoostEnabled` boolean key still maps true→.strong
// / false→.off for old persisted data.
// `EpisodeTrimDurationText` is the single display formatter for start/end trim
// values on both settings pages. Keep that wording UI-only: persisted and engine
// values remain TimeInterval seconds so playback and sync formats do not change.
public enum TrimSilenceAmount: String, CaseIterable, Codable, Sendable {
    case off
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}

public enum VocalBoostLevel: String, CaseIterable, Codable, Sendable {
    case off
    case light
    case standard
    case strong

    public var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .standard: return "Standard"
        case .strong: return "Strong"
        }
    }

    public var usesSpokenAudioMode: Bool {
        self != .off
    }

    public var outputGain: Float {
        switch self {
        case .strong:
            return 1.1
        case .off, .light, .standard:
            return 1.0
        }
    }
}

public struct PlaybackPreference: Equatable, Codable, Sendable {
    public var speed: Double
    public var startSkipSeconds: TimeInterval
    public var endSkipSeconds: TimeInterval
    public var vocalBoostLevel: VocalBoostLevel
    public var trimSilence: TrimSilenceAmount

    public var vocalBoostEnabled: Bool {
        vocalBoostLevel != .off
    }

    public static let speedOptions: [Double] = stride(from: 1.0, through: 2.5, by: 0.1).map {
        (Double(Int(($0 * 10).rounded())) / 10)
    }

    // Defaults for NEW subscriptions. Existing subscriptions keep their own
    // persisted values (and the one-shot migrations in AppState moved pre-existing
    // users to 1.6x / Strong / Low — those are not affected by changes here).
    public static let `default` = PlaybackPreference(
        speed: 1.0,
        startSkipSeconds: 0,
        endSkipSeconds: 0,
        vocalBoostLevel: .off,
        trimSilence: .off
    )

    public static func speedLabel(_ speed: Double) -> String {
        speed == 1.0 ? "1x" : String(format: "%.1fx", speed)
    }

    public init(
        speed: Double,
        startSkipSeconds: TimeInterval,
        endSkipSeconds: TimeInterval,
        vocalBoostLevel: VocalBoostLevel = .off,
        trimSilence: TrimSilenceAmount = .off
    ) {
        self.speed = speed
        self.startSkipSeconds = startSkipSeconds
        self.endSkipSeconds = endSkipSeconds
        self.vocalBoostLevel = vocalBoostLevel
        self.trimSilence = trimSilence
    }

    private enum CodingKeys: String, CodingKey {
        case speed
        case startSkipSeconds
        case endSkipSeconds
        case vocalBoostLevel
        case vocalBoostEnabled
        case trimSilence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? Self.default.speed
        startSkipSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .startSkipSeconds) ?? 0
        endSkipSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .endSkipSeconds) ?? 0
        if let savedLevel = try container.decodeIfPresent(VocalBoostLevel.self, forKey: .vocalBoostLevel) {
            vocalBoostLevel = savedLevel
        } else if let savedEnabled = try container.decodeIfPresent(Bool.self, forKey: .vocalBoostEnabled) {
            // Legacy boolean key: true mapped to Strong, false to Off.
            vocalBoostLevel = savedEnabled ? .strong : .off
        } else {
            // Neither key present → fall back to the default (.off), matching
            // `.default` and the member-wise init (see ASSESSMENT.md B3).
            vocalBoostLevel = Self.default.vocalBoostLevel
        }
        trimSilence = try container.decodeIfPresent(TrimSilenceAmount.self, forKey: .trimSilence) ?? .off
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speed, forKey: .speed)
        try container.encode(startSkipSeconds, forKey: .startSkipSeconds)
        try container.encode(endSkipSeconds, forKey: .endSkipSeconds)
        try container.encode(vocalBoostLevel, forKey: .vocalBoostLevel)
        try container.encode(trimSilence, forKey: .trimSilence)
    }
}

/// AI CONTEXT — Human-readable episode-trim text shared by global and
/// per-subscription settings. This deliberately avoids DateComponentsFormatter:
/// trim values are short elapsed durations, and the product wording requires
/// compact forms such as "1 min 30 secs" rather than locale-dependent timestamps.
public enum EpisodeTrimDurationText {
    public static func string(for seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        guard totalSeconds > 0 else { return "Off" }

        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        let minuteUnit = minutes == 1 ? "min" : "mins"
        let secondUnit = remainingSeconds == 1 ? "sec" : "secs"

        switch (minutes, remainingSeconds) {
        case (0, let seconds):
            return "\(seconds) \(secondUnit)"
        case (let minutes, 0):
            return "\(minutes) \(minuteUnit)"
        default:
            return "\(minutes) \(minuteUnit) \(remainingSeconds) \(secondUnit)"
        }
    }
}
