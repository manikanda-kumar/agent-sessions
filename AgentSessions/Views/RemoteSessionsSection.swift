import SwiftUI

/// Read-only section showing live remote presences when "Monitor Remote" is enabled.
/// Non-selectable, non-navigable. Placed above the main sessions table.
struct RemoteSessionsSection: View {
    @ObservedObject var model: RemoteMonitorModel

    var body: some View {
        if !model.isEnabled { EmptyView() } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.machines.filter { $0.enabled }) { m in
                    machineHeader(m)
                    let status = model.machineStatuses[m.id.uuidString] ?? .probing
                    switch status {
                    case .probing:
                        remoteRowPlaceholder("Probing \(m.name)…")
                    case .unreachable(let msg):
                        remoteRowPlaceholder("⚠️ \(m.name): \(msg)")
                            .foregroundStyle(.secondary)
                    case .ok(let pres):
                        if pres.isEmpty {
                            remoteRowPlaceholder("\(m.name): no live agents")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(pres) { p in
                                remotePresenceRow(p)
                            }
                        }
                    }
                }
                if model.presences.isEmpty && model.machines.filter({$0.enabled}).isEmpty {
                    remoteRowPlaceholder("No remote machines configured")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
    }

    @ViewBuilder
    private func machineHeader(_ m: RemoteMachine) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(m.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if case .ok(let arr) = (model.machineStatuses[m.id.uuidString] ?? .probing) {
                Text("\(arr.count)")
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .padding(.top, 2)
    }

    private func remotePresenceRow(_ p: RemotePresence) -> some View {
        HStack(spacing: 6) {
            // Agent badge (reuse brand color)
            Text(p.agent.displayName.replacingOccurrences(of: " CLI", with: ""))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(TranscriptColorSystem.agentBrandAccent(source: p.agent).opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(TranscriptColorSystem.agentBrandAccent(source: p.agent).opacity(0.35), lineWidth: 0.5)
                )

            // Project / cwd (read-only label)
            Text(p.projectName ?? p.cwd ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            // State dot
            Circle()
                .fill(p.state == .active ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)

            // Times
            if let started = p.startedAt {
                Text("started \(relative(started))")
                    .foregroundStyle(.secondary)
            }
            if let la = p.lastActivityAt {
                Text("· \(relative(la))")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Text("#\(p.pid)")
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help("Remote presence on \(p.machineName) (read-only)")
    }

    private func remoteRowPlaceholder(_ text: String) -> some View {
        HStack {
            Text(text)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
