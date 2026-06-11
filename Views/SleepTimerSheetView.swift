import SwiftUI

// AI CONTEXT — Views/SleepTimerSheetView.swift ("Sleep Timer" sheet, from the
// Player; MIT-licensed original code, see NOTICE). Inactive state: six
// duration presets (5–60 min) in a 3×2 grid plus an end-of-N-episodes stepper
// (1–10). Active state: countdown (+5 min extend) or episodes-remaining, with
// Cancel. All timer logic lives in SleepTimerService — this is pure UI.

// MARK: - Sleep Timer Sheet

struct SleepTimerSheetView: View {
    @ObservedObject var sleepTimer: SleepTimerService
    @Environment(\.dismiss) private var dismiss

    // Local state for the episode-count stepper shown in the inactive preset list.
    @State private var episodeCount: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            if sleepTimer.isDurationMode {
                activeTimerView
            } else if sleepTimer.isEpisodeMode {
                activeEpisodeView
            } else {
                inactiveView
            }

            Spacer(minLength: 20)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }

    // MARK: - Sheet height

    private var sheetHeight: CGFloat {
        if sleepTimer.isDurationMode || sleepTimer.isEpisodeMode {
            return 240
        }
        return 380
    }

    // MARK: - Drag handle

    private var dragHandle: some View {
        Capsule()
            .fill(Color(white: 0.3))
            .frame(width: 36, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 20)
    }

    // MARK: - Inactive: preset grid + End of Episode

    private var inactiveView: some View {
        VStack(spacing: 0) {
            sectionHeader("Sleep Timer")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible())], spacing: 10) {
                presetButton(label: "5 min",  seconds: 5 * 60)
                presetButton(label: "10 min", seconds: 10 * 60)
                presetButton(label: "15 min", seconds: 15 * 60)
                presetButton(label: "30 min", seconds: 30 * 60)
                presetButton(label: "45 min", seconds: 45 * 60)
                presetButton(label: "1 hour", seconds: 60 * 60)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            sheetDivider

            endOfEpisodeRow
        }
    }

    private func presetButton(label: String, seconds: TimeInterval) -> some View {
        Button {
            sleepTimer.start(mode: .duration(seconds))
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var endOfEpisodeRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 26)

            Text("End of Episode")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            // Episode count stepper
            HStack(spacing: 0) {
                Button {
                    if episodeCount > 1 { episodeCount -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(episodeCount > 1 ? .white : Color(white: 0.35))
                        .frame(width: 38, height: 36)
                }
                .disabled(episodeCount <= 1)

                Text("\(episodeCount)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 24)

                Button {
                    if episodeCount < 10 { episodeCount += 1 }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(episodeCount < 10 ? .white : Color(white: 0.35))
                        .frame(width: 38, height: 36)
                }
                .disabled(episodeCount >= 10)
            }
            .background(Color(white: 0.20))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                sleepTimer.start(mode: .endOfEpisode(count: episodeCount))
            } label: {
                Text("Set")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Active: duration countdown

    private var activeTimerView: some View {
        VStack(spacing: 24) {
            sectionHeader("Sleep Timer")

            // Countdown display
            Text(formattedTimeRemaining)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            HStack(spacing: 12) {
                // +5 min
                Button {
                    sleepTimer.extend(by: 5)
                } label: {
                    Text("+5 min")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                // Cancel
                Button {
                    sleepTimer.cancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(white: 0.55))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color(white: 0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.20), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var formattedTimeRemaining: String {
        let total = max(0, Int(sleepTimer.timeRemaining))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Active: episode countdown

    private var activeEpisodeView: some View {
        VStack(spacing: 24) {
            sectionHeader("Sleep Timer")

            VStack(spacing: 6) {
                Text("\(sleepTimer.episodesRemaining)")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text(sleepTimer.episodesRemaining == 1 ? "episode remaining" : "episodes remaining")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.45))
            }

            Button {
                sleepTimer.cancel()
            } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.20), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Color(white: 0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
    }

    private var sheetDivider: some View {
        Divider()
            .background(Color(white: 0.20))
            .padding(.leading, 60)
    }
}
