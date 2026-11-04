import Foundation

/// Bounded, read-only discovery of local main-session transcripts. History is never
/// treated as evidence of current runtime state; candidates begin as .unknown.
public struct HistoryImporter {
    public init() {}
    public func discover(root: URL, limit: Int = Int.max) throws -> [TrackedSession] {
        let projects = root.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projects.path) else { return [] }
        guard
            let enumerator = FileManager.default.enumerator(
                at: projects,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var candidates: [(URL, Date)] = []
        for case let file as URL in enumerator {
            if file.lastPathComponent == "subagents" {
                enumerator.skipDescendants()
                continue
            }
            guard file.pathExtension == "jsonl", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
            else { continue }
            let resource = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if resource.isRegularFile == true {
                candidates.append((file, resource.contentModificationDate ?? .distantPast))
            }
        }
        return try candidates.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { file, modified in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: 128 * 1024) ?? Data()
            var chunks = [head]
            if size > 128 * 1024 {
                try handle.seek(toOffset: max(UInt64(128 * 1024), size > 256 * 1024 ? size - 256 * 1024 : 0))
                chunks.append(try handle.read(upToCount: 256 * 1024) ?? Data())
            }
            var title: String?
            var generatedTitle: String?
            var firstPrompt: String?
            var workspace = ""
            var isSubagent = false
            for bytes in chunks {
                for line in bytes.split(separator: 10) {
                    guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        continue
                    }
                    if item["isSidechain"] as? Bool == true { isSubagent = true }
                    if let cwd = item["cwd"] as? String { workspace = cwd }
                    if item["sessionId"] as? String == file.deletingPathExtension().lastPathComponent {
                        if item["type"] as? String == "custom-title", let custom = item["customTitle"] as? String,
                            !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            title = custom
                        }
                        if item["type"] as? String == "ai-title", let generated = item["aiTitle"] as? String,
                            !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            generatedTitle = generated
                        }
                    }
                    if title == nil, item["type"] as? String == "summary", let summary = item["summary"] as? String {
                        title = summary
                    }
                    if firstPrompt == nil, item["type"] as? String == "user", item["isMeta"] as? Bool != true,
                        let message = item["message"] as? [String: Any]
                    {
                        if let content = message["content"] as? String {
                            firstPrompt = content
                        } else if let blocks = message["content"] as? [[String: Any]] {
                            firstPrompt = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                        }
                        if let prompt = firstPrompt, ClaudeSessionOrigin.isLocalCommand(prompt) { firstPrompt = nil }
                    }
                }
            }
            guard !ClaudeSessionOrigin.isCommandOnly(transcriptPath: file.path), !isSubagent,
                !ClaudeSessionOrigin.isBackground(transcriptPath: file.path)
            else { return nil }
            let display =
                (title ?? generatedTitle ?? firstPrompt ?? "Claude conversation").split(whereSeparator: { $0.isNewline }
                ).first.map(String.init) ?? "Claude conversation"
            return TrackedSession(
                sessionID: file.deletingPathExtension().lastPathComponent,
                title: title ?? generatedTitle ?? String(display.prefix(100)), workspace: workspace,
                updatedAt: modified,
                transcriptPath: file.path, imported: true)
        }
    }
}
