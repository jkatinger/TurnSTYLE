import Foundation

public enum TurnStylePaths {
    public static var dataRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["TURNSTYLE_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnSTYLE", isDirectory: true)
    }
    public static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public struct EventInbox {
    public let root: URL
    public var folder: URL { root.appendingPathComponent("events", isDirectory: true) }
    public init(root: URL = TurnStylePaths.dataRoot) { self.root = root }
    public func enqueue(_ event: SessionEvent) throws {
        try TurnStylePaths.prepare(root)
        try TurnStylePaths.prepare(folder)
        // Event IDs are payload data, never filesystem paths. Keep UUID names
        // for bridge acknowledgement compatibility, even for custom event IDs.
        let filename = UUID(uuidString: event.id) == nil ? UUID().uuidString : event.id
        let url = folder.appendingPathComponent(filename + ".json")
        try JSONEncoder().encode(event).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func pending() throws -> [(URL, SessionEvent)] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var result: [(URL, SessionEvent)] = []
        for url in files where url.pathExtension == "json" {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            // Never follow links or open special files from the inbox.
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do {
                data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if data.count <= 8 * 1024 * 1024,
                let event = try? JSONDecoder().decode(SessionEvent.self, from: data)
            {
                result.append((url, event))
            } else {
                // A damaged file must not permanently block all valid events.
                // Preserve it privately for diagnosis instead of discarding it.
                let quarantine = root.appendingPathComponent("invalid-events", isDirectory: true)
                try TurnStylePaths.prepare(quarantine)
                let destination = quarantine.appendingPathComponent(UUID().uuidString + ".json")
                try FileManager.default.moveItem(at: url, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
        return result.sorted {
            $0.1.occurredAt == $1.1.occurredAt ? $0.1.id < $1.1.id : $0.1.occurredAt < $1.1.occurredAt
        }
    }
    public func acknowledge(_ files: [URL]) throws {
        for file in files { try FileManager.default.removeItem(at: file) }
    }
}

public struct QueuePersistence {
    public let root: URL
    public var file: URL { root.appendingPathComponent("queue.json") }
    public init(root: URL = TurnStylePaths.dataRoot) { self.root = root }
    public func load() throws -> QueueState {
        guard FileManager.default.fileExists(atPath: file.path) else { return QueueState() }
        return try JSONDecoder().decode(QueueState.self, from: Data(contentsOf: file))
    }
    public func save(_ state: QueueState) throws {
        try TurnStylePaths.prepare(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
