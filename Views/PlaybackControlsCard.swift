import SwiftUI

// AI CONTEXT — Views/PlaybackControlsCard.swift
// Reusable sound controls card (Speed / Trim Silence / Vocal Boost / optional
// per-subscription Volume Adjustment / Mono Audio). Single
// source of truth shared by SubscriptionSettingsView and SettingsView.
// iOS 26: card uses glassCard(cornerRadius:12), stepper uses glassCard(cornerRadius:10).
// iOS 17–25: card uses the `fill` background param (callers pass white.opacity(0.08)
// or a conditional cardBackground). SettingsView passes usesHostBackground: true so
// the card drops its own surface and inherits the section row background, matching
// its sibling sections on iOS 26. This file also hosts SettingsRowLabel — the
// shared purple-icon row label used across the settings flow. It also owns
// EpisodeTrimControlRow, the stable replacement for SwiftUI's Form Stepper on
// both trim pages. That row keeps taps in local @State and coalesces persistence
// after 350 ms, preventing active-playback publications and synchronous settings
// writes from rebuilding the control once per tap. Its solid capsule intentionally
// avoids the iOS 26 scrolling/glass compositing flicker seen in native Stepper.
struct PlaybackControlsCard: View {
    let preference: PlaybackPreference
    let onSpeedChange: (Double) -> Void
    let onTrimChange: (TrimSilenceAmount) -> Void
    let onVocalChange: (VocalBoostLevel) -> Void
    let onChannelModeChange: (AudioChannelMode) -> Void
    var onVolumeAdjustmentChange: ((Int) -> Void)? = nil
    var showsVolumeAdjustment = false
    // Card fill colour. Defaults to the standalone near-black used by the audio
    // controls sheet and the per-podcast Playback section. SettingsView overrides
    // it with white.opacity(0.08) so the card matches the other dark cards on the
    // (black-backed) App Settings page.
    var fill: Color = Color(red: 0.10, green: 0.10, blue: 0.13)
    // When true the card omits its own outer surface (no glassCard / fill) so the
    // host — a Form section's own row background — provides the background. Used by
    // SettingsView on iOS 26 so this card reads identically to its sibling
    // sections instead of floating as a lighter glass card. Defaults false, which
    // keeps the self-contained card chrome for the audio sheet and the per-podcast
    // Playback section (those are unaffected).
    var usesHostBackground: Bool = false

    private let dividerColor = Color(white: 0.20)

    var body: some View {
        let stack = VStack(spacing: 0) {
            speedRow
            Divider().background(dividerColor).padding(.leading, 60)
            trimSilenceRow
            Divider().background(dividerColor).padding(.leading, 60)
            vocalBoostRow
            Divider().background(dividerColor).padding(.leading, 60)
            if showsVolumeAdjustment {
                volumeAdjustmentRow
                Divider().background(dividerColor).padding(.leading, 60)
            }
            channelModeRow
        }
        // No horizontal padding: callers zero out listRowInsets, so the row already
        // fills the standard grouped-section region. Any extra padding here would
        // inset the card *inside* that region, making it narrower than sibling sections.
        .padding(.vertical, 8)
        .preferredColorScheme(.dark)

        if usesHostBackground {
            // Transparent: the host section's row background shows through, so the
            // card matches sibling sections rather than drawing its own surface.
            stack
        } else if #available(iOS 26, *) {
            stack.glassCard(cornerRadius: 12)
        } else {
            stack
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var channelModeRow: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                rowIcon("ear")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mono Audio")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Centre left and right voices")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.50))
                }
                Spacer()
            }

            // AI CONTEXT — This binary choice deliberately uses the same full-
            // width segmented treatment as Trim Silence and Vocal Boost. Stereo
            // is an explicit selected state, not an ambiguous disabled switch.
            Picker("Audio channels", selection: Binding(
                get: { preference.audioChannelMode },
                set: { onChannelModeChange($0) }
            )) {
                ForEach(AudioChannelMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .tint(.purple)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var volumeAdjustmentRow: some View {
        let adjustment = PlaybackPreference.clampedVolumeAdjustment(preference.volumeAdjustment)
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                rowIcon("speaker.wave.1.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Volume Adjustment")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Adjust this podcast only")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.50))
                }
                Spacer()
                Text(PlaybackPreference.volumeAdjustmentLabel(adjustment))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.purple)
                    .frame(minWidth: 52, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text("−3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(adjustment) },
                        set: { onVolumeAdjustmentChange?(Int($0.rounded())) }
                    ),
                    in: -3...3,
                    step: 1
                )
                .tint(.purple)
                Text("+3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 40)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.purple)
            .frame(width: 26)
    }

    private var speedRow: some View {
        let speed = preference.speed
        let options = PlaybackPreference.speedOptions

        return HStack(spacing: 14) {
            rowIcon("speedometer")

            Text("Speed")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 0) {
                Button {
                    guard let idx = options.firstIndex(where: { abs($0 - speed) < 0.01 }), idx > 0
                    else { return }
                    onSpeedChange(options[idx - 1])
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 38)
                }
                .buttonStyle(.borderless)

                Text(PlaybackPreference.speedLabel(speed))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 46)

                Button {
                    guard let idx = options.firstIndex(where: { abs($0 - speed) < 0.01 }), idx < options.count - 1
                    else { return }
                    onSpeedChange(options[idx + 1])
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 38)
                }
                .buttonStyle(.borderless)
            }
            .glassCard(cornerRadius: 10)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var trimSilenceRow: some View {
        let trimSilence = preference.trimSilence
        let isOn = trimSilence != .off
        let levels: [TrimSilenceAmount] = [.low, .medium, .high]

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                rowIcon("scissors")

                Text("Trim Silence")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { on in onTrimChange(on ? .low : .off) }
                ))
                .labelsHidden()
                .tint(.purple)
            }

            if isOn {
                Picker("", selection: Binding(
                    get: { trimSilence },
                    set: { onTrimChange($0) }
                )) {
                    ForEach(levels, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(.purple)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }

    private var vocalBoostRow: some View {
        let level = preference.vocalBoostLevel
        let isOn = level != .off
        let levels: [VocalBoostLevel] = [.light, .standard, .strong]

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                rowIcon("speaker.wave.2.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Vocal Boost")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Voices sound clearer")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.50))
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { on in onVocalChange(on ? .strong : .off) }
                ))
                .labelsHidden()
                .tint(.purple)
            }

            if isOn {
                Picker("", selection: Binding(
                    get: { level },
                    set: { onVocalChange($0) }
                )) {
                    ForEach(levels, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(.purple)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}

// Shared purple-icon + primary-title row label used across the App Settings flow
// (SettingsView and its linked sub-screens). Mirrors the Speed / Trim Silence /
// Vocal Boost rows above so every control row gets a consistent purple glyph.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.purple)
        }
    }
}

/// AI CONTEXT — Shared start/end episode-trim row for SettingsView and
/// SubscriptionSettingsView. `persistedSeconds` is authoritative when no edit is
/// pending. Button taps update `draftSeconds` immediately, then one debounced
/// `onCommit` crosses into AppState/persistence. A disappearing row flushes the
/// pending value so Form virtualization or navigation cannot discard the last tap.
struct EpisodeTrimControlRow: View {
    let title: String
    let systemImage: String
    let persistedSeconds: TimeInterval
    let onCommit: (TimeInterval) -> Void

    private let bounds: ClosedRange<TimeInterval> = 0...300
    private let step: TimeInterval = 5

    @State private var draftSeconds: TimeInterval
    @State private var commitTask: Task<Void, Never>?

    init(
        title: String,
        systemImage: String,
        persistedSeconds: TimeInterval,
        onCommit: @escaping (TimeInterval) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.persistedSeconds = persistedSeconds
        self.onCommit = onCommit
        _draftSeconds = State(initialValue: Self.normalized(persistedSeconds))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsRowLabel(title: title, systemImage: systemImage)

                // Keep the longer minute/second text below the title instead of
                // squeezing it between the title and 44 pt tap targets on narrow
                // phones. Both settings pages therefore retain the same layout.
                Text(EpisodeTrimDurationText.string(for: draftSeconds))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, 28)
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                adjustmentButton(
                    systemImage: "minus",
                    accessibilityLabel: "Decrease \(title.lowercased()) by 5 seconds",
                    disabled: draftSeconds <= bounds.lowerBound
                ) {
                    adjust(by: -step)
                }

                Divider()
                    .frame(height: 28)

                adjustmentButton(
                    systemImage: "plus",
                    accessibilityLabel: "Increase \(title.lowercased()) by 5 seconds",
                    disabled: draftSeconds >= bounds.upperBound
                ) {
                    adjust(by: step)
                }
            }
            // A fixed-color capsule is deliberate. Native Stepper's material was
            // repeatedly recomposited while this Form scrolled over the mini player.
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
        .transaction { transaction in
            // PlaybackClock and store publications must not animate this control.
            transaction.animation = nil
        }
        .onChange(of: persistedSeconds) { _, newValue in
            guard commitTask == nil else { return }
            draftSeconds = Self.normalized(newValue)
        }
        .onDisappear {
            guard commitTask != nil else { return }
            commitTask?.cancel()
            commitTask = nil
            onCommit(draftSeconds)
        }
    }

    private func adjustmentButton(
        systemImage: String,
        accessibilityLabel: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : Color.primary)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func adjust(by delta: TimeInterval) {
        let nextValue = min(bounds.upperBound, max(bounds.lowerBound, draftSeconds + delta))
        guard nextValue != draftSeconds else { return }
        draftSeconds = nextValue
        scheduleCommit(nextValue)
    }

    private func scheduleCommit(_ seconds: TimeInterval) {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commitTask = nil
            onCommit(seconds)
        }
    }

    private static func normalized(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(300, max(0, seconds))
    }
}
