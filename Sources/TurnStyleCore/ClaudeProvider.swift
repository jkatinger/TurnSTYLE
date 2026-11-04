import Foundation

public struct ClaudeProvider: SessionProvider {
    public let id = "claude"
    public let displayName = "Claude Code"
    public init() {}
    public func event(from data: Data, at date: Date = Date()) throws -> SessionEvent? {
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = input["hook_event_name"] as? String,
            let session = input["session_id"] as? String, !session.isEmpty
        else { return nil }
        // Main conversations only. Subagent results should not become separate queue rows.
        if input["agent_id"] != nil { return nil }
        if ClaudeSessionOrigin.isBackground(transcriptPath: input["transcript_path"] as? String) { return nil }
        if let prompt = input["prompt"] as? String, ClaudeSessionOrigin.isLocalCommand(prompt) { return nil }
        if name != "UserPromptSubmit",
            ClaudeSessionOrigin.isCommandOnly(transcriptPath: input["transcript_path"] as? String)
        {
            return nil
        }
        let tool = input["tool_name"] as? String
        let toolID = input["tool_use_id"] as? String ?? tool
        var requestID: String?
        let kind: EventKind
        switch name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse":
            kind = tool == "AskUserQuestion" ? .inputRequested : .activity
            if kind == .inputRequested { requestID = toolID }
        case "PostToolUse", "PostToolUseFailure":
            kind = .requestResolved
            requestID = toolID
        case "PermissionRequest":
            kind = .approvalRequested
            requestID = toolID
        case "Elicitation":
            kind = .inputRequested
            requestID = "elicitation"
        case "ElicitationResult":
            kind = .requestResolved
            requestID = "elicitation"
        case "Stop": kind = .responseFinished
        case "StopFailure": kind = .failed
        case "SessionEnd": kind = .sessionEnded
        case "Notification":
            switch input["notification_type"] as? String {
            case "permission_prompt": kind = .approvalRequested
            case "idle_prompt": kind = .responseFinished
            case "elicitation_dialog", "elicitation_url_dialog": kind = .inputRequested
            default: return nil
            }
        default: return nil
        }
        let prompt = (input["prompt"] as? String)?.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        let title = prompt.map { String($0.prefix(100)) }
        return SessionEvent(
            provider: id, sessionID: session, kind: kind, occurredAt: date,
            title: title, workspace: input["cwd"] as? String,
            transcriptPath: input["transcript_path"] as? String, requestID: requestID)
    }
}
