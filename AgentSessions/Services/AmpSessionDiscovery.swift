import Foundation

/// Discovery for Amp CLI thread files under ~/.local/share/amp/threads.
final class AmpSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedThreadsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { url in
                guard url.pathExtension.lowercased() == "json" else { return false }
                guard url.lastPathComponent.hasPrefix("T-") else { return false }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    return false
                }
                return true
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if a != b { return a > b }
                return $0.lastPathComponent > $1.lastPathComponent
            }
    }

    private func normalizedThreadsRoot(_ root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [
            root.appendingPathComponent("threads", isDirectory: true),
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
}