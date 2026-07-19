import Foundation

// AI CONTEXT — App/PlaybackPreferenceWorkflow.swift
//
// PURPOSE / OWNERSHIP:
// Exclusive mutation and resolution workflow for playback preferences. It owns
// per-subscription speed, Vocal Boost, Volume Adjustment, Mono/Stereo, Trim
// Silence, and episode-trim updates; global defaults for new/browse feeds;
// Shared Listening overrides; live engine reconfiguration; lock-screen
// scrubbing configuration; Now Playing rate refresh; and full Now Playing card
// reassertion after foreground/output-route restoration.
//
// PERSISTENCE / SYNC:
// Subscription preferences are written through SubscriptionStore so their
// existing CloudKit record and conflict policy remain authoritative. Global and
// Shared Listening preferences are written through SettingsStoring. Existing
// subscriptions are never rewritten when a global default changes.
//
// INVARIANTS:
// - Shared Listening overrides only speed and Trim Silence.
// - Browse feeds resolve global defaults live; subscribed feeds retain their
//   own snapshot.
// - Episode trim is finite and clamped to 0...300 seconds.
// - Live engine changes apply only to the currently loaded subscription.
// - AppState may forward user intents here but contains no preference policy.

@MainActor
final class PlaybackPreferenceWorkflow {
    private let playback: PlaybackCoordinator
    private let subscriptionStore: SubscriptionStore
    private let settingsStore: any SettingsStoring
    private let logger: AppLogger

    init(
        playback: PlaybackCoordinator,
        subscriptionStore: SubscriptionStore,
        settingsStore: any SettingsStoring,
        logger: AppLogger
    ) {
        self.playback = playback
        self.subscriptionStore = subscriptionStore
        self.settingsStore = settingsStore
        self.logger = logger
    }

    var sharedListeningActive: Bool {
        settingsStore.appSettings.sharedListeningActive
    }

    var sharedListeningSpeed: Double {
        settingsStore.appSettings.sharedListeningSpeed
    }

    func reassertNowPlayingCard(reason: String) {
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return
        }
        NowPlayingService.shared.update(
            episode: episode,
            podcastTitle: subscription.title,
            currentTime: playback.clock.time,
            duration: episode.durationSeconds,
            speed: effectiveSpeed(for: subscription),
            isPlaying: playback.isPlaying,
            artworkURL: episode.artworkURL ?? subscription.artworkURL
        )
        logger.info(
            "nowPlaying.reasserted",
            "Now Playing card re-pushed",
            metadata: [
                "reason": reason,
                "episode": episode.title,
                "isPlaying": "\(playback.isPlaying)"
            ]
        )
    }

    func updatePlaybackSpeed(for subscriptionID: UUID, speed: Double) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            return
        }
        logger.info("player.speed", "Playback speed changed", metadata: [
            "podcast": subscription.title,
            "speed": PlaybackPreference.speedLabel(speed)
        ])
        var preference = subscription.playbackPreference
        preference.speed = speed
        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )

        if playback.currentEpisode?.subscriptionID == subscriptionID,
           !sharedListeningActive {
            playback.engine.updatePlaybackSpeed(speed)
            NowPlayingService.shared.updateTime(
                currentTime: playback.clock.time,
                isPlaying: playback.isPlaying,
                speed: speed
            )
        }
    }

    func cyclePlaybackSpeedForCurrentEpisode() {
        guard !sharedListeningActive,
              let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ),
              let nextSpeed = PlaybackSessionPolicy.cycledSpeed(
                after: subscription.playbackPreference.speed
              ) else {
            return
        }
        updatePlaybackSpeed(for: subscription.id, speed: nextSpeed)
    }

    func setPlaybackSpeedForCurrentEpisode(_ speed: Double) {
        guard !sharedListeningActive,
              let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return
        }
        updatePlaybackSpeed(
            for: subscription.id,
            speed: PlaybackSessionPolicy.normalizedSpeed(closestTo: speed)
        )
    }

    func updateVocalBoost(for subscriptionID: UUID, level: VocalBoostLevel) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            return
        }
        logger.info("player.vocalBoost", "Vocal Boost changed", metadata: [
            "podcast": subscription.title,
            "level": level.title,
            "targetLUFS": level == .strong ? "-14" : "none"
        ])
        var preference = subscription.playbackPreference
        preference.vocalBoostLevel = level
        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )
        if playback.currentEpisode?.subscriptionID == subscriptionID {
            playback.engine.updateVocalBoost(level)
        }
    }

    func updateVolumeAdjustment(for subscriptionID: UUID, adjustment: Int) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            return
        }
        let clamped = PlaybackPreference.clampedVolumeAdjustment(adjustment)
        var preference = subscription.playbackPreference
        guard preference.volumeAdjustment != clamped else { return }
        preference.volumeAdjustment = clamped
        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )
        logger.info(
            "player.volumeAdjustment",
            "Subscription volume adjustment changed",
            metadata: [
                "podcast": subscription.title,
                "adjustmentDB": "\(clamped)"
            ]
        )
        if playback.currentEpisode?.subscriptionID == subscriptionID {
            playback.engine.updateVolumeAdjustment(clamped)
        }
    }

    func updateAudioChannelMode(
        for subscriptionID: UUID,
        mode: AudioChannelMode
    ) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            return
        }
        var preference = subscription.playbackPreference
        guard preference.audioChannelMode != mode else { return }
        preference.audioChannelMode = mode
        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )
        logger.info(
            "player.audioChannelMode",
            "Audio channel mode changed",
            metadata: [
                "podcast": subscription.title,
                "mode": mode.title
            ]
        )
        if playback.currentEpisode?.subscriptionID == subscriptionID {
            playback.engine.updateAudioChannelMode(mode)
        }
    }

    func updateLockScreenScrubbing(enabled: Bool) {
        settingsStore.appSettings.lockScreenScrubbingEnabled = enabled
        NowPlayingService.shared.refreshScrubbingCommand(enabled: enabled)
    }

    func updateTrimSilence(
        for subscriptionID: UUID,
        amount: TrimSilenceAmount
    ) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            return
        }
        logger.info("player.trimSilence", "Trim Silence changed", metadata: [
            "podcast": subscription.title,
            "amount": amount.title
        ])
        var preference = subscription.playbackPreference
        preference.trimSilence = amount
        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )
        if playback.currentEpisode?.subscriptionID == subscriptionID,
           !sharedListeningActive {
            playback.engine.updateTrimSilence(amount)
        }
    }

    func updateEpisodeTrim(
        for subscriptionID: UUID,
        startSkipSeconds: TimeInterval? = nil,
        endSkipSeconds: TimeInterval? = nil
    ) {
        guard let subscription = subscriptionStore.subscription(id: subscriptionID) else {
            return
        }
        var preference = subscription.playbackPreference
        if let startSkipSeconds {
            preference.startSkipSeconds = normalizedEpisodeTrim(startSkipSeconds)
        }
        if let endSkipSeconds {
            preference.endSkipSeconds = normalizedEpisodeTrim(endSkipSeconds)
        }
        guard preference != subscription.playbackPreference else { return }

        subscriptionStore.updatePlaybackPreference(
            subscriptionID: subscriptionID,
            preference: preference
        )
        logger.info("settings.episodeTrim", "Podcast episode trim changed", metadata: [
            "podcast": subscription.title,
            "startSeconds": "\(Int(preference.startSkipSeconds))",
            "endSeconds": "\(Int(preference.endSkipSeconds))"
        ])
        if playback.currentEpisode?.subscriptionID == subscriptionID {
            playback.engine.updateEpisodeTrim(
                startSkipSeconds: preference.startSkipSeconds,
                endSkipSeconds: preference.endSkipSeconds
            )
        }
    }

    func updateDefaultPlaybackSpeed(_ speed: Double) {
        logger.info("settings.defaultSpeed", "Default playback speed changed", metadata: [
            "speed": PlaybackPreference.speedLabel(speed)
        ])
        mutateDefaultPlaybackPreference { $0.speed = speed }
    }

    func updateDefaultVocalBoost(_ level: VocalBoostLevel) {
        logger.info(
            "settings.defaultVocalBoost",
            "Default Vocal Boost changed",
            metadata: ["level": level.title]
        )
        mutateDefaultPlaybackPreference { $0.vocalBoostLevel = level }
    }

    func updateDefaultAudioChannelMode(_ mode: AudioChannelMode) {
        logger.info(
            "settings.defaultAudioChannelMode",
            "Default audio channel mode changed",
            metadata: ["mode": mode.title]
        )
        mutateDefaultPlaybackPreference { $0.audioChannelMode = mode }
    }

    func updateDefaultTrimSilence(_ amount: TrimSilenceAmount) {
        logger.info(
            "settings.defaultTrimSilence",
            "Default Trim Silence changed",
            metadata: ["amount": amount.title]
        )
        mutateDefaultPlaybackPreference { $0.trimSilence = amount }
    }

    func updateDefaultEpisodeTrim(
        startSkipSeconds: TimeInterval? = nil,
        endSkipSeconds: TimeInterval? = nil
    ) {
        mutateDefaultPlaybackPreference { preference in
            if let startSkipSeconds {
                preference.startSkipSeconds = normalizedEpisodeTrim(startSkipSeconds)
            }
            if let endSkipSeconds {
                preference.endSkipSeconds = normalizedEpisodeTrim(endSkipSeconds)
            }
        }
    }

    func setSharedListening(active: Bool) {
        var settings = settingsStore.appSettings
        settings.sharedListeningActive = active
        if active {
            settings.sharedListeningSpeed = 1
        }
        settingsStore.appSettings = settings
        logger.info(
            "player.sharedListening",
            active
                ? "Shared Listening activated"
                : "Shared Listening deactivated"
        )
        applyEffectivePreferenceToCurrentEpisode()
    }

    func updateSharedListeningSpeed(_ speed: Double) {
        guard sharedListeningActive else { return }
        settingsStore.appSettings.sharedListeningSpeed = speed
        logger.info("player.sharedListening", "Shared Listening speed changed", metadata: [
            "speed": PlaybackPreference.speedLabel(speed)
        ])
        applyEffectivePreferenceToCurrentEpisode()
    }

    func effectivePreference(for subscription: Subscription) -> PlaybackPreference {
        PlaybackSessionPolicy.effectivePreference(
            subscriptionPreference: subscription.playbackPreference,
            isBrowseFeed: subscription.browseDate != nil,
            defaultPreference: settingsStore.appSettings.defaultPlaybackPreference,
            sharedListeningSpeed: sharedListeningActive
                ? sharedListeningSpeed
                : nil
        )
    }

    func effectiveSpeed(for subscription: Subscription) -> Double {
        effectivePreference(for: subscription).speed
    }

    private func mutateDefaultPlaybackPreference(
        _ mutate: (inout PlaybackPreference) -> Void
    ) {
        var preference = settingsStore.appSettings.defaultPlaybackPreference
        mutate(&preference)
        settingsStore.appSettings.defaultPlaybackPreference = preference
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ),
              subscription.browseDate != nil else {
            return
        }
        applyEffectivePreferenceToCurrentEpisode()
        if !sharedListeningActive {
            playback.engine.updateVocalBoost(
                effectivePreference(for: subscription).vocalBoostLevel
            )
        }
    }

    private func applyEffectivePreferenceToCurrentEpisode() {
        guard let episode = playback.currentEpisode,
              let subscription = subscriptionStore.subscription(
                id: episode.subscriptionID
              ) else {
            return
        }
        let preference = effectivePreference(for: subscription)
        playback.engine.updatePlaybackSpeed(preference.speed)
        playback.engine.updateTrimSilence(preference.trimSilence)
        playback.engine.updateAudioChannelMode(preference.audioChannelMode)
        playback.engine.updateEpisodeTrim(
            startSkipSeconds: preference.startSkipSeconds,
            endSkipSeconds: preference.endSkipSeconds
        )
        NowPlayingService.shared.updateTime(
            currentTime: playback.clock.time,
            isPlaying: playback.isPlaying,
            speed: preference.speed
        )
    }

    private func normalizedEpisodeTrim(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(300, max(0, seconds))
    }
}
