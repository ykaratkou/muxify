import Foundation
import PackagePlugin

@main
struct EmbedWebAssetsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let directory = URL(fileURLWithPath: target.directory.string).appending(path: "Web")
        let inputs = ["index.html", "app.js", "style.css"].map { directory.appending(path: $0) }
        let output = context.pluginWorkDirectoryURL.appending(path: "WebAssets.generated.swift")
        return [.buildCommand(
            displayName: "Embed Simulator browser assets",
            executable: try context.tool(named: "EmbedWebAssets").url,
            arguments: [output.path] + inputs.map(\.path),
            inputFiles: inputs, outputFiles: [output]
        )]
    }
}
