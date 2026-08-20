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
// All state is confined to `queue`. Scene inactivity cancels an outstanding
// ping, so tvOS suspension is counted separately instead of misreported as a
// multi-minute foreground hang.
final class TVHangWatchdog: @unchecked Sendable {
    struct Snapshot: Equatable {
        let detectedCount: Int
        let maximumBlockedMilliseconds: Int
        let lastDetectedAt: Date?
        let inactiveGapCount: Int
    }
    static let shared = TVHangWatchdog()

    private let queue = DispatchQueue(label: "com.autohop.tv.hang-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingSentAt: Date?
    private var pingSentUptime: TimeInterval?
    private var reportedInProgressHang = false
    private var detectedCount = 0
    private var maximumBlockedMilliseconds = 0
    private var lastDetectedAt: Date?
    private var isSceneActive = true
    private var inactiveGapCount = 0

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

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                detectedCount: detectedCount,
                maximumBlockedMilliseconds: maximumBlockedMilliseconds,
                lastDetectedAt: lastDetectedAt,
                inactiveGapCount: inactiveGapCount
            )
        }
    }

    func setSceneActive(_ active: Bool) {
        queue.async { [self] in
            guard isSceneActive != active else { return }
            isSceneActive = active
            if !active {
                if pingSentAt != nil { inactiveGapCount += 1 }
                pingSentAt = nil
                pingSentUptime = nil
                reportedInProgressHang = false
            }
            AppLogger.shared.info("tv.watchdog.sceneState", "Updated hang-watchdog scene state", metadata: [
                "active": "\(active)", "inactiveGaps": "\(inactiveGapCount)"
            ])
        }
    }

    /// Runs on `queue` every 250 ms.
    private func tick() {
        guard isSceneActive else { return }
        if let sentAt = pingSentAt {
            // The previous ping hasn't been serviced — the main thread is
            // blocked right now. Report once per hang, with the running total.
            let blocked = Date().timeIntervalSince(sentAt)
            let activeElapsed = pingSentUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? blocked
            // A scene callback is not guaranteed to arrive before tvOS freezes
            // the process. Wall time advances during that gap while monotonic
            // active uptime does not; classify it separately instead of calling
            // it a main-thread hang.
            if blocked - activeElapsed >= 2 {
                inactiveGapCount += 1
                pingSentAt = nil
                pingSentUptime = nil
                reportedInProgressHang = false
                AppLogger.shared.info("tv.watchdog.suspensionGapExcluded", "Excluded a process-suspension gap from hang diagnostics", metadata: [
                    "wallBucket": blocked >= 300 ? "5m+" : blocked >= 30 ? "30s+" : "2s+",
                    "inactiveGaps": "\(inactiveGapCount)"
                ], alwaysPersist: true)
                return
            }
            if blocked >= hangThreshold, !reportedInProgressHang {
                reportedInProgressHang = true
                recordHang(milliseconds: Int(blocked * 1_000))
                AppLogger.shared.warning("tv.mainThreadHang", "Main thread hang in progress", metadata: [
                    "blockedMs": "\(Int(blocked * 1000))"
                ], alwaysPersist: true)
            }
            return
        }

        let sentAt = Date()
        let sentUptime = ProcessInfo.processInfo.systemUptime
        pingSentAt = sentAt
        pingSentUptime = sentUptime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async {
                let latency = Date().timeIntervalSince(sentAt)
                let activeLatency = ProcessInfo.processInfo.systemUptime - sentUptime
                self.pingSentAt = nil
                self.pingSentUptime = nil
                if latency - activeLatency >= 2 {
                    self.inactiveGapCount += 1
                    self.reportedInProgressHang = false
                    AppLogger.shared.info("tv.watchdog.suspensionGapExcluded", "Excluded a process-suspension gap from recovered hang diagnostics", metadata: [
                        "wallBucket": latency >= 300 ? "5m+" : latency >= 30 ? "30s+" : "2s+",
                        "inactiveGaps": "\(self.inactiveGapCount)"
                    ], alwaysPersist: true)
                    return
                }
                if self.reportedInProgressHang {
                    self.reportedInProgressHang = false
                    AppLogger.shared.info("tv.mainThreadHangRecovered", "Main thread hang recovered", metadata: [
                        "blockedMs": "\(Int(latency * 1000))"
                    ], alwaysPersist: true)
                } else if latency >= self.hangThreshold {
                    self.recordHang(milliseconds: Int(latency * 1_000))
                    // Hang started and ended between ticks — log it as a
                    // single recovered event with its full duration.
                    AppLogger.shared.warning("tv.mainThreadHang", "Main thread hang (recovered)", metadata: [
                        "blockedMs": "\(Int(latency * 1000))"
                    ], alwaysPersist: true)
                }
            }
        }
    }

    /// Queue-confined summary retained for the on-device Diagnostics screen;
    /// detailed events continue to live in the bounded redacted log.
    private func recordHang(milliseconds: Int) {
        detectedCount += 1
        maximumBlockedMilliseconds = max(maximumBlockedMilliseconds, milliseconds)
        lastDetectedAt = Date()
    }
}
