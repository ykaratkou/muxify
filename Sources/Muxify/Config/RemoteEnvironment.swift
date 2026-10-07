import Foundation

/// A hand-configured SSH destination. The selected Environment is UI state,
/// not part of the Config.
struct RemoteEnvironment: Equatable, Identifiable {
    let name: String
    let host: String
    let username: String
    /// Nil lets SSH config supply the port (OpenSSH otherwise defaults to 22).
    var port: Int?
    var identityFile: String?
    var forwardAgent = true

    var id: String { name }
}
