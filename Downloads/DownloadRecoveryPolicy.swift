import Foundation

// AI CONTEXT — Downloads/DownloadRecoveryPolicy.swift
// Pure characterization of durable automatic-intent ownership. Stored episode
// state is a projection, not proof of a live URLSession transfer. Recovery code
// must privilege concrete retry, URLSession, and local FIFO ownership; a stored
// queued/downloading episode without one of those owners is an orphan and is
// eligible for normalization plus automatic restart.

public enum DownloadRecoveryDisposition: String, Sendable {
    case scheduledRetry
    case liveURLSessionTask
    case localPendingQueue
    case orphanedStoredTransfer
    case eligibleForRecovery
}

public enum DownloadRetryPresentation: String, Sendable {
    case waitingToRetry
    case preserveTerminalFailure
    case paused
}

public enum DownloadRecoveryPolicy {
    public static func disposition(
        storedState: DownloadState,
        hasScheduledRetry: Bool,
        hasLiveTask: Bool,
        isLocallyQueued: Bool
    ) -> DownloadRecoveryDisposition {
        if hasScheduledRetry { return .scheduledRetry }
        if hasLiveTask { return .liveURLSessionTask }
        if isLocallyQueued { return .localPendingQueue }
        if storedState == .downloading || storedState == .queued {
            return .orphanedStoredTransfer
        }
        return .eligibleForRecovery
    }

    /// Converts concrete retry ownership into UI state. A cancelled transfer
    /// must never claim it is waiting unless a retry task actually owns the
    /// next attempt; terminal exhaustion remains visible and manually retryable.
    public static func retryPresentation(
        hasScheduledRetry: Bool,
        isTerminalFailure: Bool
    ) -> DownloadRetryPresentation {
        if hasScheduledRetry { return .waitingToRetry }
        if isTerminalFailure { return .preserveTerminalFailure }
        return .paused
    }
}
