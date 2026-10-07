import Foundation

/// Retire SSH/tmux and remove transport files off-main; terminal surfaces are
/// UI resources and must still be closed on-main. Tracks Environment switches
/// as well as quit, so termination cannot abandon an earlier cleanup.
final class ConnectionCleanup {
    private let pending = DispatchGroup()

    func run(retire: @escaping () -> Void, closeSurface: @escaping () -> Void,
             cleanup: @escaping () -> Void, completion: @escaping () -> Void = {}) {
        precondition(Thread.isMainThread)
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            retire()
            DispatchQueue.main.async {
                closeSurface()
                DispatchQueue.global(qos: .userInitiated).async {
                    cleanup()
                    DispatchQueue.main.async {
                        completion()
                        self.pending.leave()
                    }
                }
            }
        }
    }

    func whenFinished(_ completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        pending.notify(queue: .main, execute: completion)
    }
}
