import SwiftUI

// AI CONTEXT — Root tvOS state renderer. Application construction/lifecycle
// lives in AutohopTVApp; bootstrap state is owned by TVBootstrapCoordinator.
struct TVRootView: View {
    let model: TVAppModel

    var body: some View {
        switch model.bootstrapCoordinator.state {
        case .loading(let message):
            TVLaunchLoadingView(statusText: message)
        case .empty:
            emptyLibrary
        case .recoverableFailure(let message):
            ContentUnavailableView(
                "Library temporarily unavailable",
                systemImage: "icloud.slash",
                description: Text(message)
            )
        case .ready:
            TVMainTabView(model: model)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No library yet", systemImage: "square.stack")
            } description: {
                Text("Subscribe to podcasts in Autohop on your iPhone and turn on iCloud Sync in Settings → Sync. Your library appears here automatically — this can take several minutes on a fresh install.")
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Still listening for iCloud updates…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
