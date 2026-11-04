import AppKit
import SwiftUI
import TurnStyleCore
import UserNotifications

private actor ClaudeTitleWorker {
    func connectedCatalog(root: URL) throws -> [TrackedSession] {
        try CodexDesktopCatalog().discover(file: root.appendingPathComponent("sqlite/codex.db"), limit: Int(Int32.max))
    }
    private var reader = ClaudeTitles()
    func titles(for sessions: [TrackedSession], root: URL, codexRoot: URL) -> [String: String] {
        var result = reader.titles(for: sessions, root: root)
        if let names = try? CodexHistory().names(root: codexRoot) {
            for session in sessions where session.provider == "codex" && session.hostID == nil {
                result[session.id] = names[session.sessionID]
            }
        }
        return result
    }
}

enum SourceFilter: String, CaseIterable {
    case both = "Both"
    case claude = "Claude Code"
    case codex = "Codex"
    func includes(_ session: TrackedSession) -> Bool {
        self == .both || session.provider == (self == .claude ? "claude" : "codex")
    }
}

enum SessionColumn: String, CaseIterable {
    case session, source, location, status, project, updated, actions
    var title: String { rawValue.uppercased() }
}

enum QueueFilter: String, CaseIterable {
    case active = "Active"
    case snoozed = "Snoozed"
    case done = "Done"
    case archived = "Archive"
    var symbol: String {
        switch self {
        case .active: return "tray.full"
        case .snoozed: return "moon"
        case .done: return "checkmark.circle"
        case .archived: return "archivebox"
        }
    }
}

@MainActor final class QueueModel: ObservableObject {
    @Published var state = QueueState()
    @Published var filter: QueueFilter = .active
    @Published var searchQuery = ""
    var searching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Published var sourceFilter: SourceFilter = .both
    @Published var sortColumn: SessionColumn = .updated
    @Published var sortAscending = false
    func sort(by column: SessionColumn) {
        guard column != .actions else { return }
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = column != .updated
        }
    }
    var sortDescription: String {
        sortColumn == .updated
            ? (sortAscending ? "Oldest first" : "Newest first")
            : "\(sortColumn.rawValue.capitalized) · \(sortAscending ? "A–Z" : "Z–A")"
    }
    private func sorted(_ sessions: [TrackedSession]) -> [TrackedSession] {
        func value(_ session: TrackedSession) -> String {
            switch sortColumn {
            case .session: return session.title
            case .source: return session.providerName
            case .location: return session.hostID == nil ? "Local" : "Remote"
            case .status: return session.done ? "Done" : session.isSnoozed(at: now) ? "Snoozed" : session.status.label
            case .project: return session.projectName
            default: return ""
            }
        }
        return sessions.sorted { a, b in
            let order: ComparisonResult =
                sortColumn == .updated
                ? (a.updatedAt == b.updatedAt
                    ? .orderedSame : a.updatedAt < b.updatedAt ? .orderedAscending : .orderedDescending)
                : value(a).localizedStandardCompare(value(b))
            if order == .orderedSame { return a.id < b.id }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }
    @Published var selection: String?
    @Published var error: String?
    @Published var message: String?
    @Published var now = Date()
    @Published var demo = false
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var history: [TrackedSession] = []
    @Published var historySelection: Set<String> = []
    @Published var loadingHistory = false
    @Published var hooksInstalled = false
    @Published var codexHooksInstalled = false
    @Published var connectedSessions: [TrackedSession] = []
    @Published var catalogMessage = "Reading Codex’s saved connected-device catalog…"
    private var catalogRefreshing = false
    private var lastCatalogRefresh = Date.distantPast
    @Published var remoteTargetDraft = ""
    @Published var remoteConnectionMessage = "Not connected"
    @Published var remoteBusy = false
    private var remoteHistory: [TrackedSession] = []
    private let remoteClient = RemoteCodexClient()
    private var lastRemoteRefresh = Date.distantPast
    @Published var notificationAllowed = false
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var lastNudge = Date.distantPast
    private var unreadableState = false
    private let disk = QueuePersistence()
    private let inbox = EventInbox()
    private let titleWorker = ClaudeTitleWorker()
    private var refreshingTitles = false
    private var lastTitleRefresh = Date.distantPast

    init() {
        do {
            state = try disk.load()
            if state.excludeBackgroundRuns() { try disk.save(state) }
            state.reconcileAfterRestart()
        } catch {
            self.error = "Your saved queue could not be read. It has been preserved. \(error.localizedDescription)"
            unreadableState = true
        }
        remoteTargetDraft = state.remoteCodexTarget ?? ""
        refreshConnection()
        tick()
        importAndArchiveInitially()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.notificationAllowed = settings.authorizationStatus == .authorized }
        }
    }
    var root: URL { URL(fileURLWithPath: state.claudeRoot ?? NSHomeDirectory() + "/.claude", isDirectory: true) }
    var codexRoot: URL {
        URL(
            fileURLWithPath: state.codexRoot ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()
                + "/.codex", isDirectory: true)
    }
    var codexInstaller: HookInstaller { HookInstaller(claudeRoot: codexRoot, helper: helper, codex: true) }
    var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/turnstyle-hook") }
    var installer: HookInstaller { HookInstaller(claudeRoot: root, helper: helper) }
    var allReady: [TrackedSession] { state.ready(at: now) }
    var ready: [TrackedSession] { allReady.filter { sourceFilter.includes($0) } }
    var filteredSessions: [TrackedSession] { state.queueSessions.filter { sourceFilter.includes($0) } }
    func setSourceFilter(_ value: SourceFilter) {
        sourceFilter = value
        selection = visible.first?.id
        onChange?()
    }
    var working: [TrackedSession] {
        sorted(state.activeSessions(at: now).filter { sourceFilter.includes($0) && $0.status == .running })
    }
    var upNext: [TrackedSession] { sorted(ready) }
    var selected: TrackedSession? { visible.first { $0.id == selection } }
    var visible: [TrackedSession] {
        if searching { return sorted(state.searchSessions(searchQuery, at: now).filter { sourceFilter.includes($0) }) }
        switch filter {
        case .active: return working + upNext
        case .snoozed: return sorted(filteredSessions.filter { !$0.done && $0.isSnoozed(at: now) })
        case .done: return sorted(filteredSessions.filter(\.done))
        case .archived:
            return sorted(
                state.sessions.filter {
                    $0.archived == true && $0.backgroundRun != true && $0.commandOnly != true
                        && sourceFilter.includes($0)
                })
        }
    }
    func count(_ filter: QueueFilter) -> Int {
        switch filter {
        case .active: return working.count + upNext.count
        case .snoozed: return filteredSessions.filter { !$0.done && $0.isSnoozed(at: now) }.count
        case .done: return filteredSessions.filter(\.done).count
        case .archived:
            return state.sessions.filter {
                $0.archived == true && $0.backgroundRun != true && $0.commandOnly != true && sourceFilter.includes($0)
            }.count
        }
    }
    func save() {
        guard !demo, !unreadableState else {
            onChange?()
            return
        }
        do { try disk.save(state) } catch { self.error = "Could not save your queue: \(error.localizedDescription)" }
        onChange?()
    }
    func tick() {
        now = Date()
        guard !demo, !unreadableState else { return }
        do {
            let pending = try inbox.pending()
            if !pending.isEmpty {
                var next = state
                for (_, event) in pending { next.apply(event) }
                // Persist before acknowledging. On a crash, replay is idempotent.
                try disk.save(next)
                state = next
                try inbox.acknowledge(pending.map(\.0))
            }
        } catch { self.error = "Could not update the queue: \(error.localizedDescription)" }
        if state.excludeBackgroundRuns() { save() }
        refreshCatalogIfNeeded()
        refreshTitlesIfNeeded()
        if selection != nil && !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
        if state.remindersEnabled && notificationAllowed && now.timeIntervalSince(lastNudge) >= 900 {
            let count = allReady.filter { $0.status != .unknown }.count
            if count > 0 {
                notify(count: count)
                lastNudge = now
            }
        }
        onChange?()
    }
    private func importAndArchiveInitially() {
        guard state.initialArchiveCompleted != true, !unreadableState else { return }
        let claudeFolder = root
        let codexFolder = codexRoot
        Task {
            do {
                let candidates = try await Task.detached {
                    try HistoryImporter().discover(root: claudeFolder)
                        + CodexHistory().discover(root: codexFolder)
                        + CodexDesktopCatalog().discover(file: codexFolder.appendingPathComponent("sqlite/codex.db"))
                }.value
                guard !demo else { return }
                if state.completeInitialArchive(candidates) { save() }
                tick()
            } catch { self.error = "Initial chat import could not finish: " + error.localizedDescription }
        }
    }
    private func refreshCatalogIfNeeded() {
        guard state.initialArchiveCompleted == true else { return }
        guard !catalogRefreshing, now.timeIntervalSince(lastCatalogRefresh) >= 6 else { return }
        catalogRefreshing = true
        lastCatalogRefresh = now
        let folder = codexRoot
        Task {
            defer { catalogRefreshing = false }
            do {
                let discovered = try await titleWorker.connectedCatalog(root: folder)
                guard !demo, !unreadableState, codexRoot == folder else { return }
                connectedSessions = discovered
                if state.mergeConnectedCatalog(discovered) { save() }
                catalogMessage =
                    "\(discovered.count) saved remote chats · names refresh through Codex. Live status is unavailable from this catalog."
            } catch { catalogMessage = error.localizedDescription }
        }
    }
    func connectRemoteCodex() {
        guard !demo, !remoteBusy else { return }
        let target = remoteTargetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteBusy = true
        remoteConnectionMessage = "Installing the bridge over SSH…"
        Task {
            defer { remoteBusy = false }
            do {
                guard let script = Bundle.main.url(forResource: "remote-codex-bridge", withExtension: "py") else {
                    throw SetupError.invalid("The packaged remote bridge is missing.")
                }
                let hostID = try await remoteClient.install(target: target, helper: helper, script: script)
                if let previous = state.remoteCodexHostID, previous != hostID {
                    state.invalidateRemoteWorking(hostID: previous)
                }
                state.remoteCodexTarget = target
                state.remoteCodexHostID = hostID
                state.remoteCodexAckIDs = []
                lastRemoteRefresh = .distantPast
                save()
                remoteConnectionMessage =
                    "Installed. Review the new --turnstyle-remote-hook commands in Codex’s /hooks menu on the Mini, then send a prompt there."
                message = remoteConnectionMessage
            } catch { remoteConnectionMessage = error.localizedDescription }
        }
    }
    func disconnectRemoteCodex() {
        guard !remoteBusy else { return }
        if let hostID = state.remoteCodexHostID { state.invalidateRemoteWorking(hostID: hostID) }
        state.remoteCodexTarget = nil
        remoteHistory = []
        save()
        remoteConnectionMessage =
            "Sync disconnected. The Mini’s hook collector remains installed; see README for removal."
    }
    private func refreshRemoteIfNeeded() {
        guard let target = state.remoteCodexTarget, !remoteBusy,
            now.timeIntervalSince(lastRemoteRefresh) >= 6
        else { return }
        remoteBusy = true
        lastRemoteRefresh = now
        let ack = state.remoteCodexAckIDs ?? []
        Task {
            defer { remoteBusy = false }
            do {
                let snapshot = try await remoteClient.snapshot(target: target, ack: ack)
                guard !demo, !unreadableState, state.remoteCodexTarget == target else { return }
                if let expected = state.remoteCodexHostID, expected != snapshot.hostID {
                    throw SetupError.invalid(
                        "The remote bridge identity changed. Reconnect this host in Settings to review it.")
                }
                var next = state
                next.applyRemote(snapshot)
                try disk.save(next)
                state = next
                remoteHistory = snapshot.historySessions()
                remoteConnectionMessage =
                    "\(snapshot.hostName) · Last sync \(Date().formatted(date: .omitted, time: .shortened))"
                    + (snapshot.historyError.map { " · " + $0 } ?? "")
                onChange?()
            } catch {
                guard state.remoteCodexTarget == target else { return }
                remoteConnectionMessage = "Sync unavailable · " + error.localizedDescription
                if let hostID = state.remoteCodexHostID {
                    state.invalidateRemoteWorking(hostID: hostID)
                    save()
                }
            }
        }
    }
    private func refreshTitlesIfNeeded() {
        guard !refreshingTitles, now.timeIntervalSince(lastTitleRefresh) >= 5 else { return }
        refreshingTitles = true
        lastTitleRefresh = now
        let sessions = state.sessions
        let folder = root
        let codexFolder = codexRoot
        Task {
            let titles = await titleWorker.titles(for: sessions, root: folder, codexRoot: codexFolder)
            defer { refreshingTitles = false }
            guard !demo, !unreadableState, root == folder, codexRoot == codexFolder else { return }
            let originalPaths = Dictionary(
                sessions.map { ($0.id, $0.transcriptPath) }, uniquingKeysWith: { first, _ in first })
            var changed = false
            for index in state.sessions.indices {
                let session = state.sessions[index]
                guard let originalPath = originalPaths[session.id],
                    originalPath == session.transcriptPath,
                    let title = titles[session.id], session.title != title
                else { continue }
                state.sessions[index].title = title
                changed = true
            }
            if changed { save() }
        }
    }
    func refreshConnection() {
        hooksInstalled = installer.installed()
        codexHooksInstalled = codexInstaller.installed()
    }
    func connectCodex() {
        guard !demo else { return }
        do {
            _ = try codexInstaller.install()
            state.codexRoot = codexRoot.path
            save()
            refreshConnection()
            message =
                "Codex hooks installed with a settings backup. Review and trust the new TurnSTYLE hooks in Codex’s /hooks menu, then start a fresh local session. No trust or permission settings were changed."
        } catch { self.error = error.localizedDescription }
    }
    func disconnectCodex() {
        guard !demo else { return }
        do {
            _ = try codexInstaller.uninstall()
            refreshConnection()
            message =
                "TurnSTYLE’s Codex hooks removed. Restart affected sessions. Your queue and other hooks are preserved."
        } catch { self.error = error.localizedDescription }
    }
    func chooseCodexRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose your Codex home folder containing hooks.json and sessions."
        panel.directoryURL = codexRoot
        if panel.runModal() == .OK, let url = panel.url {
            state.codexRoot = url.path
            save()
            refreshConnection()
        }
    }
    func connect() {
        guard !demo else { return }
        do {
            _ = try installer.install()
            state.claudeRoot = root.path
            save()
            refreshConnection()
            message =
                "Hooks installed. Restart your local Claude Code sessions to load them. TurnSTYLE will confirm when the first event arrives. A settings backup was retained."
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        guard !demo else { return }
        do {
            _ = try installer.uninstall()
            refreshConnection()
            message =
                "TurnSTYLE hooks removed. Restart your Claude Code sessions. Your queue and other Claude settings remain available."
        } catch { self.error = error.localizedDescription }
    }
    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the Claude settings folder containing settings.json and projects."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            state.claudeRoot = url.path
            save()
            refreshConnection()
        }
    }
    func setFilter(_ value: QueueFilter) {
        searchQuery = ""
        filter = value
        selection = visible.first?.id
    }
    func next() {
        setFilter(.active)
        selection = ready.first?.id
    }
    func change(_ id: String, _ update: (inout TrackedSession) -> Void) {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        update(&state.sessions[i])
        save()
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }
    func markDone(_ id: String) {
        change(id) {
            $0.done = true
            $0.snoozedUntil = nil
            $0.snoozedIndefinitely = false
        }
    }
    func restore(_ id: String) {
        change(id) {
            $0.done = false
            $0.snoozedUntil = nil
            $0.snoozedIndefinitely = false
            $0.archived = false
        }
    }
    func snooze(_ id: String, until date: Date) {
        change(id) {
            $0.snoozedUntil = date
            $0.snoozedIndefinitely = false
        }
    }
    func snoozeIndefinitely(_ id: String) {
        change(id) {
            $0.snoozedUntil = nil
            $0.snoozedIndefinitely = true
        }
    }
    var tomorrow: Date {
        let day = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    }
    func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            [weak self] allowed, error in
            Task { @MainActor in
                self?.notificationAllowed = allowed
                if let error { self?.error = error.localizedDescription }
            }
        }
    }
    private func notify(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "TurnSTYLE"
        content.body = "\(count) conversation\(count == 1 ? " is" : "s are") ready for your attention."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "turnstyle-queue", content: content, trigger: nil))
    }
    func copy(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = confirmation
    }
    func openConversation(_ session: TrackedSession) {
        if demo {
            message = "This is a sample conversation. Connect Claude to use real sessions."
            return
        }
        // Use verified provider routes; Claude requires its native Desktop ID, not the hook UUID.
        if let url = session.codexURL {
            NSWorkspace.shared.open(url)
            return
        }
        if session.provider == "claude" {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
            Task {
                do {
                    let url = try await Task.detached {
                        try ClaudeDesktopLinks().url(sessionID: session.sessionID, root: folder)
                    }.value
                    guard let url else {
                        error =
                            "Claude’s exact Desktop session could not be found for this chat. Open the chat in Claude once, then try again."
                        return
                    }
                    if !NSWorkspace.shared.open(url) { error = "macOS could not open this Claude session link." }
                } catch { self.error = "Could not resolve the Claude Desktop session: " + error.localizedDescription }
            }
            return
        }
        let identifiers =
            session.provider == "codex" ? ["com.openai.codex", "com.openai.chat"] : ["com.anthropic.claudefordesktop"]
        guard let app = identifiers.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else {
            error =
                "macOS could not locate \(session.appName). Open it normally, then find this conversation by its title."
            return
        }
        copy(session.title, confirmation: "Title copied. Find this conversation in \(session.appName)’s sidebar.")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
    func loadHistory() {
        guard !demo else { return }
        loadingHistory = true
        showHistory = true
        historySelection = []
        let folder = root
        let codexFolder = codexRoot
        Task {
            do {
                let result = try await Task.detached {
                    let claude = try HistoryImporter().discover(root: folder)
                    let codex = try CodexHistory().discover(root: codexFolder)
                    return Array((claude + codex).sorted { $0.updatedAt > $1.updatedAt }.prefix(150))
                }.value
                let ids = Set(state.sessions.map(\.id))
                history = Array(
                    (result + remoteHistory + connectedSessions).filter { !ids.contains($0.id) }.sorted {
                        $0.updatedAt > $1.updatedAt
                    }.prefix(150))
            } catch { self.error = error.localizedDescription }
            loadingHistory = false
        }
    }
    func addHistory(_ ids: Set<String>) {
        let existing = Set(state.sessions.map(\.id))
        state.sessions += history.filter { ids.contains($0.id) && !existing.contains($0.id) }
        save()
        showHistory = false
        next()
    }
    func showDemo() {
        demo = true
        state = QueueState()
        state.lastHookAt = now
        let examples: [(String, String, SessionStatus, TimeInterval)] = [
            ("Finalize the launch brief", "Launch planning", .needsInput, 4800),
            ("Review the customer research", "Research", .needsApproval, 1800),
            ("Draft next week’s team update", "Team updates", .ready, 900),
            ("Check the website changes", "Website", .running, 240),
            ("Revisit the onboarding flow", "Product", .ready, 7200),
        ]
        for (i, item) in examples.enumerated() {
            var session = TrackedSession(
                sessionID: "sample-\(i)", title: item.0,
                workspace: "/Sample projects/" + item.1, status: item.2, updatedAt: now.addingTimeInterval(-item.3))
            if i == 4 { session.snoozedUntil = tomorrow }
            state.sessions.append(session)
        }
        next()
        onChange?()
    }
    func exitDemo() {
        demo = false
        do {
            state = try disk.load()
            state.reconcileAfterRestart()
            error = nil
        } catch {
            unreadableState = true
            self.error = error.localizedDescription
        }
        refreshConnection()
        tick()
        next()
    }
}
