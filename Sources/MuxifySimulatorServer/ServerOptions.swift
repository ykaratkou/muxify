import Foundation
import Security

public struct ServerOptions: Sendable {
    public var port = 8787
    public var token: String
    public var origins: Set<String> = []
    public var help = false

    public static let usage = """
    usage: muxify simulator serve [--port <port>] [--origin <https://host>]

    Serves the Simulator on 127.0.0.1 (default port 8787).
    --origin allows a remote browser origin when using a reverse proxy; repeatable.
    The printed URL contains a secret per-process token. Share it only with trusted users.
    Use MUXIFY_SIMULATOR_TOKEN to keep a stable token (at least 32 URL-safe characters).
    """

    public init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OptionsError("Could not generate an access token.")
        }
        token = environment["MUXIFY_SIMULATOR_TOKEN"] ?? bytes.map { String(format: "%02x", $0) }.joined()
        guard token.count >= 32, token.count <= 128,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw OptionsError("MUXIFY_SIMULATOR_TOKEN must contain 32–128 URL-safe characters.")
        }
        var args = ArraySlice(arguments)
        if args.first == "simulator" { args = args.dropFirst() }
        if args.first == "--help" || args.first == "-h" { help = true; return }
        guard args.popFirst() == "serve" else { throw OptionsError(Self.usage) }
        while let argument = args.popFirst() {
            switch argument {
            case "--help", "-h": help = true
            case "--port":
                guard let value = args.popFirst(), let number = Int(value), (1...65535).contains(number) else {
                    throw OptionsError("--port requires a number between 1 and 65535.")
                }
                port = number
            case "--origin":
                guard let value = args.popFirst(), let url = URLComponents(string: value),
                      ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
                    throw OptionsError("--origin requires an http(s) origin without a path.")
                }
                origins.insert(String(value.hasSuffix("/") ? value.dropLast() : Substring(value)).lowercased())
            default: throw OptionsError("Unknown argument: \(argument)\n\(Self.usage)")
            }
        }
    }
}

private struct OptionsError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
