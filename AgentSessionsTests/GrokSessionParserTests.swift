import XCTest
@testable import AgentSessions

final class GrokSessionParserTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "Resources/Fixtures/stage0/agents/grok/small/%2Ftmp%2Fas-agent-fixture%2Fproject/019b18d0-d9af-77f4-8a95-0621cfa5e266/chat_history.jsonl"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    func testParseFileReadsGrokSummaryMetadata() throws {
        let session = try XCTUnwrap(GrokSessionParser.parseFile(at: fixtureURL()))
        XCTAssertEqual(session.id, "019b18d0-d9af-77f4-8a95-0621cfa5e266")
        XCTAssertEqual(session.source, .grok)
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-fixture/project")
        XCTAssertEqual(session.lightweightTitle, "Fixture grok session title")
        XCTAssertEqual(session.eventCount, 2)
        XCTAssertEqual(session.model, "grok-build-fixture")
    }

    func testParseFileFullBuildsUserAssistantEvents() throws {
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: fixtureURL()))
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)
        XCTAssertTrue(session.events.contains { $0.text?.contains("hello.py") == true })
    }

    func testGrokHomeReadsSummaryField() throws {
        let grokHome = GrokSessionParser.grokHome(forSessionFileAt: try fixtureURL())
        XCTAssertEqual(grokHome, "/tmp/as-agent-fixture/grok-home")
    }
}