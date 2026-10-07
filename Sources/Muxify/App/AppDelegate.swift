import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by the app once its App Windows coordinator is available.
    var shutdown: ((@escaping () -> Void) -> Void)?
    var openURLs: (([URL]) -> Void)? {
        didSet { deliverURLs() }
    }
    private var pendingURLs: [URL] = []
    private var isTerminating = false
    private var hasReplied = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs += urls
        deliverURLs()
    }

    private func deliverURLs() {
        guard let openURLs, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        openURLs(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: true) }
    }

    /// AppKit must keep the process alive for asynchronous cleanup. A task
    /// launched from willTerminate would otherwise be abandoned during exit.
    func requestTermination(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        precondition(Thread.isMainThread)
        guard let shutdown else { return .terminateNow }
        guard !isTerminating else { return hasReplied ? .terminateNow : .terminateLater }
        isTerminating = true
        shutdown {
            // Even an immediate completion must wait until terminateLater has
            // been returned; reply once, on the main thread, after cleanup.
            DispatchQueue.main.async {
                guard !self.hasReplied else { return }
                self.hasReplied = true
                reply()
            }
        }
        return .terminateLater
    }
}
