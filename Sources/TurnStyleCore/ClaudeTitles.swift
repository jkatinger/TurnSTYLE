import Foundation

/// Read-only, incremental title metadata lookup. The caller runs this off the UI thread.
/// Only title records are decoded; conversation content is never retained.
public struct ClaudeTitles {
    private struct Cursor {
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var modified = Date.distantPast
        var partial = Data()
        var skippingLine = false
        var custom: String?
        var generated: String?
    }
    private var cursors: [String: Cursor] = [:]
    public init() {}

    public mutating func titles(for sessions: [TrackedSession], root: URL) -> [String: String] {
        let projects = root.appendingPathComponent("projects").resolvingSymlinksInPath().path + "/"
        var result: [String: String] = [:]
        var active: Set<String> = []
        for session in sessions where session.provider == "claude" {
            guard let path = session.transcriptPath else { continue }
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(projects), file.lastPathComponent == session.sessionID + ".jsonl",
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.uint64Value
            else { continue }
            active.insert(file.path)
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            var cursor = cursors[file.path] ?? Cursor()
            if cursor.inode != inode || size < cursor.offset || (size == cursor.offset && cursor.modified != modified) {
                cursor = Cursor()
            }
            cursor.inode = inode
            cursor.modified = modified
            if cursor.offset < size {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                do {
                    try handle.seek(toOffset: cursor.offset)
                    // Bound each poll; long transcripts continue on the next poll.
                    let end = min(size, cursor.offset + 4 * 1024 * 1024)
                    while cursor.offset < end {
                        let data = try handle.read(upToCount: Int(min(64 * 1024, end - cursor.offset))) ?? Data()
                        if data.isEmpty { break }
                        cursor.offset += UInt64(data.count)
                        for byte in data {
                            if byte == 10 {
                                if !cursor.skippingLine {
                                    Self.consume(cursor.partial, sessionID: session.sessionID, cursor: &cursor)
                                }
                                cursor.partial.removeAll(keepingCapacity: true)
                                cursor.skippingLine = false
                            } else if !cursor.skippingLine {
                                if cursor.partial.count < 256 * 1024 {
                                    cursor.partial.append(byte)
                                } else {
                                    cursor.partial.removeAll(keepingCapacity: true)
                                    cursor.skippingLine = true
                                }
                            }
                        }
                    }
                } catch { continue }  // Retry from the previous saved cursor next time.
            }
            cursors[file.path] = cursor
            // Do not publish an older name while catching up through a large file.
            if cursor.offset == size, let title = cursor.custom ?? cursor.generated { result[session.id] = title }
        }
        cursors = cursors.filter { active.contains($0.key) }
        return result
    }

    private static func consume(_ data: Data, sessionID: String, cursor: inout Cursor) {
        guard data.range(of: Data("\"custom-title\"".utf8)) != nil || data.range(of: Data("\"ai-title\"".utf8)) != nil,
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            row["sessionId"] as? String == sessionID
        else { return }
        let type = row["type"] as? String
        let value = row[type == "custom-title" ? "customTitle" : "aiTitle"] as? String
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if type == "custom-title" { cursor.custom = value } else if type == "ai-title" { cursor.generated = value }
    }
}
