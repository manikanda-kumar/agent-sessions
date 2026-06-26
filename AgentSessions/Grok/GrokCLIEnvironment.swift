import Foundation

protocol GrokCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<GrokCLIEnvironment.ProbeResult, GrokCLIEnvironment.ProbeError>
}

struct GrokCLIEnvironment: GrokCLIEnvironmentProviding {
    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsResume: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Grok CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute grok --version." : stderr
            }
        }
    }

    private let executor: CommandExecuting

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        if let url = whichViaLoginShell("grok").flatMap({ URL(fileURLWithPath: $0) }),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }

        if let url = which("grok").flatMap({ URL(fileURLWithPath: $0) }),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.grok/bin/grok",
            "\(home)/.local/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try executor.run([binary.path, "--version"], cwd: nil)
            let versionString: String
            if versionRes.exitCode == 0 {
                let combined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = combined.isEmpty ? "unknown" : combined
            } else {
                versionString = "unknown"
            }

            let helpRes = try? executor.run([binary.path, "--help"], cwd: nil)
            let helpOut = [helpRes?.stdout, helpRes?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsResume: helpContainsFlag("-r", in: helpOut) || helpContainsFlag("--resume", in: helpOut)
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private func whichViaLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let result = try executor.run([shell, "-lic", "command -v \(command) || true"], cwd: nil)
            let res = [result.stdout, result.stderr].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !res.isEmpty, res != command else { return nil }
            return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        } catch {
            return nil
        }
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { character in
            character.isWhitespace || ",=[](){}<>:;".contains(character)
        }
        .contains { $0 == flag }
    }
}