import Foundation

/// Discovery for Google Antigravity CLI session index at ~/.gemini/antigravity-cli/history.jsonl.
final class AntigravitySessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let env = ProcessInfo.processInfo.environment
        if let geminiHome = env["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !geminiHome.isEmpty {
            let expanded = (geminiHome as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("antigravity-cli", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
    }

    func historyFileURL() -> URL {
        sessionsRoot().appendingPathComponent("history.jsonl", isDirectory: false)
    }

    func conversationsRoot() -> URL {
        sessionsRoot().appendingPathComponent("conversations", isDirectory: true)
    }

    func hasConversationDBFiles() -> Bool {
        let conversations = conversationsRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: conversations.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: conversations.path) else {
            return false
        }
        return entries.contains { $0.lowercased().hasSuffix(".db") }
    }

    func discoverSessionFiles() -> [URL] {
        let history = historyFileURL()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: history.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return []
        }
        return [history]
    }
}