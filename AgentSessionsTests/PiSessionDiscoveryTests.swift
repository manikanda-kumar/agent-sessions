import XCTest
@testable import AgentSessions

final class PiSessionDiscoveryTests: XCTestCase {
    private func normalizedFixturePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path
    }

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
        let paths = Set(files.map { normalizedFixturePath($0) })
        XCTAssertTrue(paths.contains(normalizedFixturePath(expected)), "Expected fixture session in unfiltered discovery")
    }

    func testDiscoverSessionFilesFindsFixtureWithProjectFilter() throws {
        let discovery = PiSessionDiscovery(customRoot: fixtureSessionsRoot().path)
        let files = discovery.discoverSessionFiles(cwdFilter: "/tmp/as-agent-fixture/project")
        let expected = expectedFixtureSession()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(normalizedFixturePath(files.first!), normalizedFixturePath(expected))
    }
}