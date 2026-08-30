//
//  AppLifecycleCoordinator.swift
//  Autohop
//
//  AI CONTEXT
//  Stage 12 process-lifecycle owner. It owns the idempotent runtime state,
//  foreground/background-audio poller task, startup maintenance tasks, delayed
//  diagnostic tasks, and deterministic cancellation used by tests.
//  AppRuntimeWorkflow supplies lifecycle policy while this coordinator remains
//  the exclusive retained-Task registry.
//
//  INVARIANTS:
//  - start transitions constructed -> starting -> started exactly once;
//  - every long-lived/delayed Task created here is retained and cancelled;
//  - completed maintenance and delayed tasks remove themselves from storage;
//  - stop is idempotent and never destroys persisted user state;
//  - a stopped coordinator is not restarted; tests construct a fresh graph;
//  - lifecycle checkpoints remain local-save-before-sync.
//  - sleep scheduling is injected; production uses Task.sleep while tests may
//    advance deterministically without waiting for wall-clock time.
//
//  This type does not implement playback, feeds, downloads, sync,
//  archiving, onboarding, or navigation policy.
//

import Foundation

@MainActor
final class AppLifecycleCoordinator: ObservableObject {
    typealias Sleep = @Sendable (Duration) async -> Void

    @Published private(set) var state: AppStartupState = .constructed

    private let sleep: Sleep
    private var pollerTask: Task<Void, Never>?
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var delayedDiagnosticTasks: [UUID: Task<Void, Never>] = [:]

    init(
        sleep: @escaping Sleep = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    func beginStart() -> Bool {
        guard state == .constructed else { return false }
        state = .starting
        return true
    }

    func finishStart() {
        guard state == .starting else { return }
        state = .started
    }

    func startPoller(
        interval: Duration = .seconds(30),
        operation: @escaping @MainActor () async -> Void
    ) {
        guard pollerTask == nil else { return }
        pollerTask = Task { @MainActor in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    func runMaintenance(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        maintenanceTasks[id] = Task { @MainActor [weak self] in
            await operation()
            self?.maintenanceTasks[id] = nil
        }
    }

    func replaceDelayedDiagnostics(
        delays: [TimeInterval],
        operation: @escaping @MainActor (TimeInterval) async -> Void
    ) {
        cancelDelayedDiagnostics()
        for delay in delays {
            let id = UUID()
            delayedDiagnosticTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.sleep(.seconds(delay))
                guard !Task.isCancelled else {
                    self.delayedDiagnosticTasks[id] = nil
                    return
                }
                await operation(delay)
                self.delayedDiagnosticTasks[id] = nil
            }
        }
    }

    func cancelDelayedDiagnostics() {
        delayedDiagnosticTasks.values.forEach { $0.cancel() }
        delayedDiagnosticTasks.removeAll()
    }

    func stop() {
        guard state != .stopped else { return }
        pollerTask?.cancel()
        pollerTask = nil
        maintenanceTasks.values.forEach { $0.cancel() }
        maintenanceTasks.removeAll()
        cancelDelayedDiagnostics()
        state = .stopped
    }
}
