import XCTest
@testable import AgentSessions

final class AgentResumeHintBuilderTests: XCTestCase {
    func testPiUsesSessionFlag() {
        let hint = AgentResumeHintBuilder.makeHint(source: .pi, sessionID: "pi-session", cwd: "/repo")
        XCTAssertEqual(hint, "cd /repo && pi --session pi-session")
    }

    func testGrokUsesResumeFlag() {
        let hint = AgentResumeHintBuilder.makeHint(source: .grok, sessionID: "019b18d0-d9af-77f4-8a95-0621cfa5e266", cwd: "/repo")
        XCTAssertEqual(hint, "cd /repo && grok -r 019b18d0-d9af-77f4-8a95-0621cfa5e266")
    }

    func testGrokPrefixesGrokHomeWhenNonDefault() {
        let hint = AgentResumeHintBuilder.makeHint(
            source: .grok,
            sessionID: "session-1",
            cwd: nil,
            grokHome: "/tmp/custom-grok"
        )
        XCTAssertEqual(hint, "env GROK_HOME=/tmp/custom-grok grok -r session-1")
    }

    func testAmpUsesThreadsContinue() {
        let hint = AgentResumeHintBuilder.makeHint(
            source: .amp,
            sessionID: "T-019b18d0-d9af-77f4-8a95-0621cfa5e266",
            cwd: "/repo"
        )
        XCTAssertEqual(hint, "cd /repo && amp threads continue T-019b18d0-d9af-77f4-8a95-0621cfa5e266")
    }

    func testAntigravityUsesConversationFlag() {
        let hint = AgentResumeHintBuilder.makeHint(
            source: .antigravity,
            sessionID: "019b18d0-d9af-77f4-8a95-0621cfa5e266",
            cwd: "/repo"
        )
        XCTAssertEqual(hint, "cd /repo && agy --conversation 019b18d0-d9af-77f4-8a95-0621cfa5e266")
    }

    func testCodexPrefersInternalSessionID() {
        let hint = AgentResumeHintBuilder.makeHint(
            source: .codex,
            sessionID: "file-uuid",
            codexInternalSessionID: "internal-abc"
        )
        XCTAssertEqual(hint, "codex resume internal-abc")
    }

    func testSessionIDSourceMapping() {
        XCTAssertEqual(AgentResumeHintBuilder.sessionIDSource(for: .pi), .jsonlPerFile)
        XCTAssertEqual(AgentResumeHintBuilder.sessionIDSource(for: .grok), .directoryNamed)
        XCTAssertEqual(AgentResumeHintBuilder.sessionIDSource(for: .amp), .threadJSON)
        XCTAssertEqual(AgentResumeHintBuilder.sessionIDSource(for: .antigravity), .historyIndex)
        XCTAssertEqual(AgentResumeHintBuilder.sessionIDSource(for: .opencode), .sqliteSession)
    }
}