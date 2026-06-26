import XCTest
@testable import AgentSessions

final class AntigravitySessionParserTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/Fixtures/stage0/agents/antigravity/small.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    func testParseHistoryFileDedupesByConversationID() throws {
        let sessions = AntigravitySessionParser.parseHistoryFile(at: try fixtureURL())
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "fedf71d6-9d61-4a32-a90d-7a549a20a345")
        XCTAssertEqual(session.source, .antigravity)
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-fixture/project")
        XCTAssertEqual(session.lightweightTitle, "proceed with summary")
    }

    func testParseSessionFullBuildsHistoryPromptEvents() throws {
        let url = try fixtureURL()
        let session = try XCTUnwrap(
            AntigravitySessionParser.parseSessionFull(
                id: "fedf71d6-9d61-4a32-a90d-7a549a20a345",
                historyURL: url
            )
        )
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 2)
        XCTAssertTrue(session.events.contains { $0.text == "review fixture project structure" })
    }
}