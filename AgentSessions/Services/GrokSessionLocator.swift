import Foundation

/// Grok Build session path conventions (`~/.grok/sessions/<percent-encoded-cwd>/<session-uuid>/chat_history.jsonl`).
enum GrokSessionLocator {
    static let chatHistoryFileName = "chat_history.jsonl"
    static let summaryFileName = "summary.json"

    static func defaultGrokHome(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        return (standardizedHome as NSString).appendingPathComponent(".grok")
    }

    static func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        (defaultGrokHome(homeDirectory: homeDirectory) as NSString).appendingPathComponent("sessions")
    }

    static func projectDirectoryName(for workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    static func workingDirectory(fromProjectDirectoryName name: String) -> String? {
        guard let decoded = name.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    static func inferredCWD(from sessionFileURL: URL, fileManager: FileManager = .default) -> String? {
        let projectDirectoryName = sessionFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        guard let candidate = workingDirectory(fromProjectDirectoryName: projectDirectoryName) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    static func scopedSessionsRoot(root: URL, cwdFilter: String?) -> URL {
        guard let cwdFilter,
              let projectDirectory = projectDirectoryName(for: cwdFilter) else {
            return root
        }
        return root.appendingPathComponent(projectDirectory, isDirectory: true)
    }

    static func sessionID(from sessionFileURL: URL) -> String? {
        let id = sessionFileURL.deletingLastPathComponent().lastPathComponent
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func summaryURL(forChatHistoryURL chatHistoryURL: URL) -> URL {
        chatHistoryURL.deletingLastPathComponent().appendingPathComponent(summaryFileName, isDirectory: false)
    }
}