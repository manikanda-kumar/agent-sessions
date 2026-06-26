import SwiftUI

extension PreferencesView {
    /// Machine list + add buttons, rendered inside `remoteTabImpl`.
    @ViewBuilder
    var remoteMachinesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Machines")
                    .font(.headline)
                Spacer()
                Button { addSSH() } label: { Label("SSH", systemImage: "plus") }
                    .buttonStyle(.bordered)
                Button { addLabctl() } label: { Label("labctl", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }

            if remoteMonitor.machines.isEmpty {
                Text("No machines configured. Add an SSH host or labctl playground.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remoteMonitor.machines) { m in
                    remoteMachineEditor(m)
                }
            }
        }
    }

    private func remoteMachineEditor(_ m: RemoteMachine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { m.enabled },
                    set: { newVal in
                        var copy = m; copy.enabled = newVal
                        remoteMonitor.updateMachine(copy)
                    }
                ))
                .labelsHidden()
                TextField("Name", text: Binding(
                    get: { m.name },
                    set: { newVal in var c = m; c.name = newVal; remoteMonitor.updateMachine(c) }
                ))
                .frame(width: 160)

                Picker("", selection: Binding(
                    get: { m.kind },
                    set: { newVal in
                        var c = m; c.kind = newVal
                        remoteMonitor.updateMachine(c)
                    }
                )) {
                    Text("SSH").tag(RemoteMachine.Kind.ssh)
                    Text("labctl").tag(RemoteMachine.Kind.labctl)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)

                Spacer()

                Button("Test") { testConnection(m) }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { remoteMonitor.removeMachine(id: m.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered)
            }

            if m.kind == .ssh {
                HStack(spacing: 8) {
                    Text("Host").frame(width: 40, alignment: .trailing)
                    TextField("pi-manik or 192.168.88.12", text: Binding(
                        get: { m.sshHost ?? "" },
                        set: { v in var c = m; c.sshHost = v.isEmpty ? nil : v; remoteMonitor.updateMachine(c) }
                    ))
                    .frame(maxWidth: 220)
                    Text("User").frame(width: 40, alignment: .trailing)
                    TextField("manik", text: Binding(
                        get: { m.sshUser ?? "" },
                        set: { v in var c = m; c.sshUser = v.isEmpty ? nil : v; remoteMonitor.updateMachine(c) }
                    ))
                    .frame(width: 100)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Playground ID").frame(width: 90, alignment: .trailing)
                    TextField("69886bd0f45ebe34b489cdd2", text: Binding(
                        get: { m.labctlPlaygroundID ?? "" },
                        set: { v in var c = m; c.labctlPlaygroundID = v.isEmpty ? nil : v; remoteMonitor.updateMachine(c) }
                    ))
                    .frame(maxWidth: 320)
                    Text("Machine (opt)").frame(width: 90, alignment: .trailing)
                    TextField("", text: Binding(
                        get: { m.labctlMachine ?? "" },
                        set: { v in var c = m; c.labctlMachine = v.isEmpty ? nil : v; remoteMonitor.updateMachine(c) }
                    ))
                    .frame(width: 160)
                }
            }

            // Inline status line for this machine.
            if let status = remoteMonitor.machineStatuses[m.id.uuidString] {
                switch status {
                case .probing:
                    Text("Probing…").font(.caption).foregroundStyle(.secondary)
                case .unreachable(let msg):
                    Text("⚠️ \(msg)").font(.caption).foregroundStyle(.secondary)
                case .ok(let pres):
                    Text("\(pres.count) live agent\(pres.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func addSSH() {
        let m = RemoteMachine(name: "New SSH", kind: .ssh, sshHost: "", sshUser: NSUserName())
        remoteMonitor.addMachine(m)
    }

    private func addLabctl() {
        let m = RemoteMachine(name: "New labctl", kind: .labctl, labctlPlaygroundID: "")
        remoteMonitor.addMachine(m)
    }

    private func testConnection(_ m: RemoteMachine) {
        remoteMonitor.applyTestResult(.probing, for: m.id.uuidString)
        // Run a one-shot probe outside the model poll loop.
        Task { @MainActor in
            let t: any RemoteProbeTransport
            switch m.kind {
            case .ssh:
                t = SSHRemoteTransport(machineID: m.id.uuidString, machineName: m.name, host: m.sshHost ?? "", user: m.sshUser, identityPath: m.sshIdentityPath)
            case .labctl:
                t = LabctlRemoteTransport(machineID: m.id.uuidString, machineName: m.name, playgroundID: m.labctlPlaygroundID ?? "", machine: m.labctlMachine)
            }
            do {
                let out = try await t.run(RemoteProbeScript.probe, timeout: 10)
                let facts = RemoteProbeParser.parse(out)
                let pres = RemoteProbeParser.presences(from: facts, machineID: t.machineID, machineName: t.machineName, sourceForAgent: Self.remoteSource(for:))
                remoteMonitor.applyTestResult(.ok(pres), for: m.id.uuidString)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                remoteMonitor.applyTestResult(.unreachable(msg), for: m.id.uuidString)
            }
        }
    }

    /// Mirrors RemoteMonitorModel's agent mapping for the one-shot test probe.
    private static func remoteSource(for raw: String) -> SessionSource? {
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
}
