import SwiftUI

// AI CONTEXT — Views/PlaybackControlsCard.swift
// Reusable sound controls card (Speed / Trim Silence / Vocal Boost). Single
// source of truth shared by SubscriptionSettingsView and SettingsView.
// iOS 26: card uses glassCard(cornerRadius:12), stepper uses glassCard(cornerRadius:10).
// iOS 17–25: card uses the `fill` background param (callers pass white.opacity(0.08)
// or a conditional cardBackground). This file also hosts SettingsRowLabel — the
// shared purple-icon row label used across the settings flow.
struct PlaybackControlsCard: View {
    let preference: PlaybackPreference
    let onSpeedChange: (Double) -> Void
    let onTrimChange: (TrimSilenceAmount) -> Void
    let onVocalChange: (VocalBoostLevel) -> Void
    // Card fill colour. Defaults to the standalone near-black used by the audio
    // controls sheet and the per-podcast Playback section. SettingsView overrides
    // it with white.opacity(0.08) so the card matches the other dark cards on the
    // (black-backed) App Settings page.
    var fill: Color = Color(red: 0.10, green: 0.10, blue: 0.13)

    private let dividerColor = Color(white: 0.20)

    var body: some View {
        let stack = VStack(spacing: 0) {
            speedRow
            Divider().background(dividerColor).padding(.leading, 60)
            trimSilenceRow
            Divider().background(dividerColor).padding(.leading, 60)
            vocalBoostRow
        }
        // No horizontal padding: callers zero out listRowInsets, so the row already
        // fills the standard grouped-section region. Any extra padding here would
        // inset the card *inside* that region, making it narrower than sibling sections.
        .padding(.vertical, 8)
        .preferredColorScheme(.dark)

        if #available(iOS 26, *) {
            stack.glassCard(cornerRadius: 12)
        } else {
            stack
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
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
