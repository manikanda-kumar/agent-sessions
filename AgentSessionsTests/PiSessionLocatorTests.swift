import XCTest
@testable import AgentSessions

final class PiSessionLocatorTests: XCTestCase {
    func testProjectDirectoryNameEncodesWorkingDirectory() {
        XCTAssertEqual(
            PiSessionLocator.projectDirectoryName(for: "/Users/manik/Github/foo"),
            "--Users-manik-Github-foo--"
        )
    }

    func testWorkingDirectoryDecodesProjectDirectoryName() {
        XCTAssertEqual(
            PiSessionLocator.workingDirectory(fromProjectDirectoryName: "--Users-manik-Github-foo--"),
            "/Users/manik/Github/foo"
        )
    }

    func testInferredCWDRequiresExistingDirectory() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let workspace = URL(fileURLWithPath: "/tmp/piinferred", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let sessionDir = temp.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("session.jsonl")

        XCTAssertEqual(PiSessionLocator.inferredCWD(from: sessionFile), workspace.path)
    }

    func testScopedSessionsRootNarrowsToProjectDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/pi-sessions", isDirectory: true)
        let scoped = PiSessionLocator.scopedSessionsRoot(root: root, cwdFilter: "/tmp/as-agent-fixture/project")
        XCTAssertEqual(scoped.path, "/tmp/pi-sessions/--tmp-as-agent-fixture-project--")
    }
}