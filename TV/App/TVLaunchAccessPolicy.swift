import Foundation

// AI CONTEXT — Pure policy for the App Review first-usable-screen guarantee.
// A clean-install deadline exposes setup/demo without cancelling or racing the
// mutable bootstrap workflow. Durable returning-library evidence gets a longer
// grace so normal iCloud catch-up cannot impersonate first-time onboarding.

enum TVLaunchAccessPolicy {
    static let firstUsableScreenDeadline: Duration = .seconds(10)
    static let returningLibraryRecoveryDeadline: Duration = .seconds(45)

    static func shouldExposeSetup(
        bootstrapState: TVBootstrapCoordinator.State,
        cleanInstallDeadlineReached: Bool,
        hasReturningLibraryEvidence: Bool,
        returningRecoveryDeadlineReached: Bool
    ) -> Bool {
        switch bootstrapState {
        case .loading:
            return hasReturningLibraryEvidence
                ? returningRecoveryDeadlineReached
                : cleanInstallDeadlineReached
        case .empty:
            return hasReturningLibraryEvidence ? returningRecoveryDeadlineReached : true
        case .recoverableFailure:
            return true
        case .ready:
            return false
        }
    }
}
