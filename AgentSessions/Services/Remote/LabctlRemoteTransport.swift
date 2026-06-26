import Foundation

/// labctl transport for iximiuz Labs playgrounds.
/// Invokes `labctl ssh <playgroundID> [-m <machine>] -- bash -c 'echo <b64>|base64 -d|bash'`
final class LabctlRemoteTransport: RemoteProbeTransport, @unchecked Sendable {

    // Test seam
    static func buildLabctlArguments(playgroundID: String, machine: String?) -> [String] {
        var args = ["ssh", playgroundID]
        if let m = machine, !m.isEmpty {
            args += ["-m", m]
        }
        // Note: the actual invocation appends -- bash -c "<inner with b64>"
        args += ["--", "bash", "-c", "<script>"]
        return args
    }
    let machineID: String
    let machineName: String
    private let playgroundID: String
    private let machine: String?
    private let binPath: String

    init(machineID: String,
         machineName: String,
         playgroundID: String,
         machine: String?,
         binPath: String = "~/.iximiuz/labctl/bin/labctl") {
        self.machineID = machineID
        self.machineName = machineName
        self.playgroundID = playgroundID
        self.machine = machine
        self.binPath = binPath
    }

    func run(_ script: String, timeout: TimeInterval) async throws -> String {
        let expandedBin = (binPath as NSString).expandingTildeInPath
        let binURL = URL(fileURLWithPath: expandedBin)
        // If not directly executable at that path, fall back to PATH lookup "labctl"
        let execURL: URL = {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: binURL.path, isDirectory: &isDir), !isDir.boolValue {
                return binURL
            }
            return URL(fileURLWithPath: "labctl") // rely on $PATH via Process
        }()

        // Base64 the script to avoid any quoting nightmares inside the remote ssh layer.
        let b64 = Data(script.utf8).base64EncodedString()
        // Build: bash -c "echo <b64> | base64 -d | bash"
        let inner = "echo \(b64) | base64 -d | bash"

        var args = ["ssh", playgroundID]
        if let m = machine, !m.isEmpty {
            args += ["-m", m]
        }
        args += ["--", "bash", "-c", inner]

        let result = try await runProcess(executableURL: execURL, arguments: args, timeout: timeout)
        return result.stdout
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw RemoteProbeError.launchFailed("\(executableURL.lastPathComponent): \(error.localizedDescription)")
        }

        let didTimeout = TimeoutFlag()
        let timeoutItem = DispatchWorkItem { [weak process] in
            guard let p = process, p.isRunning else { return }
            didTimeout.set()
            p.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0), execute: timeoutItem)

        // Drain pipes before waitUntilExit to avoid a pipe-buffer deadlock.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let code = process.terminationStatus

        if didTimeout.isSet {
            throw RemoteProbeError.timedOut(timeout)
        }
        if code != 0 {
            throw RemoteProbeError.nonZeroExit(Int(code), stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ProcessResult(stdout: stdout, stderr: stderr, exitCode: code)
    }
}
