import Foundation

/// Parser for Grok Build `chat_history.jsonl` sessions (directory-named UUID IDs).
final class GrokSessionParser {
    private static let metadataScanBytes = 512 * 1024
    private static let previewMessageLimit = 40

    struct SummaryMetadata {
        let id: String?
        let cwd: String?
        let title: String?
        let model: String?
        let createdAt: Date?
        let updatedAt: Date?
        let messageCount: Int?
        let grokHome: String?
    }

    static func parseFile(at url: URL) -> Session? {
        guard let sessionID = GrokSessionLocator.sessionID(from: url) else { return nil }
        let summary = loadSummary(for: url)
        let cwd = summary?.cwd
            ?? GrokSessionLocator.inferredCWD(from: url)
        let scan = scanChatHistory(url)
        let modified = fileModifiedDate(url) ?? summary?.updatedAt ?? summary?.createdAt ?? Date()
        let created = summary?.createdAt ?? modified
        let title = summary?.title ?? scan.title ?? "Grok session \(sessionID.prefix(12))"
        let messageCount = summary?.messageCount ?? scan.messageCount
        let model = summary?.model ?? scan.model

        return Session(
            id: sessionID,
            source: .grok,
            startTime: created,
            endTime: modified,
            model: model,
            filePath: url.path,
            fileSizeBytes: fileSize(at: url),
            eventCount: messageCount,
            events: [],
            cwd: cwd,
            repoName: SessionPathNormalization.repoName(from: cwd),
            lightweightTitle: title,
            lightweightCommands: scan.toolCount,
            customTitle: title,
            surface: .cli
        )
    }

    static func parseFileFull(at url: URL) -> Session? {
        guard var session = parseFile(at: url) else { return nil }
        let events = buildEvents(from: url)
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

    static func grokHome(forSessionFileAt url: URL) -> String? {
        loadSummary(for: url)?.grokHome
    }

    private static func loadSummary(for chatHistoryURL: URL) -> SummaryMetadata? {
        let summaryURL = GrokSessionLocator.summaryURL(forChatHistoryURL: chatHistoryURL)
        guard let data = try? Data(contentsOf: summaryURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let info = payload["info"] as? [String: Any] ?? [:]
        let title = stringValue(payload["session_summary"])
            ?? stringValue(payload["generated_title"])
        let created = isoDate(payload["created_at"])
        let updated = isoDate(payload["updated_at"]) ?? isoDate(payload["last_active_at"])
        let messageCount = intValue(payload["num_chat_messages"]) ?? intValue(payload["num_messages"])
        return SummaryMetadata(
            id: stringValue(info["id"]),
            cwd: stringValue(info["cwd"]),
            title: title,
            model: stringValue(payload["current_model_id"]),
            createdAt: created,
            updatedAt: updated,
            messageCount: messageCount,
            grokHome: stringValue(payload["grok_home"])
        )
    }

    private struct ChatHistoryScan {
        let title: String?
        let messageCount: Int
        let toolCount: Int
        let model: String?
    }

    private static func scanChatHistory(_ url: URL) -> ChatHistoryScan {
        var messageCount = 0
        var toolCount = 0
        var title: String?
        var model: String?
        SessionJSONLScanner.forEachLine(url: url, maxBytes: metadataScanBytes) { object in
            let type = (object["type"] as? String)?.lowercased() ?? ""
            switch type {
            case "user", "tool_result":
                messageCount += 1
            case "assistant":
                messageCount += 1
                if object["tool_calls"] != nil { toolCount += 1 }
            default:
                break
            }
            if title == nil, type == "user", let text = textContent(from: object["content"]) {
                let cleaned = grokDisplayTitle(from: text)
                if !cleaned.isEmpty { title = cleaned }
            }
            if model == nil, let modelID = stringValue(object["model_id"]) {
                model = modelID
            }
            return false
        }
        return ChatHistoryScan(title: title, messageCount: messageCount, toolCount: toolCount, model: model)
    }

    private static func buildEvents(from url: URL) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var index = 0
        SessionJSONLScanner.forEachLine(url: url) { object in
            guard index < previewMessageLimit else { return true }
            let type = (object["type"] as? String)?.lowercased() ?? "meta"
            let text = textContent(from: object["content"])
            let kind: SessionEventKind
            switch type {
            case "user": kind = .user
            case "assistant": kind = .assistant
            case "tool_result": kind = .tool_result
            case "reasoning", "system": kind = .meta
            default: kind = .meta
            }
            let id = "grok-\(index + 1)"
            events.append(SessionEvent(
                id: id,
                timestamp: nil,
                kind: kind,
                role: type,
                text: text,
                toolName: stringValue((object["tool_calls"] as? [[String: Any]])?.first?["name"]),
                toolInput: nil,
                toolOutput: type == "tool_result" ? text : nil,
                messageID: stringValue(object["id"]) ?? id,
                parentID: nil,
                isDelta: false,
                rawJSON: ""
            ))
            index += 1
            return false
        }
        return events
    }

    static func grokDisplayTitle(from rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let query = extractTaggedBlock(named: "user_query", from: text) {
            text = query
        }
        text = stripTaggedBlock(named: "user_info", from: text)
        text = stripTaggedBlock(named: "git_status", from: text)
        text = stripTaggedBlock(named: "rules", from: text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractTaggedBlock(named tag: String, from text: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTaggedBlock(named tag: String, from text: String) -> String {
        var result = text
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        while let start = result.range(of: open),
              let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
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

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let raw = stringValue(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func fileModifiedDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func fileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }
}