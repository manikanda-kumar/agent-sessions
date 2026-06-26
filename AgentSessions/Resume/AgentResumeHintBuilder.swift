import Foundation

/// Canonical resume/copy-hint strings shared by the CLI and copy-to-clipboard flows.
enum AgentSessionIDSource: String, Codable, Sendable {
    case jsonlPerFile
    case historyIndex
    case threadJSON
    case sqliteSession
    case directoryNamed
}

enum AgentResumeHintBuilder {
    static func sessionIDSource(for source: SessionSource) -> AgentSessionIDSource {
        switch source {
        case .grok:
            return .directoryNamed
        case .opencode, .hermes:
            return .sqliteSession
        case .codex, .claude, .gemini, .copilot, .droid, .openclaw, .cursor, .pi:
            return .jsonlPerFile
        }
    }

    static func makeHint(
        source: SessionSource,
        sessionID: String,
        cwd: String? = nil,
        codexInternalSessionID: String? = nil,
        binary: String? = nil,
        grokHome: String? = nil
    ) -> String {
        let prefix = cwd.map { "cd \(ShellQuoting.quoteIfNeeded($0)) && " } ?? ""
        let id = ShellQuoting.quoteIfNeeded(sessionID)

        switch source {
        case .codex:
            let resumeID = codexInternalSessionID ?? sessionID
            let command = binary ?? "codex"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) resume \(ShellQuoting.quoteIfNeeded(resumeID))"
        case .claude:
            let command = binary ?? "claude"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) --resume \(id)"
        case .opencode:
            let command = binary ?? "opencode"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) --session \(id)"
        case .gemini:
            let command = binary ?? "gemini"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) --resume \(id)"
        case .hermes:
            let command = binary ?? "hermes"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) --resume \(id)"
        case .copilot:
            let command = binary ?? "copilot"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) --resume \(id)"
        case .cursor:
            let command = binary ?? "cursor"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) agent --resume \(id)"
        case .pi:
            let command = binary ?? "pi"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) --session \(id)"
        case .grok:
            let command = binary ?? "grok"
            let envPrefix = grokHomeEnvironmentPrefix(grokHome)
            return "\(prefix)\(envPrefix)\(ShellQuoting.quoteIfNeeded(command)) -r \(id)"
        case .droid:
            let command = binary ?? "droid"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) resume \(id)"
        case .openclaw:
            let command = binary ?? "openclaw"
            return "\(prefix)\(ShellQuoting.quoteIfNeeded(command)) resume \(id)"
        }
    }

    private static func grokHomeEnvironmentPrefix(_ grokHome: String?) -> String {
        guard let grokHome else { return "" }
        let trimmed = grokHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let defaultHome = GrokSessionLocator.defaultGrokHome()
        guard expanded != defaultHome else { return "" }
        return "env GROK_HOME=\(ShellQuoting.quoteIfNeeded(expanded)) "
    }
}