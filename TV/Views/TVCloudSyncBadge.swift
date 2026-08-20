import SwiftUI

// AI CONTEXT — One app-shell-owned iCloud status treatment shared by every
// tvOS tab. It is an overlay, never an in-flow row, so status changes cannot
// move page content or disturb Siri Remote focus. A healthy account with no
// phone-authored queue snapshot uses `connected`; absence of that optional
// record must never render as an iCloud outage.
struct TVCloudSyncBadge: View {
    let status: TVSyncStatus

    var body: some View {
        Label(status.label, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel(status.label)
    }

    private var systemImage: String {
        switch status {
        case .updating: "icloud.and.arrow.down"
        case .upToDate, .connected: "checkmark.icloud"
        case .cached: "icloud"
        case .unavailable, .failed: "exclamationmark.icloud"
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .unavailable, .failed: .orange
        default: .secondary
        }
    }
}
