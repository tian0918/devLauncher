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
        VStack(alignment: .leading, spacing: 14) {
            Text("导入项目").font(.title2.weight(.semibold))
            if candidates.isEmpty {
                ContentUnavailableView(
                    "未找到可导入的项目", systemImage: "folder",
                    description: Text("请选择 package.json、Python 项目文件或脚本，也可以扫描文件夹。")
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack {
                    Text("已选 \(selection.count) 项").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if !selectable.isEmpty {
                        Button(selection == selectable ? "取消全选" : "全选") {
                            selection = selection == selectable ? [] : selectable
                        }
                        .buttonStyle(.borderless)
                    }
                }
                List(candidates) { candidate in
                    let alreadyAdded = existing.contains(candidate.path)
                    Toggle(isOn: Binding(
                        get: { alreadyAdded || selection.contains(candidate.path) },
                        set: { checked in
                            if checked { selection.insert(candidate.path) }
                            else { selection.remove(candidate.path) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(candidate.name).fontWeight(.medium)
                                Text(candidate.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                if alreadyAdded {
                                    Text("已添加").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(candidate.path)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if !alreadyAdded {
                                Text(candidate.suggestedCommand.isEmpty ? "需要填写启动命令" : candidate.suggestedCommand)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(alreadyAdded)
                    .help(candidate.path)
                    .padding(.vertical, 4)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            if !skipped.isEmpty {
                DisclosureGroup("有 \(skipped.count) 项无法读取或格式无效") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(Set(skipped)).sorted(), id: \.self) { path in
                                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 85)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    if model.add(candidates.filter { selection.contains($0.path) }) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(21)
        .frame(width: 640, height: 455)
        .onAppear { selection = selectable }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑列表别名").font(.title2.weight(.semibold))
            TextField("列表别名", text: $alias, prompt: Text(project.name))
                .textFieldStyle(.roundedBorder)
            Text("留空时，列表显示原项目名。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if model.setListAlias(alias, for: project.id) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct ProjectEditor: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var project: Project
    @State private var mode: Mode
    @State private var version: String

    private enum Mode: String, CaseIterable, Identifiable {
        case automatic = "自动"
        case installed = "已安装版本"
        case custom = "手动指定"

        var id: Self { self }
    }

    init(project: Project, model: LauncherModel) {
        self.model = model
        _project = State(initialValue: project)
        let version = project.nodeVersion ?? ""
        _version = State(initialValue: version)
        _mode = State(initialValue: project.nodeVersion == nil ? .automatic :
            (model.versions.contains(version) ? .installed : .custom))
    }

    private var cleanedVersion: String { version.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        let hasCommand = !project.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasCommand && !project.command.utf8.contains(0) else { return false }
        if project.kind == .python { return true }
        let validVersion = mode == .automatic || NVM.validSelector(cleanedVersion)
        let installed = mode != .installed || model.versions.contains(cleanedVersion)
        return validVersion && installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("编辑启动配置").font(.title2.weight(.semibold))
            Text(project.name).foregroundStyle(.secondary).lineLimit(1)

            Form {
                if project.kind == .node {
                    nodeSettings
                } else {
                    Text("优先使用项目中的 .venv 或 venv，也可以在命令中指定解释器。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                TextField("启动命令", text: $project.command,
                          prompt: Text(project.kind == .python ? "python3 main.py" : "npm run dev"), axis: .vertical)
                    .lineLimit(2...5)
                    .font(.body.monospaced())
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: project.kind == .python ? 150 : 195)

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    project.command = project.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    if project.kind == .node { project.nodeVersion = mode == .automatic ? nil : cleanedVersion }
                    if model.update(project) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 535)
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
                Text("请输入有效的 nvm 版本或别名。").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct NVMSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section("Node 版本管理") {
                LabeledContent("检测方式", value: model.saved.nvmScript == nil ? "自动检测" : "手动指定")
                LabeledContent("nvm.sh") {
                    if model.detecting {
                        ProgressView().controlSize(.small)
                    } else {
                        let path = model.installation?.script ?? model.saved.nvmScript
                        Text(path ?? "未找到")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(model.installation == nil ? Color.orange : Color.secondary)
                    }
                }
                if let directory = model.installation?.directory {
                    LabeledContent("版本目录") {
                        Text(directory).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if !model.versions.isEmpty {
                    LabeledContent("已安装版本", value: model.versions.joined(separator: " · "))
                } else if !model.detecting && model.installation != nil {
                    Text("这个目录里没有可用的 Node。如果终端里已有 Node，请选择终端使用的 nvm 目录。")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !model.detecting && model.installation == nil {
                    Text("项目将使用 PATH 中的 Node。需要切换版本时，可在这里指定 nvm。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("选择 nvm 目录…", action: selectInstallation)
                    Button("重新检测", action: model.refreshNVM).disabled(model.detecting)
                    if model.saved.nvmScript != nil {
                        Button("恢复自动检测") { model.setNVMScript(nil) }
                    }
                }
            }
            if let alert = model.alert {
                Text(alert).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 260)
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
