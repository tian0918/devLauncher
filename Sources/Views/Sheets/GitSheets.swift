import AppKit
import SwiftUI

struct GitCreateBranchSheet: View {
    let project: Project
    let baseBranch: String?
    var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var submitting = false

    private var trimmed: String { branchName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ProjectGit.isValidBranchName(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(LauncherPalette.badgeFill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(LauncherPalette.badgeEdge)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建分支")
                        .font(.title3.weight(.semibold))
                    Text(baseBranch.map { "\(project.name) · 基于 \($0)" } ?? project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("分支名称")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("分支名称", text: $branchName, prompt: Text("例如 feat/login"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(submitting)
                if !trimmed.isEmpty && !isValid {
                    Label("分支名不能包含空格、.. 或特殊符号，也不能以 - 开头。", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(LauncherPalette.stop)
                } else {
                    Text("创建后会立即切换到新分支。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            HStack(spacing: 8) {
                if submitting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ProjectActionStyle())
                    .disabled(submitting)
                Button("创建并切换") {
                    submitting = true
                    Task {
                        let ok = await model.gitCreateBranch(trimmed, for: project)
                        submitting = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ProjectActionStyle(tone: .primary))
                .disabled(submitting || !isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .nativeControlFocus()
        .background(LauncherPalette.canvas)
        .frame(width: 410)
    }
}

struct GitHistoryPopover: View {
    let status: GitRepositoryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("最近提交")
                    .font(.headline)
                Spacer()
                NeutralPillBadge(text: status.branch, monospaced: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if status.recentCommits.isEmpty {
                ContentUnavailableView(
                    "暂无提交记录",
                    systemImage: "tray",
                    description: Text("当前分支还没有可显示的 Git 提交历史。")
                )
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(status.recentCommits.enumerated()), id: \.element.id) { index, commit in
                            GitCommitRow(commit: commit)
                            if index < status.recentCommits.count - 1 {
                                Divider()
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 330)
            }
        }
        .background(LauncherPalette.surface)
        .frame(width: 400)
        .nativeControlFocus()
    }
}

private struct GitCommitRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let commit: GitCommit
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    await MainActor.run {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { copied = false }
                    }
                }
            } label: {
                Text(copied ? "已复制" : commit.hash)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(copied ? LauncherPalette.running : LauncherPalette.badgeInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        copied ? LauncherPalette.runningFill : LauncherPalette.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(copied ? LauncherPalette.runningEdge : LauncherPalette.lineSubtle)
                    }
            }
            .buttonStyle(.borderless)
            .help("复制提交哈希 \(commit.hash)")
            .accessibilityLabel("复制提交哈希 \(commit.hash)")

            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(commit.author)
                        .lineLimit(1)
                    Text("·")
                    Text(commit.relativeDate)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? LauncherPalette.surfaceHover.opacity(0.6) : Color.clear)
        .onHover { hovering = $0 }
    }
}
