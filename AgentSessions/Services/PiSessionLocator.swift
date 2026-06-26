import Foundation

/// Pi-compatible session path conventions (`~/.pi/agent/sessions/<projectDir>/*.jsonl`).
enum PiSessionLocator {
    static func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        return (standardizedHome as NSString).appendingPathComponent(".pi/agent/sessions")
    }

    static func projectDirectoryName(for workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutLeadingSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let sanitized = withoutLeadingSlash
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return nil }
        return "--\(sanitized)--"
    }

    /// Best-effort decode of Pi's `--<path-with-slashes-as-dashes>--` layout.
    /// Paths whose segments contain hyphens cannot round-trip uniquely; prefer session header `cwd` when present.
    static func workingDirectory(fromProjectDirectoryName name: String) -> String? {
        guard name.hasPrefix("--"), name.hasSuffix("--"), name.count > 4 else { return nil }
        let body = String(name.dropFirst(2).dropLast(2))
        guard !body.isEmpty else { return nil }
        return "/" + body.replacingOccurrences(of: "-", with: "/")
    }

    static func inferredCWD(from sessionFileURL: URL, fileManager: FileManager = .default) -> String? {
        let directoryName = sessionFileURL.deletingLastPathComponent().lastPathComponent
        guard let candidate = workingDirectory(fromProjectDirectoryName: directoryName) else { return nil }
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
}