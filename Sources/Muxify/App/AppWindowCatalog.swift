import Foundation

/// Stable SwiftUI scene identity; Environment names resolve against live Config.
struct AppWindowRequest: Codable, Hashable, Identifiable {
    let id: UUID
    var environmentName: String?

    init(id: UUID = UUID(), environmentName: String? = nil) {
        self.id = id
        self.environmentName = environmentName
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Reserves destinations before their native windows appear, so repeated
/// Environment clicks cannot start duplicate connections during opening.
struct AppWindowCatalog {
    private(set) var requests: [AppWindowRequest] = []
    private(set) var focusedID: UUID?

    mutating func register(_ request: AppWindowRequest) {
        guard !requests.contains(where: { $0.id == request.id }) else { return }
        requests.append(request)
    }

    mutating func openEnvironment(named name: String?) -> AppWindowRequest {
        if let existing = window(forEnvironment: name) { return existing }
        let request = AppWindowRequest(environmentName: name)
        register(request)
        return request
    }

    func window(forEnvironment name: String?) -> AppWindowRequest? {
        if let focused = requests.first(where: { $0.id == focusedID && $0.environmentName == name }) { return focused }
        return requests.last(where: { $0.environmentName == name })
    }

    mutating func newLocalWindow() -> AppWindowRequest {
        let request = AppWindowRequest()
        register(request)
        return request
    }

    mutating func focus(_ id: UUID) {
        guard requests.contains(where: { $0.id == id }) else { return }
        focusedID = id
    }

    mutating func updateEnvironment(_ id: UUID, name: String?) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].environmentName = name
    }

    mutating func close(_ id: UUID) {
        requests.removeAll { $0.id == id }
        if focusedID == id { focusedID = nil }
    }
}
