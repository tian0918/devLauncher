import SwiftUI

struct MainView: View {
    private enum SidebarFocus: Hashable {
        case list
        case search
    }

    @ObservedObject var model: LauncherModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var runningOnly = false
    @State private var editing: Project?
    @State private var editingAlias: Project?
    @State private var creatingBranchFor: Project?
    @State private var showingGitHistory = false
    @State private var showingImport = false
    @State private var confirmingRemoval = false
    @State private var available = true
    @State private var openingTerminal = false
    @State private var copiedPath = false
    @State private var pathCopyTask: Task<Void, Never>?
    @FocusState private var sidebarFocus: SidebarFocus?

    private var filtered: [Project] {
        model.projects.filter { project in
            if runningOnly && model.runState(project.id).phase != .running {
                return false
            }
            guard !search.isEmpty else { return true }
            return project.listName.localizedStandardContains(search)
                || project.name.localizedStandardContains(search)
                || project.path.localizedStandardContains(search)
        }
    }

    private var selected: Project? {
        model.projects.first { $0.id == model.selection }
    }

    private var runningCount: Int {
        model.runs.values.filter { $0.phase == .running }.count
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 232, ideal: 274, max: 350)
        } detail: {
            Group {
                if let project = selected {
                    detail(project)
                        .id(project.id)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LauncherPalette.canvas)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("nvm 设置")
            }
        }
        .sheet(item: $editing) { ProjectEditor(project: $0, model: model) }
        .sheet(item: $editingAlias) { ProjectAliasEditor(project: $0, model: model) }
        .sheet(item: $creatingBranchFor) { project in
            GitCreateBranchSheet(
                project: project,
                baseBranch: model.gitStatus(project.id)?.branch,
                model: model
            )
        }
        .sheet(isPresented: $showingImport, onDismiss: model.cancelScan) {
            ImportSheet(model: model)
        }
        .onChange(of: model.scanResult != nil) { _, ready in
            if ready { showingImport = true }
        }
        .onChange(of: runningCount) { _, count in
            if count == 0 { runningOnly = false }
        }
        .onChange(of: selected?.path, initial: true) { _, _ in
            copiedPath = false
            showingGitHistory = false
            pathCopyTask?.cancel()
            refreshFolderAvailability()
            if let project = selected {
                model.refreshGit(for: project)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFolderAvailability()
            model.refreshInstalledIDEs()
            model.refreshTerminalTools()
            model.refreshAllGit()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshFolderAvailability()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshFolderAvailability()
        }
        .alert("Dev Launcher", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )) {
            Button("好") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("项目")
                    .font(.system(size: 14, weight: .semibold))
                if !model.projects.isEmpty {
                    Text("\(model.projects.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(LauncherPalette.actionInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LauncherPalette.selection, in: Capsule())
                }
                Spacer()
                SidebarIconButton(systemImage: "plus", accessibilityLabel: "添加项目", helpText: "添加项目（⌘O）") {
                    selectProjects(model)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sidebarFocus == .search ? LauncherPalette.actionInk : .secondary)
                TextField("搜索项目或路径", text: $search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($sidebarFocus, equals: .search)
                    .accessibilityLabel("搜索项目")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        sidebarFocus == .search ? LauncherPalette.focusRing : LauncherPalette.line,
                        lineWidth: sidebarFocus == .search ? 1.25 : 1
                    )
            }
            .animation(.easeOut(duration: 0.14), value: sidebarFocus == .search)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            projectList

            Rectangle().fill(LauncherPalette.line).frame(height: 1)
            sidebarFooter
        }
        .background(LauncherPalette.sidebar)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("正在扫描…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: model.cancelScan)
                    .buttonStyle(.borderless)
                    .foregroundStyle(LauncherPalette.actionInk)
            } else {
                if runningCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            runningOnly.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(LauncherPalette.running)
                                .frame(width: 6, height: 6)
                            Text("\(runningCount) 个运行中")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(runningOnly ? LauncherPalette.running : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            runningOnly ? LauncherPalette.runningFill : LauncherPalette.surface,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(runningOnly ? LauncherPalette.runningEdge : LauncherPalette.line)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(runningOnly ? "显示全部项目" : "仅显示运行中的项目")
                } else {
                    Text("\(model.projects.count) 个项目")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if runningOnly {
                    Button("全部") {
                        withAnimation(.easeInOut(duration: 0.15)) { runningOnly = false }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LauncherPalette.actionInk)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { project in
                        ProjectRowView(
                            project: project,
                            phase: model.runState(project.id).phase,
                            gitStatus: model.gitStatus(project.id),
                            selected: project.id == model.selection,
                            listFocused: sidebarFocus == .list,
                            onSelect: {
                                model.selection = project.id
                                sidebarFocus = .list
                            }
                        )
                        .id(project.id)
                        .contextMenu {
                            openInIDEMenu(project)
                            Menu("在终端中打开") {
                                terminalMenuContent(project)
                            }
                            Button("编辑列表别名…") { editingAlias = project }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($sidebarFocus, equals: .list)
            .defaultFocus($sidebarFocus, .list)
            .focusEffectDisabled()
            .accessibilityLabel("项目列表")
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onMoveCommand { direction in
                switch direction {
                case .up: moveProjectSelection(by: -1)
                case .down: moveProjectSelection(by: 1)
                default: break
                }
            }
            .overlay {
                if filtered.isEmpty && (!search.isEmpty || runningOnly) {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(runningOnly && search.isEmpty ? "没有运行中的项目" : "没有匹配的项目")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("重置筛选") {
                            search = ""
                            runningOnly = false
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LauncherPalette.actionInk)
                    }
                    .padding(16)
                }
            }
        }
    }

    private func moveProjectSelection(by offset: Int) {
        let projects = filtered
        guard let first = projects.first else { return }
        guard let currentIndex = projects.firstIndex(where: { $0.id == model.selection }) else {
            model.selection = offset > 0 ? first.id : projects.last?.id
            return
        }
        let nextIndex = currentIndex + offset
        if projects.indices.contains(nextIndex) { model.selection = projects[nextIndex].id }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LauncherPalette.selection)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(LauncherPalette.selectionEdge.opacity(0.7))
                    .frame(width: 68, height: 68)
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(LauncherPalette.actionInk)
            }
            .shadow(color: LauncherPalette.cardShadow(colorScheme), radius: 8, y: 3)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(model.projects.isEmpty ? "添加你的第一个项目" : "选择一个项目")
                    .font(.title2.weight(.semibold))
                if model.projects.isEmpty {
                    Text("选择 Node.js 或 Python 项目文件，或扫描包含多个项目的文件夹。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if model.projects.isEmpty {
                Button { selectProjects(model) } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .buttonStyle(ProjectActionStyle(tone: .primary))
                .focusEffectDisabled()
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ project: Project) -> some View {
        let state = model.runState(project.id)
        return VStack(alignment: .leading, spacing: 16) {
            header(project, state: state)

            if let git = model.gitStatus(project.id) {
                gitBar(project, status: git)
            }

            configuration(project, state: state)

            if !available {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LauncherPalette.warning)
                    Text("项目文件夹不可用。连接磁盘后再试，或重新定位项目。")
                        .font(.callout)
                        .foregroundStyle(LauncherPalette.warning)
                    Spacer(minLength: 8)
                    Button("重新定位…") { relocate(project) }
                        .buttonStyle(ProjectActionStyle(size: .compact))
                        .focusEffectDisabled()
                        .disabled(state.phase.isActive)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(LauncherPalette.warningFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(LauncherPalette.warningEdge)
                }
            }

            ConsoleView(
                state: state,
                clearLog: { model.clearLog(project.id) },
                installAndRestart: { model.installAndRestart(project.id) }
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .confirmationDialog("移除「\(project.name)」？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除项目", role: .destructive) { model.remove(project.id) }
        } message: {
            Text("这会从项目列表移除该项目。磁盘上的文件会保留。")
        }
    }

    private func header(_ project: Project, state: RunState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusLabel(phase: state.phase, style: .pill)
                    ProjectKindBadge(kind: project.kind)
                    if let alias = project.listAlias {
                        Text("别名：\(alias)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(LauncherPalette.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(LauncherPalette.line) }
                    }
                }

                Text(project.name)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .help(project.name)

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(project.path)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(project.path, forType: .string)
                        pathCopyTask?.cancel()
                        withAnimation(.easeInOut(duration: 0.14)) { copiedPath = true }
                        pathCopyTask = Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(.easeInOut(duration: 0.14)) { copiedPath = false }
                            }
                        }
                    } label: {
                        Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(copiedPath ? LauncherPalette.running : .secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(copiedPath ? "已复制路径" : "复制项目路径")
                    .accessibilityLabel("复制项目路径")
                }
            }

            Spacer(minLength: 8)

            actions(project, state: state, available: available)
                .padding(.top, 4)
        }
    }

    private func actions(_ project: Project, state: RunState, available: Bool) -> some View {
        HStack(spacing: 8) {
            if state.phase.isActive {
                Button(role: .destructive) { model.stop(project.id) } label: {
                    Label(state.phase == .stopping ? "正在停止" : "停止", systemImage: "stop.fill")
                }
                .buttonStyle(ProjectActionStyle(tone: .stop))
                .disabled(state.phase == .stopping)

                Button { model.restart(project.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(ProjectActionStyle())
                .disabled(state.phase != .running)
                .help("重启")
                .accessibilityLabel("重启")
            } else {
                Button {
                    refreshFolderAvailability()
                    model.start(project)
                } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(ProjectActionStyle(tone: .primary))
                .disabled(!project.hasLaunchCommand)
            }

            Menu {
                terminalMenuContent(project)
            } label: {
                HoverableControlSurface {
                    HStack(spacing: 6) {
                        Label("终端", systemImage: "terminal")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(openingTerminal)
            .fixedSize()
            .help("在项目目录中打开终端或启动已安装的 AI CLI")

            Menu {
                openInIDEMenuContent(project)
            } label: {
                HoverableControlSurface {
                    HStack(spacing: 6) {
                        Label("IDE", systemImage: "chevron.left.forwardslash.chevron.right")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("在已安装的 IDE 中打开项目")
            .accessibilityLabel("在 IDE 中打开")

            Menu {
                Button("编辑列表别名…") { editingAlias = project }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                }
                .disabled(!available)
                Button("重新定位…") { relocate(project) }.disabled(state.phase.isActive)
                Divider()
                Button("移除项目…", role: .destructive) { confirmingRemoval = true }
                    .disabled(state.phase.isActive)
            } label: {
                HoverableControlSurface {
                    Image(systemName: "ellipsis")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("项目操作")
        }
        .focusEffectDisabled()
    }

    private func openInIDEMenu(_ project: Project) -> some View {
        Menu("在 IDE 中打开") {
            openInIDEMenuContent(project)
        }
    }

    @ViewBuilder
    private func openInIDEMenuContent(_ project: Project) -> some View {
        if model.installedIDEs.isEmpty {
            Text("未检测到已安装的 IDE")
        } else {
            ForEach(model.installedIDEs) { ide in
                Button {
                    Task { await model.openProject(project, in: ide) }
                } label: {
                    Label {
                        Text(ide.name)
                    } icon: {
                        Image(nsImage: ide.menuIcon)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func terminalMenuContent(_ project: Project) -> some View {
        let terminals = model.installedTerminals

        Section("直接打开终端") {
            ForEach(terminals, id: \.self) { terminal in
                Button {
                    openTerminal(project, in: terminal)
                } label: {
                    Label("在 \(terminal.rawValue) 中打开", systemImage: "terminal")
                }
            }
        }

        Section("打开 AI CLI") {
            if model.installedAICLIs.isEmpty {
                Text("未检测到已安装的 AI CLI")
            } else if terminals.count == 1, let terminal = terminals.first {
                ForEach(model.installedAICLIs) { cli in
                    Button {
                        openTerminal(project, in: terminal, running: cli)
                    } label: {
                        Label(cli.name, systemImage: "sparkles")
                    }
                }
            } else {
                ForEach(model.installedAICLIs) { cli in
                    Menu {
                        ForEach(terminals, id: \.self) { terminal in
                            Button("在 \(terminal.rawValue) 中打开") {
                                openTerminal(project, in: terminal, running: cli)
                            }
                        }
                    } label: {
                        Label(cli.name, systemImage: "sparkles")
                    }
                }
            }
        }
    }

    private func openTerminal(_ project: Project, in terminal: ProjectTerminal, running cli: ProjectAICLI? = nil) {
        guard !openingTerminal else { return }
        openingTerminal = true
        Task { @MainActor in
            defer { openingTerminal = false }
            do {
                try await terminal.open(at: project.path, running: cli)
            } catch {
                model.alert = error.localizedDescription
            }
        }
    }

    private func gitBar(_ project: Project, status: GitRepositoryStatus) -> some View {
        let busy = model.isGitBusy(project.id)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                gitStatusCluster(project, status: status, busy: busy)
                Spacer(minLength: 8)
                gitActionButtons(project, status: status, busy: busy)
            }
            VStack(alignment: .leading, spacing: 8) {
                gitStatusCluster(project, status: status, busy: busy)
                HStack {
                    Spacer(minLength: 0)
                    gitActionButtons(project, status: status, busy: busy)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(LauncherPalette.line)
        }
        .shadow(color: LauncherPalette.cardShadow(colorScheme), radius: 5, y: 1.5)
        .animation(.easeInOut(duration: 0.16), value: model.gitNotices[project.id])
    }

    private func gitStatusCluster(_ project: Project, status: GitRepositoryStatus, busy: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Section("切换本地分支") {
                    if status.branches.isEmpty {
                        Text("暂无本地分支")
                    } else {
                        ForEach(status.branches, id: \.self) { branch in
                            Button {
                                if branch != status.branch || status.isDetached {
                                    model.gitSwitchBranch(branch, for: project)
                                }
                            } label: {
                                if branch == status.branch && !status.isDetached {
                                    Label(branch, systemImage: "checkmark")
                                } else {
                                    Text(branch)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    creatingBranchFor = project
                } label: {
                    Label("新建分支…", systemImage: "plus")
                }
            } label: {
                HoverableControlSurface(size: .compact) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LauncherPalette.actionInk)
                        Text(status.branch)
                            .font(.caption.monospaced().weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(busy)
            .fixedSize()
            .help(status.upstream.map { "当前分支：\(status.branch)（跟踪 \($0)）" } ?? "当前分支：\(status.branch)")

            if status.conflictedCount > 0 {
                gitBadge(
                    icon: "exclamationmark.triangle.fill",
                    text: "\(status.conflictedCount) 处冲突",
                    ink: LauncherPalette.stop,
                    fill: LauncherPalette.stopFill,
                    edge: LauncherPalette.stopEdge
                )
                .help(status.changeSummary)
            } else if status.isDirty {
                gitBadge(
                    icon: "pencil",
                    text: "\(status.changedCount) 项未提交",
                    ink: LauncherPalette.warning,
                    fill: LauncherPalette.warningFill,
                    edge: LauncherPalette.warningEdge
                )
                .help(status.changeSummary)
            }

            if status.behind > 0 {
                gitBadge(
                    icon: "arrow.down.circle.fill",
                    text: "待拉取 \(status.behind)",
                    ink: LauncherPalette.pythonInk,
                    fill: LauncherPalette.pythonFill,
                    edge: LauncherPalette.pythonEdge
                )
                .help("远程 \(status.upstream ?? "分支") 有 \(status.behind) 个新提交待拉取")
            }

            if status.ahead > 0 {
                gitBadge(
                    icon: "arrow.up.circle.fill",
                    text: "待推送 \(status.ahead)",
                    ink: LauncherPalette.actionInk,
                    fill: LauncherPalette.selection,
                    edge: LauncherPalette.selectionEdge
                )
                .help("本地有 \(status.ahead) 个已提交但尚未推送到远程的提交")
            }

            if !status.isDirty && status.behind == 0 && status.ahead == 0 {
                gitBadge(
                    icon: "checkmark",
                    text: status.upstream != nil ? "已同步" : "无未提交",
                    ink: LauncherPalette.running,
                    fill: LauncherPalette.runningFill,
                    edge: LauncherPalette.runningEdge
                )
                .help(status.upstream != nil ? "工作区无未提交变更，且与远程分支保持同步" : "工作区无未提交变更")
            }

            if busy {
                ProgressView()
                    .controlSize(.small)
            } else if let notice = model.gitNotices[project.id] {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LauncherPalette.running)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
    }

    private func gitBadge(icon: String, text: String, ink: Color, fill: Color, edge: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(fill, in: Capsule())
        .overlay { Capsule().strokeBorder(edge) }
        .fixedSize()
    }

    private func gitActionButtons(_ project: Project, status: GitRepositoryStatus, busy: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                model.gitFetch(for: project)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(ProjectActionStyle(size: .compact))
            .disabled(busy)
            .help("检查远程更新（git fetch）")
            .accessibilityLabel("检查远程更新")

            Button {
                model.gitPull(for: project)
            } label: {
                Label("拉取", systemImage: "arrow.down")
            }
            .buttonStyle(ProjectActionStyle(size: .compact))
            .disabled(busy)
            .help(status.behind > 0 ? "拉取远程 \(status.behind) 个待拉取提交（git pull）" : "拉取最新代码（git pull）")

            Button {
                model.gitPush(for: project)
            } label: {
                Label("推送", systemImage: "arrow.up")
            }
            .buttonStyle(ProjectActionStyle(size: .compact))
            .disabled(busy || status.isDetached)
            .help(status.ahead > 0 ? "推送 \(status.ahead) 个待推送提交到远程（git push）" : "推送代码到远程（git push）")

            Button {
                showingGitHistory.toggle()
            } label: {
                Label("记录", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(ProjectActionStyle(size: .compact))
            .popover(isPresented: $showingGitHistory, arrowEdge: .bottom) {
                GitHistoryPopover(status: status)
            }
            .help("查看最近提交记录")

            Button {
                model.refreshGit(for: project)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(ProjectActionStyle(size: .compact))
            .disabled(busy)
            .help("刷新本地 Git 状态")
            .accessibilityLabel("刷新 Git 状态")
        }
        .fixedSize()
        .focusEffectDisabled()
    }

    private func configuration(_ project: Project, state: RunState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LauncherPalette.actionInk)
                Text("启动配置")
                    .font(.headline)
                Spacer()
                Button("编辑…") { editing = project }
                    .buttonStyle(ProjectActionStyle(size: .compact))
                    .focusEffectDisabled()
                    .disabled(state.phase.isActive)
            }

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        project.kind == .python ? "Python 环境" : "Node 版本",
                        systemImage: project.kind == .python ? "chevron.left.forwardslash.chevron.right" : "cube"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                    let setting = project.kind == .python ? "自动（.venv / venv / PATH）"
                        : (project.nodeVersion ?? "自动（.nvmrc / default）")
                    let displayRuntime = state.phase == .running ? (state.node ?? setting) : setting

                    HStack(spacing: 6) {
                        if state.phase == .running && state.node != nil {
                            Circle()
                                .fill(LauncherPalette.running)
                                .frame(width: 6, height: 6)
                        }
                        Text(displayRuntime)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .help(displayRuntime)
                    }

                    if let requirement = project.nodeRequirement {
                        Text("要求 \(requirement)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(LauncherPalette.lineSubtle)
                            }
                    }
                }
                .frame(width: 190, alignment: .leading)

                Rectangle()
                    .fill(LauncherPalette.lineSubtle)
                    .frame(width: 1)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Label("启动命令", systemImage: "terminal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if project.hasLaunchCommand {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("$")
                                .font(.callout.monospaced().weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(project.command)
                                .font(.callout.monospaced())
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .help(project.command)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(LauncherPalette.lineSubtle)
                        }
                    } else {
                        Label("未检测到可用的启动命令。请点击「编辑…」手动填写后再启动。",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(LauncherPalette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(LauncherPalette.warningFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(LauncherPalette.warningEdge)
                            }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let port = project.launchPort {
                Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)
                HStack(spacing: 10) {
                    Label("启动端口", systemImage: "network")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(":\(port.formatted(.number.grouping(.never)))")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(LauncherPalette.actionInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(LauncherPalette.lineSubtle)
                        }
                    if !state.phase.isActive {
                        PortStatusLabel(port: port)
                            .id(port)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.line)
        }
        .shadow(color: LauncherPalette.cardShadow(colorScheme), radius: 6, y: 2)
    }

    private func refreshFolderAvailability() {
        guard let path = selected?.path else { return }
        var directory: ObjCBool = false
        available = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func relocate(_ project: Project) {
        let panel = NSOpenPanel()
        panel.title = "重新定位项目"
        panel.message = "选择包含 \(project.kind.rawValue) 项目文件的文件夹。"
        panel.prompt = "选取"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        presentOpenPanel(panel) { urls in
            if let url = urls.first { model.relocate(project, to: url) }
        }
    }
}

// MARK: - Design System Tokens

enum LauncherPalette {
    static let canvas = adaptive(0xF4F6F9, 0x1A2027)
    static let sidebar = adaptive(0xECEFF4, 0x20272F)
    static let surface = adaptive(0xFFFFFF, 0x262E37)
    static let surfaceSubtle = adaptive(0xF6F8FB, 0x202730)
    static let surfaceHover = adaptive(0xF0F4F9, 0x2E3844)
    static let rowHover = adaptive(0xE3E9F1, 0x29323D)
    static let line = adaptive(0xDCE3EC, 0x36414E)
    static let lineSubtle = adaptive(0xE8EEF5, 0x2E3844)
    static let selection = adaptive(0xDDE7F2, 0x324152)
    static let selectionEdge = adaptive(0xA9BFD6, 0x5C7691)
    static let focusRing = adaptive(0x5B7A9C, 0x82A3C4)
    static let actionInk = adaptive(0x3D526A, 0xD0DCE9)
    static let actionFill = adaptive(0x435B75, 0x9FB8D2)
    static let actionFillHover = adaptive(0x374D65, 0xB2C8DF)
    static let actionLabel = adaptive(0xFFFFFF, 0x192531)

    static let running = adaptive(0x236B4B, 0x8DD0AB)
    static let runningFill = adaptive(0xE2F2E9, 0x253F35)
    static let runningEdge = adaptive(0xC3E3D1, 0x355C4C)

    static let pending = adaptive(0x8C5D1F, 0xE2BA82)
    static let pendingFill = adaptive(0xF7EFE2, 0x3E3425)
    static let pendingEdge = adaptive(0xE9D7BC, 0x594932)

    static let stop = adaptive(0x9A3D47, 0xF2A7A8)
    static let stopFill = adaptive(0xF7E8EA, 0x462E34)
    static let stopFillHover = adaptive(0xF1DADF, 0x54363D)
    static let stopEdge = adaptive(0xE7C8CC, 0x6A454D)

    static let warning = adaptive(0x9E5E1A, 0xE8B270)
    static let warningFill = adaptive(0xFBF2E6, 0x3B3123)
    static let warningEdge = adaptive(0xECD7BA, 0x5B4830)

    static let nodeInk = adaptive(0x2E6B4E, 0x8BC7A4)
    static let nodeFill = adaptive(0xE5F2EB, 0x243A31)
    static let nodeEdge = adaptive(0xCBE3D6, 0x345446)

    static let pythonInk = adaptive(0x375E85, 0x8DB8E2)
    static let pythonFill = adaptive(0xE4EEF7, 0x243648)
    static let pythonEdge = adaptive(0xC8DCEF, 0x364F69)

    static let consoleBody = Color(nsColor: rgb(0x1E252D))
    static let consoleHeader = Color(nsColor: rgb(0x262F39))
    static let consoleLine = Color(nsColor: rgb(0x36414F))
    static let consoleBorder = adaptive(0xCBD5E1, 0x3A4654)
    static let consoleText = rgb(0xDCE4EF)
    static let consoleMuted = rgb(0x8B9BB0)
    static let consoleActionHover = Color.white.opacity(0.09)
    static let consoleErrorFill = Color(nsColor: rgb(0x36272C))
    static let consoleErrorInk = Color(nsColor: rgb(0xF3B7B2))
    static let consoleInfoFill = Color(nsColor: rgb(0x26313E))

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.24 : 0.045)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

// MARK: - Shared Controls & Badges

enum ActionTone {
    case neutral, primary, stop

    func colors(hovering: Bool) -> (label: Color, fill: Color, edge: Color) {
        switch self {
        case .neutral:
            (
                LauncherPalette.actionInk,
                hovering ? LauncherPalette.surfaceHover : LauncherPalette.surface,
                hovering ? LauncherPalette.selectionEdge : LauncherPalette.line
            )
        case .primary:
            (
                LauncherPalette.actionLabel,
                hovering ? LauncherPalette.actionFillHover : LauncherPalette.actionFill,
                hovering ? LauncherPalette.actionFillHover : LauncherPalette.actionFill
            )
        case .stop:
            (
                LauncherPalette.stop,
                hovering ? LauncherPalette.stopFillHover : LauncherPalette.stopFill,
                LauncherPalette.stopEdge
            )
        }
    }
}

enum ControlSizeVariant {
    case regular, compact

    var horizontalPadding: CGFloat { self == .compact ? 9 : 11 }
    var minHeight: CGFloat { self == .compact ? 26 : 31 }
    var minWidth: CGFloat { self == .compact ? 28 : 32 }
    var cornerRadius: CGFloat { self == .compact ? 7 : 8 }
    var font: Font { self == .compact ? .caption.weight(.medium) : .callout.weight(.medium) }
}

struct ProjectControlSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    var tone: ActionTone = .neutral
    var size: ControlSizeVariant = .regular
    var hovering = false
    var pressed = false

    func body(content: Content) -> some View {
        let colors = tone.colors(hovering: hovering && isEnabled)
        content
            .font(size.font)
            .foregroundStyle(colors.label)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minWidth: size.minWidth, minHeight: size.minHeight)
            .background(colors.fill, in: RoundedRectangle(cornerRadius: size.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .strokeBorder(colors.edge)
            }
            .shadow(
                color: tone == .primary && isEnabled
                    ? Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08)
                    : .clear,
                radius: 3, y: 1
            )
            .scaleEffect(pressed ? 0.98 : 1)
            .opacity(isEnabled ? (pressed ? 0.84 : 1) : 0.45)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
    }
}

private struct HoverableControlSurface<Content: View>: View {
    var tone: ActionTone = .neutral
    var size: ControlSizeVariant = .regular
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .modifier(ProjectControlSurface(tone: tone, size: size, hovering: hovering))
            .onHover { hovering = $0 }
    }
}

struct ProjectActionStyle: ButtonStyle {
    var tone: ActionTone = .neutral
    var size: ControlSizeVariant = .regular

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, tone: tone, size: size)
    }

    private struct ActionButtonBody: View {
        let configuration: Configuration
        let tone: ActionTone
        let size: ControlSizeVariant
        @State private var hovering = false

        var body: some View {
            configuration.label
                .modifier(ProjectControlSurface(
                    tone: tone,
                    size: size,
                    hovering: hovering,
                    pressed: configuration.isPressed
                ))
                .onHover { hovering = $0 }
        }
    }
}

private struct SidebarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let helpText: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LauncherPalette.actionInk)
                .frame(width: 26, height: 26)
                .background(
                    hovering ? LauncherPalette.rowHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    if hovering {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(LauncherPalette.line)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(accessibilityLabel)
        .help(helpText)
    }
}

struct ProjectKindIcon: View {
    let kind: ProjectKind
    var size: CGFloat = 28

    private var label: String { kind == .python ? "PY" : "JS" }
    private var ink: Color { kind == .python ? LauncherPalette.pythonInk : LauncherPalette.nodeInk }
    private var fill: Color { kind == .python ? LauncherPalette.pythonFill : LauncherPalette.nodeFill }
    private var edge: Color { kind == .python ? LauncherPalette.pythonEdge : LauncherPalette.nodeEdge }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.27))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(edge)
            }
            .accessibilityHidden(true)
    }
}

struct ProjectKindBadge: View {
    let kind: ProjectKind

    private var ink: Color { kind == .python ? LauncherPalette.pythonInk : LauncherPalette.nodeInk }
    private var fill: Color { kind == .python ? LauncherPalette.pythonFill : LauncherPalette.nodeFill }
    private var edge: Color { kind == .python ? LauncherPalette.pythonEdge : LauncherPalette.nodeEdge }

    var body: some View {
        Text(kind.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(edge) }
    }
}

private struct ProjectRowView: View {
    let project: Project
    let phase: RunPhase
    let gitStatus: GitRepositoryStatus?
    let selected: Bool
    let listFocused: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    private var parentFolder: String {
        URL(fileURLWithPath: project.path).deletingLastPathComponent().lastPathComponent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ProjectKindIcon(kind: project.kind, size: 28)

                VStack(alignment: .leading, spacing: 2.5) {
                    Text(project.listName)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if let git = gitStatus {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text(git.branch)
                                    .lineLimit(1)
                                if git.isDirty {
                                    HStack(spacing: 1.5) {
                                        Image(systemName: git.conflictedCount > 0 ? "exclamationmark.triangle.fill" : "pencil")
                                            .font(.system(size: 8.5, weight: .semibold))
                                        Text("\(git.changedCount)")
                                            .monospacedDigit()
                                    }
                                    .foregroundStyle(git.conflictedCount > 0 ? LauncherPalette.stop : LauncherPalette.warning)
                                }
                                if git.behind > 0 {
                                    Text("↓\(git.behind)")
                                        .monospacedDigit()
                                        .foregroundStyle(LauncherPalette.pythonInk)
                                }
                                if git.ahead > 0 {
                                    Text("↑\(git.ahead)")
                                        .monospacedDigit()
                                        .foregroundStyle(LauncherPalette.actionInk)
                                }
                            }
                        } else {
                            Text(parentFolder)
                                .lineLimit(1)
                        }
                        if let port = project.launchPort {
                            Text("·")
                            Text(":\(port.formatted(.number.grouping(.never)))")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if phase.isActive {
                    StatusLabel(phase: phase, style: .compact).fixedSize()
                } else if phase == .failed {
                    Circle()
                        .fill(LauncherPalette.stop)
                        .frame(width: 7, height: 7)
                        .help("上次运行失败")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .padding(.vertical, 7.5)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        selected
                            ? LauncherPalette.selection
                            : (hovering ? LauncherPalette.rowHover : Color.clear)
                    )
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(phase == .running ? LauncherPalette.running : LauncherPalette.actionFill)
                        .frame(width: 3, height: 18)
                        .padding(.leading, 2.5)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(listFocused ? LauncherPalette.selectionEdge : LauncherPalette.line)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(gitStatus.map { "\(project.path)\n\($0.overviewSummary)" } ?? project.path)
    }
}

struct StatusLabel: View {
    enum Style {
        case compact
        case pill
    }

    let phase: RunPhase
    var style: Style = .compact

    private var color: Color {
        switch phase {
        case .running: LauncherPalette.running
        case .starting, .installing, .stopping: LauncherPalette.pending
        case .failed: LauncherPalette.stop
        default: .secondary
        }
    }

    private var fill: Color {
        switch phase {
        case .running: LauncherPalette.runningFill
        case .starting, .installing, .stopping: LauncherPalette.pendingFill
        case .failed: LauncherPalette.stopFill
        default: LauncherPalette.surface
        }
    }

    private var edge: Color {
        switch phase {
        case .running: LauncherPalette.runningEdge
        case .starting, .installing, .stopping: LauncherPalette.pendingEdge
        case .failed: LauncherPalette.stopEdge
        default: LauncherPalette.line
        }
    }

    private var showBadge: Bool {
        style == .pill || phase == .running || phase == .starting || phase == .installing || phase == .stopping
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(phase.rawValue)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(phase.isActive || phase == .failed ? color : .secondary)
        .padding(.horizontal, showBadge ? 8 : 0)
        .padding(.vertical, showBadge ? 2.5 : 0)
        .background {
            if showBadge {
                Capsule().fill(fill)
            }
        }
        .overlay {
            if showBadge {
                Capsule().strokeBorder(edge)
            }
        }
    }
}

// MARK: - Console View

private struct ConsoleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: RunState
    let clearLog: () -> Void
    let installAndRestart: () -> Void
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: LauncherPalette.consoleMuted))
                Text("运行日志")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: LauncherPalette.consoleText))

                if state.phase == .running || state.phase == .starting || state.phase == .installing {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(state.phase == .running ? LauncherPalette.running : LauncherPalette.pending)
                            .frame(width: 6, height: 6)
                        Text(state.phase == .running ? "实时输出" : state.phase.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(nsColor: LauncherPalette.consoleMuted))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }

                Spacer()

                ConsoleHeaderButton(
                    title: "清空",
                    systemImage: "trash",
                    tint: Color(nsColor: LauncherPalette.consoleMuted),
                    disabled: state.log.isEmpty,
                    action: clearLog
                )

                ConsoleHeaderButton(
                    title: copied ? "已复制" : "复制日志",
                    systemImage: copied ? "checkmark" : "document.on.document",
                    tint: copied ? LauncherPalette.running : Color(nsColor: LauncherPalette.consoleText),
                    disabled: state.log.isEmpty
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.log, forType: .string)
                    copyResetTask?.cancel()
                    withAnimation(.easeInOut(duration: 0.14)) { copied = true }
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.14)) { copied = false }
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(LauncherPalette.consoleHeader)

            Rectangle().fill(LauncherPalette.consoleLine).frame(height: 1)

            ConsoleText(
                text: state.log.isEmpty ? placeholder : state.log,
                isPlaceholder: state.log.isEmpty
            )
            .frame(minHeight: 120, maxHeight: .infinity)

            if let message = state.message {
                Rectangle().fill(LauncherPalette.consoleLine).frame(height: 1)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: state.phase == .failed ? "exclamationmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .font(.callout.weight(.medium))
                        if let command = state.installCommand {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Spacer()
                    if state.phase == .failed && state.install != nil {
                        Button("安装并重启", action: installAndRestart)
                            .buttonStyle(ProjectActionStyle(tone: .primary, size: .compact))
                            .focusEffectDisabled()
                    }
                }
                .foregroundStyle(
                    state.phase == .failed
                        ? LauncherPalette.consoleErrorInk
                        : Color(nsColor: LauncherPalette.consoleText)
                )
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    state.phase == .failed
                        ? LauncherPalette.consoleErrorFill
                        : LauncherPalette.consoleInfoFill
                )
            }
        }
        .background(LauncherPalette.consoleBody)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LauncherPalette.consoleBorder)
        }
        .shadow(color: LauncherPalette.cardShadow(colorScheme), radius: 8, y: 3)
    }

    private var placeholder: String {
        switch state.phase {
        case .starting: "正在准备启动环境…"
        case .installing: "正在安装…"
        case .running, .stopping: "尚无输出。"
        default: "启动项目后，输出将显示在这里。"
        }
    }
}

private struct ConsoleHeaderButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    hovering && !disabled ? LauncherPalette.consoleActionHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .opacity(disabled ? 0.4 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ConsoleText: NSViewRepresentable {
    let text: String
    let isPlaceholder: Bool
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3.5
        return style
    }()

    final class Coordinator {
        var lastPlaceholder: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.knobStyle = .light
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.font = Self.font
        view.textColor = LauncherPalette.consoleText
        view.setAccessibilityLabel("运行日志")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let placeholderChanged = context.coordinator.lastPlaceholder != isPlaceholder
        guard view.string != text || placeholderChanged else { return }
        context.coordinator.lastPlaceholder = isPlaceholder

        let bounds = scroll.contentView.bounds
        let follow = view.bounds.maxY - bounds.maxY < 26 && view.selectedRange().length == 0
        let old = view.string
        let foreground = isPlaceholder ? LauncherPalette.consoleMuted : LauncherPalette.consoleText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: foreground,
            .paragraphStyle: Self.paragraphStyle,
        ]
        if !placeholderChanged && text.hasPrefix(old) {
            let tail = String(text.dropFirst(old.count))
            storage.append(NSAttributedString(string: tail, attributes: attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        if follow {
            view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }
}
