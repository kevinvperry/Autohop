import SwiftUI

// AI CONTEXT — Views/PlaybackControlsCard.swift
// Reusable dark "sound controls" card (Speed / Trim Silence / Vocal Boost)
// matching AudioControlsSheetView. Single source of truth for this design,
// shared by the per-podcast Playback section (SubscriptionSettingsView) and the
// global Default Playback panel (SettingsView). It is purely presentational:
// it reads a PlaybackPreference and reports edits through three closures, so the
// caller decides whether the change targets a subscription or the global default.
struct PlaybackControlsCard: View {
    let preference: PlaybackPreference
    let onSpeedChange: (Double) -> Void
    let onTrimChange: (TrimSilenceAmount) -> Void
    let onVocalChange: (VocalBoostLevel) -> Void

    private let darkBG = Color(red: 0.10, green: 0.10, blue: 0.13)
    private let dividerColor = Color(white: 0.20)

    var body: some View {
        VStack(spacing: 0) {
            speedRow
            Divider().background(dividerColor).padding(.leading, 60)
            trimSilenceRow
            Divider().background(dividerColor).padding(.leading, 60)
            vocalBoostRow
        }
        .background(darkBG)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .preferredColorScheme(.dark)
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
            .background(Color(white: 0.20))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
