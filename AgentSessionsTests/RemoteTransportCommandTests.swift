import XCTest
@testable import AgentSessions

final class RemoteTransportCommandTests: XCTestCase {

    func testSSHArguments_DefaultUserHost() {
        let args = SSHRemoteTransport.buildSSHArguments(host: "pi-manik", user: "manik", identityPath: nil)
        XCTAssertEqual(args, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "manik@pi-manik",
            "bash", "-s"
        ])
    }

    func testSSHArguments_WithIdentity() {
        let args = SSHRemoteTransport.buildSSHArguments(host: "192.168.88.12", user: nil, identityPath: "/tmp/key")
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/tmp/key"))
        XCTAssertTrue(args.contains("192.168.88.12"))
    }

    func testLabctlArguments_WithAndWithoutMachine() {
        let a1 = LabctlRemoteTransport.buildLabctlArguments(playgroundID: "69886bd0f45ebe34b489cdd2", machine: nil)
        XCTAssertEqual(a1.prefix(2), ["ssh", "69886bd0f45ebe34b489cdd2"])
        XCTAssertTrue(a1.contains("--"))

        let a2 = LabctlRemoteTransport.buildLabctlArguments(playgroundID: "abc", machine: "clawdbot-prod-2dd22ab6")
        XCTAssertTrue(a2.contains("-m"))
        XCTAssertTrue(a2.contains("clawdbot-prod-2dd22ab6"))
    }
}
