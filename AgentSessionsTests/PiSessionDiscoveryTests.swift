import XCTest
@testable import AgentSessions

final class PiSessionDiscoveryTests: XCTestCase {
    private func fixtureSessionsRoot() -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Resources/Fixtures/stage0/agents/pi/small", isDirectory: true)
    }

    private func expectedFixtureSession() -> URL {
        fixtureSessionsRoot()
            .appendingPathComponent("--tmp-as-agent-fixture-project--", isDirectory: true)
            .appendingPathComponent("019e19b4-eb48-746a-aa6b-8dfcfa37954b.jsonl", isDirectory: false)
    }

    func testDiscoverSessionFilesFindsFixtureWithoutFilter() throws {
        let discovery = PiSessionDiscovery(customRoot: fixtureSessionsRoot().path)
        let files = discovery.discoverSessionFiles()
        let expected = expectedFixtureSession()
        XCTAssertTrue(files.contains(expected), "Expected fixture session in unfiltered discovery")
    }

    func testDiscoverSessionFilesFindsFixtureWithProjectFilter() throws {
        let discovery = PiSessionDiscovery(customRoot: fixtureSessionsRoot().path)
        let files = discovery.discoverSessionFiles(cwdFilter: "/tmp/as-agent-fixture/project")
        let expected = expectedFixtureSession()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first, expected)
    }
}