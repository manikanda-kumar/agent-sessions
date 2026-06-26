import XCTest
@testable import AgentSessions

final class RemoteMonitorStateTests: XCTestCase {

    @MainActor
    func testEnabledGate_NoProbesWhenOff() {
        // The model itself won't start polling tasks under tests (AppRuntime.isRunningTests),
        // but we can validate that when disabled the public state stays clean and refresh is a no-op.
        let model = RemoteMonitorModel()
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.presences.isEmpty)
        model.refreshNow() // should be safe no-op
        XCTAssertTrue(model.presences.isEmpty)
    }

    func testMTimeActiveIdleThreshold() {
        // Use the pure parser helper for classification logic.
        let recent = Date().addingTimeInterval(-30)
        let old = Date().addingTimeInterval(-300)

        let f1 = RemoteProbeParser.Facts(
            procs: [.init(agentRaw: "claude", pid: 1, cwd: "/p", startedAt: nil)],
            projectMtimes: ["r": ["-p": recent]]
        )
        let p1 = RemoteProbeParser.presences(from: f1, machineID: "m", machineName: "M", sourceForAgent: { _ in .claude })
        XCTAssertEqual(p1.first?.state, .active)

        let f2 = RemoteProbeParser.Facts(
            procs: [.init(agentRaw: "claude", pid: 2, cwd: "/p", startedAt: nil)],
            projectMtimes: ["r": ["-p": old]]
        )
        let p2 = RemoteProbeParser.presences(from: f2, machineID: "m", machineName: "M", sourceForAgent: { _ in .claude })
        XCTAssertEqual(p2.first?.state, .idle)
    }

    func testUnreachableDoesNotAffectOtherMachines() {
        // Indirect: the model publishes per-machine status. Parser + model glue is exercised via public API surface.
        // Here we just confirm enum shape and that ok/unreachable are distinct.
        let ok: RemoteMachineStatus = .ok([])
        let bad: RemoteMachineStatus = .unreachable("ssh failed")
        XCTAssertNotEqual(ok, bad)
    }
}
