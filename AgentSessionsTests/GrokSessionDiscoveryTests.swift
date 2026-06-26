import XCTest
@testable import AgentSessions

final class GrokSessionDiscoveryTests: XCTestCase {
    private func fixtureSessionsRoot() -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Resources/Fixtures/stage0/agents/grok/small", isDirectory: true)
    }

    private func expectedFixtureChatHistory() -> URL {
        fixtureSessionsRoot()
            .appendingPathComponent("%2Ftmp%2Fas-agent-fixture%2Fproject", isDirectory: true)
            .appendingPathComponent("019b18d0-d9af-77f4-8a95-0621cfa5e266", isDirectory: true)
            .appendingPathComponent(GrokSessionLocator.chatHistoryFileName, isDirectory: false)
    }

    func testDiscoverSessionFilesFindsFixtureWithoutFilter() throws {
        let discovery = GrokSessionDiscovery(customRoot: fixtureSessionsRoot().path)
        let files = discovery.discoverSessionFiles()
        let expected = expectedFixtureChatHistory()
        XCTAssertTrue(files.contains(expected), "Expected fixture chat history in unfiltered discovery")
    }

    func testDiscoverSessionFilesFindsFixtureWithProjectFilter() throws {
        let discovery = GrokSessionDiscovery(customRoot: fixtureSessionsRoot().path)
        let files = discovery.discoverSessionFiles(cwdFilter: "/tmp/as-agent-fixture/project")
        let expected = expectedFixtureChatHistory()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first, expected)
    }

    func testScopedSessionsRootNarrowsToEncodedProjectDirectory() {
        let root = URL(fileURLWithPath: "/tmp/grok-sessions", isDirectory: true)
        let scoped = GrokSessionLocator.scopedSessionsRoot(root: root, cwdFilter: "/tmp/as-agent-fixture/project")
        XCTAssertEqual(scoped.path, "/tmp/grok-sessions/%2Ftmp%2Fas-agent-fixture%2Fproject")
    }
}