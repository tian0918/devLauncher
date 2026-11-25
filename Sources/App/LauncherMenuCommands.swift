import AppKit
import SwiftUI

struct FocusedLauncherActions {
    let selectedProject: Project?
    let selectedPhase: RunPhase
    let browserURL: URL?
    let isProjectAvailable: Bool
    let hasLog: Bool
    let gitStatus: GitRepositoryStatus?
    let isGitBusy: Bool
    let runningCount: Int
    let runningOnly: Bool
    let isModalPresented: Bool

    let focusSearch: () -> Void
    let toggleRunningOnly: () -> Void
    let editConfiguration: () -> Void
    let editAlias: () -> Void
    let relocateProject: () -> Void
    let removeProject: () -> Void
    let revealInFinder: () -> Void
    let copyPath: () -> Void
    let openInBrowser: () -> Void
    let createBranch: () -> Void
}

private struct FocusedLauncherActionsKey: FocusedValueKey {
    typealias Value = FocusedLauncherActions
}

extension FocusedValues {
    var launcherActions: FocusedLauncherActions? {
        get { self[FocusedLauncherActionsKey.self] }
        set { self[FocusedLauncherActionsKey.self] = newValue }
    }
}

struct LauncherMenuCommands: Commands {
    let model: LauncherModel
    @FocusedValue(\.launcherActions) private var actions
    @AppStorage(ConsoleTypography.storageKey) private var consoleFontSize = ConsoleTypography.defaultSize

    private var canActOnProject: Bool {
        actions != nil && actions?.isModalPresented == false && actions?.selectedProject != nil
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            AddProjectsCommandButton(model: model)
        }

        CommandGroup(after: .textEditing) {
            Button("查找项目…") {
                actions?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil || actions?.isModalPresented == true)
        }

        CommandGroup(after: .toolbar) {
            Button(actions?.runningOnly == true ? "显示全部项目" : "仅显示运行中的项目") {
                actions?.toggleRunningOnly()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(actions == nil || (actions?.runningCount == 0 && actions?.runningOnly == false))

            Divider()

            Button("放大日志字号") {
                consoleFontSize = ConsoleTypography.clamp(consoleFontSize + ConsoleTypography.step)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(consoleFontSize >= ConsoleTypography.maxSize)

            Button("缩小日志字号") {
                consoleFontSize = ConsoleTypography.clamp(consoleFontSize - ConsoleTypography.step)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(consoleFontSize <= ConsoleTypography.minSize)

            Button("实际日志字号") {
                consoleFontSize = ConsoleTypography.defaultSize
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(consoleFontSize == ConsoleTypography.defaultSize)
        }

        CommandMenu("项目") {
            Button("启动") {
                if let project = actions?.selectedProject {
                    model.start(project)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
                !canActOnProject
                    || actions?.selectedPhase.isActive == true
                    || actions?.selectedProject?.hasLaunchCommand != true
            )

            Button("启动全部置顶项目") {
                model.startPinnedProjects()
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(model.startablePinnedProjects.isEmpty)

            Button("停止") {
                if let id = actions?.selectedProject?.id {
                    model.stop(id)
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(
                !canActOnProject
                    || actions?.selectedPhase.isActive != true
                    || actions?.selectedPhase == .stopping
            )

            Button("重启") {
                if let id = actions?.selectedProject?.id {
                    model.restart(id)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canActOnProject || actions?.selectedPhase != .running)

            Button("停止全部运行中的项目") {
                model.stopAll()
            }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(model.runningCount == 0)

            Divider()

            Button(actions?.selectedProject?.pinned == true ? "取消置顶" : "置顶项目") {
                if let id = actions?.selectedProject?.id {
                    model.togglePinned(id)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!canActOnProject)

            Button("清空运行日志") {
                if let id = actions?.selectedProject?.id {
                    model.clearLog(id)
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canActOnProject || actions?.hasLog != true)

            Button("在浏览器中打开") {
                actions?.openInBrowser()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!canActOnProject || actions?.browserURL == nil)

            Divider()

            Button("编辑启动配置…") {
                actions?.editConfiguration()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!canActOnProject || actions?.selectedPhase.isActive == true)

            Button("编辑列表别名…") {
                actions?.editAlias()
            }
            .disabled(!canActOnProject)

            Button("在 Finder 中显示") {
                actions?.revealInFinder()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!canActOnProject || actions?.isProjectAvailable != true)

            Button("复制项目路径") {
                actions?.copyPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!canActOnProject)

            Button("重新定位…") {
                actions?.relocateProject()
            }
            .disabled(!canActOnProject || actions?.selectedPhase.isActive == true)

            Divider()

            Button("检查远程更新（Fetch）") {
                if let project = actions?.selectedProject {
                    model.gitFetch(for: project)
                }
            }
            .disabled(!canActOnProject || actions?.gitStatus == nil || actions?.isGitBusy == true)

            Button("拉取（Pull）") {
                if let project = actions?.selectedProject {
                    model.gitPull(for: project)
                }
            }
            .disabled(!canActOnProject || actions?.gitStatus == nil || actions?.isGitBusy == true)

            Button("推送（Push）") {
                if let project = actions?.selectedProject {
                    model.gitPush(for: project)
                }
            }
            .disabled(
                !canActOnProject
                    || actions?.gitStatus == nil
                    || actions?.gitStatus?.isDetached == true
                    || actions?.isGitBusy == true
            )

            Button("新建分支…") {
                actions?.createBranch()
            }
            .disabled(!canActOnProject || actions?.gitStatus == nil || actions?.isGitBusy == true)

            Divider()

            Button("移除项目…", role: .destructive) {
                actions?.removeProject()
            }
            .disabled(!canActOnProject || actions?.selectedPhase.isActive == true)
        }
    }
}

private struct AddProjectsCommandButton: View {
    let model: LauncherModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("添加项目…") {
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && $0.identifier?.rawValue.contains("projects") == true
            }
            if !hasVisibleMainWindow {
                openWindow(id: "projects")
                Task { @MainActor in
                    selectProjects(model)
                }
            } else {
                selectProjects(model)
            }
        }
        .keyboardShortcut("o")
    }
}
