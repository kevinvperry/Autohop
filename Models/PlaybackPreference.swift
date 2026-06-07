import Foundation

public enum TrimSilenceAmount: String, CaseIterable, Codable {
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

public enum VocalBoostLevel: String, CaseIterable, Codable {
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

public struct PlaybackPreference: Equatable, Codable {
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

    public static let `default` = PlaybackPreference(
        speed: 1.6,
        startSkipSeconds: 0,
        endSkipSeconds: 0,
        vocalBoostLevel: .strong,
        trimSilence: .low
    )

    public static func speedLabel(_ speed: Double) -> String {
        speed == 1.0 ? "1x" : String(format: "%.1fx", speed)
    }

    public init(
        speed: Double,
        startSkipSeconds: TimeInterval,
        endSkipSeconds: TimeInterval,
        vocalBoostLevel: VocalBoostLevel = .strong,
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
            vocalBoostLevel = savedEnabled ? .strong : .off
        } else {
            vocalBoostLevel = .strong
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
