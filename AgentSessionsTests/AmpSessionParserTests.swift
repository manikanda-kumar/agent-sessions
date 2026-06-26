import XCTest
@testable import AgentSessions

final class AmpSessionParserTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/Fixtures/stage0/agents/amp/small.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    func testParseFileReadsAmpThreadMetadata() throws {
        let session = try XCTUnwrap(AmpSessionParser.parseFile(at: fixtureURL()))
        XCTAssertEqual(session.id, "T-019b18d0-d9af-77f4-8a95-0621cfa5e265")
        XCTAssertEqual(session.source, .amp)
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-fixture/project")
        XCTAssertEqual(session.lightweightTitle, "Fixture amp thread title")
        XCTAssertEqual(session.eventCount, 2)
    }

    func testParseFileFullBuildsUserAssistantEvents() throws {
        let session = try XCTUnwrap(AmpSessionParser.parseFileFull(at: fixtureURL()))
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .assistant }.count, 1)
        XCTAssertTrue(session.events.contains { $0.text?.contains("hello.py prints a fixture greeting.") == true })
    }
}