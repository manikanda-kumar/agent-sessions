import Foundation

/// A live (or recently-live) agent process observed on a remote machine.
/// Read-only; no navigable file paths are exposed.
struct RemotePresence: Identifiable, Equatable {
    let id: String                 // stable: machineID|pid
    let machineID: String
    let machineName: String

    let agent: SessionSource
    let pid: Int
    let cwd: String?
    let projectName: String?       // derived friendly name (e.g. last path component or decoded)

    let startedAt: Date?
    let lastActivityAt: Date?      // from newest jsonl mtime for matching project dir (or root proxy)
    let state: State

    enum State: String, Codable, Equatable {
        case active
        case idle
    }

    /// Threshold used to classify active vs idle from mtime.
    static let defaultActiveThreshold: TimeInterval = 120

    init(id: String,
         machineID: String,
         machineName: String,
         agent: SessionSource,
         pid: Int,
         cwd: String?,
         projectName: String?,
         startedAt: Date?,
         lastActivityAt: Date?,
         state: State) {
        self.id = id
        self.machineID = machineID
        self.machineName = machineName
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.projectName = projectName
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.state = state
    }
}

/// Status of one configured remote machine.
enum RemoteMachineStatus: Equatable {
    case probing
    case ok([RemotePresence])
    case unreachable(String)   // human error message
}
