import SwiftUI

struct ProjectGitToolbarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: Project
    let status: GitRepositoryStatus
    var model: LauncherModel
    @Binding var creatingBranchFor: Project?
    @Binding var showingGitHistory: Bool

    var body: some View {
        let busy = model.isGitBusy(project.id)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                gitStatusCluster(busy: busy)
                Spacer(minLength: 8)
                gitActionButtons(busy: busy)
            }
            VStack(alignment: .leading, spacing: 8) {
                gitStatusCluster(busy: busy)
                HStack {
                    Spacer(minLength: 0)
                    gitActionButtons(busy: busy)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.line)
        }
        .shadow(color: LauncherPalette.cardShadow(colorScheme, contrast: colorSchemeContrast), radius: 4, y: 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.gitNotices[project.id])
    }

    private func gitStatusCluster(busy: Bool) -> some View {
        HStack(spacing: 7) {
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
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
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
            .accessibilityLabel("Git 分支：\(status.branch)")

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
                    ink: LauncherPalette.pushInk,
                    fill: LauncherPalette.pushFill,
                    edge: LauncherPalette.pushEdge
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
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 2.5)
        .background(fill, in: Capsule())
        .overlay { Capsule().strokeBorder(edge) }
        .fixedSize()
    }

    private func gitActionButtons(busy: Bool) -> some View {
        HStack(spacing: 5) {
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
    }
}
