import XCTest
@testable import AgentSessions

final class RemoteProbeParserTests: XCTestCase {

    func testParsesHostAndProcAndProjectMtimes() {
        let stdout = """
        {"type":"host","text":"manik@pi5-manik Linux aarch64"}
        {"type":"proc","agent":"claude","pid":35429,"cwd":"/home/manik/Github","start_epoch":1712345678}
        {"type":"project_mtime","root":"$HOME/.claude/projects","project":"-home-manik-Github","mtime_epoch":1712345900}
        """

        let facts = RemoteProbeParser.parse(stdout)
        XCTAssertEqual(facts.hostLine, "manik@pi5-manik Linux aarch64")
        XCTAssertEqual(facts.procs.count, 1)
        XCTAssertEqual(facts.procs[0].agentRaw, "claude")
        XCTAssertEqual(facts.procs[0].pid, 35429)
        XCTAssertEqual(facts.procs[0].cwd, "/home/manik/Github")

        let m = facts.projectMtimes["$HOME/.claude/projects"]?["-home-manik-Github"]
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.timeIntervalSince1970 ?? 0, 1712345900, accuracy: 1)
    }

    func testProjectDirNameMapping() {
        XCTAssertEqual(RemoteProbeParser.projectDirName(fromCwd: "/home/manik/Github"), "-home-manik-Github")
        XCTAssertEqual(RemoteProbeParser.projectDirName(fromCwd: "/Users/alexm/Repo"), "-Users-alexm-Repo")
        XCTAssertEqual(RemoteProbeParser.projectDirName(fromCwd: "/home/laborant/Github/book-search"), "-home-laborant-Github-book-search")
        XCTAssertNil(RemoteProbeParser.projectDirName(fromCwd: nil))
        XCTAssertNil(RemoteProbeParser.projectDirName(fromCwd: ""))
    }

    func testPresencesActiveIdleClassification() {
        let facts = RemoteProbeParser.Facts(
            hostLine: "x@y Linux",
            procs: [
                .init(agentRaw: "claude", pid: 100, cwd: "/home/u/P", startedAt: nil)
            ],
            projectMtimes: [
                "$HOME/.claude/projects": ["-home-u-P": Date().addingTimeInterval(-30)]
            ]
        )

        let pres = RemoteProbeParser.presences(from: facts,
                                               machineID: "m1",
                                               machineName: "M",
                                               now: Date(),
                                               activeThreshold: 120,
                                               sourceForAgent: { $0 == "claude" ? .claude : nil })

        XCTAssertEqual(pres.count, 1)
        XCTAssertEqual(pres[0].agent, .claude)
        XCTAssertEqual(pres[0].state, .active)
        XCTAssertEqual(pres[0].projectName, "P")
    }

    func testEmptyAndMalformed() {
        let facts = RemoteProbeParser.parse("garbage\n\n{\"type\":\"proc\"}\n")
        XCTAssertTrue(facts.procs.isEmpty)
        XCTAssertTrue(facts.projectMtimes.isEmpty)

        let pres = RemoteProbeParser.presences(from: facts, machineID: "m", machineName: "M", sourceForAgent: { _ in .claude })
        XCTAssertTrue(pres.isEmpty)
    }

    func testFallsBackToGlobalMtimeWhenNoProjectMatch() {
        let recent = Date().addingTimeInterval(-10)
        let facts = RemoteProbeParser.Facts(
            procs: [.init(agentRaw: "claude", pid: 7, cwd: "/no/match", startedAt: nil)],
            projectMtimes: ["$HOME/.claude/projects": ["-other": recent]]
        )
        let pres = RemoteProbeParser.presences(from: facts, machineID: "m", machineName: "M", sourceForAgent: { _ in .claude })
        XCTAssertEqual(pres.count, 1)
        XCTAssertEqual(pres[0].lastActivityAt?.timeIntervalSince1970 ?? 0, recent.timeIntervalSince1970, accuracy: 1)
    }
}
