import AppIntents

// AI CONTEXT — Widgets/Shared/PlayAutohopEpisodeIntent.swift
//
// PURPOSE:
// Cross-target declaration for the Stage 3 interactive widget playback intent.
// The app target supplies the real `intentPlayback` implementation through an
// extension; the widget target supplies a compile-only no-op extension. iOS
// executes the app-hosted AudioPlaybackIntent without foregrounding Autohop.
//
// SECURITY:
// Parameters are an untrusted stable-identity claim. The app-side handler must
// resolve subscriptionID + episodeKey against the live SubscriptionStore and
// re-check downloaded/playable state before touching playback.

@available(iOS 17.0, *)
struct PlayAutohopEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Autohop Episode"
    static var description = IntentDescription(
        "Plays or pauses a downloaded Autohop episode."
    )
    static var isDiscoverable = false
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Subscription ID")
    var subscriptionID: String

    @Parameter(title: "Episode Key")
    var episodeKey: String

    init(identity: WidgetEpisodeIdentity) {
        subscriptionID = identity.subscriptionID.uuidString
        episodeKey = identity.episodeKey
    }

    init() {
        subscriptionID = ""
        episodeKey = ""
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await intentPlayback(
            subscriptionID: subscriptionID,
            episodeKey: episodeKey
        )
        return .result()
    }
}
