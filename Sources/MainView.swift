import SwiftUI

struct MainView: View {
    @ObservedObject var model: LauncherModel
    @State private var search = ""
    @State private var editing: Project?
    @State private var editingAlias: Project?
    @State private var showingImport = false
    @State private var confirmingRemoval = false
    @State private var available = true
    @State private var openingCodex = false
    @FocusState private var projectListFocused: Bool

    private var filtered: [Project] {
        guard !search.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.name.localizedStandardContains(search) || $0.path.localizedStandardContains(search)
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
                .navigationSplitViewColumnWidth(min: 220, ideal: 265, max: 340)
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
        .sheet(isPresented: $showingImport, onDismiss: model.cancelScan) {
            ImportSheet(model: model)
        }
        .onChange(of: model.scanResult != nil) { _, ready in
            if ready { showingImport = true }
        }
        .onChange(of: selected?.path, initial: true) { _, _ in refreshFolderAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFolderAvailability()
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
            HStack {
                Text("项目").font(.headline)
                Spacer()
                Button { selectProjects(model) } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("添加项目")
                .help("添加项目（⌘O）")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索项目", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索项目")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(LauncherPalette.line) }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            projectList

            Rectangle().fill(LauncherPalette.line).frame(height: 1)
            HStack(spacing: 8) {
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text("正在扫描…")
                    Spacer()
                    Button("取消", action: model.cancelScan).buttonStyle(.borderless)
                } else {
                    if runningCount > 0 {
                        Circle().fill(LauncherPalette.running).frame(width: 6, height: 6)
                        Text("\(runningCount) 个项目运行中")
                    } else {
                        Text("\(model.projects.count) 个项目")
                    }
                    Spacer()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .background(LauncherPalette.sidebar)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filtered) { project in
                        projectRow(project).id(project.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
            .focusable()
            .focused($projectListFocused)
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
                if filtered.isEmpty && !search.isEmpty {
                    Text("没有匹配的项目").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let phase = model.runState(project.id).phase
        let selected = project.id == model.selection
        return Button {
            model.selection = project.id
            projectListFocused = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LauncherPalette.actionInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.listName)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(URL(fileURLWithPath: project.path).deletingLastPathComponent().lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if phase.isActive {
                    StatusLabel(phase: phase).fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(LauncherPalette.selection)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(projectListFocused ? LauncherPalette.selectionEdge : LauncherPalette.line)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(project.path)
        .contextMenu {
            openInIDEMenu(project)
            Button("编辑列表别名…") { editingAlias = project }
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
        VStack(spacing: 13) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(LauncherPalette.actionInk)
                .frame(width: 66, height: 66)
                .background(LauncherPalette.selection, in: RoundedRectangle(cornerRadius: 17))
                .accessibilityHidden(true)
            Text(model.projects.isEmpty ? "添加你的第一个项目" : "选择一个项目")
                .font(.title2.weight(.semibold))
            if model.projects.isEmpty {
                Text("选择 Node.js 或 Python 项目文件，或扫描包含多个项目的文件夹。")
                    .font(.callout).foregroundStyle(.secondary)
                Button { selectProjects(model) } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .buttonStyle(ProjectActionStyle(tone: .primary))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ project: Project) -> some View {
        let state = model.runState(project.id)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    StatusLabel(phase: state.phase)
                    Text(project.name).font(.system(size: 30, weight: .semibold)).lineLimit(1)
                        .help(project.name)
                    Text(project.path)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(project.path)
                }
                Spacer(minLength: 0)
                actions(project, state: state, available: available)
            }

            configuration(project, state: state)

            if !available {
                Label("项目文件夹不可用。连接磁盘后再试，或重新定位项目。", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            ConsoleView(state: state) { model.installAndRestart(project.id) }
                .frame(maxHeight: .infinity)
        }
        .padding(25)
        .confirmationDialog("移除「\(project.name)」？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除项目", role: .destructive) { model.remove(project.id) }
        } message: {
            Text("这会从项目列表移除该项目。磁盘上的文件会保留。")
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
                ForEach(ProjectTerminal.allCases, id: \.self) { terminal in
                    Button("在 \(terminal.rawValue) 中打开") { openCodex(project, in: terminal) }
                }
            } label: {
                HStack(spacing: 6) {
                    Label("Codex", systemImage: "terminal")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .modifier(ProjectControlSurface())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(openingCodex)
            .fixedSize()
            .help("在项目目录中启动 Codex CLI")

            Menu {
                openInIDEMenu(project)
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
                Image(systemName: "ellipsis").modifier(ProjectControlSurface())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("项目操作")
        }
    }

    private func openInIDEMenu(_ project: Project) -> some View {
        Menu("在 IDE 中打开") {
            ForEach(ProjectIDE.allCases, id: \.self) { ide in
                Button(ide.rawValue) {
                    Task { await model.openProject(project, in: ide) }
                }
            }
        }
    }

    private func openCodex(_ project: Project, in terminal: ProjectTerminal) {
        guard !openingCodex else { return }
        openingCodex = true
        Task { @MainActor in
            defer { openingCodex = false }
            do {
                try await terminal.openCodex(at: project.path)
            } catch {
                model.alert = error.localizedDescription
            }
        }
    }

    private func configuration(_ project: Project, state: RunState) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("启动配置").font(.headline)
                Spacer()
                Button("编辑…") { editing = project }
                    .buttonStyle(ProjectActionStyle())
                    .disabled(state.phase.isActive)
            }
            Rectangle().fill(LauncherPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.kind == .python ? "Python 环境" : "Node 版本")
                        .font(.caption).foregroundStyle(.secondary)
                    let setting = project.kind == .python ? "自动（.venv / venv / PATH）"
                        : (project.nodeVersion ?? "自动（.nvmrc / default）")
                    Text(state.phase == .running ? state.node ?? setting : setting)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(setting)
                    if let requirement = project.nodeRequirement {
                        Text("项目要求 \(requirement)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 177, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text("启动命令").font(.caption).foregroundStyle(.secondary)
                    if project.hasLaunchCommand {
                        Text(project.command)
                            .font(.callout.monospaced())
                            .lineLimit(2).textSelection(.enabled)
                            .help(project.command)
                    } else {
                        Label("未检测到可用的启动命令。请点击「编辑…」手动填写后再启动。",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let port = project.launchPort {
                HStack(spacing: 8) {
                    Text("启动端口").foregroundStyle(.secondary)
                    Text(port.formatted(.number.grouping(.never))).monospacedDigit()
                    if !state.phase.isActive {
                        PortStatusLabel(port: port)
                            .id(port)
                    }
                }
                .font(.caption)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.line)
        }
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

private enum LauncherPalette {
    static let canvas = adaptive(0xF5F7FA, 0x1C2229)
    static let sidebar = adaptive(0xEDF0F4, 0x222930)
    static let surface = adaptive(0xFCFDFE, 0x272F38)
    static let line = adaptive(0xDCE3EB, 0x3C4754)
    static let selection = adaptive(0xDEE7F1, 0x344251)
    static let selectionEdge = adaptive(0xB2C4D7, 0x667D94)
    static let actionInk = adaptive(0x42566D, 0xCDD9E6)
    static let actionFill = adaptive(0x48607A, 0xABC0D6)
    static let actionLabel = adaptive(0xFFFFFF, 0x1D2B38)
    static let running = adaptive(0x276247, 0x9BD2B2)
    static let runningFill = adaptive(0xDFEEE5, 0x2C473B)
    static let stop = adaptive(0x873F47, 0xF1AEAD)
    static let stopFill = adaptive(0xF4E7E8, 0x473338)
    static let stopEdge = adaptive(0xE7CFD1, 0x684A51)
    static let pending = adaptive(0x795323, 0xDEB783)

    static let consoleBody = Color(nsColor: rgb(0x242B34))
    static let consoleHeader = Color(nsColor: rgb(0x2E3742))
    static let consoleLine = Color(nsColor: rgb(0x3B4654))
    static let consoleText = rgb(0xD8E0EB)

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

private enum ActionTone {
    case neutral, primary, stop

    var colors: (label: Color, fill: Color, edge: Color) {
        switch self {
        case .neutral: (LauncherPalette.actionInk, LauncherPalette.surface, LauncherPalette.line)
        case .primary: (LauncherPalette.actionLabel, LauncherPalette.actionFill, LauncherPalette.actionFill)
        case .stop: (LauncherPalette.stop, LauncherPalette.stopFill, LauncherPalette.stopEdge)
        }
    }
}

private struct ProjectControlSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    var tone: ActionTone = .neutral
    var pressed = false

    func body(content: Content) -> some View {
        let colors = tone.colors
        content
            .font(.callout.weight(.medium))
            .foregroundStyle(colors.label)
            .padding(.horizontal, 10)
            .frame(minWidth: 31, minHeight: 30)
            .background(colors.fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(colors.edge) }
            .opacity(isEnabled ? (pressed ? 0.72 : 1) : 0.48)
            .contentShape(Rectangle())
    }
}

private struct ProjectActionStyle: ButtonStyle {
    var tone: ActionTone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ProjectControlSurface(tone: tone, pressed: configuration.isPressed))
    }
}

private struct StatusLabel: View {
    let phase: RunPhase

    private var color: Color {
        switch phase {
        case .running: LauncherPalette.running
        case .starting, .installing, .stopping: LauncherPalette.pending
        case .failed: LauncherPalette.stop
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(phase.rawValue)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(phase.isActive || phase == .failed ? color : .secondary)
        .padding(.horizontal, phase == .running ? 7 : 0)
        .padding(.vertical, phase == .running ? 3 : 0)
        .background {
            if phase == .running {
                Capsule().fill(LauncherPalette.runningFill)
            }
        }
    }
}

private struct ConsoleView: View {
    let state: RunState
    let installAndRestart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("运行日志").fontWeight(.semibold)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.log, forType: .string)
                } label: {
                    Label("复制日志", systemImage: "document.on.document")
                }
                .buttonStyle(.plain)
                .disabled(state.log.isEmpty)
            }
            .font(.callout)
            .foregroundStyle(Color(nsColor: LauncherPalette.consoleText))
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(LauncherPalette.consoleHeader)

            Rectangle().fill(LauncherPalette.consoleLine).frame(height: 1)

            ConsoleText(text: state.log.isEmpty ? placeholder : state.log)
                .frame(minHeight: 120, maxHeight: .infinity)

            if let message = state.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: state.phase == .failed ? "exclamationmark.circle" : "info.circle")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                        if let command = state.installCommand {
                            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if state.phase == .failed && state.install != nil {
                        Button("安装并重启", action: installAndRestart)
                            .buttonStyle(ProjectActionStyle())
                    }
                }
                .font(.callout)
                .foregroundStyle(state.phase == .failed ? Color(red: 0.92, green: 0.75, blue: 0.71) :
                    Color(nsColor: LauncherPalette.consoleText))
                .padding(12)
                .background(LauncherPalette.consoleHeader)
            }
        }
        .background(LauncherPalette.consoleBody)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

private struct ConsoleText: NSViewRepresentable {
    let text: String
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let foreground = LauncherPalette.consoleText

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
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.font = Self.font
        view.textColor = Self.foreground
        view.setAccessibilityLabel("运行日志")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage,
              view.string != text else { return }
        let bounds = scroll.contentView.bounds
        let follow = view.bounds.maxY - bounds.maxY < 26 && view.selectedRange().length == 0
        let old = view.string
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Self.foreground]
        if text.hasPrefix(old) {
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
