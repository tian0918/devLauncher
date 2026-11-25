import SwiftUI

struct ProjectEditor: View {
    var model: LauncherModel
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
                ProjectKindIcon(kind: project.kind, size: 30)
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
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

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
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .nativeControlFocus()
        .background(LauncherPalette.canvas)
        .frame(width: 540)
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
                ProjectKindIcon(kind: project.kind, size: 28)
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

            Divider()

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

            Divider()

            HStack(spacing: 8) {
                if !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("恢复原名") { alias = "" }
                        .buttonStyle(.borderless)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .nativeControlFocus()
        .background(LauncherPalette.canvas)
        .frame(width: 390)
    }
}
