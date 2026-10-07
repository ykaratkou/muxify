import Darwin
import Foundation

@main
struct MuxifyCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let command = try CLICommand(arguments: arguments)
            try await command.execute()
        } catch {
            let status = (error as? CLIError)?.exitCode ?? 1
            let prefix = error.localizedDescription == CLICommand.usage ? "" : (arguments.first == "simulator" ? "muxify simulator: " : "muxify: ")
            FileHandle.standardError.write(Data("\(prefix)\(error.localizedDescription)\n".utf8))
            exit(status)
        }
    }
}
