import SwiftUI

struct ProjectRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let project: Project
    let phase: RunPhase
    let effectivePort: UInt16?
    let gitStatus: GitRepositoryStatus?
    let selected: Bool
    let listFocused: Bool
    var showPinIcon: Bool = false
    let onSelect: () -> Void
    @State private var hovering = false

    private var parentFolder: String {
        URL(fileURLWithPath: project.path).deletingLastPathComponent().lastPathComponent
    }

    private var indicatorColor: Color {
        if phase == .running { return LauncherPalette.running }
        return appearsActive && listFocused ? Color.accentColor : .secondary
    }

    var body: some View {
        HStack(spacing: 9) {
            ProjectKindIcon(kind: project.kind, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(project.listName)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if showPinIcon {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: 5) {
                    if let git = gitStatus {
                        HStack(spacing: 3.5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption2.weight(.medium))
                                .accessibilityHidden(true)
                            Text(git.branch)
                                .lineLimit(1)
                            if git.isDirty {
                                HStack(spacing: 1.5) {
                                    Image(systemName: git.conflictedCount > 0 ? "exclamationmark.triangle.fill" : "pencil")
                                        .font(.caption2.weight(.semibold))
                                        .accessibilityHidden(true)
                                    Text("\(git.changedCount)")
                                        .monospacedDigit()
                                }
                                .foregroundStyle(git.conflictedCount > 0 ? LauncherPalette.stop : LauncherPalette.warning)
                            }
                            if git.behind > 0 {
                                Text("↓\(git.behind)")
                                    .monospacedDigit()
                                    .foregroundStyle(LauncherPalette.pythonInk)
                            }
                            if git.ahead > 0 {
                                Text("↑\(git.ahead)")
                                    .monospacedDigit()
                                    .foregroundStyle(LauncherPalette.pushInk)
                            }
                        }
                    } else {
                        Text(parentFolder)
                            .lineLimit(1)
                    }
                    if let port = effectivePort {
                        Text("·")
                        Text(":\(port.formatted(.number.grouping(.never)))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if phase.isActive {
                StatusLabel(phase: phase, style: .compact)
                    .fixedSize()
            } else if phase == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(LauncherPalette.stop)
                    .help("上次运行失败")
                    .accessibilityLabel("上次运行失败")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .padding(.vertical, 6.5)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LauncherPalette.sidebarRowFill(
                        selected: selected,
                        hovering: hovering,
                        focused: listFocused,
                        appearsActive: appearsActive,
                        scheme: colorScheme,
                        contrast: colorSchemeContrast
                    )
                )
        }
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(indicatorColor)
                    .frame(width: 3, height: 16)
                    .padding(.leading, 2)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    LauncherPalette.sidebarRowBorder(
                        selected: selected,
                        focused: listFocused,
                        appearsActive: appearsActive,
                        contrast: colorSchemeContrast
                    )
                )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onSelect)
        .help(gitStatus.map { "\(project.path)\n\($0.overviewSummary)" } ?? project.path)
    }
}
