import Foundation

/// Discovery for Grok Build sessions under `~/.grok/sessions/<encoded-cwd>/<session-id>/chat_history.jsonl`.
final class GrokSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let env = ProcessInfo.processInfo.environment
        if let grokHome = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !grokHome.isEmpty {
            let expanded = (grokHome as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: GrokSessionLocator.defaultSessionsRoot(), isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        discoverSessionFiles(cwdFilter: nil)
    }

    func discoverSessionFiles(cwdFilter: String?) -> [URL] {
        let root = sessionsRoot()
        let scanRoot = GrokSessionLocator.scopedSessionsRoot(root: root, cwdFilter: cwdFilter)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: scanRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let scopedToProject = scanRoot.path != root.path
        var files: [URL] = []

        if scopedToProject {
            collectSessionFiles(in: scanRoot, fileManager: fm, into: &files)
        } else {
            guard let projectEntries = try? fm.contentsOfDirectory(
                at: scanRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            for projectURL in projectEntries {
                guard isProjectDirectory(projectURL) else { continue }
                collectSessionFiles(in: projectURL, fileManager: fm, into: &files)
            }
        }

        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.path > $1.path
        }
    }

    private func normalizedSessionsRoot(_ root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [
            root.appendingPathComponent("sessions", isDirectory: true),
            root
        ]
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return root
    }

    private func collectSessionFiles(in parent: URL, fileManager: FileManager, into files: inout [URL]) {
        guard let sessionEntries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for sessionURL in sessionEntries {
            guard isSessionDirectory(sessionURL) else { continue }
            let chatHistory = sessionURL.appendingPathComponent(GrokSessionLocator.chatHistoryFileName, isDirectory: false)
            var isFile: ObjCBool = false
            guard fileManager.fileExists(atPath: chatHistory.path, isDirectory: &isFile), !isFile.boolValue else {
                continue
            }
            guard isGrokChatHistoryFile(chatHistory) else { continue }
            files.append(chatHistory)
        }
    }

    private func isProjectDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return false
        }
        let name = url.lastPathComponent
        if name == "session_search.sqlite" { return false }
        return name.contains("%")
    }

    private func isSessionDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return false
        }
        let name = url.lastPathComponent.lowercased()
        if name == "subagents" { return false }
        return name.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    private func isGrokChatHistoryFile(_ url: URL) -> Bool {
        var found = false
        SessionJSONLScanner.forEachLine(url: url, maxBytes: 8 * 1024) { object in
            guard let type = object["type"] as? String else { return false }
            if ["system", "user", "assistant", "reasoning", "tool_result"].contains(type) {
                found = true
                return true
            }
            return false
        }
        return found
    }
}