import Foundation

/// Called only by SharedDevice's ordered operations. Ownership survives failed delivery,
/// so recovery can retry releases without lifting another viewer's keys or contact.
final class DeviceInput {
    private let input: any InputSession
    private var keyOwners: [UInt32: Set<UUID>] = [:]
    private var contact: (owner: UUID, event: TouchEvent)?

    init(_ input: any InputSession) { self.input = input }

    func key(_ event: KeyEvent, owner: UUID) async throws {
        let owners = keyOwners[event.usage] ?? []
        switch event.phase {
        case .down:
            keyOwners[event.usage, default: []].insert(owner)
            if owners.isEmpty { try await input.key(event) }
        case .up:
            guard owners.contains(owner) else { return }
            if owners.count == 1 { try await input.key(event) }
            keyOwners[event.usage]?.remove(owner)
            if keyOwners[event.usage]?.isEmpty == true { keyOwners[event.usage] = nil }
        }
    }

    func touch(_ command: ControlMessage.TouchCommand, owner: UUID) async throws {
        if command.phase == .began {
            guard contact == nil || contact?.owner == owner else { return }
            try await releaseContact(owner)
        } else if contact?.owner != owner { return }
        if command.phase == .cancelled { try await releaseContact(owner); return }

        let point = command.orientation.nativePoint(command.point)
        let edge: TouchEvent.Edge
        if let contact { edge = contact.event.edge }
        else if point.y <= 0.02 { edge = .top }
        else if point.y >= 0.98 { edge = .bottom }
        else if point.x <= 0.02 { edge = .left }
        else if point.x >= 0.98 { edge = .right }
        else { edge = .none }
        let event = TouchEvent(phase: command.phase, point: point, edge: edge)
        contact = (owner, event)
        try await input.touch(event)
        if command.phase == .ended { contact = nil }
    }

    func home() async throws {
        try await input.home(phase: .down)
        try await retryRelease { try await self.input.home(phase: .up) }
    }

    private func releaseContact(_ owner: UUID) async throws {
        guard let contact, contact.owner == owner else { return }
        try await input.touch(TouchEvent(phase: .cancelled, point: contact.event.point, edge: contact.event.edge))
        self.contact = nil
    }

    func release(_ owner: UUID) async throws {
        // Attempt every release even if one fails. Keep failed ownership for another attempt.
        var failure: Error?
        do { try await retryRelease { try await self.releaseContact(owner) } }
        catch { failure = error }
        for usage in keyOwners.keys.sorted() where keyOwners[usage]?.contains(owner) == true {
            do { try await retryRelease { try await self.key(KeyEvent(phase: .up, usage: usage), owner: owner) } }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    func releaseAll() async throws {
        var owners = Set(keyOwners.values.flatMap { $0 })
        if let contact { owners.insert(contact.owner) }
        var failure: Error?
        for owner in owners {
            do { try await release(owner) }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private func retryRelease(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { try await operation() }
    }
}
