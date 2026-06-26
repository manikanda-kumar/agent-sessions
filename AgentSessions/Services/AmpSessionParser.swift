import Foundation

/// Parser for Amp CLI thread JSON files (`T-*.json`).
final class AmpSessionParser {
    private static let previewMessageLimit = 40

    static func parseFile(at url: URL) -> Session? {
        guard let payload = loadPayload(url) else { return nil }
        guard let id = stringValue(payload["id"]), !id.isEmpty else { return nil }

        let cwd = cwd(from: payload)
        let title = deriveTitle(payload: payload, fallbackID: id)
        let created = millisDate(payload["created"])
        let modified = fileModifiedDate(url) ?? created ?? Date()
        let messageCount = estimatedMessageCount(payload)

        return Session(
            id: id,
            source: .amp,
            startTime: created ?? modified,
            endTime: modified,
            model: nil,
            filePath: url.path,
            fileSizeBytes: fileSize(at: url),
            eventCount: messageCount,
            events: [],
            cwd: cwd,
            repoName: repoName(from: cwd),
            lightweightTitle: title,
            lightweightCommands: 0,
            customTitle: title,
            surface: .cli
        )
    }

    static func parseFileFull(at url: URL) -> Session? {
        guard var session = parseFile(at: url) else { return nil }
        guard let payload = loadPayload(url) else { return session }
        let events = buildEvents(from: payload)
        session = Session(
            id: session.id,
            source: session.source,
            startTime: events.compactMap(\.timestamp).min() ?? session.startTime,
            endTime: events.compactMap(\.timestamp).max() ?? session.endTime,
            model: session.model,
            filePath: session.filePath,
            fileSizeBytes: session.fileSizeBytes,
            eventCount: events.filter { $0.kind != .meta }.count,
            events: events,
            cwd: session.cwd,
            repoName: session.repoName,
            lightweightTitle: session.lightweightTitle,
            lightweightCommands: session.lightweightCommands,
            customTitle: session.customTitle,
            surface: session.surface
        )
        return session
    }

    private static func loadPayload(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func buildEvents(from payload: [String: Any]) -> [SessionEvent] {
        guard let messages = payload["messages"] as? [[String: Any]] else { return [] }
        let created = millisDate(payload["created"])
        return messages.prefix(previewMessageLimit).enumerated().compactMap { index, message in
            let role = (message["role"] as? String)?.lowercased() ?? "unknown"
            let text = textContent(from: message["content"])
            let kind: SessionEventKind = role == "assistant" ? .assistant : (role == "user" ? .user : .meta)
            let id = "amp-\(index + 1)"
            return SessionEvent(
                id: id,
                timestamp: created,
                kind: kind,
                role: message["role"] as? String,
                text: text,
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: stringValue(message["messageId"]) ?? id,
                parentID: nil,
                isDelta: false,
                rawJSON: ""
            )
        }
    }

    private static func estimatedMessageCount(_ payload: [String: Any]) -> Int {
        guard let messages = payload["messages"] as? [[String: Any]] else { return 0 }
        return messages.filter { message in
            let text = textContent(from: message["content"]) ?? ""
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private static func deriveTitle(payload: [String: Any], fallbackID: String) -> String {
        if let title = stringValue(payload["title"]),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let messages = payload["messages"] as? [[String: Any]] {
            for message in messages where (message["role"] as? String)?.lowercased() == "user" {
                if let text = textContent(from: message["content"]),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return "Amp thread \(fallbackID.prefix(12))"
    }

    private static func cwd(from payload: [String: Any]) -> String? {
        guard let env = payload["env"] as? [String: Any],
              let initial = env["initial"] as? [String: Any],
              let trees = initial["trees"] as? [[String: Any]],
              let first = trees.first,
              let uri = stringValue(first["uri"]) else {
            return nil
        }
        return fileURIToPath(uri)
    }

    private static func fileURIToPath(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed) {
                return url.path
            }
            return String(trimmed.dropFirst("file://".count))
        }
        return trimmed
    }

    private static func textContent(from value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            if let text = block["content"] as? String { return text }
            return nil
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func millisDate(_ value: Any?) -> Date? {
        guard let millis = numericValue(value) else { return nil }
        return Date(timeIntervalSince1970: millis / 1_000)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func fileModifiedDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func normalizedStoredPath(_ rawPath: String?) -> String? {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func repoName(from rawPath: String?) -> String? {
        guard let path = normalizedStoredPath(rawPath) else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func fileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }
}