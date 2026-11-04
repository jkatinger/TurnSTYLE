import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case running, needsInput, needsApproval, ready, failed, unknown
    public var label: String {
        switch self {
        case .running: return "Working"
        case .needsInput: return "Needs your answer"
        case .needsApproval: return "Needs approval"
        case .ready: return "Ready for review"
        case .failed: return "Needs a check"
        case .unknown: return "Check status"
        }
    }
    public var needsAttention: Bool { self != .running }
    public var priority: Int {
        switch self {
        case .needsApproval, .needsInput: return 0
        case .failed: return 1
        case .ready: return 2
        case .unknown: return 3
        case .running: return 4
        }
    }
}

public enum EventKind: String, Codable, Sendable {
    case sessionStarted, promptSubmitted, activity, approvalRequested, inputRequested
    case requestResolved, responseFinished, failed, sessionEnded
}

/// Provider-neutral events shared by the Claude and Codex adapters.
public struct SessionEvent: Codable, Sendable {
    public var id: String
    public var provider: String
    public var hostID: String?
    public var hostName: String?
    public var sessionID: String
    public var occurredAt: Date
    public var kind: EventKind
    public var title: String?
    public var workspace: String?
    public var transcriptPath: String?
    public var requestID: String?
    public var requestFallbackID: String?
    public init(
        provider: String = "claude", sessionID: String, kind: EventKind,
        occurredAt: Date = Date(), title: String? = nil, workspace: String? = nil,
        transcriptPath: String? = nil, requestID: String? = nil, requestFallbackID: String? = nil,
        hostID: String? = nil, hostName: String? = nil
    ) {
        id = UUID().uuidString
        self.provider = provider
        self.sessionID = sessionID
        self.hostID = hostID
        self.hostName = hostName
        self.kind = kind
        self.occurredAt = occurredAt
        self.title = title
        self.workspace = workspace
        self.transcriptPath = transcriptPath
        self.requestID = requestID
        self.requestFallbackID = requestFallbackID
    }
}

public struct TrackedSession: Codable, Identifiable, Sendable {
    public var id: String { provider + ":" + (hostID.map { $0 + ":" } ?? "") + sessionID }
    public var provider: String
    public var hostID: String?
    public var hostName: String?
    public var sessionID: String
    public var title: String
    public var workspace: String
    public var transcriptPath: String?
    public var status: SessionStatus
    public var updatedAt: Date
    public var attentionSince: Date?
    public var lastEventAt: Date?
    public var pendingRequests: [String: SessionStatus]
    public var done: Bool
    public var snoozedUntil: Date?
    public var snoozedIndefinitely: Bool?
    public var commandOnly: Bool?
    public var archived: Bool?
    public var backgroundRun: Bool?
    public var imported: Bool
    public init(
        provider: String = "claude", sessionID: String, title: String,
        workspace: String = "", status: SessionStatus = .unknown, updatedAt: Date = Date(),
        transcriptPath: String? = nil, imported: Bool = false, hostID: String? = nil, hostName: String? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.title = title
        self.hostID = hostID
        self.hostName = hostName
        self.workspace = workspace
        self.status = status
        self.updatedAt = updatedAt
        self.transcriptPath = transcriptPath
        self.imported = imported
        attentionSince = status.needsAttention ? updatedAt : nil
        pendingRequests = [:]
        done = false
    }
    public func isSnoozed(at now: Date) -> Bool { snoozedIndefinitely == true || (snoozedUntil ?? .distantPast) > now }
    public func isReady(at now: Date) -> Bool { !done && !isSnoozed(at: now) && status.needsAttention }
    public var originName: String { hostName ?? (hostID == nil ? "This Mac" : "Remote Mac") }
    public var providerName: String { provider == "codex" ? "Codex" : "Claude Code" }
    public var appName: String { provider == "codex" ? "Codex" : "Claude" }
    public var defaultTitle: String { provider == "codex" ? "Codex conversation" : "Claude conversation" }
    public var projectName: String {
        workspace.isEmpty ? providerName : URL(fileURLWithPath: workspace).lastPathComponent
    }
}

public struct QueueState: Codable, Sendable {
    public var version = 1
    public var initialArchiveCompleted: Bool?
    public var codexQueueLimit: Int?
    public var sessions: [TrackedSession] = []
    public var remindersEnabled = true
    public var claudeRoot: String?
    public var codexRoot: String?
    public var lastCodexHookAt: Date?
    public var remoteCodexTarget: String?
    public var remoteCodexHostID: String?
    public var remoteCodexHostName: String?
    public var remoteCodexAckIDs: [String]?
    public var lastHookAt: Date?
    public var recentEventIDs: [String] = []
    public init() {}

    @discardableResult public mutating func apply(_ event: SessionEvent) -> Bool {
        guard !recentEventIDs.contains(event.id) else { return false }
        if event.provider == "claude", event.kind != .promptSubmitted,
            ClaudeSessionOrigin.isCommandOnly(transcriptPath: event.transcriptPath)
        {
            return false
        }
        if event.provider == "claude", let title = event.title, ClaudeSessionOrigin.isLocalCommand(title) {
            return false
        }
        if event.provider == "claude", ClaudeSessionOrigin.isBackground(transcriptPath: event.transcriptPath) {
            return false
        }
        // Opening/closing an empty Codex client is not a user conversation.
        if event.provider == "codex", [.sessionStarted, .sessionEnded].contains(event.kind),
            !sessions.contains(where: {
                $0.provider == event.provider && $0.sessionID == event.sessionID && $0.hostID == event.hostID
            })
        {
            return false
        }
        recentEventIDs.append(event.id)
        if recentEventIDs.count > 1024 { recentEventIDs.removeFirst(recentEventIDs.count - 1024) }
        let key = event.provider + ":" + (event.hostID.map { $0 + ":" } ?? "") + event.sessionID
        let index: Int
        if let existing = sessions.firstIndex(where: { $0.id == key }) {
            index = existing
        } else {
            sessions.append(
                TrackedSession(
                    provider: event.provider, sessionID: event.sessionID,
                    title: event.title ?? (event.provider == "codex" ? "Codex conversation" : "Claude conversation"),
                    workspace: event.workspace ?? "",
                    updatedAt: event.occurredAt, transcriptPath: event.transcriptPath, hostID: event.hostID,
                    hostName: event.hostName))
            index = sessions.count - 1
        }
        if let last = sessions[index].lastEventAt, event.occurredAt < last { return false }
        var session = sessions[index]
        let oldStatus = session.status
        session.lastEventAt = event.occurredAt
        session.updatedAt = event.occurredAt
        session.imported = false
        if let workspace = event.workspace, !workspace.isEmpty { session.workspace = workspace }
        if let path = event.transcriptPath { session.transcriptPath = path }
        if let title = event.title, !title.isEmpty,
            session.title == session.defaultTitle || session.title == session.projectName
                || (event.kind == .promptSubmitted && ClaudeSessionOrigin.isLocalCommand(session.title))
        {
            session.title = title
        }
        switch event.kind {
        case .sessionStarted:
            // Opening/resuming a session is not proof that a model turn is running.
            session.status = .unknown
            session.pendingRequests = [:]
        case .promptSubmitted:
            session.status = .running
            session.pendingRequests = [:]
            session.done = false
            session.snoozedUntil = nil
            session.snoozedIndefinitely = false
            session.archived = false
            session.commandOnly = false
        case .activity:
            if session.pendingRequests.isEmpty { session.status = .running }
        case .approvalRequested:
            session.status = .needsApproval
            if let key = event.requestID { session.pendingRequests[key] = .needsApproval }
        case .inputRequested:
            session.status = .needsInput
            if let key = event.requestID { session.pendingRequests[key] = .needsInput }
        case .requestResolved:
            if let key = event.requestID { session.pendingRequests.removeValue(forKey: key) }
            if let key = event.requestFallbackID { session.pendingRequests.removeValue(forKey: key) }
            session.status =
                session.pendingRequests.values.contains(.needsApproval)
                ? .needsApproval
                : session.pendingRequests.isEmpty ? .running : .needsInput
        case .responseFinished:
            session.status = .ready
            session.pendingRequests = [:]
        case .failed:
            session.status = .failed
            session.pendingRequests = [:]
        case .sessionEnded:
            session.status = .unknown
            session.pendingRequests = [:]
        }
        if !session.status.needsAttention {
            session.attentionSince = nil
        } else if !oldStatus.needsAttention || session.attentionSince == nil {
            session.attentionSince = event.occurredAt
        }
        sessions[index] = session
        if event.provider == "codex" && event.hostID == nil {
            lastCodexHookAt = max(lastCodexHookAt ?? .distantPast, event.occurredAt)
        }
        lastHookAt = max(lastHookAt ?? .distantPast, event.occurredAt)
        return true
    }

    public var queueSessions: [TrackedSession] {
        sessions.filter { $0.backgroundRun != true && $0.commandOnly != true && $0.archived != true }
    }

    /// One-time initial import and cleanup. Later events have no count limit.
    @discardableResult public mutating func completeInitialArchive(_ candidates: [TrackedSession], keep: Int = 5)
        -> Bool
    {
        guard initialArchiveCompleted != true else { return false }
        mergeConnectedCatalog(candidates)
        var known = Set(sessions.map(\.id))
        for candidate in candidates where known.insert(candidate.id).inserted { sessions.append(candidate) }
        excludeBackgroundRuns()
        let latest = sessions.filter { $0.backgroundRun != true && $0.commandOnly != true }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        let retained = Set(latest.prefix(max(0, keep)).map(\.id))
        for i in sessions.indices where sessions[i].backgroundRun != true {
            sessions[i].archived = !retained.contains(sessions[i].id)
        }
        codexQueueLimit = nil
        initialArchiveCompleted = true
        return true
    }

    /// Metadata search includes archived, done, snoozed and working chats.
    public func searchSessions(_ query: String, at now: Date) -> [TrackedSession] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map {
            String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        guard !terms.isEmpty else { return [] }
        return sessions.filter { session in
            guard session.backgroundRun != true, session.commandOnly != true else { return false }
            let status =
                session.archived == true
                ? "archived archive"
                : session.done ? "done" : session.isSnoozed(at: now) ? "snoozed" : session.status.label
            let text = [
                session.title, session.workspace, session.providerName, session.originName,
                session.hostID == nil ? "local" : "remote", status, session.sessionID,
            ]
            .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    public func activeSessions(at now: Date) -> [TrackedSession] {
        queueSessions.filter { !$0.done && !$0.isSnoozed(at: now) }
    }

    public func ready(at now: Date) -> [TrackedSession] {
        queueSessions.filter { $0.isReady(at: now) }.sorted {
            if $0.status.priority != $1.status.priority { return $0.status.priority < $1.status.priority }
            return ($0.attentionSince ?? $0.updatedAt) < ($1.attentionSince ?? $1.updatedAt)
        }
    }

    @discardableResult public mutating func excludeBackgroundRuns() -> Bool {
        var changed = false
        for i in sessions.indices
        where sessions[i].provider == "claude" && sessions[i].backgroundRun != true
            && (sessions[i].archived != true || ClaudeSessionOrigin.isLocalCommand(sessions[i].title))
        {
            let command = ClaudeSessionOrigin.isCommandOnly(transcriptPath: sessions[i].transcriptPath)
            if command && sessions[i].commandOnly != true {
                sessions[i].commandOnly = true
                changed = true
            }
            let background = ClaudeSessionOrigin.isBackground(transcriptPath: sessions[i].transcriptPath)
            if background && sessions[i].backgroundRun != true {
                sessions[i].backgroundRun = true
                changed = true
            }
        }
        return changed
    }

    public mutating func reconcileAfterRestart() {
        excludeBackgroundRuns()
        for i in sessions.indices where sessions[i].status == .running {
            sessions[i].status = .unknown
            sessions[i].attentionSince = Date()
        }
    }
}

public protocol SessionProvider {
    var id: String { get }
    var displayName: String { get }
    func event(from data: Data, at date: Date) throws -> SessionEvent?
}
