import Foundation
import SQLite3

/// Read-only access to the desktop app's synced connected-device catalog.
/// This internal schema can change. It contains saved names, not live runtime state.
public struct CodexDesktopCatalog {
    public init() {}
    public func discover(file: URL, limit: Int = Int(Int32.max)) throws -> [TrackedSession] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            throw SetupError.invalid("Codex’s connected-device catalog could not be opened read-only.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        let query = """
            SELECT host_id, thread_id, display_title, COALESCE(cwd, ''), source_updated_at
            FROM local_thread_catalog
            WHERE host_id LIKE 'remote-control:%' AND missing_candidate = 0
              AND source_kind IN ('cli', 'vscode', 'appServer')
            ORDER BY source_updated_at DESC, source_recency_at DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw SetupError.invalid("Codex’s saved catalog format has changed. Connected-device sync is unavailable.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(0, min(limit, Int(Int32.max)))))
        func value(_ column: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: bytes)
        }
        var result: [TrackedSession] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SetupError.invalid("Codex’s catalog is busy. TurnSTYLE will retry.") }
            let id = value(1)
            let title = value(2)
            guard UUID(uuidString: id) != nil, !title.isEmpty else { continue }
            result.append(
                TrackedSession(
                    provider: "codex", sessionID: id, title: title,
                    workspace: value(3), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    imported: true, hostID: value(0), hostName: "Connected Codex device"))
        }
        return result
    }
}

extension TrackedSession {
    /// Format verified against the installed desktop app's URL builder and route parser.
    public var codexURL: URL? {
        guard provider == "codex", UUID(uuidString: sessionID) != nil else { return nil }
        // SSH bridge UUIDs aren't Codex connection IDs and must not be put in a deep link.
        guard hostID == nil || hostID?.hasPrefix("remote-control:") == true else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/" + sessionID
        if let hostID { components.queryItems = [URLQueryItem(name: "hostId", value: hostID)] }
        return components.url
    }
}

extension QueueState {
    /// Catalog metadata may update names, but never overwrites live status or user choices.
    @discardableResult public mutating func mergeConnectedCatalog(_ candidates: [TrackedSession]) -> Bool {
        var changed = false
        for candidate in candidates
        where candidate.provider == "codex" && candidate.hostID?.hasPrefix("remote-control:") == true {
            if let index = sessions.firstIndex(where: { $0.id == candidate.id }) {
                if sessions[index].title != candidate.title {
                    sessions[index].title = candidate.title
                    changed = true
                }
                if sessions[index].workspace != candidate.workspace {
                    sessions[index].workspace = candidate.workspace
                    changed = true
                }
                if sessions[index].imported && candidate.updatedAt > sessions[index].updatedAt {
                    sessions[index].updatedAt = candidate.updatedAt
                    sessions[index].archived = false
                    changed = true
                }
            } else {
                var session = candidate
                session.status = .unknown
                session.imported = true
                sessions.append(session)
                changed = true
            }
        }
        return changed
    }
}
