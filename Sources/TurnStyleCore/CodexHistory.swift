import Foundation

/// Local metadata only. Codex's index and rollout formats are internal and may change.
public struct CodexHistory {
    public init() {}
    public func names(root: URL) throws -> [String: String] {
        let file = root.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > 8 * 1024 * 1024 ? size - 8 * 1024 * 1024 : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
        var names: [String: String] = [:]
        let lines = data.split(separator: 10)
        for line in start > 0 ? lines.dropFirst() : lines[...] {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = row["id"] as? String, let name = row["thread_name"] as? String,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            names[id] = name
        }
        return names
    }
    public func discover(root: URL, limit: Int = Int.max) throws -> [TrackedSession] {
        let folder = root.appendingPathComponent("sessions")
        guard
            let files = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        let names = try names(root: root)
        var candidates: [(URL, Date)] = []
        for case let file as URL in files where file.pathExtension == "jsonl" {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values.isRegularFile == true {
                candidates.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        return try candidates.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { file, modified in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard let line = data.split(separator: 10).first,
                let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                row["type"] as? String == "session_meta", let payload = row["payload"] as? [String: Any],
                let id = payload["id"] as? String,
                let source = payload["source"] as? String,
                ["cli", "vscode", "appServer"].contains(source)
            else { return nil }
            return TrackedSession(
                provider: "codex", sessionID: id, title: names[id] ?? "Codex conversation",
                workspace: payload["cwd"] as? String ?? "", updatedAt: modified,
                transcriptPath: file.path, imported: true)
        }
    }
}
