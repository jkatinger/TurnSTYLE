import Foundation

/// Map the hook/CLI ID to Claude Desktop's native session ID without importing or forking.
/// Link format verified in the installed Claude Desktop 4.4212.0 handler and live UI.
public struct ClaudeDesktopLinks {
    private struct Record: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let isArchived: Bool?
        let lastFocusedAt: Double?
    }
    public init() {}
    public func url(sessionID: String, root: URL) throws -> URL? {
        guard UUID(uuidString: sessionID) != nil,
            let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        else { return nil }
        var match: (String, Double)?
        for case let file as URL in files {
            guard file.pathExtension == "json", file.lastPathComponent.hasPrefix("local_") else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
                let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
                record.cliSessionId == sessionID, record.isArchived != true,
                record.sessionId.hasPrefix("local_"), UUID(uuidString: String(record.sessionId.dropFirst(6))) != nil,
                file.lastPathComponent == record.sessionId + ".json"
            else { continue }
            let focused = record.lastFocusedAt ?? 0
            if match == nil || focused > match!.1 { match = (record.sessionId, focused) }
        }
        guard let match else { return nil }
        var url = URLComponents()
        url.scheme = "claude"
        url.host = "code"
        url.path = "/continue"
        url.queryItems = [URLQueryItem(name: "session", value: match.0)]
        return url.url
    }
}
