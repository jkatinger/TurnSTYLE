import Foundation
import SQLite3
import TurnStyleCore

final class TurnStyleCoreTests {
    var teardown: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { teardown.append(block) }
    deinit { for block in teardown { block() } }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ kind: EventKind, offset: TimeInterval = 0, session: String = "one", request: String? = nil)
        -> SessionEvent
    {
        SessionEvent(sessionID: session, kind: kind, occurredAt: start.addingTimeInterval(offset), requestID: request)
    }
    func temporary() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("turnstyle-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    func testActiveQueueKeepsRunningAndReadyTogether() {
        var state = QueueState()
        state.apply(event(.promptSubmitted, session: "chat"))
        state.apply(event(.responseFinished, session: "review"))
        var archived = TrackedSession(sessionID: "archived", title: "Archived", status: .running)
        archived.archived = true
        var done = TrackedSession(sessionID: "done", title: "Done", status: .running)
        done.done = true
        var snoozed = TrackedSession(sessionID: "snoozed", title: "Snoozed", status: .running)
        snoozed.snoozedIndefinitely = true
        var background = TrackedSession(sessionID: "background", title: "Background", status: .running)
        background.backgroundRun = true
        state.sessions += [archived, done, snoozed, background]
        assertEqual(Set(state.activeSessions(at: start).map(\.sessionID)), Set(["chat", "review"]))
        assertEqual(state.ready(at: start).map(\.sessionID), ["review"])
        state.apply(event(.responseFinished, offset: 1, session: "chat"))
        assertEqual(state.activeSessions(at: start).count, 2)
        assertEqual(state.ready(at: start).count, 2)
        state.apply(event(.promptSubmitted, offset: 2, session: "chat"))
        assertEqual(state.activeSessions(at: start).count, 2)
        assertEqual(state.ready(at: start).map(\.sessionID), ["review"])
    }

    func testGlobalSearchAndIndefiniteSnooze() throws {
        var state = QueueState()
        var working = TrackedSession(
            provider: "codex", sessionID: "working", title: "Café budget", workspace: "/Projects/Finance",
            status: .running, updatedAt: start)
        var snoozed = TrackedSession(sessionID: "snoozed", title: "Budget review", updatedAt: start)
        snoozed.snoozedIndefinitely = true
        var archived = TrackedSession(sessionID: "archived", title: "Budget history", updatedAt: start)
        archived.archived = true
        var done = TrackedSession(sessionID: "done", title: "Budget complete", updatedAt: start)
        done.done = true
        var hidden = TrackedSession(sessionID: "background", title: "Budget automation", updatedAt: start)
        hidden.backgroundRun = true
        state.sessions = [working, snoozed, archived, done, hidden]
        assertEqual(state.searchSessions("budget", at: start).count, 4)
        assertEqual(state.searchSessions("cafe FINANCE", at: start).map(\.sessionID), ["working"])
        assertEqual(state.searchSessions("budget archived", at: start).map(\.sessionID), ["archived"])
        assertEqual(state.searchSessions("budget snoozed", at: start).map(\.sessionID), ["snoozed"])
        assertEqual(state.searchSessions("   ", at: start).count, 0)
        assertTrue(snoozed.isSnoozed(at: start.addingTimeInterval(100 * 365 * 86400)))
        assertFalse(state.ready(at: start).contains { $0.sessionID == "snoozed" })
        let saved = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(state))
        assertTrue(saved.sessions[1].isSnoozed(at: start.addingTimeInterval(100 * 365 * 86400)))
        state.apply(event(.responseFinished, offset: 1, session: "snoozed"))
        assertTrue(state.sessions[1].isSnoozed(at: start.addingTimeInterval(5)))
        state.apply(event(.promptSubmitted, offset: 2, session: "snoozed"))
        assertFalse(state.sessions[1].isSnoozed(at: start.addingTimeInterval(5)))
        working.snoozedUntil = start.addingTimeInterval(60)
        assertTrue(working.isSnoozed(at: start))
        assertFalse(working.isSnoozed(at: start.addingTimeInterval(61)))
    }

    func testClaudeLocalCommandsAreNotChats() throws {
        let root = try temporary()
        let folder = root.appendingPathComponent("projects/test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let file = folder.appendingPathComponent(UUID().uuidString + ".jsonl")
        func record(_ text: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": text]])
            data.append(10)
            return data
        }
        try
            (record("<command-name>/mcp</command-name>")
            + record("<local-command-stdout>Connected</local-command-stdout>")).write(to: file)
        assertTrue(ClaudeSessionOrigin.isCommandOnly(transcriptPath: file.path))
        try assertEqual(HistoryImporter().discover(root: root).count, 0)
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": id, "prompt": "<command-name>/mcp</command-name>",
            "transcript_path": file.path,
        ])
        try assertNil(ClaudeProvider().event(from: payload))
        var state = QueueState()
        state.sessions = [
            TrackedSession(sessionID: id, title: "<command-name>/mcp</command-name>", transcriptPath: file.path)
        ]
        state.excludeBackgroundRuns()
        assertEqual(state.queueSessions.count, 0)
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: record("Explain this project"))
        try h.close()
        assertFalse(ClaudeSessionOrigin.isCommandOnly(transcriptPath: file.path))
        let history = try HistoryImporter().discover(root: root)
        assertEqual(history.first?.title, "Explain this project")
        var resumed = event(.promptSubmitted, session: id)
        resumed.title = "Explain this project"
        resumed.transcriptPath = file.path
        assertTrue(state.apply(resumed))
        assertEqual(state.queueSessions.count, 1)
    }

    func testInitialArchiveHasNoOngoingLimit() throws {
        var state = QueueState()
        state.codexQueueLimit = 2
        let candidates = (0..<12).map { i in
            TrackedSession(
                provider: i % 2 == 0 ? "claude" : "codex", sessionID: "initial-\(i)", title: "Chat \(i)",
                updatedAt: start.addingTimeInterval(Double(i)))
        }
        assertTrue(state.completeInitialArchive(candidates))
        assertEqual(state.sessions.count, 12)
        assertEqual(state.queueSessions.count, 5)
        assertEqual(Set(state.queueSessions.map(\.sessionID)), Set((7..<12).map { "initial-\($0)" }))
        assertNil(state.codexQueueLimit)
        assertEqual(state.sessions.filter { $0.archived == true }.count, 7)
        for i in 0..<8 {
            var e = event(.promptSubmitted, offset: 100 + Double(i), session: "new-\(i)")
            e.provider = "codex"
            state.apply(e)
        }
        assertEqual(state.queueSessions.count, 13)
        state.apply(event(.promptSubmitted, offset: 200, session: "initial-0"))
        assertEqual(state.queueSessions.count, 14)
        assertFalse(state.completeInitialArchive([]))
        assertEqual(state.queueSessions.count, 14)
        let restored = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(state))
        assertEqual(restored.queueSessions.count, 14)
        assertEqual(restored.initialArchiveCompleted, true)
        var remote = QueueState()
        var old = TrackedSession(
            provider: "codex", sessionID: "remote", title: "Remote", updatedAt: start, imported: true,
            hostID: "remote-control:test")
        remote.sessions = [old]
        remote.completeInitialArchive([], keep: 0)
        remote.mergeConnectedCatalog([old])
        assertEqual(remote.queueSessions.count, 0)
        old.updatedAt = start.addingTimeInterval(60)
        remote.mergeConnectedCatalog([old])
        assertEqual(remote.queueSessions.count, 1)
    }

    func testBackgroundClaudeRunsExcluded() throws {
        let root = try temporary()
        let projects = root.appendingPathComponent("projects/test")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let sdk = projects.appendingPathComponent(UUID().uuidString + ".jsonl")
        let desktop = projects.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data("{\"type\":\"user\",\"entrypoint\":\"sdk-cli\"}\n".utf8).write(to: sdk)
        try Data("{\"type\":\"user\",\"entrypoint\":\"claude-desktop\"}\n".utf8).write(to: desktop)
        assertTrue(ClaudeSessionOrigin.isBackground(transcriptPath: sdk.path))
        assertFalse(ClaudeSessionOrigin.isBackground(transcriptPath: desktop.path))
        assertFalse(ClaudeSessionOrigin.isBackground(transcriptPath: root.appendingPathComponent("missing").path))
        for kind in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "PermissionRequest"] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": kind, "session_id": "sdk", "transcript_path": sdk.path,
            ])
            try assertNil(ClaudeProvider().event(from: payload))
        }
        var state = QueueState()
        state.sessions = [
            TrackedSession(sessionID: "sdk", title: "Background", transcriptPath: sdk.path),
            TrackedSession(sessionID: "desktop", title: "Personal", transcriptPath: desktop.path),
        ]
        assertTrue(state.excludeBackgroundRuns())
        assertEqual(state.sessions.count, 2)
        assertEqual(state.queueSessions.map(\.sessionID), ["desktop"])
        assertEqual(state.ready(at: start).map(\.sessionID), ["desktop"])
        var event = self.event(.promptSubmitted, session: "new-sdk")
        event.transcriptPath = sdk.path
        assertFalse(state.apply(event))
        assertEqual(state.sessions.count, 2)
        let restored = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(state))
        assertEqual(restored.queueSessions.map(\.sessionID), ["desktop"])
        let history = try HistoryImporter().discover(root: root)
        assertEqual(history.count, 1)
        assertEqual(history.first?.sessionID, desktop.deletingPathExtension().lastPathComponent)
    }

    func testClaudeTitlesFollowRenamesAndPartialWrites() throws {
        let root = try temporary()
        let folder = root.appendingPathComponent("projects/test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("one.jsonl")
        let session = TrackedSession(sessionID: "one", title: "First prompt", workspace: "", transcriptPath: file.path)
        func record(_ type: String, _ name: String, sessionID: String = "one") throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": type, "sessionId": sessionID,
                type == "custom-title" ? "customTitle" : "aiTitle": name,
            ])
            data.append(10)
            return data
        }
        var reader = ClaudeTitles()
        try record("ai-title", "Generated name").write(to: file)
        assertEqual(reader.titles(for: [session], root: root)[session.id], "Generated name")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let renamed = try record("custom-title", "My renamed chat 🪩")
        try handle.write(contentsOf: renamed.dropLast(3))
        assertEqual(reader.titles(for: [session], root: root)[session.id], "Generated name")
        try handle.write(contentsOf: renamed.suffix(3))
        assertEqual(reader.titles(for: [session], root: root)[session.id], "My renamed chat 🪩")
        try handle.write(contentsOf: record("ai-title", "Later generated name"))
        try handle.write(contentsOf: record("custom-title", "Wrong session", sessionID: "other"))
        assertEqual(reader.titles(for: [session], root: root)[session.id], "My renamed chat 🪩")
        try handle.write(contentsOf: record("custom-title", "Second rename"))
        assertEqual(reader.titles(for: [session], root: root)[session.id], "Second rename")
        try record("custom-title", "Replaced transcript").write(to: file, options: .atomic)
        assertEqual(reader.titles(for: [session], root: root)[session.id], "Replaced transcript")
        var outside = session
        outside.transcriptPath = root.appendingPathComponent("one.jsonl").path
        try record("custom-title", "Outside projects").write(to: URL(fileURLWithPath: outside.transcriptPath!))
        assertTrue(reader.titles(for: [outside], root: root).isEmpty)
    }
    func testClaudeTitlesFindMetadataInLargeTranscripts() throws {
        let root = try temporary()
        let folder = root.appendingPathComponent("projects/test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("one.jsonl")
        var bytes = Data(repeating: 120, count: 300 * 1024)  // Oversized conversation record, discarded.
        bytes.append(10)
        bytes.append(
            Data("{\"type\":\"custom-title\",\"sessionId\":\"one\",\"customTitle\":\"Name in the middle\"}\n".utf8))
        bytes.append(Data(repeating: 10, count: 4 * 1024 * 1024))
        try bytes.write(to: file)
        let session = TrackedSession(sessionID: "one", title: "Fallback", workspace: "", transcriptPath: file.path)
        var reader = ClaudeTitles()
        assertTrue(reader.titles(for: [session], root: root).isEmpty)
        assertEqual(reader.titles(for: [session], root: root)[session.id], "Name in the middle")
    }
    func testCodexLifecycleAndPrivacy() throws {
        let provider = CodexProvider()
        func normalized(_ name: String, tool: String? = nil, offset: TimeInterval = 0) throws -> SessionEvent {
            var payload: [String: Any] = [
                "hook_event_name": name, "session_id": "shared-id", "cwd": "/test",
                "transcript_path": "/fixture/rollout.jsonl",
                "prompt": "First prompt", "last_assistant_message": "PRIVATE RESPONSE",
                "tool_input": ["secret": "PRIVATE TOOL"],
            ]
            if let tool {
                payload["tool_name"] = tool
                payload["tool_use_id"] = tool
            }
            return try unwrap(
                provider.event(
                    from: JSONSerialization.data(withJSONObject: payload), at: start.addingTimeInterval(offset)))
        }
        var state = QueueState()
        try assertFalse(state.apply(try normalized("SessionStart")))
        try assertFalse(state.apply(try normalized("SessionEnd")))
        assertTrue(state.sessions.isEmpty)
        state.apply(SessionEvent(sessionID: "shared-id", kind: .responseFinished, occurredAt: start))
        state.apply(try normalized("UserPromptSubmit"))
        assertEqual(state.sessions.count, 2)
        assertEqual(state.sessions[1].provider, "codex")
        assertEqual(state.sessions[1].status, .running)
        state.apply(try normalized("PreToolUse", tool: "functions.request_user_input", offset: 1))
        assertEqual(state.sessions[1].status, .needsInput)
        state.apply(try normalized("PermissionRequest", tool: "Bash", offset: 2))
        state.apply(try normalized("PostToolUse", tool: "functions.request_user_input", offset: 3))
        assertEqual(state.sessions[1].status, .needsApproval)
        state.apply(try normalized("PostToolUse", tool: "Bash", offset: 4))
        assertEqual(state.sessions[1].status, .running)
        // Codex PermissionRequest can omit tool_use_id while PostToolUse supplies it.
        var approval: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "shared-id", "tool_name": "Bash",
            "transcript_path": "/fixture/rollout.jsonl",
        ]
        let approved = try unwrap(
            provider.event(from: JSONSerialization.data(withJSONObject: approval), at: start.addingTimeInterval(4.1)))
        state.apply(approved)
        approval["hook_event_name"] = "PostToolUse"
        approval["tool_use_id"] = "actual-call-id"
        state.apply(
            try unwrap(
                provider.event(
                    from: JSONSerialization.data(withJSONObject: approval), at: start.addingTimeInterval(4.2))))
        assertEqual(state.sessions[1].status, .running)
        let stop = try normalized("Stop", offset: 5)
        let encoded = String(data: try JSONEncoder().encode(stop), encoding: .utf8)!
        assertFalse(encoded.contains("PRIVATE"))
        state.apply(stop)
        assertEqual(state.sessions[1].status, .ready)
        state.sessions[1].done = true
        state.apply(try normalized("Stop", offset: 6))
        assertTrue(state.sessions[1].done)
        state.apply(try normalized("UserPromptSubmit", offset: 7))
        assertFalse(state.sessions[1].done)
        state.apply(try normalized("Interrupt", offset: 8))
        assertEqual(state.sessions[1].status, .unknown)
        let compact: [String: Any] = [
            "hook_event_name": "SessionStart", "session_id": "shared-id", "source": "compact",
            "transcript_path": "/fixture/rollout.jsonl",
        ]
        try assertEqual(try provider.event(from: JSONSerialization.data(withJSONObject: compact))?.kind, .activity)
        let sub: [String: Any] = [
            "hook_event_name": "Stop", "session_id": "shared-id", "agent_id": "child",
            "transcript_path": "/fixture/rollout.jsonl",
        ]
        try assertNil(try provider.event(from: JSONSerialization.data(withJSONObject: sub)))
        let auxiliary: [String: Any] = [
            "hook_event_name": "UserPromptSubmit", "session_id": "suggestion", "prompt": "App-generated suggestion",
        ]
        try assertNil(try provider.event(from: JSONSerialization.data(withJSONObject: auxiliary)))
    }
    func testCodexHookMergeAndExactBackup() throws {
        let folder = try temporary()
        let helper = folder.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let file = folder.appendingPathComponent("hooks.json")
        let original = Data(
            "{ \"description\": \"Existing hooks\", \"hooks\": { \"Stop\": [{\"hooks\":[{\"type\":\"command\",\"command\":\"echo existing\"}]}] } }"
                .utf8)
        try original.write(to: file)
        let config = folder.appendingPathComponent("config.toml")
        let configBytes = Data("notify = [\"existing-notifier\"]\n[hooks.state]\n".utf8)
        try configBytes.write(to: config)
        let installer = HookInstaller(claudeRoot: folder, helper: helper, codex: true)
        let backup = try unwrap(installer.install())
        try assertEqual(try Data(contentsOf: backup), original)
        assertTrue(installer.installed())
        let installed = try Data(contentsOf: file)
        _ = try installer.install()
        try assertEqual(try Data(contentsOf: file), installed)
        try assertEqual(try Data(contentsOf: config), configBytes)
        _ = try installer.uninstall()
        assertFalse(installer.installed())
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let expected = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        assertTrue(NSDictionary(dictionary: remaining).isEqual(to: expected))
        try Data("broken".utf8).write(to: file)
        assertThrowsError(try installer.install())
        try assertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
    func testCodexNamesAndHistory() throws {
        let root = try temporary()
        let folder = root.appendingPathComponent("sessions/2026/11/01")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try Data(
            "{\"id\":\"main\",\"thread_name\":\"Old name\"}\n{\"id\":\"main\",\"thread_name\":\"Renamed Codex chat\"}\n{incomplete"
                .utf8
        ).write(to: index)
        for (id, source) in [("main", "vscode"), ("child", "subAgent")] {
            let record: [String: Any] = [
                "type": "session_meta", "payload": ["id": id, "source": source, "cwd": "/project"],
            ]
            var data = try JSONSerialization.data(withJSONObject: record)
            data.append(10)
            try data.write(to: folder.appendingPathComponent(id + ".jsonl"))
        }
        let sessions = try CodexHistory().discover(root: root)
        assertEqual(sessions.count, 1)
        assertEqual(sessions[0].title, "Renamed Codex chat")
        assertEqual(sessions[0].status, .unknown)
        assertEqual(sessions[0].provider, "codex")
        assertTrue(sessions[0].imported)
    }
    func testRemoteCodexHostIsolationAndReplay() throws {
        func snapshot(host: String, title: String, event: SessionEvent) throws -> RemoteCodexSnapshot {
            let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
            return try JSONDecoder().decode(
                RemoteCodexSnapshot.self,
                from: JSONSerialization.data(withJSONObject: [
                    "hostID": host, "hostName": "Mac Mini", "events": [item], "names": [event.sessionID: title],
                    "history": [],
                ]))
        }
        var state = QueueState()
        let prompt = SessionEvent(
            provider: "codex", sessionID: "same-session", kind: .promptSubmitted, occurredAt: start)
        state.apply(prompt)
        let remote = try snapshot(host: "mini", title: "Remote chat", event: prompt)
        state.applyRemote(remote)
        assertEqual(state.sessions.count, 2)
        assertEqual(Set(state.sessions.map(\.id)).count, 2)
        assertEqual(state.sessions[1].title, "Remote chat")
        assertEqual(state.remoteCodexAckIDs, [prompt.id])
        state.sessions[1].done = true
        state.applyRemote(remote)
        assertTrue(state.sessions[1].done)
        state.applyRemote(try snapshot(host: "other-mini", title: "Other host", event: prompt))
        assertEqual(state.sessions.count, 3)
        state.invalidateRemoteWorking(hostID: "mini")
        assertEqual(state.sessions[0].status, .running)
        assertEqual(state.sessions[1].status, .unknown)
        assertEqual(state.sessions[2].status, .running)
        let newPrompt = SessionEvent(
            provider: "codex", sessionID: "same-session", kind: .promptSubmitted,
            occurredAt: start.addingTimeInterval(1))
        state.applyRemote(try snapshot(host: "mini", title: "Renamed remote chat", event: newPrompt))
        assertFalse(state.sessions[1].done)
        assertEqual(state.sessions[1].title, "Renamed remote chat")
        assertEqual(state.sessions[0].title, "Codex conversation")
        let loaded = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(state))
        assertEqual(loaded.sessions[1].hostID, "mini")
        assertEqual(loaded.remoteCodexAckIDs, [newPrompt.id])
    }
    func testRemoteHistoryStartsUnknown() throws {
        let json = """
            {"hostID":"mini","hostName":"Test Mac mini","events":[],"names":{"old":"Saved sidebar name"},"history":[{"id":"old","title":"Fallback","workspace":"/remote/project","updatedAt":1800000000,"transcriptPath":"/remote/session.jsonl"}]}
            """
        let snapshot = try JSONDecoder().decode(RemoteCodexSnapshot.self, from: Data(json.utf8))
        let session = snapshot.historySessions()[0]
        assertEqual(session.title, "Saved sidebar name")
        assertEqual(session.status, .unknown)
        assertEqual(session.hostID, "mini")
        assertTrue(session.imported)
    }
    func testConnectedCodexCatalogIsReadOnlyAndHostScoped() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("catalog.db")
        var db: OpaquePointer?
        assertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT, cwd TEXT, source_updated_at REAL, source_recency_at REAL, missing_candidate INTEGER, source_kind TEXT);
            INSERT INTO local_thread_catalog VALUES ('remote-control:mini','019fa3dd-c884-7b43-a51a-638e46a0843f','Renamed remote chat','/remote',1800000000,1800000000,0,'vscode');
            INSERT INTO local_thread_catalog VALUES ('local','019fa3dd-c884-7b43-a51a-638e46a0843f','Local same ID','/local',1800000000,1800000000,0,'vscode');
            INSERT INTO local_thread_catalog VALUES ('remote-control:mini','01a19767-c42b-7cf1-af3d-bd87074d806e','Missing chat','/remote',1800000000,1800000000,1,'vscode');
            """
        assertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: file)
        let items = try CodexDesktopCatalog().discover(file: file)
        assertEqual(items.count, 1)
        assertEqual(items[0].title, "Renamed remote chat")
        assertEqual(items[0].hostID, "remote-control:mini")
        assertEqual(items[0].status, .unknown)
        try assertEqual(try Data(contentsOf: file), before)
    }
    func testCodexLinksPreserveConnectedHost() throws {
        let id = "019fa3dd-c884-7b43-a51a-638e46a0843f"
        var session = TrackedSession(
            provider: "codex", sessionID: id, title: "A remote chat", hostID: "remote-control:env_e_test")
        let url = try unwrap(session.codexURL)
        let components = try unwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        assertEqual(components.scheme, "codex")
        assertEqual(components.host, "threads")
        assertEqual(components.path, "/" + id)
        assertEqual(components.queryItems?.first(where: { $0.name == "hostId" })?.value, "remote-control:env_e_test")
        session.hostID = "independent-ssh-bridge-id"
        assertNil(session.codexURL)
        session.hostID = nil
        assertNotNil(session.codexURL)
        session.sessionID = "bad/path?injection"
        assertNil(session.codexURL)
    }
    func testUnifiedCatalogPreservesStatusAndUserChoices() {
        let candidate = TrackedSession(
            provider: "codex", sessionID: "remote", title: "Remote chat", hostID: "remote-control:mini")
        var state = QueueState()
        assertTrue(state.mergeConnectedCatalog([candidate]))
        assertEqual(state.ready(at: start).count, 1)
        assertEqual(state.sessions[0].status, .unknown)
        state.sessions[0].done = true
        var renamed = candidate
        renamed.title = "Renamed remote chat"
        assertTrue(state.mergeConnectedCatalog([renamed]))
        assertTrue(state.sessions[0].done)
        assertTrue(state.ready(at: start).isEmpty)
        state.sessions[0].done = false
        state.sessions[0].snoozedUntil = start.addingTimeInterval(100)
        state.sessions[0].status = .running
        assertFalse(state.mergeConnectedCatalog([renamed]))
        assertEqual(state.sessions[0].status, .running)
        assertEqual(state.sessions[0].snoozedUntil, start.addingTimeInterval(100))
        assertEqual(state.sessions.count, 1)
    }
    func testCodexQueueLimitKeepsTwoNewestAcrossHosts() throws {
        var state = QueueState()
        state.codexQueueLimit = 2
        let claude = TrackedSession(sessionID: "claude", title: "Claude", status: .ready, updatedAt: start)
        let old = TrackedSession(
            provider: "codex", sessionID: "old", title: "Old remote", updatedAt: start, hostID: "remote-control:mini")
        let recent = TrackedSession(
            provider: "codex", sessionID: "recent", title: "Recent remote", updatedAt: start.addingTimeInterval(1),
            hostID: "remote-control:mini")
        let local = TrackedSession(
            provider: "codex", sessionID: "local", title: "Current local", status: .running,
            updatedAt: start.addingTimeInterval(2))
        state.sessions = [claude, old, recent, local]
        assertEqual(Set(state.queueSessions.map(\.id)), Set([claude.id, recent.id, local.id]))
        assertFalse(state.ready(at: start).contains { $0.id == old.id })
        state.sessions[2].done = true
        assertFalse(state.ready(at: start).contains { $0.id == recent.id })
        assertEqual(state.queueSessions.filter { $0.provider == "codex" }.count, 2)
        let restored = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(state))
        assertEqual(restored.codexQueueLimit, 2)
        assertTrue(restored.sessions[2].done)
        state.apply(
            SessionEvent(
                provider: "codex", sessionID: "old", kind: .promptSubmitted, occurredAt: start.addingTimeInterval(3),
                hostID: "remote-control:mini"))
        assertTrue(state.queueSessions.contains { $0.id == old.id })
        assertFalse(state.queueSessions.contains { $0.id == recent.id })
    }
    func testClaudeDesktopLinksUseNativeSessionID() throws {
        let root = try temporary()
        let folder = root.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = UUID().uuidString.lowercased()
        let native = "local_" + UUID().uuidString.lowercased()
        let file = folder.appendingPathComponent(native + ".json")
        let bytes = try JSONSerialization.data(withJSONObject: [
            "sessionId": native, "cliSessionId": cli, "isArchived": false, "lastFocusedAt": 100,
            "title": "A renamed chat",
        ])
        try bytes.write(to: file)
        let resolver = ClaudeDesktopLinks()
        let link = try unwrap(resolver.url(sessionID: cli, root: root))
        let parts = try unwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        assertEqual(parts.scheme, "claude")
        assertEqual(parts.host, "code")
        assertEqual(parts.path, "/continue")
        assertEqual(parts.queryItems?.first?.value, native)
        assertFalse(link.absoluteString.contains(cli))
        try assertEqual(try Data(contentsOf: file), bytes)
        try assertNil(try resolver.url(sessionID: UUID().uuidString, root: root))
        try assertNil(try resolver.url(sessionID: "last", root: root))
        let archived = try JSONSerialization.data(withJSONObject: [
            "sessionId": native, "cliSessionId": cli, "isArchived": true,
        ])
        try archived.write(to: file)
        try assertNil(try resolver.url(sessionID: cli, root: root))
        try Data("broken".utf8).write(to: file)
        try assertNil(try resolver.url(sessionID: cli, root: root))
    }
    func testTurnMovesFromWorkingToReviewAndBack() {
        var state = QueueState()
        state.apply(event(.promptSubmitted))
        assertEqual(state.sessions[0].status, .running)
        state.apply(event(.responseFinished, offset: 1))
        assertEqual(state.ready(at: start).count, 1)
        state.apply(event(.promptSubmitted, offset: 2))
        assertTrue(state.ready(at: start).isEmpty)
    }
    func testDoneSurvivesLateNotificationsButNewPromptReopens() {
        var state = QueueState()
        state.apply(event(.responseFinished))
        state.sessions[0].done = true
        state.apply(event(.responseFinished, offset: 1))
        assertTrue(state.sessions[0].done)
        state.apply(event(.sessionEnded, offset: 2))
        assertTrue(state.sessions[0].done)
        state.apply(event(.promptSubmitted, offset: 3))
        assertFalse(state.sessions[0].done)
    }
    func testSnoozeExpiresAndReplyClearsSnooze() {
        var state = QueueState()
        state.apply(event(.responseFinished))
        state.sessions[0].snoozedUntil = start.addingTimeInterval(100)
        state.apply(event(.responseFinished, offset: 5))
        assertTrue(state.ready(at: start.addingTimeInterval(99)).isEmpty)
        assertEqual(state.ready(at: start.addingTimeInterval(101)).count, 1)
        state.apply(event(.promptSubmitted, offset: 105))
        assertNil(state.sessions[0].snoozedUntil)
    }
    func testUnrelatedToolDoesNotClearPendingApproval() {
        var state = QueueState()
        state.apply(event(.approvalRequested, request: "tool-a"))
        state.apply(event(.activity, offset: 1))
        state.apply(event(.requestResolved, offset: 2, request: "tool-b"))
        assertEqual(state.sessions[0].status, .needsApproval)
        state.apply(event(.requestResolved, offset: 3, request: "tool-a"))
        assertEqual(state.sessions[0].status, .running)
    }
    func testDuplicateAndOldEventsDoNotRegressState() {
        var state = QueueState()
        let latest = event(.responseFinished, offset: 5)
        assertTrue(state.apply(latest))
        assertFalse(state.apply(latest))
        assertFalse(state.apply(event(.promptSubmitted, offset: 1)))
        assertEqual(state.sessions[0].status, .ready)
    }
    func testRestartDoesNotClaimSavedRunningStateIsLive() {
        var state = QueueState()
        state.apply(event(.promptSubmitted))
        state.reconcileAfterRestart()
        assertEqual(state.sessions[0].status, .unknown)
    }
    func testBlockedAndOldestSortFirst() {
        var state = QueueState()
        state.apply(event(.responseFinished, session: "old-ready"))
        state.apply(event(.approvalRequested, offset: 50, session: "approval"))
        state.apply(event(.inputRequested, offset: 20, session: "question"))
        assertEqual(state.ready(at: start).map(\.sessionID), ["question", "approval", "old-ready"])
    }
    func testStartDoesNotClaimRunning() {
        var state = QueueState()
        state.apply(event(.sessionStarted))
        assertEqual(state.sessions[0].status, .unknown)
    }
    func testProviderMapsQuestionAndIgnoresSubagent() throws {
        let raw: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "one", "tool_name": "AskUserQuestion",
            "tool_use_id": "ask-1",
        ]
        let provider = ClaudeProvider()
        let mapped = try provider.event(from: JSONSerialization.data(withJSONObject: raw), at: start)
        assertEqual(mapped?.kind, .inputRequested)
        assertEqual(mapped?.requestID, "ask-1")
        var child = raw
        child["agent_id"] = "child"
        try assertNil(try provider.event(from: JSONSerialization.data(withJSONObject: child), at: start))
    }
    func testProviderDoesNotStoreToolInputOrAssistantText() throws {
        let raw: [String: Any] = [
            "hook_event_name": "Stop", "session_id": "one", "last_assistant_message": "sensitive tool result",
            "tool_input": ["secret": "sensitive value"],
        ]
        let mapped = try unwrap(ClaudeProvider().event(from: JSONSerialization.data(withJSONObject: raw), at: start))
        let encoded = String(data: try JSONEncoder().encode(mapped), encoding: .utf8)!
        assertFalse(encoded.contains("sensitive"))
    }
    func testInboxReplayAfterSaveIsIdempotent() throws {
        let root = try temporary()
        let inbox = EventInbox(root: root)
        let disk = QueuePersistence(root: root)
        let sent = event(.responseFinished)
        try inbox.enqueue(sent)
        let received = try inbox.pending()
        assertEqual(received.count, 1)
        var state = try disk.load()
        state.apply(received[0].1)
        try disk.save(state)
        var restored = try disk.load()
        assertFalse(restored.apply(received[0].1))
        try inbox.acknowledge(received.map(\.0))
        try assertTrue(try inbox.pending().isEmpty)
        assertEqual(restored.sessions.count, 1)
    }
    func testInboxQuarantinesInvalidFilesAndDoesNotFollowLinks() throws {
        let root = try temporary()
        let inbox = EventInbox(root: root)
        let valid = event(.responseFinished)
        try inbox.enqueue(valid)
        let damaged = inbox.folder.appendingPathComponent("damaged.json")
        try Data("{invalid".utf8).write(to: damaged)
        let oversized = inbox.folder.appendingPathComponent("oversized.json")
        try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: oversized)
        let outside = root.appendingPathComponent("outside.json")
        try JSONEncoder().encode(event(.promptSubmitted)).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: inbox.folder.appendingPathComponent("linked.json"), withDestinationURL: outside)
        let pending = try inbox.pending()
        assertEqual(pending.count, 1)
        assertEqual(pending.first?.1.id, valid.id)
        assertTrue(FileManager.default.fileExists(atPath: outside.path))
        let quarantine = root.appendingPathComponent("invalid-events")
        let files = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        assertEqual(files.count, 2)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            assertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        try inbox.acknowledge(pending.map(\.0))
        try assertTrue(try inbox.pending().isEmpty)
    }

    func testEventIDsCannotEscapeInbox() throws {
        let root = try temporary()
        let inbox = EventInbox(root: root)
        var sent = event(.responseFinished)
        sent.id = "../escaped"
        try inbox.enqueue(sent)
        assertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.json").path))
        let pending = try inbox.pending()
        assertEqual(pending.first?.1.id, sent.id)
        assertNotNil(UUID(uuidString: pending[0].0.deletingPathExtension().lastPathComponent))
    }

    func testColumnWidthsRejectInvalidPreferences() {
        let defaults = ColumnWidthPreferences.defaults
        assertEqual(ColumnWidthPreferences.load(nil), defaults)
        assertEqual(ColumnWidthPreferences.load([200]), defaults)
        assertEqual(ColumnWidthPreferences.load([.nan, .infinity, -1, 0, 1500, 120, 106]), defaults)
        let custom: [Double] = [500, 150, 80, 160, 140, 120, 106]
        assertEqual(ColumnWidthPreferences.load(custom), custom)
    }

    func testUninstallPreservesUnknownHookSchemas() throws {
        let root = try temporary()
        let original: [String: Any] = ["hooks": ["FutureEvent": [["hooks": "future schema", "keep": true]]]]
        let bytes = try JSONSerialization.data(withJSONObject: original)
        let installer = HookInstaller(claudeRoot: root, helper: URL(fileURLWithPath: "/usr/bin/true"))
        try bytes.write(to: installer.settingsFile)
        _ = try installer.install()
        _ = try installer.uninstall()
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsFile)) as! NSDictionary
        assertEqual(restored, original as NSDictionary)
    }

    func testPersistencePreservesChoicesAndIgnoresRetiredFields() throws {
        let disk = QueuePersistence(root: try temporary())
        var state = QueueState()
        state.apply(event(.responseFinished))
        state.sessions[0].done = true
        state.sessions[0].snoozedUntil = start
        state.remindersEnabled = false
        try disk.save(state)
        let restored = try disk.load()
        assertTrue(restored.sessions[0].done)
        assertFalse(restored.remindersEnabled)
        assertEqual(restored.sessions[0].snoozedUntil, start)
        // Older queue files may still contain the retired reminder-pause field.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy["pausedUntil"] = Date.distantFuture.timeIntervalSinceReferenceDate
        let migrated = try JSONDecoder().decode(QueueState.self, from: JSONSerialization.data(withJSONObject: legacy))
        assertTrue(migrated.sessions[0].done)
        assertEqual(migrated.sessions[0].snoozedUntil, start)
        assertFalse(migrated.remindersEnabled)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
        assertNil(saved["pausedUntil"])
    }
    func testHookInstallPreservesSettingsAndIsIdempotent() throws {
        let root = try temporary()
        let original: [String: Any] = [
            "permissions": ["allow": ["Read"]],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "existing-script"]]]]],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: original)
        try bytes.write(to: root.appendingPathComponent("settings.json"))
        let installer = HookInstaller(claudeRoot: root, helper: URL(fileURLWithPath: "/usr/bin/true"))
        let backup = try unwrap(installer.install())
        try assertEqual(try Data(contentsOf: backup), bytes)
        assertTrue(installer.installed())
        _ = try installer.install()
        let configured =
            try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsFile)) as! [String: Any]
        assertNotNil(configured["permissions"])
        let hooks = configured["hooks"] as! [String: Any]
        assertEqual((hooks["Stop"] as! [[String: Any]]).count, 2)
        _ = try installer.uninstall()
        assertFalse(installer.installed())
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsFile)) as! NSDictionary
        assertEqual(removed, original as NSDictionary)
    }
    func testMalformedSettingsAreNeverOverwritten() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("settings.json")
        let bytes = Data("{ broken".utf8)
        try bytes.write(to: file)
        let installer = HookInstaller(claudeRoot: root, helper: URL(fileURLWithPath: "/usr/bin/true"))
        assertThrowsError(try installer.install())
        try assertEqual(try Data(contentsOf: file), bytes)
    }
    func testDisabledHooksAreRespected() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("settings.json")
        let bytes = Data("{\"disableAllHooks\":true}".utf8)
        try bytes.write(to: file)
        assertThrowsError(
            try HookInstaller(claudeRoot: root, helper: URL(fileURLWithPath: "/usr/bin/true")).install())
        try assertEqual(try Data(contentsOf: file), bytes)
    }
    func testHistoryIsUnknownAndExcludesSubagents() throws {
        let root = try temporary()
        let project = root.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("subagents"), withIntermediateDirectories: true)
        let id = UUID().uuidString
        let record: [String: Any] = [
            "type": "user", "sessionId": id, "cwd": "/work/project", "message": ["content": "Finish the task"],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: record)
        try bytes.write(to: project.appendingPathComponent(id + ".jsonl"))
        try bytes.write(to: project.appendingPathComponent("subagents/" + UUID().uuidString + ".jsonl"))
        let result = try HistoryImporter().discover(root: root)
        assertEqual(result.count, 1)
        assertEqual(result[0].title, "Finish the task")
        assertEqual(result[0].status, .unknown)
        assertTrue(result[0].imported)
    }
}
