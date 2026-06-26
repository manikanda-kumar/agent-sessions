import Foundation

/// Shared JSONL scanning and field extraction for agent session stores.
enum SessionJSONLFieldKeys {
    static let cwd: [String] = [
        "cwd", "workingDirectory", "workspacePath", "workspace", "projectPath", "directory"
    ]

    static let sessionID: [String] = [
        "sessionId", "session_id", "id"
    ]

    static let conversationID: [String] = [
        "conversationId", "conversation_id", "sessionId", "session_id", "id"
    ]

    static let historyTitle: [String] = [
        "title", "prompt", "display"
    ]
}

enum SessionJSONLScanner {
    /// Streams newline-delimited JSON objects. Return `true` from `handler` to stop early.
    static func forEachLine(
        url: URL,
        maxBytes: Int = .max,
        handler: ([String: Any]) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        var bytesRead = 0
        let newline = Data([0x0A])

        while bytesRead < maxBytes {
            let remaining = maxBytes - bytesRead
            let chunk = (try? handle.read(upToCount: min(64 * 1024, remaining))) ?? Data()
            if chunk.isEmpty && buffer.isEmpty { break }
            if !chunk.isEmpty {
                buffer.append(chunk)
                bytesRead += chunk.count
            }

            while let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer = Data(buffer[range.upperBound..<buffer.endIndex])
                guard !lineData.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                if handler(object) { return }
            }
            if chunk.isEmpty { break }
        }

        guard bytesRead < maxBytes,
              !buffer.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
            return
        }
        _ = handler(object)
    }
}

enum SessionJSONLValues {
    static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func firstText(in object: [String: Any], keys: [String]) -> String? {
        firstString(in: object, keys: keys)
    }

    static func numericTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func date(fromEpochTimestamp value: Any?, fallback: Date) -> Date {
        guard let timestamp = numericTimestamp(value) else { return fallback }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum SessionPathNormalization {
    static func normalizedStoredPath(_ rawPath: String?) -> String? {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func repoName(from rawPath: String?) -> String? {
        guard let path = normalizedStoredPath(rawPath) else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}