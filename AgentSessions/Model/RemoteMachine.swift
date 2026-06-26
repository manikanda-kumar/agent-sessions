import Foundation

/// Persisted configuration for a remote machine to monitor (read-only live presence).
struct RemoteMachine: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: Kind

    // SSH
    var sshHost: String?
    var sshUser: String?
    var sshIdentityPath: String?  // optional explicit -i path

    // labctl / iximiuz
    var labctlPlaygroundID: String?
    var labctlMachine: String?    // optional -m

    var enabled: Bool

    enum Kind: String, Codable, CaseIterable, Equatable {
        case ssh
        case labctl
    }

    init(id: UUID = UUID(),
         name: String,
         kind: Kind,
         sshHost: String? = nil,
         sshUser: String? = nil,
         sshIdentityPath: String? = nil,
         labctlPlaygroundID: String? = nil,
         labctlMachine: String? = nil,
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshIdentityPath = sshIdentityPath
        self.labctlPlaygroundID = labctlPlaygroundID
        self.labctlMachine = labctlMachine
        self.enabled = enabled
    }
}
