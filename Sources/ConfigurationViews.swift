import SwiftUI

struct ImportSheet: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    private var candidates: [ProjectCandidate] { model.scanResult?.candidates ?? [] }
    private var existing: Set<String> { Set(model.saved.projects.map(\.path)) }
    private var selectable: Set<String> { Set(candidates.map(\.path)).subtracting(existing) }
    private var skipped: [String] { model.scanResult?.skipped ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入项目")
                        .font(.title2.weight(.semibold))
                    if !candidates.isEmpty {
                        Text("发现 \(candidates.count) 个项目，已选 \(selection.count) 项")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !selectable.isEmpty {
                    Button(selection == selectable ? "取消全选" : "全选") {
                        selection = selection == selectable ? [] : selectable
                    }
                    .buttonStyle(ProjectActionStyle(size: .compact))
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "未找到可导入的项目", systemImage: "folder",
                        description: Text("请选择 package.json、Python 项目文件或脚本，也可以扫描文件夹。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(candidates) { candidate in
                                ImportCandidateRow(
                                    candidate: candidate,
                                    alreadyAdded: existing.contains(candidate.path),
                                    selected: Binding(
                                        get: { existing.contains(candidate.path) || selection.contains(candidate.path) },
                                        set: { checked in
                                            if checked { selection.insert(candidate.path) }
                                            else { selection.remove(candidate.path) }
                                        }
                                    )
                                )
                            }
                        }
                        .padding(8)
                    }
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(LauncherPalette.line)
                    }
                }

                if !skipped.isEmpty {
                    DisclosureGroup("有 \(skipped.count) 项无法读取或格式无效") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(Set(skipped)).sorted(), id: \.self) { path in
                                    Text(path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                        }
                        .frame(maxHeight: 85)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(LauncherPalette.line)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxHeight: .infinity)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ProjectActionStyle())
                Button(selection.isEmpty ? "导入" : "导入 \(selection.count) 个项目") {
                    if model.add(candidates.filter { selection.contains($0.path) }) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ProjectActionStyle(tone: .primary))
                .disabled(selection.isEmpty)
            }
            .focusEffectDisabled()
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(LauncherPalette.canvas)
        .frame(width: 660, height: 470)
        .onAppear { selection = selectable }
    }
}

private struct ImportCandidateRow: View {
    let candidate: ProjectCandidate
    let alreadyAdded: Bool
    @Binding var selected: Bool
    @State private var hovering = false

    var body: some View {
        Toggle(isOn: $selected) {
            HStack(alignment: .top, spacing: 10) {
                ProjectKindIcon(kind: candidate.kind, size: 28)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(candidate.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        ProjectKindBadge(kind: candidate.kind)
                        if alreadyAdded {
                            Text("已添加")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(LauncherPalette.surfaceSubtle, in: Capsule())
                                .overlay { Capsule().strokeBorder(LauncherPalette.line) }
                        }
                    }

                    Text(candidate.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !alreadyAdded {
                        if candidate.suggestedCommand.isEmpty {
                            Label("未检测到可用的启动命令，导入后需手动填写。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(LauncherPalette.warning)
                        } else {
                            Text("$ \(candidate.suggestedCommand)")
                                .font(.caption.monospaced())
                                .foregroundStyle(LauncherPalette.actionInk)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .disabled(alreadyAdded)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            hovering && !alreadyAdded ? LauncherPalette.surfaceHover : LauncherPalette.surfaceSubtle.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    selected && !alreadyAdded ? LauncherPalette.selectionEdge : LauncherPalette.lineSubtle
                )
        }
        .opacity(alreadyAdded ? 0.65 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(candidate.path)
    }
}

struct ProjectAliasEditor: View {
    let project: Project
    let model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var alias: String

    init(project: Project, model: LauncherModel) {
        self.project = project
        self.model = model
        _alias = State(initialValue: project.listAlias ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProjectKindIcon(kind: project.kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑列表别名")
                        .font(.title3.weight(.semibold))
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Text("别名")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("列表别名", text: $alias, prompt: Text(project.name))
                    .textFieldStyle(.roundedBorder)
                Text("留空时，侧边栏列表显示原项目名。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            HStack(spacing: 10) {
                if !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("恢复原名") { alias = "" }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(LauncherPalette.actionInk)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ProjectActionStyle())
                Button("保存") {
                    if model.setListAlias(alias, for: project.id) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ProjectActionStyle(tone: .primary))
            }
            .focusEffectDisabled()
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(LauncherPalette.canvas)
        .frame(width: 390)
    }
}

struct GitCreateBranchSheet: View {
    let project: Project
    let baseBranch: String?
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var submitting = false

    private var trimmed: String { branchName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ProjectGit.isValidBranchName(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LauncherPalette.actionInk)
                    .frame(width: 30, height: 30)
                    .background(LauncherPalette.selection, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(LauncherPalette.selectionEdge.opacity(0.7))
                    }
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

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

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

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            HStack(spacing: 10) {
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
            .focusEffectDisabled()
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LauncherPalette.actionInk)
                Text("最近提交")
                    .font(.headline)
                Spacer()
                Text(status.branch)
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(LauncherPalette.actionInk)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(LauncherPalette.selection, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            if status.recentCommits.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("暂无提交记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(status.recentCommits.enumerated()), id: \.element.id) { index, commit in
                            GitCommitRow(commit: commit)
                            if index < status.recentCommits.count - 1 {
                                Rectangle()
                                    .fill(LauncherPalette.lineSubtle)
                                    .frame(height: 1)
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
    }
}

private struct GitCommitRow: View {
    let commit: GitCommit
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
                withAnimation(.easeInOut(duration: 0.14)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.14)) { copied = false }
                    }
                }
            } label: {
                Text(copied ? "已复制" : commit.hash)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(copied ? LauncherPalette.running : LauncherPalette.actionInk)
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
            .buttonStyle(.plain)
            .help("复制提交哈希 \(commit.hash)")

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

struct ProjectEditor: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var project: Project
    @State private var mode: Mode
    @State private var version: String
    @State private var port: String

    private enum Mode: String, CaseIterable, Identifiable {
        case automatic = "自动"
        case installed = "已安装版本"
        case custom = "手动指定"

        var id: Self { self }
    }

    init(project: Project, model: LauncherModel) {
        self.model = model
        _project = State(initialValue: project)
        _port = State(initialValue: project.launchPort.map(String.init) ?? "")
        let version = project.nodeVersion ?? ""
        _version = State(initialValue: version)
        _mode = State(initialValue: project.nodeVersion == nil ? .automatic :
            (model.versions.contains(version) ? .installed : .custom))
    }

    private var cleanedVersion: String { version.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanedPort: String { port.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var launchPort: UInt16? {
        guard let value = UInt16(cleanedPort), value != 0 else { return nil }
        return value
    }

    private var canSave: Bool {
        guard project.hasLaunchCommand && !project.command.utf8.contains(0) else { return false }
        guard cleanedPort.isEmpty || launchPort != nil else { return false }
        if project.kind == .python { return true }
        let validVersion = mode == .automatic || NVM.validSelector(cleanedVersion)
        let installed = mode != .installed || model.versions.contains(cleanedVersion)
        return validVersion && installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ProjectKindIcon(kind: project.kind, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("编辑启动配置")
                            .font(.title3.weight(.semibold))
                        ProjectKindBadge(kind: project.kind)
                    }
                    Text(project.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            Form {
                Section("运行环境与命令") {
                    if project.kind == .node {
                        nodeSettings
                    } else {
                        Text("优先使用项目中的 .venv 或 venv，也可以在命令中指定解释器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("启动命令", text: $project.command,
                              prompt: Text(project.kind == .python ? "python3 main.py" : "npm run dev"), axis: .vertical)
                        .lineLimit(2...5)
                        .font(.body.monospaced())
                }

                Section {
                    TextField("启动端口", text: $port, prompt: Text("留空使用项目默认设置"))
                        .font(.body.monospaced())
                    if let launchPort {
                        PortStatusLabel(port: launchPort)
                            .id(launchPort)
                    } else if !cleanedPort.isEmpty {
                        Label("请输入 1–65535 之间的端口号。", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(LauncherPalette.stop)
                    }
                } header: {
                    Text("端口配置")
                } footer: {
                    Text("端口通过 `PORT` 环境变量传入，并自动为 Vite、Django、Uvicorn 等常见框架附加端口参数。其他框架可在启动命令中引用 `$PORT`。")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: project.kind == .python ? 305 : 355)

            Rectangle().fill(LauncherPalette.lineSubtle).frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ProjectActionStyle())
                Button("保存") {
                    project.command = project.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    project.launchPort = launchPort
                    if project.kind == .node { project.nodeVersion = mode == .automatic ? nil : cleanedVersion }
                    if model.update(project) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ProjectActionStyle(tone: .primary))
                .disabled(!canSave)
            }
            .focusEffectDisabled()
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(LauncherPalette.canvas)
        .frame(width: 550)
        .onAppear {
            if project.kind == .node { model.refreshInstalledVersions() }
        }
        .onChange(of: mode) { _, newValue in
            if newValue == .installed && !model.versions.contains(version) {
                version = model.versions.first ?? ""
            }
        }
    }

    @ViewBuilder
    private var nodeSettings: some View {
        Picker("Node 版本", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        switch mode {
        case .automatic:
            Text("优先使用 .nvmrc 或 nvm 的 default；没有 nvm 时使用 PATH 中的 Node。")
                .font(.caption).foregroundStyle(.secondary)
        case .installed:
            if model.versions.isEmpty {
                Text(model.detecting ? "正在检测已安装版本…" : "未检测到已安装版本。请检查 nvm 设置。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("已安装版本", selection: $version) {
                    if !model.versions.contains(version) { Text("选择版本").tag(version) }
                    ForEach(model.versions, id: \.self) { Text($0).tag($0) }
                }
            }
        case .custom:
            TextField("版本或别名", text: $version, prompt: Text("例如 22 或 lts/*"))
                .font(.body.monospaced())
            if !cleanedVersion.isEmpty && !NVM.validSelector(cleanedVersion) {
                Label("请输入有效的 nvm 版本或别名。", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(LauncherPalette.stop)
            }
        }
    }
}

struct PortStatusLabel: View {
    let port: UInt16
    @State private var status: TCPPortStatus?

    private var presentation: (text: String, icon: String?, ink: Color, fill: Color, edge: Color) {
        switch status {
        case .available:
            ("TCP 端口可用", "checkmark.circle.fill", LauncherPalette.running, LauncherPalette.runningFill, LauncherPalette.runningEdge)
        case .occupied:
            ("TCP 端口已被占用", "exclamationmark.triangle.fill", LauncherPalette.warning, LauncherPalette.warningFill, LauncherPalette.warningEdge)
        case .unknown:
            ("无法检测 TCP 端口", "questionmark.circle", .secondary, LauncherPalette.surfaceSubtle, LauncherPalette.line)
        case nil:
            ("正在检测 TCP 端口…", nil, .secondary, LauncherPalette.surfaceSubtle, LauncherPalette.line)
        }
    }

    var body: some View {
        let style = presentation
        HStack(spacing: 5) {
            if let icon = style.icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(style.text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(style.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(style.fill, in: Capsule())
        .overlay { Capsule().strokeBorder(style.edge) }
        .task(id: port) {
            while !Task.isCancelled {
                status = TCPPortStatus.check(port)
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }
}

struct NVMSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section("Node 版本管理") {
                LabeledContent("检测方式") {
                    Text(model.saved.nvmScript == nil ? "自动检测" : "手动指定")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LauncherPalette.actionInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(LauncherPalette.selection, in: Capsule())
                }

                LabeledContent("nvm.sh") {
                    if model.detecting {
                        ProgressView().controlSize(.small)
                    } else {
                        let path = model.installation?.script ?? model.saved.nvmScript
                        Text(path ?? "未找到")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(model.installation == nil ? LauncherPalette.warning : .secondary)
                    }
                }

                if let directory = model.installation?.directory {
                    LabeledContent("版本目录") {
                        Text(directory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !model.versions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("已安装版本")
                            Spacer()
                            Text("\(model.versions.count) 个版本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VersionTagFlowLayout(spacing: 6) {
                            ForEach(model.versions, id: \.self) { ver in
                                Text(ver)
                                    .font(.caption.monospaced().weight(.medium))
                                    .foregroundStyle(LauncherPalette.actionInk)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(LauncherPalette.line)
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } else if !model.detecting && model.installation != nil {
                    Label("这个目录里没有可用的 Node。如果终端里已有 Node，请选择终端使用的 nvm 目录。",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(LauncherPalette.warning)
                }

                if !model.detecting && model.installation == nil {
                    Text("项目将使用 PATH 中的 Node。需要切换版本时，可在这里指定 nvm。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("选择 nvm 目录…", action: selectInstallation)
                        .buttonStyle(ProjectActionStyle(size: .compact))
                    Button("重新检测", action: model.refreshNVM)
                        .buttonStyle(ProjectActionStyle(size: .compact))
                        .disabled(model.detecting)
                    if model.saved.nvmScript != nil {
                        Button("恢复自动检测") { model.setNVMScript(nil) }
                            .buttonStyle(ProjectActionStyle(size: .compact))
                    }
                }
                .focusEffectDisabled()
                .padding(.top, 2)
            }

            if let alert = model.alert {
                Section {
                    Label(alert, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(LauncherPalette.stop)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(LauncherPalette.canvas)
        .frame(minWidth: 590, minHeight: 280)
    }

    private func selectInstallation() {
        let panel = NSOpenPanel()
        panel.title = "选择 nvm 安装目录"
        panel.message = "请选择包含 nvm.sh 和已安装 Node 版本的目录，也可以直接选择 nvm.sh。"
        panel.prompt = "选取"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        presentOpenPanel(panel) { urls in
            guard let url = urls.first else { return }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let script = isDirectory ? url.appendingPathComponent("nvm.sh") : url
            let path = script.standardizedFileURL.path
            guard script.lastPathComponent == "nvm.sh", NVM.manual(path) != nil else {
                model.alert = "请选择可读取的 nvm.sh 文件。"
                return
            }
            model.setNVMScript(path)
        }
    }
}

private struct VersionTagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: usedWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
