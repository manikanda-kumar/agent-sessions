import Foundation
import SwiftUI
import Combine

/// Observable model for remote machine live presence (read-only).
/// Polls only when `MonitorRemoteEnabled` is true and the window has registered visibility.
@MainActor
final class RemoteMonitorModel: ObservableObject {
    static let storageKeyMachines = "RemoteMachines"
    static let storageKeyEnabled = "MonitorRemoteEnabled"

    /// Shared instance so the toolbar toggle, Preferences editor, and the
    /// sessions-list section all observe the same state.
    static let shared = RemoteMonitorModel()

    /// Source of truth for the feature toggle. Persisted to UserDefaults under
    /// `storageKeyEnabled` so any `@AppStorage("MonitorRemoteEnabled")` reader
    /// stays in sync. The `didSet` does not fire during `init`, so startup is
    /// handled explicitly after the ready gate.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.storageKeyEnabled)
            if isEnabled {
                startIfNeeded()
            } else {
                stop(clear: true)
            }
        }
    }

    @Published private(set) var machineStatuses: [String: RemoteMachineStatus] = [:]
    @Published private(set) var presences: [RemotePresence] = []

    /// Configured machines (persisted as JSON in UserDefaults for simplicity).
    @Published private(set) var machines: [RemoteMachine] = [] {
        didSet { persistMachines() }
    }

    private var pollTask: Task<Void, Never>?
    private var visibleConsumerIDs: Set<UUID> = []
    private var lastProbeAt: Date?
    private var isRefreshing = false

    // Tunables
    nonisolated static let foregroundInterval: TimeInterval = 20
    nonisolated static let backgroundInterval: TimeInterval = 60
    nonisolated static let probeTimeout: TimeInterval = RemoteProbeScript.defaultTimeout

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.storageKeyEnabled)

        // Load persisted machines
        if let data = UserDefaults.standard.data(forKey: Self.storageKeyMachines),
           let decoded = try? JSONDecoder().decode([RemoteMachine].self, from: data) {
            self.machines = decoded
        } else {
            self.machines = []
        }

        // Avoid background work under tests
        guard !AppRuntime.isRunningTests else { return }

        Task {
            await AppReadyGate.waitUntilReady()
            if isEnabled { startIfNeeded() }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Config

    func setMachines(_ newMachines: [RemoteMachine]) {
        machines = newMachines
        // Drop statuses for removed machines
        let ids = Set(newMachines.map(\.id.uuidString))
        machineStatuses = machineStatuses.filter { ids.contains($0.key) }
        recomputePresences()
    }

    func addMachine(_ m: RemoteMachine) {
        if !machines.contains(where: { $0.id == m.id }) {
            machines.append(m)
        }
    }

    func updateMachine(_ m: RemoteMachine) {
        if let idx = machines.firstIndex(where: { $0.id == m.id }) {
            machines[idx] = m
        }
    }

    func removeMachine(id: UUID) {
        machines.removeAll { $0.id == id }
        machineStatuses.removeValue(forKey: id.uuidString)
        recomputePresences()
    }

    func machine(withID id: UUID) -> RemoteMachine? {
        machines.first { $0.id == id }
    }

    /// Apply a one-shot probe result (used by the Preferences "Test" button)
    /// without going through the poll loop.
    func applyTestResult(_ status: RemoteMachineStatus, for machineID: String) {
        machineStatuses[machineID] = status
        recomputePresences()
    }

    // MARK: - Visibility (reuse pattern from CodexActiveSessionsModel)

    func setVisible(_ visible: Bool, consumerID: UUID) {
        guard !AppRuntime.isRunningTests else { return }
        let had = hasVisibleConsumer
        if visible { visibleConsumerIDs.insert(consumerID) } else { visibleConsumerIDs.remove(consumerID) }
        guard hasVisibleConsumer != had else { return }
        if hasVisibleConsumer, isEnabled {
            // Kick an immediate refresh when becoming visible
            Task { await refreshOnce() }
        }
    }

    private var hasVisibleConsumer: Bool { !visibleConsumerIDs.isEmpty }

    // MARK: - Polling

    private func startIfNeeded() {
        guard !AppRuntime.isRunningTests else { return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.isEnabled && self.hasVisibleConsumer {
                    await self.refreshOnce()
                }
                let interval = self.hasVisibleConsumer ? Self.foregroundInterval : Self.backgroundInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stop(clear: Bool) {
        pollTask?.cancel()
        pollTask = nil
        if clear {
            machineStatuses.removeAll()
            presences = []
        }
    }

    func refreshNow() {
        guard !AppRuntime.isRunningTests else { return }
        guard isEnabled else { return }
        Task { await refreshOnce() }
    }

    // MARK: - Core probe cycle

    private func refreshOnce() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let enabledMachines = machines.filter { $0.enabled }
        guard !enabledMachines.isEmpty else {
            machineStatuses = [:]
            presences = []
            return
        }

        // Build transports (cheap objects)
        let transports: [any RemoteProbeTransport] = enabledMachines.map { m in
            switch m.kind {
            case .ssh:
                return SSHRemoteTransport(
                    machineID: m.id.uuidString,
                    machineName: m.name,
                    host: m.sshHost ?? "",
                    user: m.sshUser,
                    identityPath: m.sshIdentityPath
                )
            case .labctl:
                return LabctlRemoteTransport(
                    machineID: m.id.uuidString,
                    machineName: m.name,
                    playgroundID: m.labctlPlaygroundID ?? "",
                    machine: m.labctlMachine
                )
            }
        }

        let script = RemoteProbeScript.probe

        await withTaskGroup(of: (String, RemoteMachineStatus).self) { group in
            for t in transports {
                group.addTask {
                    do {
                        let out = try await t.run(script, timeout: Self.probeTimeout)
                        let facts = RemoteProbeParser.parse(out)
                        let pres = RemoteProbeParser.presences(from: facts,
                                                               machineID: t.machineID,
                                                               machineName: t.machineName,
                                                               now: Date(),
                                                               activeThreshold: RemotePresence.defaultActiveThreshold,
                                                               sourceForAgent: Self.sourceFromAgentRaw)
                        return (t.machineID, .ok(pres))
                    } catch {
                        let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        return (t.machineID, .unreachable(msg))
                    }
                }
            }

            var newStatuses: [String: RemoteMachineStatus] = [:]
            for await (mid, status) in group {
                newStatuses[mid] = status
            }

            // Preserve .probing if a machine had no result (shouldn't happen)
            for m in enabledMachines {
                let key = m.id.uuidString
                if newStatuses[key] == nil {
                    newStatuses[key] = machineStatuses[key] ?? .probing
                }
            }

            self.machineStatuses = newStatuses
            self.recomputePresences()
        }

        lastProbeAt = Date()
    }

    private func recomputePresences() {
        var all: [RemotePresence] = []
        for status in machineStatuses.values {
            if case .ok(let arr) = status {
                all.append(contentsOf: arr)
            }
        }
        // Stable order: by machine name then agent display
        all.sort { lhs, rhs in
            if lhs.machineName != rhs.machineName { return lhs.machineName < rhs.machineName }
            if lhs.agent != rhs.agent { return lhs.agent.displayName < rhs.agent.displayName }
            return lhs.pid < rhs.pid
        }
        presences = all
    }

    // MARK: - Agent mapping (expandable)

    private static func sourceFromAgentRaw(_ raw: String) -> SessionSource? {
        switch raw.lowercased() {
        case "codex": return .codex
        case "claude", "claude-code": return .claude
        case "opencode": return .opencode
        case "pi": return .pi
        case "gemini": return .gemini
        case "cursor": return .cursor
        default: return nil
        }
    }

    // MARK: - Persistence

    private func persistMachines() {
        guard let data = try? JSONEncoder().encode(machines) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKeyMachines)
    }

    // MARK: - Seeding helpers (used by UI/config)

    static func defaultPi5() -> RemoteMachine {
        RemoteMachine(
            name: "Pi5",
            kind: .ssh,
            sshHost: "pi-manik",
            sshUser: "manik",
            sshIdentityPath: nil,
            enabled: true
        )
    }

    static func defaultLabctlPlayground() -> RemoteMachine {
        RemoteMachine(
            name: "labctl playground",
            kind: .labctl,
            labctlPlaygroundID: "69886bd0f45ebe34b489cdd2",
            labctlMachine: nil,
            enabled: true
        )
    }

    /// If no machines configured, seed the two verified targets (disabled until user toggles on).
    func seedDefaultsIfEmpty() {
        guard machines.isEmpty else { return }
        var seeded: [RemoteMachine] = []
        var p = Self.defaultPi5(); p.enabled = false; seeded.append(p)
        var l = Self.defaultLabctlPlayground(); l.enabled = false; seeded.append(l)
        machines = seeded
    }
}
