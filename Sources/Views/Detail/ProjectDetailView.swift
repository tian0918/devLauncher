import AppKit
import SwiftUI

struct ProjectDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let project: Project
    var model: LauncherModel
    let available: Bool
    let openingTerminal: Bool
    let copiedPath: Bool
    @Binding var creatingBranchFor: Project?
    @Binding var showingGitHistory: Bool

    let onStart: () -> Void
    let onCopyPath: () -> Void
    let onEditConfiguration: () -> Void
    let onEditAlias: () -> Void
    let onRelocate: () -> Void
    let onRemove: () -> Void
    let onOpenTerminal: (ProjectTerminal, ProjectAICLI?) -> Void

    @State private var hoveringCopyPath = false

    var body: some View {
        let state = model.runMetadataState(project.id)
        VStack(alignment: .leading, spacing: 12) {
            header(state: state)

            if let git = model.gitStatus(project.id) {
                ProjectGitToolbarView(
                    project: project,
                    status: git,
                    model: model,
                    creatingBranchFor: $creatingBranchFor,
                    showingGitHistory: $showingGitHistory
                )
            }

            configuration(state: state)

            if !available {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(LauncherPalette.warning)
                    Text("项目文件夹不可用。连接磁盘后再试，或重新定位项目。")
                        .font(.callout)
                        .foregroundStyle(LauncherPalette.warning)
                    Spacer(minLength: 8)
                    Button("重新定位…", action: onRelocate)
                        .buttonStyle(ProjectActionStyle(size: .compact))
                        .disabled(state.phase.isActive)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LauncherPalette.warningFill, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(LauncherPalette.warningEdge)
                }
            }

            ConsoleView(
                projectID: project.id,
                model: model,
                clearLog: { model.clearLog(project.id) },
                installAndRestart: { model.installAndRestart(project.id) }
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .nativeControlFocus()
    }

    // MARK: - Header & Primary Actions

    private func header(state: RunMetadata) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                headerIdentity(state: state, enforceMinTitleWidth: true)
                Spacer(minLength: 8)
                actions(state: state)
            }

            VStack(alignment: .leading, spacing: 10) {
                headerIdentity(state: state, enforceMinTitleWidth: false)
                HStack {
                    actions(state: state)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func headerIdentity(state: RunMetadata, enforceMinTitleWidth: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Text(project.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: enforceMinTitleWidth ? 120 : nil, alignment: .leading)
                    .help(project.name)

                HStack(spacing: 6) {
                    StatusLabel(phase: state.phase, style: .pill)
                    ProjectKindBadge(kind: project.kind)
                    if project.pinned {
                        NeutralPillBadge(text: "已置顶")
                    }
                    if let alias = project.listAlias {
                        NeutralPillBadge(text: "别名：\(alias)")
                    }
                }
                .fixedSize()
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(project.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(project.path)

                Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(copiedPath ? LauncherPalette.running : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        hoveringCopyPath ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .contentShape(Rectangle())
                    .onHover { hoveringCopyPath = $0 }
                    .onTapGesture(perform: onCopyPath)
                    .help(copiedPath ? "已复制路径" : "复制项目路径（⌥⌘C）")
                    .accessibilityElement()
                    .accessibilityLabel(copiedPath ? "已复制项目路径" : "复制项目路径")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, onCopyPath)
            }
        }
    }

    private func actions(state: RunMetadata) -> some View {
        HStack(spacing: 6) {
            Button(role: state.phase.isActive ? .destructive : nil) {
                if state.phase.isActive {
                    model.stop(project.id)
                } else {
                    onStart()
                }
            } label: {
                if state.phase.isActive {
                    Label(state.phase == .stopping ? "正在停止" : "停止", systemImage: "stop.fill")
                } else {
                    Label("启动", systemImage: "play.fill")
                }
            }
            .buttonStyle(ProjectActionStyle(tone: state.phase.isActive ? .stop : .primary))
            .disabled(state.phase == .stopping || (!state.phase.isActive && !project.hasLaunchCommand))
            .help(state.phase.isActive ? "停止（⌘.）" : "启动（⌘↩）")

            if state.phase.isActive {
                Button { model.restart(project.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(ProjectActionStyle())
                .disabled(state.phase != .running)
                .help("重启（⇧⌘R）")
                .accessibilityLabel("重启")
            }

            Menu {
                ProjectTerminalMenuItems(model: model, onLaunch: onOpenTerminal)
            } label: {
                HoverableControlSurface {
                    HStack(spacing: 5) {
                        Label("终端", systemImage: "terminal")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(openingTerminal)
            .fixedSize()
            .help("在项目目录中打开终端或启动已安装的 AI CLI")
            .accessibilityLabel("打开终端或 AI CLI")

            Menu {
                ProjectIDEMenuItems(project: project, model: model)
            } label: {
                HoverableControlSurface {
                    HStack(spacing: 5) {
                        Label("IDE", systemImage: "chevron.left.forwardslash.chevron.right")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
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
                Button(project.pinned ? "取消置顶" : "置顶项目") {
                    model.togglePinned(project.id)
                }
                Divider()
                Button("编辑启动配置…", action: onEditConfiguration)
                    .disabled(state.phase.isActive)
                Button("编辑列表别名…", action: onEditAlias)
                Divider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                }
                .disabled(!available)
                Button("复制项目路径", action: onCopyPath)
                Button("重新定位…", action: onRelocate)
                    .disabled(state.phase.isActive)
                Divider()
                Button("移除项目…", role: .destructive, action: onRemove)
                    .disabled(state.phase.isActive)
            } label: {
                HoverableControlSurface {
                    Image(systemName: "ellipsis")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多项目操作")
            .accessibilityLabel("更多项目操作")
        }
        .fixedSize()
    }

    // MARK: - Compact Launch Configuration Inspector Bar

    @ViewBuilder
    private func configuration(state: RunMetadata) -> some View {
        if !project.hasLaunchCommand {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(LauncherPalette.warning)
                    .accessibilityHidden(true)
                Text("未检测到可用的启动命令。请配置命令后再启动项目。")
                    .font(.callout)
                    .foregroundStyle(LauncherPalette.warning)
                Spacer(minLength: 8)
                Button("配置命令…", action: onEditConfiguration)
                    .buttonStyle(ProjectActionStyle(tone: .primary, size: .compact))
                    .disabled(state.phase.isActive)
                    .help("编辑启动配置（⌘E）")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.warningFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(LauncherPalette.warningEdge)
            }
        } else {
            let liveURL = model.browserURL(for: project)
            let displayPort = model.effectivePort(for: project)
            let hasPortOrURL = displayPort != nil || liveURL != nil

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    runtimeSummary(state: state)
                        .fixedSize()
                    Divider().frame(height: 14)
                    commandPill(project.command, expand: false)
                    if hasPortOrURL {
                        Divider().frame(height: 14)
                        portCluster(port: displayPort, liveURL: liveURL, phase: state.phase)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    editConfigButton(disabled: state.phase.isActive)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        runtimeSummary(state: state)
                        if hasPortOrURL {
                            Divider().frame(height: 14)
                            portCluster(port: displayPort, liveURL: liveURL, phase: state.phase)
                        }
                        Spacer(minLength: 6)
                        editConfigButton(disabled: state.phase.isActive)
                    }
                    commandPill(project.command, expand: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.line)
            }
            .shadow(color: LauncherPalette.cardShadow(colorScheme, contrast: colorSchemeContrast), radius: 4, y: 1)
        }
    }

    private func runtimeSummary(state: RunMetadata) -> some View {
        let setting = project.kind == .python
            ? "自动 (.venv / PATH)"
            : (project.nodeVersion ?? "自动 (.nvmrc)")
        let displayRuntime = state.phase == .running ? (state.node ?? setting) : setting
        let tooltip = project.nodeRequirement.map { "\(displayRuntime)（package.json 要求 \($0)）" } ?? displayRuntime

        return HStack(spacing: 5.5) {
            Image(systemName: project.kind == .python ? "chevron.left.forwardslash.chevron.right" : "cube")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if state.phase == .running && state.node != nil {
                Circle()
                    .fill(LauncherPalette.running)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }

            Text(displayRuntime)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if let requirement = project.nodeRequirement {
                Text(requirement)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(LauncherPalette.lineSubtle)
                    }
            }
        }
        .help(tooltip)
    }

    private func commandPill(_ command: String, expand: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("$")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(command)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 4)
        .frame(minWidth: expand ? nil : 120, maxWidth: expand ? .infinity : nil, alignment: .leading)
        .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(LauncherPalette.lineSubtle)
        }
        .help("启动命令：\(command)")
    }

    private func portCluster(port: UInt16?, liveURL: URL?, phase: RunPhase) -> some View {
        HStack(spacing: 6) {
            if let port {
                NeutralPillBadge(text: ":\(port.formatted(.number.grouping(.never)))", monospaced: true)
            }

            if phase == .running, let url = liveURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("打开", systemImage: "safari")
                }
                .buttonStyle(ProjectActionStyle(size: .compact))
                .help("在默认浏览器中打开 \(url.absoluteString)（⇧⌘O）")
            } else if !phase.isActive, let configuredPort = project.launchPort {
                PortStatusLabel(port: configuredPort, interval: .seconds(3))
                    .id(configuredPort)
            }
        }
    }

    private func editConfigButton(disabled: Bool) -> some View {
        Button("编辑…", action: onEditConfiguration)
            .buttonStyle(ProjectActionStyle(size: .compact))
            .disabled(disabled)
            .fixedSize()
            .help("编辑启动配置（⌘E）")
    }
}
