import Foundation

/// Read only bounded transcript metadata; never infer automation from prompt wording.
public enum ClaudeSessionOrigin {
    public static func isLocalCommand(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<command-name>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>"].contains
        { value.hasPrefix($0) }
    }
    public static func isCommandOnly(transcriptPath: String?) -> Bool {
        guard let transcriptPath, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
        else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        try? handle.seek(toOffset: 0)
        var chunks = [(try? handle.read(upToCount: 256 * 1024)) ?? Data()]
        if size > 256 * 1024 {
            try? handle.seek(toOffset: max(256 * 1024, size - min(size, 256 * 1024)))
            chunks.append((try? handle.read(upToCount: 256 * 1024)) ?? Data())
        }
        var command = false
        for data in chunks {
            for line in data.split(separator: 10) {
                guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    item["type"] as? String == "user", item["isMeta"] as? Bool != true,
                    let message = item["message"] as? [String: Any]
                else { continue }
                let text =
                    message["content"] as? String ?? (message["content"] as? [[String: Any]])?.filter {
                        $0["type"] as? String == "text"
                    }.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                if isLocalCommand(text) {
                    command = true
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return false
                }
            }
        }
        return command
    }
    public static func isBackground(transcriptPath: String?) -> Bool {
        guard let transcriptPath, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
        else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return false }
        var sdk = false
        for line in data.split(separator: 10) {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if item["entrypoint"] as? String == "claude-desktop" { return false }
            if item["entrypoint"] as? String == "sdk-cli" { sdk = true }
        }
        return sdk
    }
}
