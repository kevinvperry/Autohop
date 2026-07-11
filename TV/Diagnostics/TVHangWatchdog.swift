import Foundation
import AutohopCore

// AI CONTEXT — TV/Diagnostics/TVHangWatchdog.swift (added 2026-07-11, Kevin's
// round 8: "extreme stutter... is there any kind of diagnostic log?"). A
// minimal tvOS port of the iPhone's main-thread hang watchdog (Logging/
// ResourceMonitor.swift, which is iOS-app-target-only): a utility-QoS timer
// pings the main queue every 250 ms and measures how long the ping takes to
// be serviced. Latency ≥ 350 ms = a hang the focus engine will visibly
// stutter on. Two log shapes, both alwaysPersist (they must survive even if
// the diagnostics toggle were off):
//   • tv.mainThreadHang          — an IN-PROGRESS hang: a previous ping is
//     still unanswered at the next tick, logged once per hang with the
//     running blocked duration.
//   • tv.mainThreadHangRecovered — the ping finally landed; blockedMs is the
//     hang's true total length. Short hangs (≥ threshold but recovered before
//     the next tick observed them) log ONLY this recovery line.
// Correlate the timestamps against tv.perf.* stage timings (TVAppModel /
// TVArtworkLoader) to see WHAT was on the main thread during the hang.
// All state is confined to `queue`; the main-queue hop only carries the
// timestamp back. @unchecked Sendable for the same reason as CloudSyncEngine.
final class TVHangWatchdog: @unchecked Sendable {
    static let shared = TVHangWatchdog()

    private let queue = DispatchQueue(label: "com.autohop.tv.hang-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingSentAt: Date?
    private var reportedInProgressHang = false

    private let pingInterval: TimeInterval = 0.25
    private let hangThreshold: TimeInterval = 0.35

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    /// Runs on `queue` every 250 ms.
    private func tick() {
        if let sentAt = pingSentAt {
            // The previous ping hasn't been serviced — the main thread is
            // blocked right now. Report once per hang, with the running total.
            let blocked = Date().timeIntervalSince(sentAt)
            if blocked >= hangThreshold, !reportedInProgressHang {
                reportedInProgressHang = true
                AppLogger.shared.warning("tv.mainThreadHang", "Main thread hang in progress", metadata: [
                    "blockedMs": "\(Int(blocked * 1000))"
                ], alwaysPersist: true)
            }
            return
        }

        let sentAt = Date()
        pingSentAt = sentAt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async {
                let latency = Date().timeIntervalSince(sentAt)
                self.pingSentAt = nil
                if self.reportedInProgressHang {
                    self.reportedInProgressHang = false
                    AppLogger.shared.info("tv.mainThreadHangRecovered", "Main thread hang recovered", metadata: [
                        "blockedMs": "\(Int(latency * 1000))"
                    ], alwaysPersist: true)
                } else if latency >= self.hangThreshold {
                    // Hang started and ended between ticks — log it as a
                    // single recovered event with its full duration.
                    AppLogger.shared.warning("tv.mainThreadHang", "Main thread hang (recovered)", metadata: [
                        "blockedMs": "\(Int(latency * 1000))"
                    ], alwaysPersist: true)
                }
            }
        }
    }
}
