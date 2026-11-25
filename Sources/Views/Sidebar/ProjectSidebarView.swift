import AppKit
import SwiftUI

struct ProjectSidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var model: LauncherModel
    let filtered: [Project]
    @Binding var search: String
    @Binding var runningOnly: Bool
    var listFocused: FocusState<Bool>.Binding

    let onEditConfiguration: (Project) -> Void
    let onEditAlias: (Project) -> Void
    let onRelocate: (Project) -> Void
    let onRemove: (Project) -> Void
    let onOpenTerminal: (Project, ProjectTerminal, ProjectAICLI?) -> Void

    private var runningCount: Int { model.runningCount }
    private var pinnedFiltered: [Project] { filtered.filter(\.pinned) }
    private var unpinnedFiltered: [Project] { filtered.filter { !$0.pinned } }

    var body: some View {
        VStack(spacing: 0) {
            projectList
            Divider()
            sidebarFooter
        }
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if !pinnedFiltered.isEmpty {
                        sidebarSectionHeader("置顶", showBatchLaunch: !model.startablePinnedProjects.isEmpty)
                        ForEach(pinnedFiltered) { project in
                            projectRow(project, showPinIcon: false)
                        }

                        if !unpinnedFiltered.isEmpty {
                            sidebarSectionHeader("全部项目", showBatchLaunch: false)
                                .padding(.top, 6)
                        }
                    }

                    ForEach(pinnedFiltered.isEmpty ? filtered : unpinnedFiltered) { project in
                        projectRow(project, showPinIcon: project.pinned)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused(listFocused)
            .defaultFocus(listFocused, true)
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
                if filtered.isEmpty && !model.projects.isEmpty && (!search.isEmpty || runningOnly) {
                    ContentUnavailableView {
                        Label(
                            runningOnly && search.isEmpty ? "没有运行中的项目" : "没有匹配的项目",
                            systemImage: runningOnly && search.isEmpty ? "bolt.slash" : "magnifyingglass"
                        )
                    } description: {
                        if !search.isEmpty {
                            Text("未找到与「\(search)」匹配的项目或路径。")
                        }
                    } actions: {
                        Button("重置筛选") {
                            search = ""
                            runningOnly = false
                        }
                        .buttonStyle(ProjectActionStyle(size: .compact))
                    }
                    .controlSize(.small)
                    .padding(12)
                    .nativeControlFocus()
                }
            }
        }
    }

    private func sidebarSectionHeader(_ title: String, showBatchLaunch: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if showBatchLaunch {
                Button {
                    model.startPinnedProjects()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8.5))
                        Text("全部启动")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("一键启动所有尚未运行的置顶项目（⌥⌘↩）")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func projectRow(_ project: Project, showPinIcon: Bool) -> some View {
        ProjectRowView(
            project: project,
            phase: model.runPhase(project.id),
            effectivePort: model.effectivePort(for: project),
            gitStatus: model.gitStatus(project.id),
            selected: project.id == model.selection,
            listFocused: listFocused.wrappedValue,
            showPinIcon: showPinIcon,
            onSelect: {
                model.selection = project.id
                listFocused.wrappedValue = true
            }
        )
        .contextMenu {
            ProjectContextMenu(
                projectID: project.id,
                fallbackProject: project,
                model: model,
                onEditConfiguration: onEditConfiguration,
                onEditAlias: onEditAlias,
                onRelocate: onRelocate,
                onRemove: onRemove,
                onOpenTerminal: onOpenTerminal
            )
        }
        .id(project.id)
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
            } else {
                if runningCount > 0 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            runningOnly.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(LauncherPalette.running)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text("\(runningCount) 个运行中")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(runningOnly ? LauncherPalette.running : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            runningOnly
                                ? LauncherPalette.runningFill
                                : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    runningOnly
                                        ? LauncherPalette.runningEdge
                                        : Color.primary.opacity(0.10)
                                )
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(runningOnly ? "显示全部项目" : "仅显示运行中的项目")
                } else {
                    Text("\(model.projects.count) 个项目")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if runningOnly {
                    Button("全部") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            runningOnly = false
                        }
                    }
                    .buttonStyle(.borderless)
                } else if !model.projects.isEmpty && runningCount > 0 {
                    Text("共 \(model.projects.count) 项")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .nativeControlFocus()
    }

    private func moveProjectSelection(by offset: Int) {
        guard let first = filtered.first else { return }
        guard let currentIndex = filtered.firstIndex(where: { $0.id == model.selection }) else {
            model.selection = offset > 0 ? first.id : filtered.last?.id
            return
        }
        let nextIndex = currentIndex + offset
        if filtered.indices.contains(nextIndex) {
            model.selection = filtered[nextIndex].id
        }
    }
}

private struct ProjectContextMenu: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let projectID: UUID
    let fallbackProject: Project
    var model: LauncherModel
    let onEditConfiguration: (Project) -> Void
    let onEditAlias: (Project) -> Void
    let onRelocate: (Project) -> Void
    let onRemove: (Project) -> Void
    let onOpenTerminal: (Project, ProjectTerminal, ProjectAICLI?) -> Void

    var body: some View {
        let project = model.project(for: projectID) ?? fallbackProject
        let phase = model.runPhase(project.id)

        if phase.isActive {
            Button(role: .destructive) {
                model.stop(project.id)
            } label: {
                Label(phase == .stopping ? "正在停止" : "停止", systemImage: "stop.fill")
            }
            .disabled(phase == .stopping)

            Button {
                model.restart(project.id)
            } label: {
                Label("重启", systemImage: "arrow.clockwise")
            }
            .disabled(phase != .running)
        } else {
            Button {
                let latest = model.project(for: projectID) ?? project
                model.selection = latest.id
                model.start(latest)
            } label: {
                Label("启动", systemImage: "play.fill")
            }
            .disabled(!project.hasLaunchCommand)
        }

        if let url = model.browserURL(for: project) {
            let portSuffix = url.port.map { " (:\($0))" } ?? ""
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("在浏览器中打开\(portSuffix)", systemImage: "safari")
            }
        }

        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                _ = model.togglePinned(project.id)
            }
        } label: {
            Label(project.pinned ? "取消置顶" : "置顶项目", systemImage: project.pinned ? "pin.slash" : "pin")
        }

        Divider()

        Menu("在 IDE 中打开") {
            ProjectIDEMenuItems(project: project, model: model)
        }
        Menu("在终端中打开") {
            ProjectTerminalMenuItems(model: model) { terminal, cli in
                onOpenTerminal(model.project(for: projectID) ?? project, terminal, cli)
            }
        }
        Button {
            let latest = model.project(for: projectID) ?? project
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: latest.path)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        Button {
            let latest = model.project(for: projectID) ?? project
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(latest.path, forType: .string)
        } label: {
            Label("复制项目路径", systemImage: "doc.on.doc")
        }

        Divider()

        Button("编辑启动配置…") {
            onEditConfiguration(model.project(for: projectID) ?? project)
        }
        .disabled(phase.isActive)

        Button("编辑列表别名…") {
            onEditAlias(model.project(for: projectID) ?? project)
        }

        Button("重新定位…") {
            onRelocate(model.project(for: projectID) ?? project)
        }
        .disabled(phase.isActive)

        Divider()

        Button("移除项目…", role: .destructive) {
            onRemove(model.project(for: projectID) ?? project)
        }
        .disabled(phase.isActive)
    }
}
