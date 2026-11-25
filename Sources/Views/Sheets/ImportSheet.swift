import SwiftUI

struct ImportSheet: View {
    var model: LauncherModel
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
                        .font(.title3.weight(.semibold))
                    if !candidates.isEmpty {
                        Text("发现 \(candidates.count) 个项目，已选 \(selection.count) 项")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !selectable.isEmpty {
                    Button(selection == selectable ? "取消全选" : "全选") {
                        selection = selection == selectable ? [] : selectable
                    }
                    .buttonStyle(ProjectActionStyle(size: .compact))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "未找到可导入的项目",
                        systemImage: "folder",
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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .nativeControlFocus()
        .background(LauncherPalette.canvas)
        .frame(width: 650, height: 460)
        .onAppear { selection = selectable }
    }
}

private struct ImportCandidateRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let candidate: ProjectCandidate
    let alreadyAdded: Bool
    @Binding var selected: Bool
    @State private var hovering = false

    var body: some View {
        Toggle(isOn: $selected) {
            HStack(alignment: .top, spacing: 10) {
                ProjectKindIcon(kind: candidate.kind, size: 26)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(candidate.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        ProjectKindBadge(kind: candidate.kind)
                        if alreadyAdded {
                            NeutralPillBadge(text: "已添加")
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
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(LauncherPalette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 5))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(LauncherPalette.lineSubtle)
                                }
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
        .padding(.vertical, 8.5)
        .background(
            hovering && !alreadyAdded ? LauncherPalette.surfaceHover : LauncherPalette.surfaceSubtle.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    selected && !alreadyAdded
                        ? Color.accentColor.opacity(0.45)
                        : LauncherPalette.lineSubtle
                )
        }
        .opacity(alreadyAdded ? 0.65 : 1)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help(candidate.path)
    }
}
