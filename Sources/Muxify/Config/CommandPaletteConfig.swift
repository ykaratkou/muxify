/// One kind of thing a Command Palette searches (CONTEXT.md).
enum PaletteSource: String, CaseIterable {
    /// Running Sessions and the Session Paths that have none.
    case sessions
    case windows
    case agents

    var title: String { rawValue.capitalized }
}

struct CommandPaletteConfig: Equatable, Identifiable {
    /// Unique among the Config's palettes.
    let name: String
    var triggers: [KeyTrigger]
    /// The chips that are on when it opens, in Config order, without
    /// repeats; never empty. The other Sources can be switched on.
    let sources: [PaletteSource]

    var id: String { name }

    /// Every Source as a chip: the palette's own first, then the others.
    var chips: [PaletteSource] { sources + PaletteSource.allCases.filter { !sources.contains($0) } }

    var placeholder: String { name.hasSuffix("…") ? name : "Search \(name)" }

    /// The palette a Config without `command_palettes` has.
    static let goTo = CommandPaletteConfig(name: "Go to…", triggers: [try! KeyTrigger("cmd+shift+p")],
                                           sources: [.agents, .sessions, .windows])
}

/// A `sessions.paths` entry: a folder, or every folder under it down to
/// `depth` levels.
struct SessionPathRoot: Equatable {
    /// As written: absolute, or starting with `~`, which is the home folder
    /// of the machine that has it.
    let path: String
    /// 0 is the folder itself. Hidden folders are skipped.
    let depth: Int
}
