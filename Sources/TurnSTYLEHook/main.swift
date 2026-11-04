import Foundation
import TurnStyleCore

// Fail open: no output and never a non-zero exit that could interrupt Claude.
do {
    // Read incrementally: fragmented pipe writes are valid, but an oversized
    // payload must not allocate unbounded memory before the limit is checked.
    let limit = 8 * 1024 * 1024
    var data = Data()
    while data.count <= limit {
        guard let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, limit + 1 - data.count)),
            !chunk.isEmpty
        else { break }
        data.append(chunk)
    }
    let provider: any SessionProvider =
        CommandLine.arguments.contains("--turnstyle-codex-hook") ? CodexProvider() : ClaudeProvider()
    if data.count <= limit, let event = try provider.event(from: data, at: Date()) {
        try EventInbox().enqueue(event)
    }
} catch {
    FileHandle.standardError.write(Data("TurnSTYLE could not record this event.\n".utf8))
}
