import AppKit
import SwiftUI

struct MainView: View {
    var model: LauncherModel
    weak var delegate: LauncherDelegate?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var search = ""
    @State private var isSearching = false
    @State private var runningOnly = false
    @State private var editing: Project?
    @State private var editingAlias: Project?
    @State private var creatingBranchFor: Project?
    @State private var projectPendingRemoval: Project?
    @State private var showingGitHistory = false
    @State private var showingImport = false
    @State private var available = true
    @State private var openingTerminal = false
    @State private var copiedPath = false
    @State private var isDropTargeted = false
    @State private var pathCopyTask: Task<Void, Never>?
    @FocusState private var isSidebarListFocused: Bool

    private var filtered: [Project] {
        model.projects.filter { project in
            if runningOnly && model.runPhase(project.id) != .running {
                return false
            }
            guard !search.isEmpty else { return true }
            return project.listName.localizedStandardContains(search)
                || project.name.localizedStandardContains(search)
                || project.path.localizedStandardContains(search)
        }
    }

    private var selected: Project? {
        model.project(for: model.selection)
    }

    private var runningCount: Int {
        model.runningCount
    }

    private var isModalPresented: Bool {
        editing != nil
            || editingAlias != nil
            || creatingBranchFor != nil
            || showingImport
            || projectPendingRemoval != nil
    }

    private var focusedActions: FocusedLauncherActions {
        let current = selected
        let phase = current.map { model.runPhase($0.id) } ?? .idle
        let browserURL = current.flatMap { model.browserURL(for: $0) }
        let hasLog = current.map { !model.logSnapshot($0.id).isEmpty } ?? false
        let git = current.flatMap { model.gitStatus($0.id) }
        let gitBusy = current.map { model.isGitBusy($0.id) } ?? false

        return FocusedLauncherActions(
            selectedProject: current,
            selectedPhase: phase,
            browserURL: browserURL,
            isProjectAvailable: available,
            hasLog: hasLog,
            gitStatus: git,
            isGitBusy: gitBusy,
            runningCount: runningCount,
            runningOnly: runningOnly,
            isModalPresented: isModalPresented,
            focusSearch: { isSearching = true },
            toggleRunningOnly: {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    runningOnly.toggle()
                }
            },
            editConfiguration: {
                if let current, !model.runPhase(current.id).isActive {
                    editing = current
                }
            },
            editAlias: {
                if let current { editingAlias = current }
            },
            relocateProject: {
                if let current, !model.runPhase(current.id).isActive {
                    relocate(current)
                }
            },
            removeProject: {
                if let current, !model.runPhase(current.id).isActive {
                    projectPendingRemoval = current
                }
            },
            revealInFinder: {
                if let current {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: current.path)
                }
            },
            copyPath: {
                if let current { copyProjectPath(current.path) }
            },
            openInBrowser: {
                if let browserURL {
                    NSWorkspace.shared.open(browserURL)
                }
            },
            createBranch: {
                if let current, model.gitStatus(current.id) != nil {
                    creatingBranchFor = current
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(
                model: model,
                filtered: filtered,
                search: $search,
                runningOnly: $runningOnly,
                listFocused: $isSidebarListFocused,
                onEditConfiguration: { project in
                    model.selection = project.id
                    editing = project
                },
                onEditAlias: { editingAlias = $0 },
                onRelocate: { relocate($0) },
                onRemove: { projectPendingRemoval = $0 },
                onOpenTerminal: { project, terminal, cli in
                    openTerminal(project, in: terminal, running: cli)
                }
            )
            .navigationSplitViewColumnWidth(min: 236, ideal: 274, max: 350)
        } detail: {
            Group {
                if let project = selected {
                    ProjectDetailView(
                        project: project,
                        model: model,
                        available: available,
                        openingTerminal: openingTerminal,
                        copiedPath: copiedPath,
                        creatingBranchFor: $creatingBranchFor,
                        showingGitHistory: $showingGitHistory,
                        onStart: {
                            refreshFolderAvailability()
                            model.start(project)
                        },
                        onCopyPath: { copyProjectPath(project.path) },
                        onEditConfiguration: { editing = project },
                        onEditAlias: { editingAlias = project },
                        onRelocate: { relocate(project) },
                        onRemove: { projectPendingRemoval = project },
                        onOpenTerminal: { terminal, cli in
                            openTerminal(project, in: terminal, running: cli)
                        }
                    )
                    .id(project.id)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LauncherPalette.canvas)
        }
        .searchable(
            text: $search,
            isPresented: $isSearching,
            placement: .sidebar,
            prompt: "搜索项目或路径"
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    selectProjects(model)
                } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .help("添加项目（⌘O）")

                if runningCount > 0 || runningOnly {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            runningOnly.toggle()
                        }
                    } label: {
                        Label(
                            runningOnly ? "显示全部项目" : "仅显示运行中",
                            systemImage: runningOnly
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                    .help(runningOnly ? "显示全部项目（⌥⌘R）" : "仅显示运行中的项目（⌥⌘R）")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("nvm 设置（⌘,）")
            }
        }
        .focusedSceneValue(\.launcherActions, focusedActions)
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                    .allowsHitTesting(false)
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
        .confirmationDialog(
            projectPendingRemoval.map { "移除「\($0.name)」？" } ?? "移除项目？",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除项目", role: .destructive) {
                if let target = projectPendingRemoval {
                    model.remove(target.id)
                }
                projectPendingRemoval = nil
            }
        } message: {
            Text("这会从项目列表移除该项目。磁盘上的文件会保留。")
        }
        .onAppear {
            delegate?.openMainWindow = { openWindow(id: "projects") }
            DispatchQueue.main.async {
                if !isSearching {
                    isSidebarListFocused = true
                }
            }
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
                model.refreshGit(for: project, detail: .full)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFolderAvailability()
            model.refreshOnAppActivation()
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

    private var placeholder: some View {
        ContentUnavailableView {
            Label(
                model.projects.isEmpty ? "添加你的第一个项目" : "选择一个项目",
                systemImage: "terminal"
            )
        } description: {
            if model.projects.isEmpty {
                Text("选择 Node.js 或 Python 项目文件、扫描文件夹，或直接将目录拖入窗口。")
            } else {
                Text("从左侧列表选择一个项目以查看状态、Git 信息与运行日志。")
            }
        } actions: {
            if model.projects.isEmpty {
                Button {
                    selectProjects(model)
                } label: {
                    Label("添加项目…", systemImage: "plus")
                }
                .buttonStyle(ProjectActionStyle(tone: .primary))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nativeControlFocus()
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

    private func copyProjectPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        pathCopyTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { copiedPath = true }
        pathCopyTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { copiedPath = false }
            }
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        let validURLs = urls.filter { url in
            guard url.isFileURL else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDir || ProjectFiles.isImportFile(url)
        }
        guard !validURLs.isEmpty else { return false }
        model.scan(validURLs)
        return true
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
