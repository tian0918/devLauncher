import AppKit
import SwiftUI

struct NVMSettings: View {
    var model: LauncherModel
    @AppStorage(LauncherPreferences.showMenuBarExtraKey) private var showMenuBarExtra = true
    @State private var selectionError: String?

    var body: some View {
        Form {
            Section {
                Toggle("在菜单栏显示快捷入口", isOn: $showMenuBarExtra)
            } header: {
                Text("通用")
            } footer: {
                Text("关闭主窗口后，可通过屏幕右上角的菜单栏图标查看运行状态、一键启停项目及打开本地监听地址。")
            }

            Section("Node 版本管理") {
                LabeledContent("检测方式") {
                    NeutralPillBadge(text: model.saved.nvmScript == nil ? "自动检测" : "手动指定")
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
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        VersionTagFlowLayout(spacing: 6) {
                            ForEach(model.versions, id: \.self) { ver in
                                Text(ver)
                                    .font(.caption.monospaced().weight(.medium))
                                    .foregroundStyle(LauncherPalette.badgeInk)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
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
                    Button("重新检测") {
                        selectionError = nil
                        model.refreshNVM()
                    }
                    .buttonStyle(ProjectActionStyle(size: .compact))
                    .disabled(model.detecting)
                    if model.saved.nvmScript != nil {
                        Button("恢复自动检测") {
                            selectionError = nil
                            model.setNVMScript(nil)
                        }
                        .buttonStyle(ProjectActionStyle(size: .compact))
                    }
                }
                .padding(.top, 2)
                .nativeControlFocus()
            }

            if let errorText = selectionError {
                Section {
                    Label(errorText, systemImage: "exclamationmark.circle")
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
                selectionError = "请选择可读取的 nvm.sh 文件。"
                return
            }
            selectionError = nil
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
