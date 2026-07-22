import Foundation
import UIKit
import Darwin.Mach

// AI CONTEXT — Logging/ResourceMonitor.swift
// Captures device/process resource snapshots (Mach task memory, battery,
// thermal state, low-power mode) for diagnostic log context. AppRuntimeWorkflow
// attaches coordinator-owned context to significant events and controls periodic sampling
// timer while diagnostics are enabled. Routine logSnapshot calls are throttled
// (8 s foreground, 45 s while the scene is inactive) so a background-audio night
// fits the capped diagnostic file; the forced five-minute periodic heartbeat and warning
// snapshots (thermal/power/memory/hang) bypass the throttle.
// BATTERY/THERMAL DIAGNOSTICS: each snapshot also carries `cpuPercent` (app CPU as
// a % of one core, summed over live non-idle threads via task_threads/thread_info —
// the primary "warm phone" signal; sustained high values with the app backgrounded /
// audio-only point at a busy loop or over-frequent timer), `threadCount`, and
// `batteryDrainPctPerHour` (discharge rate tracked between real 1% level changes,
// unplugged only). Thermal escalations and Low Power Mode flips are ALSO logged as
// discrete events (resources.thermalChange / resources.powerModeChange) so they're
// timestamped, not just caught at the next sample. Pair with AppRuntimeWorkflow
// context's `playingVideo`, `activeDownloads`, `refreshActive`, and the playback-tick
// cost fields to attribute the load. The main-thread watchdog reuses the same
// lightweight context provider only when a hang/recovery is detected, so hang
// bursts include app state without doing extra work on every 100 ms watchdog
// tick. The watchdog must keep only one outstanding main-queue ping at a time:
// queueing a fresh ping while the prior one is blocked creates a backlog that
// can look like a cluster of repeated UI hangs after the main thread recovers.
// Short watchdog delays while the app scene is inactive/backgrounded are logged
// separately from visible UI hangs. The watchdog's timing state lives in the
// private MainThreadWatchdog helper on its serial queue; ResourceMonitor stays
// @MainActor for UIKit/device snapshot work.
//
// IMPORTANT: `footprintMB` is the real iOS physical footprint
// (task_vm_info.phys_footprint) and intentionally replaced the old virtual
// address-space `memoryMB` value, which could report hundreds of GB and was not
// useful. Do not reintroduce `memoryMB` unless it is a clearly labelled virtual
// size. DIAGNOSTIC SESSION POLICY (2026-07-21): full CPU/thread sampling and the
// 100 ms main-thread watchdog run only while user-enabled diagnostics are active.
// A five-minute safety heartbeat remains alive with logging off, but reads only
// physical footprint so proactive artwork-cache eviction still operates; it does
// not enumerate threads, build runtime context, or write a routine log line.
// Debug/observability only — no feature behaviour depends on logged values.
struct ResourceSnapshot {
    /// iOS jetsam-relevant physical footprint from task_vm_info.phys_footprint.
    /// This replaced the old virtual address-space metric, which reported
    /// hundreds of GB and was not useful for diagnosing memory pressure.
    var footprintMB: Int
    var residentMemoryMB: Int
    var batteryLevelPercent: Int?
    var batteryState: String
    var thermalState: String
    var lowPowerMode: Bool
    var activeProcessorCount: Int
    var physicalMemoryMB: Int
    var deviceModel: String
    var osVersion: String
    /// Instantaneous app (task) CPU load as a percentage of ONE core — summed over
    /// all live, non-idle threads. > 100 means multiple cores busy. The primary
    /// signal for "the phone feels warm": sustained high values here (especially with
    /// the app backgrounded / audio-only) point at a busy loop, over-frequent timer,
    /// or runaway view invalidation rather than normal playback.
    var cpuUsagePercent: Double?
    /// Live thread count — a spike or steady climb hints at thread churn / leaks that
    /// also burn CPU.
    var threadCount: Int?
    /// Battery drain since the last level change, in percentage points per hour
    /// (positive = draining). Only populated while unplugged and after the level has
    /// actually moved, so it reflects a real discharge rate rather than 1%-granularity
    /// noise. Correlate a high rate with the concurrent cpuUsagePercent / thermalState.
    var batteryDrainPercentPerHour: Double?

    var metadata: [String: String] {
        var m = [
            "footprintMB": "\(footprintMB)",
            "residentMemoryMB": "\(residentMemoryMB)",
            "batteryPercent": batteryLevelPercent.map(String.init) ?? "unknown",
            "batteryState": batteryState,
            "thermalState": thermalState,
            "lowPowerMode": "\(lowPowerMode)",
            "activeProcessorCount": "\(activeProcessorCount)",
            "physicalMemoryMB": "\(physicalMemoryMB)",
            "deviceModel": deviceModel,
            "osVersion": osVersion
        ]
        if let cpuUsagePercent { m["cpuPercent"] = String(format: "%.0f", cpuUsagePercent) }
        if let threadCount { m["threadCount"] = "\(threadCount)" }
        if let batteryDrainPercentPerHour {
            m["batteryDrainPctPerHour"] = String(format: "%.1f", batteryDrainPercentPerHour)
        }
        return m
    }
}

struct MemoryFootprintSample: Sendable {
    let footprintMB: Int
    let residentMemoryMB: Int
}

private final class MainThreadWatchdog: @unchecked Sendable {
    private let logger: AppLogger
    private var contextProvider: (@MainActor () -> [String: String])?

    // Watchdog state — accessed only from watchdogQueue.
    private let watchdogQueue = DispatchQueue(label: "com.autohop.watchdog", qos: .utility)
    private var watchdogPingTime: Double = 0       // CFAbsoluteTime of last ping sent
    private var watchdogPongTime: Double = 0       // CFAbsoluteTime of last pong received from main
    private var watchdogHanging: Bool = false      // true while a hang is in progress
    private var watchdogAwaitingPong: Bool = false // true while a main-queue ping is outstanding
    private var watchdogLastInactiveGapLogTime: Double = 0
    private var isActive = false
    private let watchdogPollInterval: TimeInterval = 0.1
    private let watchdogHangThreshold: TimeInterval = 0.25
    private let watchdogInactiveGapLogInterval: TimeInterval = 5
    /// Gaps this long are app suspension (background, lock screen), not main-thread
    /// hangs — the watchdog simply wasn't running. Logged as info, not a warning.
    private let watchdogSuspensionThreshold: TimeInterval = 30

    init(logger: AppLogger) {
        self.logger = logger
    }

    func start(contextProvider: @escaping @MainActor () -> [String: String]) {
        self.contextProvider = contextProvider
        let now = CFAbsoluteTimeGetCurrent()
        watchdogQueue.async { [weak self] in
            guard let self, !self.isActive else { return }
            self.isActive = true
            self.watchdogPingTime = now
            self.watchdogPongTime = now
            self.watchdogAwaitingPong = false
            self.watchdogLastInactiveGapLogTime = 0
            self.scheduleWatchdogTick()
        }
    }

    func stop() {
        watchdogQueue.async { [weak self] in
            self?.isActive = false
            self?.watchdogAwaitingPong = false
            self?.watchdogHanging = false
        }
    }

    private func scheduleWatchdogTick() {
        watchdogQueue.asyncAfter(deadline: .now() + watchdogPollInterval) { [weak self] in
            guard let self, self.isActive else { return }
            self.watchdogTick()
        }
    }

    private func watchdogTick() {
        guard !watchdogAwaitingPong else {
            scheduleWatchdogTick()
            return
        }

        let pingTime = CFAbsoluteTimeGetCurrent()
        watchdogPingTime = pingTime
        watchdogAwaitingPong = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - pingTime
            let context: [String: String]
            if elapsed >= self.watchdogHangThreshold {
                context = MainActor.assumeIsolated {
                    self.contextProvider?() ?? [:]
                }
            } else {
                context = [:]
            }
            self.watchdogQueue.async {
                self.watchdogPong(pingTime: pingTime, elapsed: elapsed, context: context)
            }
        }

        scheduleWatchdogTick()
    }

    private func watchdogPong(pingTime: Double, elapsed: TimeInterval, context: [String: String]) {
        guard isActive else {
            watchdogAwaitingPong = false
            return
        }
        let pongTime = CFAbsoluteTimeGetCurrent()
        watchdogAwaitingPong = false

        if elapsed >= watchdogSuspensionThreshold {
            var metadata = context
            metadata["durationMs"] = "\(Int((elapsed * 1000).rounded()))"
            logger.info("ui.watchdogSuspensionGap", "Watchdog gap — app was suspended, not hung", metadata: metadata)
            watchdogHanging = false
        } else if elapsed >= watchdogHangThreshold {
            if context["sceneActive"] == "false" {
                watchdogHanging = false
                if pongTime - watchdogLastInactiveGapLogTime >= watchdogInactiveGapLogInterval {
                    watchdogLastInactiveGapLogTime = pongTime
                    var metadata = context
                    metadata["durationMs"] = "\(Int((elapsed * 1000).rounded()))"
                    logger.info(
                        "ui.watchdogInactiveGap",
                        "Watchdog gap while app scene was inactive, not a visible UI hang",
                        metadata: metadata
                    )
                }
            } else if !watchdogHanging {
                watchdogHanging = true
                let ms = Int((elapsed * 1000).rounded())
                var metadata = context
                metadata["durationMs"] = "\(ms)"
                logger.warning("ui.mainThreadHang", "Main thread hang detected", metadata: metadata)
            }
        } else {
            if watchdogHanging {
                watchdogHanging = false
                let ms = Int((elapsed * 1000).rounded())
                var metadata = context
                metadata["lastResponseMs"] = "\(ms)"
                logger.info("ui.mainThreadHangRecovered", "Main thread hang recovered", metadata: metadata)
            }
        }

        watchdogPongTime = pongTime
    }
}

@MainActor
final class ResourceMonitor {
    static let shared = ResourceMonitor()

    private let logger = AppLogger.shared
    private let watchdog = MainThreadWatchdog(logger: AppLogger.shared)
    private var samplingTask: Task<Void, Never>?
    private var diagnosticSessionEnabled = false
    private var contextProvider: (@MainActor () -> [String: String])?
    private var lastSnapshotTime: Date?
    private let minimumManualSnapshotInterval: TimeInterval = 8
    /// While the scene is inactive (background audio overnight is the case that matters),
    /// routine non-forced snapshots are throttled harder so the ~5 MB diagnostic log can
    /// span a whole night of playback instead of rotating every ~30 min. The forced five-minute
    /// periodic heartbeat and all warning snapshots (thermal/power/memory/hang) bypass this,
    /// so escalations are still timestamped promptly.
    private let minimumBackgroundSnapshotInterval: TimeInterval = 45
    /// Anchor for the battery drain-rate calc: the last level (0…1) and when it was
    /// observed. Held until the level actually changes so the rate spans a real 1%
    /// drop rather than 60 s of unchanged reading.
    private var batteryAnchor: (level: Float, at: Date)?
    private var lastHighMemoryTrimAt: Date?
    private let highMemoryTrimThresholdMB = 350
    private let highMemoryTrimCooldown: TimeInterval = 5 * 60

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Thermal + power-mode transitions logged as discrete events so a "warm phone"
        // escalation (nominal → fair → serious) is timestamped and correlatable with
        // what the app was doing, not just caught at the next 60 s sample. These
        // notifications post on arbitrary threads, so observe on the main queue and
        // assumeIsolated to stay MainActor-safe (ResourceMonitor is @MainActor).
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let monitor = ResourceMonitor.shared
                monitor.logger.warning("resources.thermalChange", "Thermal state changed", metadata: monitor.snapshot().metadata)
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let monitor = ResourceMonitor.shared
                monitor.logger.info("resources.powerModeChange", "Low Power Mode changed", metadata: monitor.snapshot().metadata)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let monitor = ResourceMonitor.shared
                monitor.logWarningSnapshot(
                    event: "resources.memoryWarning",
                    message: "Memory warning received",
                    reason: "memoryWarning",
                    context: monitor.contextProvider?() ?? [:]
                )
                Task { await ArtworkImageCache.shared.trimMemory(reason: "memoryWarning") }
            }
        }
    }

    func startPeriodicSampling(context: @escaping @MainActor () -> [String: String]) {
        guard samplingTask == nil else { return }
        contextProvider = context
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.diagnosticSessionEnabled {
                    self.logSnapshot(reason: "periodic", context: context(), force: true)
                } else {
                    let memory = self.taskMemoryMB()
                    self.requestHighMemoryTrimIfNeeded(
                        footprintMB: memory.footprintMB,
                        residentMemoryMB: memory.residentMB,
                        reason: "safetyHeartbeat"
                    )
                }
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
        if diagnosticSessionEnabled {
            watchdog.start(contextProvider: context)
            logSnapshot(
                reason: "diagnosticSession.started",
                context: context(),
                force: true
            )
        } else {
            setDiagnosticSessionEnabled(logger.isEnabled)
        }
    }

    func setDiagnosticSessionEnabled(_ enabled: Bool) {
        guard diagnosticSessionEnabled != enabled else { return }
        diagnosticSessionEnabled = enabled
        if enabled, let contextProvider {
            logger.info("resources.monitorStart", "Diagnostic resource monitoring started")
            watchdog.start(contextProvider: contextProvider)
            logSnapshot(reason: "diagnosticSession.started", context: contextProvider(), force: true)
        } else {
            watchdog.stop()
        }
    }

    func logSnapshot(reason: String, context: [String: String] = [:], force: Bool = false) {
        guard diagnosticSessionEnabled, logger.isEnabled else { return }
        if !force, let lastSnapshotTime {
            // Background (scene-inactive) sessions log far more sparsely so the capped
            // file can cover a whole night; foreground keeps the tighter 8 s cadence.
            let sceneInactive = context["sceneActive"] == "false"
            let minimumInterval = sceneInactive ? minimumBackgroundSnapshotInterval : minimumManualSnapshotInterval
            if Date().timeIntervalSince(lastSnapshotTime) < minimumInterval {
                return
            }
        }

        lastSnapshotTime = Date()
        let resourceSnapshot = snapshot()
        var metadata = resourceSnapshot.metadata
        metadata["reason"] = reason
        context.forEach { metadata[$0.key] = $0.value }
        logger.info("resources.snapshot", "Resource snapshot", metadata: metadata)
        requestHighMemoryTrimIfNeeded(snapshot: resourceSnapshot, reason: reason)
    }

    func logWarningSnapshot(event: String, message: String, reason: String, context: [String: String] = [:]) {
        lastSnapshotTime = Date()
        let resourceSnapshot = snapshot()
        var metadata = resourceSnapshot.metadata
        metadata["reason"] = reason
        context.forEach { metadata[$0.key] = $0.value }
        logger.warning(event, message, metadata: metadata)
        requestHighMemoryTrimIfNeeded(snapshot: resourceSnapshot, reason: reason)
    }

    /// Cheap stage boundary used by refresh/download/widget diagnostics. It does
    /// not enumerate threads or sample CPU and is therefore suitable for the
    /// finite background execution paths whose memory peaks we are isolating.
    func memoryFootprintSample() -> MemoryFootprintSample {
        let memory = taskMemoryMB()
        return MemoryFootprintSample(
            footprintMB: memory.footprintMB,
            residentMemoryMB: memory.residentMB
        )
    }

    func logMemoryStageDelta(
        stage: String,
        from before: MemoryFootprintSample,
        context: [String: String] = [:]
    ) -> MemoryFootprintSample {
        let after = memoryFootprintSample()
        let footprintDelta = after.footprintMB - before.footprintMB
        let residentDelta = after.residentMemoryMB - before.residentMemoryMB
        var metadata = context
        metadata.merge([
            "stage": stage,
            "footprintBeforeMB": "\(before.footprintMB)",
            "footprintAfterMB": "\(after.footprintMB)",
            "footprintDeltaMB": "\(footprintDelta)",
            "residentBeforeMB": "\(before.residentMemoryMB)",
            "residentAfterMB": "\(after.residentMemoryMB)",
            "residentDeltaMB": "\(residentDelta)"
        ]) { _, new in new }
        if abs(footprintDelta) >= 25 || after.footprintMB >= 300 {
            logger.info(
                "resources.stageDelta",
                "Process memory changed across a bounded work stage",
                metadata: metadata
            )
        } else {
            logger.verbose(
                "resources.stageDelta",
                "Process memory remained bounded across work stage",
                metadata: metadata
            )
        }
        requestHighMemoryTrimIfNeeded(
            footprintMB: after.footprintMB,
            residentMemoryMB: after.residentMemoryMB,
            reason: stage
        )
        return after
    }

    var externalPowerStateLabel: String {
        batteryStateLabel(UIDevice.current.batteryState)
    }

    /// Proactive decoded-image eviction keeps a transient artwork/list load from
    /// becoming a sustained 600–700 MB process. Cooldown prevents trim/log churn.
    private func requestHighMemoryTrimIfNeeded(snapshot: ResourceSnapshot, reason: String) {
        requestHighMemoryTrimIfNeeded(
            footprintMB: snapshot.footprintMB,
            residentMemoryMB: snapshot.residentMemoryMB,
            reason: reason
        )
    }

    private func requestHighMemoryTrimIfNeeded(
        footprintMB: Int,
        residentMemoryMB: Int,
        reason: String
    ) {
        guard footprintMB >= highMemoryTrimThresholdMB else { return }
        let now = Date()
        guard lastHighMemoryTrimAt.map({ now.timeIntervalSince($0) >= highMemoryTrimCooldown }) ?? true else { return }
        lastHighMemoryTrimAt = now
        logger.warning("resources.highMemoryTrim", "High process footprint triggered cache eviction", metadata: [
            "footprintMB": "\(footprintMB)",
            "residentMemoryMB": "\(residentMemoryMB)",
            "reason": reason
        ])
        Task { await ArtworkImageCache.shared.trimMemory(reason: "highFootprint") }
    }

    // MARK: - Device Snapshot

    private func snapshot() -> ResourceSnapshot {
        let taskMemory = taskMemoryMB()
        let device = UIDevice.current
        let batteryLevel = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        let processInfo = ProcessInfo.processInfo
        let cpu = cpuUsage()

        return ResourceSnapshot(
            footprintMB: taskMemory.footprintMB,
            residentMemoryMB: taskMemory.residentMB,
            batteryLevelPercent: batteryLevel,
            batteryState: batteryStateLabel(device.batteryState),
            thermalState: thermalStateLabel(processInfo.thermalState),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryMB: Int(processInfo.physicalMemory / 1_048_576),
            deviceModel: deviceModelIdentifier(),
            osVersion: "\(device.systemName) \(device.systemVersion)",
            cpuUsagePercent: cpu?.percent,
            threadCount: cpu?.threadCount,
            batteryDrainPercentPerHour: batteryDrainRate(level: device.batteryLevel, state: device.batteryState)
        )
    }

    /// Discharge rate in percentage points per hour, tracked between real 1% level
    /// changes. Returns nil while charging, before the level has moved, or when the
    /// level is unknown. Mutates `batteryAnchor` (safe — ResourceMonitor is a class).
    private func batteryDrainRate(level: Float, state: UIDevice.BatteryState) -> Double? {
        guard level >= 0 else { return nil }
        let now = Date()
        let charging = state == .charging || state == .full
        guard !charging else {
            batteryAnchor = (level, now)   // no discharge while on power
            return nil
        }
        guard let anchor = batteryAnchor else {
            batteryAnchor = (level, now)
            return nil
        }
        if level < anchor.level {
            let hours = now.timeIntervalSince(anchor.at) / 3600
            let rate = hours > 0 ? Double(anchor.level - level) * 100 / hours : nil
            batteryAnchor = (level, now)   // re-anchor at the new, lower level
            return rate
        }
        if level > anchor.level {
            batteryAnchor = (level, now)   // level rose (brief charge) — reset
        }
        // level == anchor.level: keep the anchor so elapsed grows until a real drop.
        return nil
    }

    /// Instantaneous app CPU load as a % of one core (sum over live non-idle threads),
    /// plus the live thread count. See `ResourceSnapshot.cpuUsagePercent`.
    private func cpuUsage() -> (percent: Double, threadCount: Int)? {
        var threadsArray: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadsArray, &threadCount) == KERN_SUCCESS,
              let threadsArray else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadsArray)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }
        // TH_USAGE_SCALE (1000) and TH_FLAGS_IDLE (0x1) are C macros that don't import
        // into Swift; use their fixed values from <mach/thread_info.h>.
        let usageScale = 1000.0
        let idleFlag: Int32 = 0x1
        let infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        var totalPercent = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = infoCount
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadsArray[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & idleFlag) == 0 {
                totalPercent += Double(info.cpu_usage) / usageScale * 100.0
            }
        }
        return (totalPercent, Int(threadCount))
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            bytes
                .filter { $0 != 0 }
                .compactMap { Unicode.Scalar(UInt32($0)) }
                .map(Character.init)
                .map(String.init)
                .joined()
        }
    }

    private func taskMemoryMB() -> (footprintMB: Int, residentMB: Int) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0) }

        let residentMB = Int(info.resident_size / 1_048_576)
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        let footprintMB = vmResult == KERN_SUCCESS
            ? Int(vmInfo.phys_footprint / 1_048_576)
            : residentMB
        return (footprintMB, residentMB)
    }

    private func batteryStateLabel(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
