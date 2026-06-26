import Foundation

/// SSH transport using /usr/bin/ssh in BatchMode with piped script.
/// Script is sent via `bash -s` after optional base64 to dodge quoting.
final class SSHRemoteTransport: RemoteProbeTransport, @unchecked Sendable {

    // Test seam: return the argv (without the script) that would be used.
    static func buildSSHArguments(host: String, user: String?, identityPath: String?) -> [String] {
        var args = ["-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "StrictHostKeyChecking=accept-new"]
        if let id = identityPath, !id.isEmpty {
            args += ["-i", id]
        }
        let target: String = {
            if let u = user, !u.isEmpty { return "\(u)@\(host)" }
            return host
        }()
        args += [target, "bash", "-s"]
        return args
    }
    let machineID: String
    let machineName: String
    private let host: String
    private let user: String?
    private let identityPath: String?

    init(machineID: String, machineName: String, host: String, user: String?, identityPath: String?) {
        self.machineID = machineID
        self.machineName = machineName
        self.host = host
        self.user = user
        self.identityPath = identityPath
    }

    func run(_ script: String, timeout: TimeInterval) async throws -> String {
        let ssh = "/usr/bin/ssh"
        var args = ["-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "StrictHostKeyChecking=accept-new"]
        if let id = identityPath, !id.isEmpty {
            args += ["-i", id]
        }
        let target: String = {
            if let u = user, !u.isEmpty { return "\(u)@\(host)" }
            return host
        }()
        args += [target, "bash", "-s"]

        let result = try await runProcess(executable: ssh, arguments: args, input: script, timeout: timeout)
        return result.stdout
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(executable: String, arguments: [String], input: String, timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        // Write input without blocking main
        DispatchQueue.global(qos: .utility).async {
            let handle = inPipe.fileHandleForWriting
            if let data = input.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }

        try process.run()

        let didTimeout = TimeoutFlag()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            if process.isRunning {
                didTimeout.set()
                process.terminate()
            }
        }

        // Drain stdout/stderr concurrently with waitUntilExit to avoid a
        // pipe-buffer deadlock when the remote emits more than the OS pipe size.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let code = process.terminationStatus

        if didTimeout.isSet {
            throw RemoteProbeError.timedOut(timeout)
        }
        if code != 0 {
            // Surface non-zero for unreachable classification upstream
            throw RemoteProbeError.nonZeroExit(Int(code), stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ProcessResult(stdout: stdout, stderr: stderr, exitCode: code)
    }
}
