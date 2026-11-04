import Foundation

public enum SetupError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

public struct HookInstaller {
    public static let marker = "--turnstyle-hook"
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
        "SessionEnd", "Elicitation", "ElicitationResult",
    ]
    public static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "Stop", "Interrupt", "SessionEnd",
    ]
    public let codex: Bool
    private var eventNames: [String] { codex ? Self.codexEvents : Self.events }
    private var hookMarker: String { codex ? "--turnstyle-codex-hook" : Self.marker }
    private var appName: String { codex ? "Codex" : "Claude" }
    public let claudeRoot: URL
    public let helper: URL
    public init(claudeRoot: URL, helper: URL, codex: Bool = false) {
        self.claudeRoot = claudeRoot
        self.helper = helper
        self.codex = codex
    }
    public var settingsFile: URL { claudeRoot.appendingPathComponent(codex ? "hooks.json" : "settings.json") }
    public var command: String { "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + hookMarker }

    private func settings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any]
        else {
            throw SetupError.invalid("\(appName) settings are not a JSON object. No changes were made.")
        }
        return object
    }

    public func installed() -> Bool {
        guard let object = try? settings(), let hooks = object["hooks"] as? [String: Any] else { return false }
        return eventNames.allSatisfy { name in
            (hooks[name] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
            }
        }
    }

    public func install() throws -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw SetupError.invalid(
                "\(appName)’s local settings folder was not found. Open a local session in \(appName), then try again.")
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SetupError.invalid(
                "The TurnSTYLE helper is missing. Run the packaged app from its installed location.")
        }
        var object = try settings()
        if object["disableAllHooks"] as? Bool == true || object["allowManagedHooksOnly"] as? Bool == true {
            throw SetupError.invalid(
                "\(appName) settings disable personal hooks. TurnSTYLE has left those settings unchanged.")
        }
        var hooks = try validatedHooks(object)
        for name in eventNames {
            var groups = hooks[name] as? [[String: Any]] ?? []
            // Remove only our own prior entries, retaining other hooks in the same group.
            groups = cleaned(groups)
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 3]]]
            if ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"].contains(name) {
                group["matcher"] = "*"
            }
            if name == "Notification" {
                group["matcher"] = "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog"
            }
            hooks[name] = groups + [group]
        }
        object["hooks"] = hooks
        return try writeWithBackup(object)
    }

    public func uninstall() throws -> URL? {
        var object = try settings()
        var hooks = try validatedHooks(object)
        for name in Array(hooks.keys) {
            if let groups = hooks[name] as? [[String: Any]] {
                let remaining = cleaned(groups)
                if remaining.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = remaining }
            }
        }
        object["hooks"] = hooks
        return try writeWithBackup(object)
    }

    private func validatedHooks(_ object: [String: Any]) throws -> [String: Any] {
        guard let value = object["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw SetupError.invalid("\(appName)’s hooks setting is malformed. No changes were made.")
        }
        for (name, value) in hooks where eventNames.contains(name) {
            guard let groups = value as? [[String: Any]], groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
                throw SetupError.invalid("\(appName)’s \(name) hooks could not be read safely. No changes were made.")
            }
        }
        return hooks
    }

    private func cleaned(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { original in
            var group = original
            // Unknown hook event schemas belong to the provider, not us.
            guard let existing = group["hooks"] as? [[String: Any]] else { return original }
            let entries = existing.filter { entry in
                guard let command = entry["command"] as? String else { return true }
                return !command.hasSuffix(" " + hookMarker)
            }
            guard !entries.isEmpty else { return nil }
            group["hooks"] = entries
            return group
        }
    }

    private func writeWithBackup(_ object: [String: Any]) throws -> URL? {
        let bytes = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var backup: URL?
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            let folder = claudeRoot.appendingPathComponent("turnstyle-backups")
            try TurnStylePaths.prepare(folder)
            let path = folder.appendingPathComponent("settings-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: settingsFile, to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            backup = path
        }
        try bytes.write(to: settingsFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
        return backup
    }
}
