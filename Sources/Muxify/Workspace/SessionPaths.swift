import Foundation

/// A folder a Command Palette offers as a Session (CONTEXT.md): one from
/// `sessions.paths`, or a git worktree of one.
struct SessionPath: Hashable, Identifiable {
    let path: String
    /// For a worktree, the folder of its repository.
    var repository: String?

    var id: String { path }
    var isWorktree: Bool { repository != nil }

    /// The folder's name, or `<project> [<worktree>]`, as tmux-sessionizer
    /// named them.
    var sessionName: String {
        let name = SessionPaths.sanitize((path as NSString).lastPathComponent)
        guard let repository else { return name }
        return "\(SessionPaths.sanitize((repository as NSString).lastPathComponent)) [\(name)]"
    }
}

/// Finds the Session Paths on the Environment's machine, with one script run
/// locally or over the SSH master (ADR 0009, ADR 0010).
enum SessionPaths {
    /// Takes each root and its depth as a pair of arguments. Prints `E` to
    /// start a root that exists, `D` and a folder, and `W` and a worktree of
    /// the folder before it. Missing roots and hidden folders are skipped.
    static let script = """
    s='\(Tmux.separator)'
    while [ "$#" -ge 2 ]; do
        root=$1
        depth=$2
        shift 2
        case $root in
            "~") root=$HOME ;;
            "~/"*) root=$HOME/${root#"~/"} ;;
        esac
        [ "$root" = / ] || root=${root%/}
        [ -d "$root" ] || continue
        printf 'E\\n'
        if [ "$depth" -eq 0 ]; then
            printf '%s\\n' "$root"
        else
            find "$root" -mindepth 1 -maxdepth "$depth" -name '.*' -prune -o -type d -print 2>/dev/null
        fi | while IFS= read -r dir; do
            printf 'D%s%s\\n' "$s" "$dir"
            [ -d "$dir/.git" ] || continue
            # The first worktree listed is the repository itself.
            git -C "$dir" worktree list --porcelain 2>/dev/null | {
                main=1
                while IFS= read -r line; do
                    case $line in
                        "worktree "*)
                            if [ "$main" = 1 ]; then main=0; continue; fi
                            tree=${line#worktree }
                            if [ -d "$tree" ]; then printf 'W%s%s\\n' "$s" "$tree"; fi ;;
                    esac
                done
            }
        done
    done
    """

    static func arguments(for roots: [SessionPathRoot]) -> [String] {
        roots.flatMap { [$0.path, String($0.depth)] }
    }

    /// In Config order, folders by name within a root, and each worktree
    /// right after its repository. A folder found twice is listed once.
    static func parse(_ output: String) -> [SessionPath] {
        var roots: [[(folder: String, worktrees: [String])]] = []
        for line in output.split(separator: "\n") {
            let fields = line.components(separatedBy: Tmux.separator)
            switch (fields.first, fields.count) {
            case ("E", 1):
                roots.append([])
            case ("D", 2) where !roots.isEmpty:
                roots[roots.count - 1].append((fields[1], []))
            case ("W", 2) where roots.last?.isEmpty == false:
                let last = roots.count - 1
                roots[last][roots[last].count - 1].worktrees.append(fields[1])
            default:
                continue
            }
        }
        let byName = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        var seen = Set<String>()
        var paths: [SessionPath] = []
        for root in roots {
            for entry in root.sorted(by: { byName($0.folder, $1.folder) }) {
                if seen.insert(entry.folder).inserted { paths.append(SessionPath(path: entry.folder)) }
                for tree in entry.worktrees.sorted(by: byName) where seen.insert(tree).inserted {
                    paths.append(SessionPath(path: tree, repository: entry.folder))
                }
            }
        }
        return paths
    }

    /// tmux-sessionizer's names: spaces go, and `.` and `:`, which tmux
    /// doesn't allow, become `_`.
    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Whether a Session started in `sessionFolder` is the one for `path`.
    static func matches(_ path: SessionPath, sessionFolder: String) -> Bool {
        !sessionFolder.isEmpty && standardized(sessionFolder) == standardized(path.path)
    }

    /// The name for a new Session at `path`. When a Session in another
    /// folder has it, the parent folder goes in front (`work-foo`); when that
    /// is taken too, nil leaves the name to tmux.
    static func newSessionName(for path: SessionPath, taken: Set<String>) -> String? {
        let name = path.sessionName
        guard taken.contains(name) else { return name }
        let parent = sanitize(((path.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        let qualified = "\(parent)-\(name)"
        return parent.isEmpty || taken.contains(qualified) ? nil : qualified
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

/// Reads a Remote Environment's own Config file over the SSH master (ADR 0010).
enum RemoteConfigFile {
    /// Prints the file's path, then `present` and its text, or `missing`.
    static let script = """
    file=${XDG_CONFIG_HOME:-$HOME/.config}/muxify/config.yaml
    printf '%s\\n' "$file"
    if [ -f "$file" ]; then
        printf 'present\\n'
        cat "$file"
    else
        printf 'missing\\n'
    fi
    """

    /// The file's path, and its text when it exists.
    static func parse(_ output: String) -> (path: String, text: String?)? {
        let lines = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2, !lines[0].isEmpty else { return nil }
        switch lines[1] {
        case "present": return (String(lines[0]), lines.count > 2 ? String(lines[2]) : "")
        case "missing": return (String(lines[0]), nil)
        default: return nil
        }
    }
}
