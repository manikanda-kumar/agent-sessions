import Foundation

/// Abstraction for executing a read-only probe script on a remote machine.
/// Both SSH and labctl transports implement this by running a command and
/// returning combined stdout. Implementations must be Sendable and safe for
/// concurrent use from the monitor model.
protocol RemoteProbeTransport: Sendable {
    /// Stable identifier for the machine (used for status dictionary keys).
    var machineID: String { get }

    /// Human name for display / errors.
    var machineName: String { get }

    /// Run the given shell script (as text) with a hard timeout.
    /// The script is typically a single-line or heredoc bash snippet.
    /// Returns raw stdout on success. Throws on transport failure/timeout.
    func run(_ script: String, timeout: TimeInterval) async throws -> String
}

/// Errors surfaced by transports (never leak into UI; mapped to .unreachable).
enum RemoteProbeError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(TimeInterval)
    case nonZeroExit(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "Failed to launch: \(msg)"
        case .timedOut(let t): return "Timed out after \(Int(t))s"
        case .nonZeroExit(let code, let stderr): return "Exit \(code): \(stderr)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Thread-safe one-shot flag used to mark that a process was killed by the
/// timeout watchdog, so transports can throw `.timedOut` instead of
/// misclassifying the resulting non-zero exit as `.nonZeroExit`.
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
