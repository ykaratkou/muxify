import Darwin
import Foundation
import MuxifySimulatorServer

enum SimulatorCommand {
    static func serve(arguments: [String]) async throws {
        let options = try ServerOptions(arguments: arguments)
        if options.help { print(ServerOptions.usage); return }
        let server = SimulatorServer(options: options)
        let port = try await server.start()
        print("Muxify Simulator: http://127.0.0.1:\(port)/#token=\(options.token)")
        print("Loopback only. Use Tailscale Serve or an SSH tunnel for remote access.")
        print("Closing a browser or stopping this server does not stop Devices.")
        fflush(stdout)
        await waitForSignal()
        await server.shutdown()
    }

    private static func waitForSignal() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        await withCheckedContinuation { continuation in
            var resumed = false
            let handler = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            interrupt.setEventHandler(handler: handler)
            terminate.setEventHandler(handler: handler)
            interrupt.resume(); terminate.resume()
        }
        interrupt.cancel(); terminate.cancel()
    }
}
