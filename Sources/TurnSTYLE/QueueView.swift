import AppKit
import SwiftUI
import TurnStyleCore
import UniformTypeIdentifiers

private let ink = AppPalette.text
private let sidebarBlack = Color(white: 0.025)
private let paper = AppPalette.chrome
private let tableCanvas = AppPalette.canvas
private let accent = Color(red: 0.42, green: 0.68, blue: 1.0)
private let brandBlue = AppPalette.blue
private let muted = AppPalette.secondary

extension SessionStatus {
    var tint: Color {
        switch self {
        case .needsApproval: return AppPalette.approval
        case .needsInput: return AppPalette.input
        case .ready: return AppPalette.ready
        case .failed: return AppPalette.failed
        case .running: return AppPalette.running
        case .unknown: return muted
        }
    }
    var symbol: String {
        switch self {
        case .needsApproval: return "hand.raised"
        case .needsInput: return "bubble.left.and.bubble.right"
        case .ready: return "checkmark.bubble"
        case .failed: return "exclamationmark.circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }
    var explanation: String {
        switch self {
        case .needsApproval: return "Claude is waiting for a permission decision. Open the conversation to review it."
        case .needsInput: return "Claude has asked for input. Your answer will help this conversation move forward."
        case .ready:
            return "Claude finished its response. Review it, keep the conversation going, or mark it done here."
        case .failed: return "The turn ended with an error. Check the conversation in Claude before continuing."
        case .running:
            return "Claude was working at the last update. Its status will update in Active when it needs attention."
        case .unknown:
            return "There isn’t a current live signal for this conversation. Open Claude to check where you left off."
        }
    }
}

struct QueueView: View {
    @ObservedObject var model: QueueModel
    @AppStorage("turnstyle.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("turnstyle.alwaysOnTop") private var alwaysOnTop = false
    private var appearanceOption: AppAppearance { AppAppearance(rawValue: appearance) ?? .system }
    @StateObject private var columns = SessionColumns()
    @StateObject private var shell = TableInteraction()
    @AppStorage("turnstyle.sidebarPinned") private var sidebarPinned = false
    @StateObject private var sidebarHover = SidebarHoverState()
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            HStack(spacing: 0) {
                if sidebarPinned && !compact {
                    sidebar.frame(width: 218)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 0) {
                    header(
                        compact: compact || geometry.size.width - (sidebarPinned && !compact ? 218 : 0) < 680,
                        overlaySidebar: compact
                    ).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
                    searchBar.padding(.horizontal, 20).padding(.bottom, 8)
                    if model.demo {
                        banner(
                            "Sample queue · Changes here don’t affect your real conversations",
                            color: AppPalette.workingHeader
                        ) { model.exitDemo() }
                    }
                    if let error = model.error { banner(error, color: AppPalette.errorSurface) { model.error = nil } }
                    if let message = model.message {
                        banner(message, color: AppPalette.successSurface) { model.message = nil }
                    }
                    if model.state.sessions.isEmpty {
                        welcome
                    } else {
                        queue.frame(maxWidth: .infinity)
                    }
                    footer
                }.background(paper)
            }
            .overlay(alignment: .leading) {
                if (!sidebarPinned || compact) && shell.drawer {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.12).onTapGesture { shell.drawer = false }
                            .allowsHitTesting(sidebarPinned)
                        sidebar.frame(width: 218)
                            .onHover { hovering in
                                sidebarHover.menuHovered = hovering
                                updateSidebarHover()
                            }
                            .shadow(color: .black.opacity(0.2), radius: 10, x: 4)

                    }
                }
            }
        }
        .foregroundStyle(ink)
        .preferredColorScheme(appearanceOption.scheme)
        .onAppear { appearanceOption.apply() }
        .onChange(of: appearance) { _, _ in appearanceOption.apply() }
        .onChange(of: sidebarPinned) { _, pinned in
            sidebarHover.cancelClose()
            shell.drawer = false
        }
        .onDisappear { sidebarHover.cancelClose() }
        .sheet(isPresented: $model.showSettings) { settings }
        .sheet(isPresented: $model.showHistory) { HistoryView(model: model) }
    }

    private func updateSidebarHover() {
        guard !sidebarPinned else { return }
        sidebarHover.cancelClose()
        if sidebarHover.hamburgerHovered || sidebarHover.menuHovered {
            withAnimation(.easeInOut(duration: 0.15)) { shell.drawer = true }
        } else {
            sidebarHover.closeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, !sidebarPinned,
                    !sidebarHover.hamburgerHovered, !sidebarHover.menuHovered
                else { return }
                withAnimation(.easeInOut(duration: 0.15)) { shell.drawer = false }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(accent)
                Text("TurnSTYLE").font(.system(size: 22, weight: .bold, design: .rounded)).tracking(-0.8)
            }.padding(.top, 14).padding(.bottom, 8)
            Button {
                sidebarPinned.toggle()
            } label: {
                Label(sidebarPinned ? "Pinned open" : "Auto-hide", systemImage: sidebarPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }.buttonStyle(.plain).help(sidebarPinned ? "Switch sidebar to auto-hide" : "Pin sidebar open")
                .accessibilityLabel(sidebarPinned ? "Unpin sidebar" : "Pin sidebar open")
                .padding(.bottom, 10)
            Text("ONE CONVERSATION AT A TIME").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(
                .white.opacity(0.45))
            VStack(spacing: 7) {
                ForEach(QueueFilter.allCases, id: \.self) { filter in
                    Button {
                        model.setFilter(filter)
                        shell.drawer = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: filter.symbol).frame(width: 18)
                            Text(filter.rawValue).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(model.count(filter))").font(
                                .system(size: 11, weight: .semibold, design: .monospaced)
                            )
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(
                                model.filter == filter ? Color.black.opacity(0.12) : Color.white.opacity(0.08),
                                in: Capsule())
                        }.padding(.horizontal, 13).padding(.vertical, 12)
                            .background(
                                model.filter == filter ? accent : .clear, in: RoundedRectangle(cornerRadius: 10)
                            )
                            .foregroundStyle(
                                model.filter == filter
                                    ? Color(red: 0.07, green: 0.11, blue: 0.18) : .white.opacity(0.73))
                    }.buttonStyle(.plain).accessibilityLabel("\(filter.rawValue), \(model.count(filter)) conversations")
                }
            }.padding(.top, 20)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("CONNECTED APPS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(
                    .white.opacity(0.4))
                HStack {
                    Image(systemName: "asterisk").foregroundStyle(Color(red: 0.90, green: 0.61, blue: 0.46))
                    Text("Claude Code").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Circle().fill(model.hooksInstalled ? accent : Color.orange).frame(width: 6, height: 6)
                }
                HStack {
                    Image(systemName: "terminal").foregroundStyle(accent)
                    Text("Codex").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Circle().fill(model.codexHooksInstalled ? accent : Color.orange).frame(width: 6, height: 6)
                }
                Text(
                    model.demo
                        ? "Previewing sample conversations"
                        : model.hooksInstalled || model.codexHooksInstalled
                            ? "Hooks installed · see settings" : "Connection needed"
                )
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.43))
            }.padding(.bottom, 26)
            Divider().overlay(.white.opacity(0.12))
            Button {
                model.showSettings = true
                model.refreshConnection()
            } label: {
                Label("Settings & connection", systemImage: "slider.horizontal.3").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).padding(.vertical, 22)
        }.padding(.horizontal, 20).frame(maxHeight: .infinity).background(sidebarBlack).foregroundStyle(.white)
    }

    private func header(compact: Bool, overlaySidebar: Bool) -> some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if overlaySidebar || !sidebarPinned { shell.drawer.toggle() } else { sidebarPinned = false }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(brandBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).foregroundStyle(brandBlue)
                    .onHover { hovering in
                        sidebarHover.hamburgerHovered = hovering
                        updateSidebarHover()
                    }
                    .help(sidebarPinned ? "Sidebar pinned open" : "Hover to show sidebar")
                    .accessibilityLabel(sidebarPinned ? "Unpin sidebar" : "Show sidebar")
                    .keyboardShortcut("s", modifiers: [.command, .control])
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model.searching
                            ? "\(model.visible.count) matching chats"
                            : model.filter == .active ? activeHeading : model.filter.rawValue
                    )
                    .font(.system(size: compact ? 20 : 22, weight: .semibold, design: .rounded)).tracking(-0.6)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    if !model.searching && model.filter != .active && !compact {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).help(subtitle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !compact { Spacer(minLength: 0) }
            HStack(spacing: 8) {
                if !compact { Text("Source").font(.system(size: 11)).foregroundStyle(muted) }
                Picker("Source", selection: Binding(get: { model.sourceFilter }, set: { model.setSourceFilter($0) })) {
                    ForEach(SourceFilter.allCases, id: \.self) { source in Text(source.rawValue).tag(source) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 130)
                    .accessibilityLabel("Filter chats by source")
                Menu {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled").frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Appearance: " + appearance).accessibilityLabel("Choose appearance")
            }
        }
    }
    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(muted)
            TextField("Search all chats and statuses", text: $model.searchQuery)
                .textFieldStyle(.plain).accessibilityLabel("Search across all chat statuses")
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(muted)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppPalette.grid))
    }
    private var activeHeading: String {
        let count = model.count(.active)
        return "\(count) active chat\(count == 1 ? "" : "s")"
    }
    private var subtitle: String {
        switch model.filter {
        case .active: return "Working chats and your next conversations, together."
        case .snoozed: return "Set aside for later, with a time to come back."
        case .done: return "Off your queue. Still available in the original app."
        case .archived: return "Archived in TurnSTYLE. Restore a chat here, or resume it in the original app."
        }
    }

    private var queue: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 40) {
                    if !model.searching && model.filter == .active {
                        tableCard(
                            "WORKING", sessions: model.working, availableWidth: geometry.size.width - 40,
                            empty: "No chats working right now.")
                        tableCard(
                            "UP NEXT", sessions: model.upNext, availableWidth: geometry.size.width - 40,
                            empty: "You’re caught up. Chats will appear here when they need attention.")
                    } else {
                        tableCard(
                            model.searching ? "SEARCH · ALL STATUSES" : "CONVERSATIONS", sessions: model.visible,
                            availableWidth: geometry.size.width - 40,
                            empty: model.searching
                                ? "No matching chats. Try another title, project, or source." : "Nothing here yet.")
                    }
                }.padding(.vertical, 16).padding(.horizontal, 20)
            }.background(tableCanvas)
        }
    }
    private func tableCard(_ title: String, sessions: [TrackedSession], availableWidth: CGFloat, empty: String)
        -> some View
    {
        let overflow = columns.total > availableWidth
        let bodyHeight = CGFloat(sessions.isEmpty ? 38 : sessions.count * 32)
        return VStack(spacing: 0) {
            tableHeading(title, count: sessions.count)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    SessionTableHeader(model: model, columns: columns, availableWidth: availableWidth)
                    LazyVStack(spacing: 0) {
                        tableRows(sessions, availableWidth: availableWidth, empty: empty)
                    }
                }.frame(width: max(columns.total, availableWidth))
                    .padding(.bottom, overflow ? 12 : 0)
            }.frame(width: availableWidth, height: 28 + bodyHeight + (overflow ? 12 : 0))
        }
        .frame(width: availableWidth)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppPalette.border, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
    }
    private func tableHeading(_ title: String, count: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    if title == "WORKING" || title == "UP NEXT" {
                        Image(systemName: title == "WORKING" ? "arrow.triangle.2.circlepath" : "tray.full")
                    }
                    Text("\(title) · \(count)").tracking(1.1)
                }.font(.system(size: 10, weight: .bold))
                    .foregroundStyle(title == "WORKING" ? brandBlue : ink)
                Spacer()
                Text(model.sortDescription).font(.system(size: 10)).foregroundStyle(muted)
            }.padding(.horizontal, 10).padding(.vertical, 11)
                .background(title == "WORKING" ? AppPalette.workingHeader : AppPalette.surface)
        }
    }
    @ViewBuilder private func tableRows(_ sessions: [TrackedSession], availableWidth: CGFloat, empty: String)
        -> some View
    {
        if sessions.isEmpty {
            Text(empty).font(.system(size: 11)).foregroundStyle(muted)
                .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).background(
                    AppPalette.surface)
        } else {
            ForEach(sessions) { session in
                SessionRow(model: model, columns: columns, session: session, availableWidth: availableWidth)
                    .zIndex(columns.hoveredSessionID == session.id ? 10 : 0)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Image(systemName: "tray.and.arrow.down").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(ink)
            Text("Give your conversations\na place to come back to.").font(
                .system(size: 34, weight: .medium, design: .rounded)
            ).tracking(-1)
            Text(
                "TurnSTYLE watches your local Claude Code and Codex sessions and gathers the ones ready for you. Respond in the original app, then come back for the next."
            )
            .font(.system(size: 15)).lineSpacing(5).foregroundStyle(muted).frame(maxWidth: 510)
            HStack(spacing: 12) {
                Button {
                    model.showSettings = true
                } label: {
                    Text("Connect your apps").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).tint(AppPalette.button)
                Button("Try the sample queue") { model.showDemo() }.buttonStyle(.bordered).controlSize(.large)
            }
            HStack(spacing: 26) {
                Label("Stays on your Mac", systemImage: "lock")
                Label("No API key needed", systemImage: "key")
            }.font(.system(size: 11)).foregroundStyle(muted).padding(.top, 8)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 48)
    }
    private var footer: some View {
        HStack {
            Circle().fill(model.demo ? muted : model.state.lastHookAt == nil ? Color.orange : Color.green).frame(
                width: 5, height: 5)
            Text(
                model.demo
                    ? "Sample data"
                    : model.state.lastHookAt == nil
                        ? "Waiting for the first event"
                        : "Last event \(model.state.lastHookAt!.formatted(date: .omitted, time: .shortened))")
            Spacer()
            if !model.demo { Button("Find older conversations") { model.loadHistory() }.buttonStyle(.plain) }
        }.font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 28).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(AppPalette.grid).frame(height: 1) }
    }
    private func banner(_ text: String, color: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            Button(model.demo && text.hasPrefix("Sample") ? "Exit preview" : "Dismiss", action: action)
                .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(color)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Make the connection.").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Spacer()
                    Button("Done") { model.showSettings = false }
                }
                Text("Appearance").font(.system(size: 14, weight: .semibold))
                Toggle("Always on top", isOn: $alwaysOnTop)
                    .toggleStyle(.switch)
                    .help("Keep TurnSTYLE above other app windows.")
                Picker("Color mode", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Picker("Sidebar", selection: $sidebarPinned) {
                    Text("Auto-hide").tag(false)
                    Text("Pinned open").tag(true)
                }.pickerStyle(.segmented)
                Text("Auto-hide opens on hamburger hover and closes when you leave the menu.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Divider()
                Text("Claude Code · Local sessions").font(.system(size: 14, weight: .semibold))
                Text(
                    "TurnSTYLE adds a small set of hooks to Claude’s settings. It keeps a backup and preserves your existing hooks. New events will appear here after you restart your local Code sessions."
                )
                .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(3)
                Label(
                    model.hooksInstalled ? "Hooks installed" : "Not connected",
                    systemImage: model.hooksInstalled ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(model.hooksInstalled ? Color.green : Color.orange)
                Text(model.root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button(model.hooksInstalled ? "Repair connection" : "Install Claude hooks") { model.connect() }
                        .buttonStyle(.borderedProminent).tint(AppPalette.button).disabled(model.demo)
                    Button("Choose settings folder…") { model.chooseRoot() }.disabled(model.demo)
                    if model.hooksInstalled { Button("Disconnect") { model.disconnect() }.disabled(model.demo) }
                }
                if let error = model.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
                if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(muted) }
                Divider()
                Text("Codex · Local sessions").font(.system(size: 14, weight: .semibold))
                Text(
                    "Preserves existing hooks and keeps an exact backup. After installing, review and trust the new TurnSTYLE hooks in Codex’s /hooks menu, then start a fresh local session."
                )
                .font(.system(size: 12)).foregroundStyle(muted)
                Label(
                    model.codexHooksInstalled ? "Hooks installed · trust required in Codex" : "Not connected",
                    systemImage: model.codexHooksInstalled ? "checkmark.circle" : "circle.dashed"
                )
                .font(.system(size: 12)).foregroundStyle(model.codexHooksInstalled ? Color.green : Color.orange)
                Text(model.codexRoot.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button(model.codexHooksInstalled ? "Repair Codex hooks" : "Install Codex hooks") {
                        model.connectCodex()
                    }.buttonStyle(.borderedProminent).tint(AppPalette.button).disabled(model.demo)
                    Button("Choose Codex folder…") { model.chooseCodexRoot() }.disabled(model.demo)
                    if model.codexHooksInstalled {
                        Button("Disconnect Codex") { model.disconnectCodex() }.disabled(model.demo)
                    }
                }
                Text(
                    model.state.lastCodexHookAt.map {
                        "Last Codex event " + $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "No Codex event received yet. Installed hooks alone do not confirm a live connection."
                )
                .font(.system(size: 11)).foregroundStyle(muted)
                Divider()
                Text(
                    "All eligible Claude and Codex chats can join the queue. Older chats from the initial import are recoverable in Archive."
                )
                .font(.system(size: 11)).foregroundStyle(muted)
                Text("Codex · Connected devices").font(.system(size: 14, weight: .semibold))
                Text(
                    "Uses the remote chat catalog already saved by this Mac’s Codex app. No SSH, Tailscale changes, or additional Mini setup are needed to browse names and open chats."
                )
                .font(.system(size: 12)).foregroundStyle(muted)
                Text(model.catalogMessage).font(.system(size: 11)).foregroundStyle(muted)
                Text(
                    "A globe beside a chat title indicates a remote session. Chats without a live status signal show Check status in Active."
                )
                .font(.system(size: 11)).foregroundStyle(muted)
                Divider()
                Text("Stay in the loop").font(.system(size: 14, weight: .semibold))
                Toggle(
                    "Remind me every 15 minutes while conversations need attention",
                    isOn: Binding(
                        get: { model.state.remindersEnabled },
                        set: {
                            model.state.remindersEnabled = $0
                            model.save()
                        })
                )
                .font(.system(size: 12))
                if !model.notificationAllowed { Button("Enable macOS notifications") { model.enableNotifications() } }
                Text(
                    "Notifications show a count, without conversation text. The menu bar queue stays available when you close this window."
                )
                .font(.system(size: 11)).foregroundStyle(muted)
                Divider()
                HStack {
                    Button("Find older conversations") {
                        model.showSettings = false
                        model.loadHistory()
                    }.disabled(model.demo)
                    Spacer()
                    Button(model.demo ? "Exit sample queue" : "Try sample queue") {
                        model.showSettings = false
                        if model.demo { model.exitDemo() } else { model.showDemo() }
                    }
                }
                Text("MVP 0.4 · Claude + Codex · Everything is stored locally").font(.system(size: 10)).foregroundStyle(
                    muted)
            }.padding(30)
        }.frame(width: 620, height: 720).background(paper).foregroundStyle(ink)
    }
}

@MainActor private final class SidebarHoverState: ObservableObject {
    var hamburgerHovered = false
    var menuHovered = false
    var closeTask: Task<Void, Never>?
    func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }
}

private final class SessionColumns: ObservableObject {
    @Published var hoveredSessionID: String?
    @Published var widths: [Double] = ColumnWidthPreferences.load(
        UserDefaults.standard.array(forKey: "turnstyle.columnWidths") as? [Double])
    @Published var order: [SessionColumn] = {
        let saved =
            UserDefaults.standard.stringArray(forKey: "turnstyle.columnOrder")?.compactMap(
                SessionColumn.init(rawValue:)) ?? []
        let visible = SessionColumn.allCases.filter { $0 != .location }
        let migrated = saved.filter { $0 != .location }
        return migrated.count == visible.count && Set(migrated) == Set(visible) ? migrated : visible
    }()
    @Published var dragging: SessionColumn?
    func move(_ column: SessionColumn, before target: SessionColumn) {
        guard column != target, let from = order.firstIndex(of: column), let to = order.firstIndex(of: target) else {
            return
        }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: from < to ? to + 1 : to)
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "turnstyle.columnOrder")
    }
    func displayWidth(_ column: SessionColumn, available: CGFloat) -> CGFloat {
        width(column) * max(1, available / total)
    }
    func width(_ column: SessionColumn) -> CGFloat { widths[SessionColumn.allCases.firstIndex(of: column)!] }
    var total: CGFloat { order.reduce(0) { $0 + width($1) } }
    func resize(_ column: SessionColumn, to width: CGFloat) {
        let index = SessionColumn.allCases.firstIndex(of: column)!
        widths[index] = min(1400, max(column == .actions ? 106 : column == .session ? 180 : 65, width))
        UserDefaults.standard.set(widths, forKey: "turnstyle.columnWidths")
    }
}

private struct SessionCell<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().lineLimit(1).padding(.horizontal, 9)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { Rectangle().fill(AppPalette.grid).frame(width: 0.5) }
    }
}

private struct SessionTableHeader: View {
    @ObservedObject var model: QueueModel
    @ObservedObject var columns: SessionColumns
    let availableWidth: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns.order, id: \.self) { column in
                SessionHeaderCell(model: model, columns: columns, column: column, availableWidth: availableWidth)
            }
        }.font(.system(size: 9, weight: .semibold)).foregroundStyle(muted).frame(height: 28)
            .background(AppPalette.header)
    }
}

private final class TableInteraction: ObservableObject {
    let tooltipID = UUID()
    @Published var drawer = false
    @Published var dragStart: CGFloat? = nil
    @Published var hovered = false
    @Published var showTip = false
}

private struct SessionHeaderCell: View {
    @ObservedObject var model: QueueModel
    @ObservedObject var columns: SessionColumns
    let column: SessionColumn
    let availableWidth: CGFloat
    @StateObject private var interaction = TableInteraction()
    var body: some View {
        SessionCell(width: columns.displayWidth(column, available: availableWidth)) {
            Button {
                model.sort(by: column)
            } label: {
                HStack(spacing: 5) {
                    Text(column.title)
                    if model.sortColumn == column {
                        Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(column == .actions)
                .accessibilityLabel("Sort by " + column.rawValue)
        }
        .onDrag {
            columns.dragging = column
            return NSItemProvider(object: ("turnstyle-column:" + column.rawValue) as NSString)
        }
        .onDrop(of: [UTType.text], delegate: ColumnDrop(columns: columns, target: column))
        .overlay(alignment: .trailing) {
            Rectangle().fill(brandBlue.opacity(interaction.dragStart == nil ? 0.15 : 0.7)).frame(width: 5)
                .contentShape(Rectangle())
                .onHover { hovering in if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture(minimumDistance: 1).onChanged { value in
                        if interaction.dragStart == nil { interaction.dragStart = columns.width(column) }
                        columns.resize(column, to: interaction.dragStart! + value.translation.width)
                    }.onEnded { _ in interaction.dragStart = nil }
                )
                .help("Drag to resize " + column.rawValue)
        }
    }
}

private struct ColumnDrop: DropDelegate {
    let columns: SessionColumns
    let target: SessionColumn
    func validateDrop(info: DropInfo) -> Bool { columns.dragging != nil }
    func dropEntered(info: DropInfo) {
        if let source = columns.dragging { columns.move(source, before: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        columns.dragging = nil
        return true
    }
}

@MainActor private final class ActionTooltipWindow: NSObject {
    static let shared = ActionTooltipWindow()
    private var panel: NSPanel?
    private var owner: UUID?
    private var menuTracking = false
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: nil)
    }
    @objc private func menuOpened(_ notification: Notification) {
        menuTracking = true
        hide()
    }
    @objc private func menuClosed(_ notification: Notification) { menuTracking = false }
    func show(_ text: String, owner: UUID) {
        guard !menuTracking, NSEvent.pressedMouseButtons == 0 else { return }
        hide()
        self.owner = owner
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 18, height: label.frame.height + 12)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSApp.appearance
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .toolTip
        background.blendingMode = .withinWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: 9, y: 6)
        background.addSubview(label)
        panel.contentView = background
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(
            NSPoint(
                x: min(max(mouse.x + 12, screen.minX), screen.maxX - size.width),
                y: max(screen.minY, mouse.y - size.height - 12)))
        self.panel = panel
        panel.orderFrontRegardless()
    }
    func hide(owner: UUID? = nil) {
        guard owner == nil || owner == self.owner else { return }
        panel?.orderOut(nil)
        panel = nil
        self.owner = nil
    }
}

private struct ActionHover: ViewModifier {
    let tooltip: String
    @StateObject private var interaction = TableInteraction()
    func body(content: Content) -> some View {
        content
            .background(interaction.hovered ? brandBlue.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onHover {
                interaction.hovered = $0
                if !$0 { ActionTooltipWindow.shared.hide(owner: interaction.tooltipID) }
            }
            .task(id: interaction.hovered) {
                guard interaction.hovered else { return }
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled && interaction.hovered {
                    ActionTooltipWindow.shared.show(tooltip, owner: interaction.tooltipID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                interaction.hovered = false
                ActionTooltipWindow.shared.hide(owner: interaction.tooltipID)
            }
            .onDisappear { ActionTooltipWindow.shared.hide(owner: interaction.tooltipID) }
    }
}

private struct SessionRow: View {
    @StateObject private var interaction = TableInteraction()
    @ObservedObject var model: QueueModel
    @ObservedObject var columns: SessionColumns
    let session: TrackedSession
    let availableWidth: CGFloat
    private var codex: Bool { session.provider == "codex" }
    private var background: Color {
        codex ? AppPalette.codexRow : AppPalette.claudeRow
    }
    private var sourceInk: Color {
        codex ? AppPalette.codexText : AppPalette.claudeText
    }
    private var snoozed: Bool { session.isSnoozed(at: model.now) }
    private var statusLabel: String {
        session.archived == true ? "Archived" : session.done ? "Done" : snoozed ? "Snoozed" : session.status.label
    }
    private var statusSymbol: String {
        session.archived == true
            ? "archivebox" : session.done ? "checkmark.circle" : snoozed ? "moon" : session.status.symbol
    }
    private var summary: String {
        if session.done { return "Marked done in TurnSTYLE. The conversation remains in \(session.appName)." }
        if snoozed && session.snoozedIndefinitely == true {
            return "Snoozed indefinitely. Restore here or send a new prompt in the original app to bring it back."
        }
        if snoozed, let date = session.snoozedUntil {
            return "Back in your queue \(date.formatted(date: .abbreviated, time: .shortened))."
        }
        if session.hostID?.hasPrefix("remote-control:") == true {
            return "Live status unavailable. Open this chat in Codex to check where you left off."
        }
        return session.status.explanation.replacingOccurrences(of: "Claude", with: session.appName)
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns.order, id: \.self) { column in
                cell(column)
            }
        }
        .font(.system(size: 11)).frame(height: 32)
        .background(background)
        .onHover { hovering in
            interaction.hovered = hovering
            if hovering {
                columns.hoveredSessionID = session.id
            } else if columns.hoveredSessionID == session.id {
                columns.hoveredSessionID = nil
            }
        }
        .zIndex(interaction.hovered ? 1 : 0)
        .overlay(alignment: .bottom) { Rectangle().fill(AppPalette.grid).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(session.providerName), \(session.hostID == nil ? "local" : "remote") conversation, \(session.title)")
    }
    @ViewBuilder private func cell(_ column: SessionColumn) -> some View {
        SessionCell(width: columns.displayWidth(column, available: availableWidth)) {
            switch column {
            case .session:
                HStack(spacing: 6) {
                    if session.hostID != nil {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(sourceInk)
                            .help("Remote session · " + session.originName)
                            .accessibilityLabel("Remote session")
                    }
                    Button {
                        model.openConversation(session)
                    } label: {
                        Text(session.title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(sourceInk).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(session.title + "\nOpen in " + session.appName)
                        .accessibilityLabel("Open \(session.title) in \(session.appName)")
                }
            case .source:
                Label(codex ? "Codex" : "Claude Code", systemImage: codex ? "terminal" : "asterisk")
                    .foregroundStyle(sourceInk)
            case .location:
                Label(
                    session.hostID == nil ? "Local" : "Remote",
                    systemImage: session.hostID == nil ? "laptopcomputer" : "network"
                )
                .foregroundStyle(sourceInk).help(session.originName)
            case .status:
                Label(statusLabel, systemImage: statusSymbol)
                    .foregroundStyle(session.done || snoozed ? muted : session.status.tint)
                    .help(summary)
            case .project:
                Text(session.projectName).foregroundStyle(muted).help(session.workspace)
            case .updated:
                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(muted)
                    .help(session.updatedAt.formatted(date: .abbreviated, time: .standard))
            case .actions:
                HStack(spacing: 6) {
                    if session.archived == true || session.done || snoozed {
                        Button {
                            model.restore(session.id)
                        } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 20, height: 22)
                        }
                        .modifier(ActionHover(tooltip: "Bring back to queue")).accessibilityLabel(
                            "Bring back \(session.title)")
                    } else {
                        Button {
                            model.markDone(session.id)
                        } label: {
                            Image(systemName: "checkmark").frame(width: 20, height: 22)
                        }
                        .modifier(ActionHover(tooltip: "Mark done")).accessibilityLabel("Mark \(session.title) done")
                        Menu {
                            Button("In 30 minutes") {
                                model.snooze(session.id, until: model.now.addingTimeInterval(1800))
                            }
                            Button("In 2 hours") { model.snooze(session.id, until: model.now.addingTimeInterval(7200)) }
                            Button("Tomorrow at 9 AM") { model.snooze(session.id, until: model.tomorrow) }
                            Divider()
                            Button("Indefinitely") { model.snoozeIndefinitely(session.id) }
                        } label: {
                            Image(systemName: "moon").frame(width: 20, height: 22)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .modifier(ActionHover(tooltip: "Snooze")).accessibilityLabel("Snooze \(session.title)")
                    }
                    Button {
                        model.copy(session.sessionID, confirmation: "Session ID copied.")
                    } label: {
                        Image(systemName: "doc.on.doc").frame(width: 20, height: 22)
                    }
                    .modifier(ActionHover(tooltip: "Copy session ID")).accessibilityLabel(
                        "Copy session ID for \(session.title)")
                }.buttonStyle(.plain).foregroundStyle(sourceInk)
            }
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var model: QueueModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Pick up an older conversation.").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Button("Cancel") { model.showHistory = false }
            }
            Text(
                "Choose which saved local conversations belong in your queue. They start at Check status until a new event arrives."
            )
            .font(.system(size: 12)).foregroundStyle(muted)
            if model.loadingHistory {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 32, weight: .light))
                    Text("No additional local conversations found.")
                    Text("Start a local Claude Code or Codex session, or choose its settings folder.").font(
                        .system(size: 12)
                    ).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.history) { session in
                    Toggle(
                        isOn: Binding(
                            get: { model.historySelection.contains(session.id) },
                            set: {
                                if $0 {
                                    model.historySelection.insert(session.id)
                                } else {
                                    model.historySelection.remove(session.id)
                                }
                            })
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).lineLimit(1)
                            Text(
                                "\(session.providerName) · \(session.originName) · \(session.projectName) · \(session.updatedAt.formatted(date: .abbreviated, time: .omitted))"
                            ).font(.system(size: 11)).foregroundStyle(muted)
                        }
                    }.toggleStyle(.checkbox).padding(.vertical, 5)
                }
            }
            HStack {
                Text("Up to 150 recent conversations").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Button("Add \(model.historySelection.count) to queue") { model.addHistory(model.historySelection) }
                    .buttonStyle(.borderedProminent).tint(AppPalette.button).disabled(model.historySelection.isEmpty)
            }
        }.padding(28).frame(width: 700, height: 510).background(paper).foregroundStyle(ink)
    }
}
