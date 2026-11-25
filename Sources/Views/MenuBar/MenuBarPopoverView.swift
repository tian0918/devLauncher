import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var model: LauncherModel
    weak var delegate: LauncherDelegate?

    private var orderedProjects: [Project] {
        model.projects.sorted { lhs, rhs in
            let lhsActive = model.runPhase(lhs.id).isActive
            let rhsActive = model.runPhase(rhs.id).isActive
            if lhsActive != rhsActive { return lhsActive && !rhsActive }
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            if model.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("尚未添加任何项目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("添加项目…") {
                        activateMainWindow()
                        Task { @MainActor in
                            selectProjects(model)
                        }
                        dismiss()
                    }
                    .buttonStyle(ProjectActionStyle(tone: .primary, size: .compact))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(orderedProjects) { project in
                            MenuBarProjectRow(
                                project: project,
                                model: model,
                                onSelectInMainWindow: {
                                    model.selection = project.id
                                    activateMainWindow()
                                    dismiss()
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
            }

            Divider()
            footerBar
        }
        .frame(width: 330)
        .background(LauncherPalette.surface)
        .nativeControlFocus()
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Dev Launcher")
                .font(.headline)

            if model.runningCount > 0 {
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(LauncherPalette.running)
                        .frame(width: 6, height: 6)
                    Text("\(model.runningCount) 运行中")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(LauncherPalette.running)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(LauncherPalette.runningFill, in: Capsule())
                .overlay { Capsule().strokeBorder(LauncherPalette.runningEdge) }
            }

            Spacer()

            if !model.startablePinnedProjects.isEmpty {
                Button {
                    model.startPinnedProjects()
                } label: {
                    Label("启动置顶", systemImage: "play.fill")
                }
                .buttonStyle(ProjectActionStyle(tone: .primary, size: .compact))
                .help("一键启动所有尚未运行的置顶项目")
            }

            if model.runningCount > 0 {
                Button {
                    model.stopAll()
                } label: {
                    Text("全部停止")
                }
                .buttonStyle(ProjectActionStyle(tone: .stop, size: .compact))
                .help("停止全部运行中的项目")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button {
                activateMainWindow()
                dismiss()
            } label: {
                Label("主窗口", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)

            Button {
                activateMainWindow()
                Task { @MainActor in
                    selectProjects(model)
                }
                dismiss()
            } label: {
                Label("添加…", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
            .accessibilityLabel("设置")

            Button("退出") {
                dismiss()
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func activateMainWindow() {
        NSApp.activate()
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("projects") == true }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "projects")
        }
    }
}

private struct MenuBarProjectRow: View {
    let project: Project
    var model: LauncherModel
    let onSelectInMainWindow: () -> Void
    @State private var hovering = false

    var body: some View {
        let phase = model.runPhase(project.id)
        let liveURL = model.browserURL(for: project)
        let displayPort = model.effectivePort(for: project)

        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ProjectKindIcon(kind: project.kind, size: 22)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 4) {
                        Text(project.listName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if project.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }

                    HStack(spacing: 5) {
                        Circle()
                            .fill(phaseColor(phase))
                            .frame(width: 5.5, height: 5.5)
                        Text(phase.rawValue)
                        if let port = displayPort {
                            Text("· :\(port.formatted(.number.grouping(.never)))")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(phase.isActive || phase == .failed ? phaseColor(phase) : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectInMainWindow)
            .help("在主窗口中查看 \(project.listName)")

            HStack(spacing: 4) {
                if let url = liveURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(ProjectActionStyle(size: .compact))
                    .help("在浏览器中打开 \(url.absoluteString)")
                    .accessibilityLabel("在浏览器中打开")
                }

                if phase == .running {
                    Button {
                        model.restart(project.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(ProjectActionStyle(size: .compact))
                    .help("重启")
                    .accessibilityLabel("重启")
                }

                Button(role: phase.isActive ? .destructive : nil) {
                    if phase.isActive {
                        model.stop(project.id)
                    } else {
                        model.start(project)
                    }
                } label: {
                    Image(systemName: phase.isActive ? "stop.fill" : "play.fill")
                }
                .buttonStyle(ProjectActionStyle(tone: phase.isActive ? .stop : .neutral, size: .compact))
                .disabled(phase == .stopping || (!phase.isActive && !project.hasLaunchCommand))
                .help(phase.isActive ? "停止" : "启动")
                .accessibilityLabel(phase.isActive ? "停止 \(project.listName)" : "启动 \(project.listName)")
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            hovering ? LauncherPalette.surfaceHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { hovering = $0 }
    }

    private func phaseColor(_ phase: RunPhase) -> Color {
        switch phase {
        case .running: LauncherPalette.running
        case .starting, .installing, .stopping: LauncherPalette.pending
        case .failed: LauncherPalette.stop
        default: .secondary
        }
    }
}
