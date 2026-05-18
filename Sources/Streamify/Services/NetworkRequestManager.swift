import Foundation

@MainActor
final class NetworkRequestManager: Sendable {
    static let shared = NetworkRequestManager()

    // No lock needed: @MainActor already serialises all access to this class.
    private var activeRequests: [String: [URLSessionTask]] = [:]

    private init() {}

    func track(_ task: URLSessionTask, for contextId: String) {
        if activeRequests[contextId] == nil { activeRequests[contextId] = [] }
        activeRequests[contextId]?.append(task)
    }

    func cancelAll(for contextId: String) {
        guard let tasks = activeRequests[contextId] else { return }
        for task in tasks where task.state != .canceling && task.state != .completed {
            task.cancel()
        }
        activeRequests.removeValue(forKey: contextId)
    }

    func cleanup(for contextId: String) {
        if let tasks = activeRequests[contextId] {
            let active = tasks.filter { $0.state != .completed && $0.state != .canceling }
            if active.isEmpty { activeRequests.removeValue(forKey: contextId) }
            else { activeRequests[contextId] = active }
        }
    }

}

extension URLSession {
    nonisolated func trackedData(from url: URL, contextId: String) async throws -> (Data, URLResponse) {
        let result = try await self.data(from: url)
        await MainActor.run { NetworkRequestManager.shared.cleanup(for: contextId) }
        return result
    }

    nonisolated func trackedDownload(from url: URL, contextId: String) async throws -> (URL, URLResponse) {
        let result = try await self.download(from: url)
        await MainActor.run { NetworkRequestManager.shared.cleanup(for: contextId) }
        return result
    }
}

