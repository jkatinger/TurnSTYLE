import Foundation

/// Official Codex command-hook inputs; outputs nothing and never makes decisions.
public struct CodexProvider: SessionProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public init() {}
    public func event(from data: Data, at date: Date = Date()) throws -> SessionEvent? {
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = input["hook_event_name"] as? String,
            let session = input["session_id"] as? String, !session.isEmpty,
            input["agent_id"] == nil,
            let transcript = input["transcript_path"] as? String,
            !transcript.isEmpty
        else { return nil }
        // App-internal suggestion/composer tasks have no saved conversation transcript.
        // They are auxiliary work, not sidebar conversations for the user's queue.
        let tool = input["tool_name"] as? String
        let request = input["tool_use_id"] as? String ?? tool
        let kind: EventKind
        var requestID: String?
        switch name {
        case "SessionStart": kind = input["source"] as? String == "compact" ? .activity : .sessionStarted
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse":
            kind =
                tool == "request_user_input" || tool?.hasSuffix(".request_user_input") == true
                    || tool?.hasSuffix("__request_user_input") == true ? .inputRequested : .activity
            if kind == .inputRequested { requestID = request }
        case "PermissionRequest":
            kind = .approvalRequested
            requestID = request
        case "PostToolUse":
            kind = .requestResolved
            requestID = request
        case "Stop": kind = .responseFinished
        case "Interrupt", "SessionEnd": kind = .sessionEnded
        default: return nil
        }
        let prompt = (input["prompt"] as? String)?.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        return SessionEvent(
            provider: id, sessionID: session, kind: kind, occurredAt: date,
            title: prompt.map { String($0.prefix(100)) }, workspace: input["cwd"] as? String,
            transcriptPath: transcript, requestID: requestID, requestFallbackID: name == "PostToolUse" ? tool : nil)
    }
}
