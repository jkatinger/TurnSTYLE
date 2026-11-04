import Foundation

public struct RemoteCodexSnapshot: Decodable, Sendable {
    public var hostID: String
    public var hostName: String
    public var events: [SessionEvent]
    public var names: [String: String]
    public var history: [RemoteCodexHistoryItem]
    public var historyError: String?
    public func historySessions() -> [TrackedSession] {
        history.map { item in
            TrackedSession(
                provider: "codex", sessionID: item.id, title: names[item.id] ?? item.title,
                workspace: item.workspace,
                updatedAt: Date(timeIntervalSince1970: item.updatedAt > 1e12 ? item.updatedAt / 1000 : item.updatedAt),
                transcriptPath: item.transcriptPath, imported: true, hostID: hostID, hostName: hostName)
        }
    }
}
public struct RemoteCodexHistoryItem: Decodable, Sendable {
    public var id: String
    public var title: String
    public var workspace: String
    public var updatedAt: Double
    public var transcriptPath: String?
}

extension QueueState {
    public mutating func applyRemote(_ snapshot: RemoteCodexSnapshot) {
        for var event in snapshot.events where event.provider == "codex" {
            // Host identity comes from our SSH endpoint, never a remote event's payload.
            event.hostID = snapshot.hostID
            event.hostName = snapshot.hostName
            // Event UUIDs are host-scoped too, avoiding cross-host replay collisions.
            event.id = snapshot.hostID + ":" + event.id
            apply(event)
        }
        for index in sessions.indices
        where sessions[index].provider == "codex" && sessions[index].hostID == snapshot.hostID {
            sessions[index].hostName = snapshot.hostName
            if let title = snapshot.names[sessions[index].sessionID] { sessions[index].title = title }
        }
        remoteCodexHostID = snapshot.hostID
        remoteCodexHostName = snapshot.hostName
        // Saved with queue state before the next poll acknowledges these files remotely.
        remoteCodexAckIDs = snapshot.events.map(\.id)
    }
    public mutating func invalidateRemoteWorking(hostID: String) {
        for index in sessions.indices where sessions[index].hostID == hostID && sessions[index].status == .running {
            sessions[index].status = .unknown
            sessions[index].attentionSince = Date()
        }
    }
}
