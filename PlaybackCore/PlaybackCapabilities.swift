import Foundation

// AI CONTEXT — PlaybackCore/PlaybackCapabilities.swift
// Phase 0 of Docs/TVOS_APP_IMPLEMENTATION_PROPOSAL.md (§4.2 move 4): per-
// platform/per-engine playback capability flags. UI on every surface (iPhone
// Effects sheet, TV transport menu, watch source flags) reads these off
// PlaybackControlling.capabilities instead of hardcoding platform checks —
// this replaces the watch proposal's D7 hardcoding with one shared mechanism.
// Trim Silence / Vocal Boost require complete local files + the AVAudioEngine
// path (iOS PlaybackEngine); StreamingPlaybackEngine reports them false and
// its update methods are no-ops. Keep the flag set small and behavioral —
// don't grow this into a general feature-flag system.

/// What the active playback engine can actually do on this platform.
public struct PlaybackCapabilities: Equatable, Sendable {
    /// AVAudioEngine silence-trimming DSP (needs a complete local file).
    public var trimSilence: Bool
    /// AVAudioEngine vocal-boost EQ (needs the engine path).
    public var vocalBoost: Bool
    /// Video episode rendering (AVPlayer surface available on this platform).
    public var video: Bool
    /// May fall back to the enclosure URL when no local file exists.
    public var streaming: Bool
    /// Sleep timer / sleep schedule integration is meaningful here.
    public var sleepTimer: Bool

    public init(trimSilence: Bool, vocalBoost: Bool, video: Bool, streaming: Bool, sleepTimer: Bool) {
        self.trimSilence = trimSilence
        self.vocalBoost = vocalBoost
        self.video = video
        self.streaming = streaming
        self.sleepTimer = sleepTimer
    }

    /// iPhone's full local-file engine (Playback/PlaybackEngine.swift):
    /// everything on, streaming off until the Tier 1 "instant play" feature is
    /// deliberately built (FUTURE_VERSIONS.md).
    public static let iOSFull = PlaybackCapabilities(
        trimSilence: true, vocalBoost: true, video: true, streaming: false, sleepTimer: true
    )

    /// tvOS lean-back streaming (StreamingPlaybackEngine): AVPlayer-only —
    /// no DSP effects, video first-class, streams from the enclosure URL.
    public static let tvStreaming = PlaybackCapabilities(
        trimSilence: false, vocalBoost: false, video: true, streaming: true, sleepTimer: false
    )
}
