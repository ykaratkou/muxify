import AppKit

/// Muxify ▸ Install Command Line Tool: links the `muxify` executable bundled at
/// `Contents/Resources/bin/muxify` into `~/.local/bin`, so any Pane can run
/// `muxify browser open <url>`.
enum CommandLineToolInstaller {
    static func run() {
        let (failed, text) = install()
        let alert = NSAlert()
        alert.messageText = failed ? "Couldn't install the command line tool" : "Command line tool installed"
        alert.informativeText = text
        alert.alertStyle = failed ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func install() -> (failed: Bool, text: String) {
        let fm = FileManager.default
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("bin/muxify"),
              fm.isExecutableFile(atPath: tool.path)
        else {
            return (true, "The tool is missing from the app bundle (Contents/Resources/bin/muxify).")
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        let link = dir.appendingPathComponent("muxify")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Replace our own earlier link (e.g. to an older build), never a real file.
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                return (true, "\(Paths.tildify(link.path)) already exists and isn't a link. Remove it and try again.")
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: tool)
        } catch {
            return (true, error.localizedDescription)
        }
        return (false, "\(Paths.tildify(link.path)) → \(Paths.tildify(tool.path))\n\nIn any Pane, run:\nmuxify browser open <url>")
    }
}
