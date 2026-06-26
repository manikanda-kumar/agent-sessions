import Foundation

/// Hosts the read-only probe script (as a Swift string constant) and the pure parser.
/// The script is designed to be robust on minimal Linux (BusyBox pgrep/ find variants).
enum RemoteProbeScript {
    /// The bash probe. Emits strict JSONL:
    /// - {"type":"host","text":"user@host uname -sm"}
    /// - {"type":"proc","agent":"claude","pid":12345,"cwd":"/home/u/proj","start_epoch":1712345678}
    /// - {"type":"project_mtime","root":"...","project":"-home-u-proj","mtime_epoch":1712345900}
    ///
    /// The script is intentionally small and uses only common tools.
    /// It is sent base64-encoded by transports to avoid quoting issues.
    static let probe: String = #"""
printf '{"type":"host","text":"%s@%s %s"}\n' "$(whoami)" "$(hostname)" "$(uname -sm)"
for a in codex claude opencode pi gemini cursor; do
  for p in $(pgrep -x "$a" 2>/dev/null || true); do
    cwd=$(readlink /proc/$p/cwd 2>/dev/null || echo "")
    # Convert lstart to epoch best-effort; fall back to 0
    lst=$(ps -o lstart= -p "$p" 2>/dev/null | xargs || echo "")
    start_epoch=0
    if [ -n "$lst" ]; then
      # Try GNU date -d first; else BSD date -j
      start_epoch=$(date -d "$lst" +%s 2>/dev/null || date -j -f "%a %b %d %T %Y" "$lst" +%s 2>/dev/null || echo 0)
    fi
    printf '{"type":"proc","agent":"%s","pid":%s,"cwd":"%s","start_epoch":%s}\n' "$a" "$p" "${cwd//\"/\\\"}" "$start_epoch"
  done
done
for root in "$HOME/.claude/projects" "$HOME/.codex/sessions" "$HOME/.pi/agent/sessions" "$HOME/.config/opencode"; do
  [ -d "$root" ] || continue
  # For each immediate project subdir, emit the newest jsonl mtime (best effort)
  for proj in "$root"/*; do
    [ -d "$proj" ] || continue
    newest=$(find "$proj" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $1}')
    if [ -n "$newest" ]; then
      b=$(basename "$proj")
      # Convert float epoch to int
      mtime_epoch=$(printf '%.0f' "$newest" 2>/dev/null || echo 0)
      printf '{"type":"project_mtime","root":"%s","project":"%s","mtime_epoch":%s}\n' "$root" "${b//\"/\\\"}" "$mtime_epoch"
    fi
  done
done
"""#

    /// Timeout used for a single machine probe.
    static let defaultTimeout: TimeInterval = 12
}

/// Pure parser seam. No I/O, no network. Designed for easy unit testing.
enum RemoteProbeParser {
    struct Facts {
        var hostLine: String?
        var procs: [ProcFact] = []
        /// root -> projectDirName -> mtime
        var projectMtimes: [String: [String: Date]] = [:]
    }

    struct ProcFact {
        let agentRaw: String
        let pid: Int
        let cwd: String?
        let startedAt: Date?
    }

    static func parse(_ stdout: String) -> Facts {
        var facts = Facts()
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = String(line).data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let type = obj["type"] as? String else { continue }
            switch type {
            case "host":
                if let t = obj["text"] as? String { facts.hostLine = t }
            case "proc":
                guard let agent = obj["agent"] as? String,
                      let pidNum = obj["pid"] as? NSNumber else { continue }
                let cwd = obj["cwd"] as? String
                var started: Date? = nil
                if let se = obj["start_epoch"] as? NSNumber, se.intValue > 0 {
                    started = Date(timeIntervalSince1970: se.doubleValue)
                }
                facts.procs.append(ProcFact(agentRaw: agent, pid: pidNum.intValue, cwd: cwd, startedAt: started))
            case "project_mtime":
                guard let root = obj["root"] as? String,
                      let proj = obj["project"] as? String,
                      let me = obj["mtime_epoch"] as? NSNumber else { continue }
                let dt = Date(timeIntervalSince1970: me.doubleValue)
                var byProj = facts.projectMtimes[root] ?? [:]
                // keep the max if duplicates
                if let prev = byProj[proj], prev > dt { /* keep prev */ } else {
                    byProj[proj] = dt
                }
                facts.projectMtimes[root] = byProj
            default:
                break
            }
        }
        return facts
    }

    /// Map a raw cwd to the Claude-style encoded project dir name used under ~/.claude/projects etc.
    /// "/home/manik/Github" -> "-home-manik-Github"
    static func projectDirName(fromCwd cwd: String?) -> String? {
        guard let c = cwd, !c.isEmpty else { return nil }
        // Strip trailing slash, replace / with -, and ensure leading -
        var p = c.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        p = p.replacingOccurrences(of: "/", with: "-")
        if !p.hasPrefix("-") { p = "-" + p }
        return p
    }

    /// Given facts + machine context, produce presences.
    /// The caller supplies the mapping from agent-raw -> SessionSource (best effort).
    static func presences(from facts: Facts,
                          machineID: String,
                          machineName: String,
                          now: Date = Date(),
                          activeThreshold: TimeInterval = RemotePresence.defaultActiveThreshold,
                          sourceForAgent: (String) -> SessionSource?) -> [RemotePresence] {
        var out: [RemotePresence] = []
        for pf in facts.procs {
            guard let source = sourceForAgent(pf.agentRaw) else { continue }
            let proj = projectDirName(fromCwd: pf.cwd)
            // Find best mtime: prefer exact project match under common roots, else any root's newest for that agent
            var lastAct: Date? = nil
            if let pr = proj {
                // Match the project dir name across every reported root.
                // Remote $HOME paths are absolute and machine-specific, so we
                // match by encoded project name rather than by root prefix.
                for (_, byp) in facts.projectMtimes {
                    if let m = byp[pr] {
                        if lastAct == nil || m > lastAct! { lastAct = m }
                    }
                }
            }
            // Fallback: global newest mtime across anything reported
            if lastAct == nil {
                var maxM: Date?
                for byp in facts.projectMtimes.values {
                    for d in byp.values {
                        if maxM == nil || d > maxM! { maxM = d }
                    }
                }
                lastAct = maxM
            }

            let st: RemotePresence.State = {
                if let la = lastAct, now.timeIntervalSince(la) < activeThreshold { return .active }
                return .idle
            }()

            let pidStr = String(pf.pid)
            let rid = "\(machineID)|\(pidStr)"
            let friendlyProject: String?
            if let p = proj {
                friendlyProject = p.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    .replacingOccurrences(of: "-", with: "/")
            } else {
                friendlyProject = pf.cwd
            }

            let pres = RemotePresence(
                id: rid,
                machineID: machineID,
                machineName: machineName,
                agent: source,
                pid: pf.pid,
                cwd: pf.cwd,
                projectName: friendlyProject.map { ($0 as NSString).lastPathComponent },
                startedAt: pf.startedAt,
                lastActivityAt: lastAct,
                state: st
            )
            out.append(pres)
        }
        return out
    }
}


