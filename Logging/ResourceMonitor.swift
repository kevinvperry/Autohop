import Foundation
import UIKit
import Darwin.Mach

// AI CONTEXT — Logging/ResourceMonitor.swift
// Captures device/process resource snapshots (Mach task memory, battery,
// thermal state, low-power mode) for diagnostic log context. AppState attaches
// a snapshot's metadata to significant log events and runs a periodic sampling
// timer while diagnostics are enabled. Debug/observability only — no feature
// behaviour depends on these values.
struct ResourceSnapshot {
    var memoryMB: Int
    var residentMemoryMB: Int
    var batteryLevelPercent: Int?
    var batteryState: String
    var thermalState: String
    var lowPowerMode: Bool
    var activeProcessorCount: Int
    var physicalMemoryMB: Int
    var deviceModel: String
    var osVersion: String

    var metadata: [String: String] {
        [
            "memoryMB": "\(memoryMB)",
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
    }
}

@MainActor
final class ResourceMonitor {
    static let shared = ResourceMonitor()

    private let logger = AppLogger.shared
    private var samplingTask: Task<Void, Never>?
    private var lastSnapshotTime: Date?
    private let minimumManualSnapshotInterval: TimeInterval = 8

    // Watchdog state — accessed only from watchdogQueue
    private let watchdogQueue = DispatchQueue(label: "com.autohop.watchdog", qos: .utility)
    private var watchdogPingTime: Double = 0       // CFAbsoluteTime of last ping sent
    private var watchdogPongTime: Double = 0       // CFAbsoluteTime of last pong received from main
    private var watchdogHanging: Bool = false      // true while a hang is in progress
    private let watchdogPollInterval: TimeInterval = 0.1
    private let watchdogHangThreshold: TimeInterval = 0.25
    /// Gaps this long are app suspension (background, lock screen), not main-thread
    /// hangs — the watchdog simply wasn't running. Logged as info, not a warning.
    private let watchdogSuspensionThreshold: TimeInterval = 30

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func startPeriodicSampling(context: @escaping @MainActor () -> [String: String]) {
        guard samplingTask == nil else { return }
        logger.info("resources.monitorStart", "Resource monitor started")
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.logSnapshot(reason: "periodic", context: context(), force: true)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        startWatchdog()
    }

    func logSnapshot(reason: String, context: [String: String] = [:], force: Bool = false) {
        if !force,
           let lastSnapshotTime,
           Date().timeIntervalSince(lastSnapshotTime) < minimumManualSnapshotInterval {
            return
        }

        lastSnapshotTime = Date()
        var metadata = snapshot().metadata
        metadata["reason"] = reason
        context.forEach { metadata[$0.key] = $0.value }
        logger.info("resources.snapshot", "Resource snapshot", metadata: metadata)
    }

    // MARK: - Main Thread Watchdog

    private func startWatchdog() {
        let now = CFAbsoluteTimeGetCurrent()
        watchdogQueue.async { [weak self] in
            self?.watchdogPingTime = now
            self?.watchdogPongTime = now
        }
        scheduleWatchdogTick()
    }

    private func scheduleWatchdogTick() {
        watchdogQueue.asyncAfter(deadline: .now() + watchdogPollInterval) { [weak self] in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        let pingTime = CFAbsoluteTimeGetCurrent()
        watchdogPingTime = pingTime

        DispatchQueue.main.async { [weak self] in
            self?.watchdogQueue.async {
                self?.watchdogPong(pingTime: pingTime)
            }
        }

        scheduleWatchdogTick()
    }

    private func watchdogPong(pingTime: Double) {
        let pongTime = CFAbsoluteTimeGetCurrent()
        let elapsed = pongTime - pingTime

        if elapsed >= watchdogSuspensionThreshold {
            logger.info("ui.watchdogSuspensionGap", "Watchdog gap — app was suspended, not hung", metadata: [
                "durationMs": "\(Int((elapsed * 1000).rounded()))"
            ])
        } else if elapsed >= watchdogHangThreshold {
            if !watchdogHanging {
                watchdogHanging = true
                let ms = Int((elapsed * 1000).rounded())
                logger.warning("ui.mainThreadHang", "Main thread hang detected", metadata: [
                    "durationMs": "\(ms)"
                ])
            }
        } else {
            if watchdogHanging {
                watchdogHanging = false
                let ms = Int((elapsed * 1000).rounded())
                logger.info("ui.mainThreadHangRecovered", "Main thread hang recovered", metadata: [
                    "lastResponseMs": "\(ms)"
                ])
            }
        }

        watchdogPongTime = pongTime
    }

    // MARK: - Device Snapshot

    private func snapshot() -> ResourceSnapshot {
        let taskMemory = taskMemoryMB()
        let device = UIDevice.current
        let batteryLevel = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        let processInfo = ProcessInfo.processInfo

        return ResourceSnapshot(
            memoryMB: taskMemory.virtualMB,
            residentMemoryMB: taskMemory.residentMB,
            batteryLevelPercent: batteryLevel,
            batteryState: batteryStateLabel(device.batteryState),
            thermalState: thermalStateLabel(processInfo.thermalState),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryMB: Int(processInfo.physicalMemory / 1_048_576),
            deviceModel: deviceModelIdentifier(),
            osVersion: "\(device.systemName) \(device.systemVersion)"
        )
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

    private func taskMemoryMB() -> (virtualMB: Int, residentMB: Int) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0) }
        return (
            Int(info.virtual_size / 1_048_576),
            Int(info.resident_size / 1_048_576)
        )
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
