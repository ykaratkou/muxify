import Foundation
import Darwin

/// One foreground, prompt-owning SSH master and its master-only channels.
/// No files, helper or listening port are installed on the remote machine.
final class RemoteSSH {
    let environment: RemoteEnvironment
    let directory: URL
    let nonce: String
    private let sshExecutable: String
    private var ownsDirectory = false
    var socketPath: String { directory.appendingPathComponent("s").path }
    var markerOption: String { "@muxify_client_\(nonce)" }
    private var exitFile: URL { directory.appendingPathComponent("exit") }
    private var errorFile: URL { directory.appendingPathComponent("stderr") }

    init(environment: RemoteEnvironment, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         sshExecutable: String = "/usr/bin/ssh") throws {
        self.environment = environment
        self.sshExecutable = sshExecutable
        nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        directory = temporaryDirectory.appendingPathComponent("mx-\(nonce.prefix(10))")
        guard directory.appendingPathComponent("s").path.utf8.count < 104 else {
            throw TmuxError.failed(status: 1, stderr: "Temporary directory path is too long for an SSH control socket")
        }
        // Exclusive creation: never reuse or later remove a directory that
        // existed before this connection, even if a random name collides.
        guard directory.path.withCString({ mkdir($0, 0o700) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        ownsDirectory = true
    }

    private var options: [String] {
        var args = [
            "-l", environment.username, environment.forwardAgent ? "-A" : "-a",
            "-o", "ControlPath=\(socketPath)",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "StrictHostKeyChecking=ask", "-o", "ForwardX11=no",
            "-o", "RemoteCommand=none",
            "-o", "ForkAfterAuthentication=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
        ]
        if let port = environment.port { args += ["-p", String(port)] }
        if let key = environment.identityFile { args += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        return args
    }

    func control(_ operation: String) -> CommandInvocation {
        CommandInvocation(executable: sshExecutable, arguments: options + ["-O", operation, "--", environment.host])
    }

    /// BatchMode alone is insufficient: ssh otherwise falls back to a new
    /// connection if the master disappears. The failing proxy closes that race.
    func command(_ args: [String]) -> CommandInvocation {
        var checks = ""
        if args != ["show-option", "-sqv", markerOption] {
            // A server restart must not turn queued IDs into commands against
            // a new server. This nonce belongs only to our attachment/server.
            checks = """
            marker=$(tmux -u show-option -sqv \(Tmux.shellQuote(markerOption))) || exit $?
            if [ -z "$marker" ]; then echo 'Muxify: remote tmux attachment is no longer available.' >&2; exit 75; fi
            """
            if ["switch-client", "display-message"].contains(args.first ?? ""),
               let index = args.firstIndex(of: "-c"), args.indices.contains(index + 1) {
                checks += """

                expected=${marker%%\(Tmux.separator)*}
                actual=$(tmux -u list-clients -F '#{client_tty} #{client_pid}' | while IFS= read -r line; do
                    tty=${line% *}
                    pid=${line##* }
                    if [ "$tty" = \(Tmux.shellQuote(args[index + 1])) ]; then printf '%s' "$pid"; break; fi
                done)
                if [ "$actual" != "$expected" ]; then echo 'Muxify: remote tmux client changed.' >&2; exit 75; fi
                """
            }
        }
        let script = Self.remotePath + "\n" + checks + "\nexec tmux -u " + args.map(Tmux.shellQuote).joined(separator: " ")
        return CommandInvocation(executable: sshExecutable, arguments: options + [
            "-T", "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false",
            "--", environment.host, "exec /bin/sh -c " + Tmux.shellQuote(script),
        ])
    }

    func terminalCommand(target: String? = nil) -> String {
        terminalInvocation(target: target).commandLine
    }

    func terminalInvocation(target: String? = nil) -> CommandInvocation {
        let ssh = attachmentInvocation(target: target)
        // Keep SSH stdout on the original terminal (fd 3), logging only stderr.
        // The pipeline is waited in full before exit, so even macOS bash 3.2
        // finishes the logger before Ghostty reports the child closed.
        // Prompts still read /dev/tty; save SSH's status, not tee/login's status.
        let script = """
        export SSH_ASKPASS_REQUIRE=never
        export TERM="${TERM:-xterm-256color}"
        exec 3>&1
        {
            \(ssh.commandLine) 2>&1 >&3
            printf '%s\\n' "$?" > \(Tmux.shellQuote(exitFile.path))
        } | /usr/bin/tee \(Tmux.shellQuote(errorFile.path)) >&2
        status=$(cat \(Tmux.shellQuote(exitFile.path)))
        exit "${status:-255}"
        """
        return CommandInvocation(executable: "/bin/bash", arguments: ["-c", script])
    }

    /// Reads the normal SSH config, including Host aliases and IdentityAgent
    /// (e.g. 1Password). Only our session/socket lifecycle and safety settings
    /// override it; background channels still cannot independently authenticate.
    func attachmentInvocation(target: String? = nil) -> CommandInvocation {
        CommandInvocation(executable: sshExecutable, arguments: options + [
            "-tt", "-M", "-o", "ControlPersist=no",
            "--", environment.host, "exec /bin/sh -c " + Tmux.shellQuote(bootstrap(target: target)),
        ])
    }

    func bootstrap(target: String? = nil) -> String {
        let targetSetup = target.map { "target=\(Tmux.shellQuote($0))" }
            ?? "target=$(tmux -u show-options -gqv \(Tmux.shellQuote(Tmux.lastWindowOption)) 2>/dev/null)"
        return """
        \(Self.remotePath)
        unset TMUX TMUX_PANE
        if ! command -v tmux >/dev/null 2>&1; then
            echo 'Muxify: tmux was not found on the remote machine.' >&2
            exit 127
        fi
        version=$(tmux -u -V)
        version=${version#tmux }
        major=${version%%.*}
        minor=${version#*.}
        minor=${minor%%[!0-9]*}
        case "$major:$minor" in *[!0-9:]*|:*) echo 'Muxify: could not determine the remote tmux version.' >&2; exit 2;; esac
        if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 2 ]; }; then
            echo 'Muxify: remote tmux 3.2 or newer is required.' >&2
            exit 2
        fi
        # SSH carries Ghostty's TERM with the PTY. Keep it when the remote
        # terminfo knows it; do not require installing an entry or infocmp.
        if [ -z "${TERM:-}" ] || ! command -v infocmp >/dev/null 2>&1 || ! infocmp "$TERM" >/dev/null 2>&1; then
            TERM=xterm-256color
        fi
        export TERM COLORTERM=truecolor
        if ! tmux -u has-session 2>/dev/null; then
            tmux -u new-session -d -s main -c "$HOME" || exit $?
        fi
        \(targetSetup)
        if [ -n "$target" ] && ! tmux -u list-panes -t "$target" >/dev/null 2>&1; then target=; fi
        # Some SSH servers (including OrbStack) omit SSH_TTY despite -tt.
        client_tty=${SSH_TTY:-$(tty)}
        case "$client_tty" in
            /dev/*) ;;
            *) echo 'Muxify: the remote SSH connection did not provide a terminal.' >&2; exit 2;;
        esac
        marker="$$\(Tmux.separator)${client_tty}\(Tmux.separator)${HOME}\(Tmux.separator)$(uname -n)"
        tmux -u set-option -sq \(Tmux.shellQuote(markerOption)) "$marker" || exit $?
        # Our renderer supports RGB even if the fallback terminfo does not.
        # Advertise it for this client only, without rewriting server options.
        if [ -n "$target" ]; then
            exec tmux -u -T RGB attach-session -t "$target"
        else
            exec tmux -u -T RGB attach-session
        fi
        """
    }

    private static let remotePath = "unset TMUX TMUX_PANE\nPATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin\"; export PATH"

    var exitStatus: Int? {
        (try? String(contentsOf: exitFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var failureMessage: String {
        let text = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        return lines.suffix(4).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var shouldReconnect: Bool {
        guard exitStatus == 255 else { return false }
        let error = failureMessage.lowercased()
        // Authentication/setup failures require user action; reconnecting may
        // otherwise repeatedly ask for a passphrase or host-key approval.
        if ["permission denied", "host key verification failed", "host identification has changed",
                 "no such identity", "unprotected private key", "too many authentication failures",
                 "muxify: tmux", "muxify: remote tmux", "muxify: could not determine"].contains(where: error.contains) { return false }
        // A cancelled verification/passphrase prompt can also exit 255.
        // Only transport failures should automatically acquire another master.
        return ["connection reset", "connection refused", "timed out", "broken pipe", "no route to host",
                "network is unreachable", "network is down", "not responding", "could not resolve hostname"]
            .contains(where: error.contains) || (error.contains("connection") && error.contains("closed"))
    }

    func cleanup() {
        guard ownsDirectory else { return }
        ownsDirectory = false
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { cleanup() }
}
