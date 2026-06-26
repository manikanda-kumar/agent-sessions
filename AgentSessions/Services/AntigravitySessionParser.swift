import Foundation

/// Parser for Antigravity CLI history index (`history.jsonl`).
/// Each conversation is deduped by `conversationId`, keeping the latest row.
final class AntigravitySessionParser {
    static func parseHistoryFile(at url: URL) -> [Session] {
        let fallbackModified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
        var latestBySessionID: [String: AntigravityHistoryMetadata] = [:]

        SessionJSONLScanner.forEachLine(url: url) { object in
            guard let sessionID = SessionJSONLValues.firstString(in: object, keys: SessionJSONLFieldKeys.conversationID) else {
                return false
            }
            let cwd = SessionPathNormalization.normalizedStoredPath(
                SessionJSONLValues.firstString(in: object, keys: SessionJSONLFieldKeys.cwd)
            )
            let title = historyTitle(in: object) ?? ""
            let modified = SessionJSONLValues.date(fromEpochTimestamp: object["timestamp"], fallback: fallbackModified)
            let metadata = AntigravityHistoryMetadata(
                sessionID: sessionID,
                title: title,
                cwd: cwd,
                modified: modified
            )
            if let existing = latestBySessionID[sessionID] {
                if metadata.modified >= existing.modified {
                    latestBySessionID[sessionID] = metadata
                }
            } else {
                latestBySessionID[sessionID] = metadata
            }
            return false
        }

        return latestBySessionID.values
            .sorted {
                if $0.modified == $1.modified { return $0.sessionID < $1.sessionID }
                return $0.modified > $1.modified
            }
            .map { metadata in
                Session(
                    id: metadata.sessionID,
                    source: .antigravity,
                    startTime: metadata.modified,
                    endTime: metadata.modified,
                    model: nil,
                    filePath: url.path,
                    fileSizeBytes: fileSize(at: url),
                    eventCount: metadata.title.isEmpty ? 0 : 1,
                    events: [],
                    cwd: metadata.cwd,
                    repoName: SessionPathNormalization.repoName(from: metadata.cwd),
                    lightweightTitle: metadata.title.isEmpty ? "Antigravity session \(metadata.sessionID.prefix(8))" : metadata.title,
                    lightweightCommands: 0,
                    customTitle: metadata.title.isEmpty ? nil : metadata.title,
                    surface: .cli
                )
            }
    }

    static func parseSession(id: String, historyURL: URL) -> Session? {
        parseHistoryFile(at: historyURL).first(where: { $0.id == id })
    }

    static func parseSessionFull(id: String, historyURL: URL) -> Session? {
        guard var session = parseSession(id: id, historyURL: historyURL) else { return nil }
        let events = historyEvents(for: id, historyURL: historyURL)
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

    private static func historyEvents(for sessionID: String, historyURL: URL) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var index = 0
        SessionJSONLScanner.forEachLine(url: historyURL) { object in
            guard SessionJSONLValues.firstString(in: object, keys: SessionJSONLFieldKeys.conversationID) == sessionID else {
                return false
            }
            let title = historyTitle(in: object) ?? ""
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            index += 1
            let timestamp = SessionJSONLValues.date(fromEpochTimestamp: object["timestamp"], fallback: Date())
            events.append(SessionEvent(
                id: "agy-\(index)",
                timestamp: timestamp,
                kind: .user,
                role: "user",
                text: title,
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: "agy-\(index)",
                parentID: nil,
                isDelta: false,
                rawJSON: ""
            ))
            return false
        }
        return events
    }

    private struct AntigravityHistoryMetadata {
        let sessionID: String
        let title: String
        let cwd: String?
        let modified: Date
    }

    private static func historyTitle(in object: [String: Any]) -> String? {
        SessionJSONLValues.firstText(in: object, keys: SessionJSONLFieldKeys.historyTitle)
    }

    private static func fileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }
}