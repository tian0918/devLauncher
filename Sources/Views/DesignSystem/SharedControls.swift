import AppKit
import SwiftUI

enum ActionTone {
    case neutral, primary, stop

    func colors(hovering: Bool, appearsActive: Bool) -> (label: Color, fill: Color, edge: Color) {
        switch self {
        case .neutral:
            return (
                .primary,
                hovering ? LauncherPalette.surfaceHover : LauncherPalette.surface,
                LauncherPalette.line
            )
        case .primary:
            guard appearsActive else {
                return (
                    .primary,
                    hovering ? LauncherPalette.surfaceHover : LauncherPalette.surface,
                    LauncherPalette.line
                )
            }
            return (
                LauncherPalette.accentLabel,
                hovering ? LauncherPalette.accentHover : Color.accentColor,
                hovering ? LauncherPalette.accentHover : Color.accentColor
            )
        case .stop:
            guard appearsActive else {
                return (
                    LauncherPalette.stop.opacity(0.85),
                    hovering ? LauncherPalette.stopFill : LauncherPalette.surface,
                    LauncherPalette.line
                )
            }
            return (
                LauncherPalette.stop,
                hovering ? LauncherPalette.stopFillHover : LauncherPalette.stopFill,
                LauncherPalette.stopEdge
            )
        }
    }
}

enum ControlSizeVariant {
    case regular, compact

    var horizontalPadding: CGFloat { self == .compact ? 8 : 10 }
    var minHeight: CGFloat { self == .compact ? 22 : 26 }
    var minWidth: CGFloat { self == .compact ? 24 : 28 }
    var cornerRadius: CGFloat { self == .compact ? 5.5 : 6.5 }
    var font: Font { self == .compact ? .caption.weight(.medium) : .callout.weight(.medium) }
}

struct ProjectControlSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tone: ActionTone = .neutral
    var size: ControlSizeVariant = .regular
    var hovering = false
    var pressed = false

    func body(content: Content) -> some View {
        let colors = tone.colors(hovering: hovering && isEnabled, appearsActive: appearsActive)
        content
            .font(size.font)
            .foregroundStyle(colors.label)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minWidth: size.minWidth, minHeight: size.minHeight)
            .background(colors.fill, in: RoundedRectangle(cornerRadius: size.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .strokeBorder(colors.edge)
            }
            .shadow(
                color: tone == .primary && isEnabled && appearsActive
                    ? Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08)
                    : .clear,
                radius: 2, y: 1
            )
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
    }
}

struct HoverableControlSurface<Content: View>: View {
    var tone: ActionTone = .neutral
    var size: ControlSizeVariant = .regular
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .modifier(ProjectControlSurface(tone: tone, size: size, hovering: hovering))
            .onHover { hovering = $0 }
    }
}

struct ProjectActionStyle: ButtonStyle {
    var tone: ActionTone = .neutral
    var size: ControlSizeVariant = .regular

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, tone: tone, size: size)
    }

    private struct ActionButtonBody: View {
        let configuration: Configuration
        let tone: ActionTone
        let size: ControlSizeVariant
        @State private var hovering = false

        var body: some View {
            configuration.label
                .modifier(ProjectControlSurface(
                    tone: tone,
                    size: size,
                    hovering: hovering,
                    pressed: configuration.isPressed
                ))
                .onHover { hovering = $0 }
        }
    }
}

private struct NativeControlFocusModifier: ViewModifier {
    @State private var keyboardNavigationEnabled = NSApp?.isFullKeyboardAccessEnabled ?? false

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled(!keyboardNavigationEnabled)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                keyboardNavigationEnabled = NSApp?.isFullKeyboardAccessEnabled ?? false
            }
    }
}

extension View {
    /// Displays focus rings on custom controls only when macOS Keyboard Navigation is enabled.
    func nativeControlFocus() -> some View {
        modifier(NativeControlFocusModifier())
    }
}

struct NeutralPillBadge: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .caption.monospaced().weight(.medium) : .caption.weight(.medium))
            .foregroundStyle(LauncherPalette.badgeInk)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(LauncherPalette.badgeFill, in: Capsule())
            .overlay { Capsule().strokeBorder(LauncherPalette.badgeEdge) }
    }
}

struct ProjectKindIcon: View {
    let kind: ProjectKind
    var size: CGFloat = 26

    private var label: String { kind == .python ? "PY" : "JS" }
    private var ink: Color { kind == .python ? LauncherPalette.pythonInk : LauncherPalette.nodeInk }
    private var fill: Color { kind == .python ? LauncherPalette.pythonFill : LauncherPalette.nodeFill }
    private var edge: Color { kind == .python ? LauncherPalette.pythonEdge : LauncherPalette.nodeEdge }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.26))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26)
                    .strokeBorder(edge)
            }
            .accessibilityHidden(true)
    }
}

struct ProjectKindBadge: View {
    let kind: ProjectKind

    private var ink: Color { kind == .python ? LauncherPalette.pythonInk : LauncherPalette.nodeInk }
    private var fill: Color { kind == .python ? LauncherPalette.pythonFill : LauncherPalette.nodeFill }
    private var edge: Color { kind == .python ? LauncherPalette.pythonEdge : LauncherPalette.nodeEdge }

    var body: some View {
        Text(kind.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(edge) }
    }
}

struct StatusLabel: View {
    enum Style {
        case compact
        case pill
    }

    @Environment(\.appearsActive) private var appearsActive
    let phase: RunPhase
    var style: Style = .compact

    private var color: Color {
        switch phase {
        case .running: LauncherPalette.running
        case .starting, .installing, .stopping: LauncherPalette.pending
        case .failed: LauncherPalette.stop
        default: .secondary
        }
    }

    private var fill: Color {
        switch phase {
        case .running: LauncherPalette.runningFill
        case .starting, .installing, .stopping: LauncherPalette.pendingFill
        case .failed: LauncherPalette.stopFill
        default: LauncherPalette.badgeFill
        }
    }

    private var edge: Color {
        switch phase {
        case .running: LauncherPalette.runningEdge
        case .starting, .installing, .stopping: LauncherPalette.pendingEdge
        case .failed: LauncherPalette.stopEdge
        default: LauncherPalette.badgeEdge
        }
    }

    private var showBadge: Bool {
        style == .pill || phase == .running || phase == .starting || phase == .installing || phase == .stopping
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(phase.rawValue)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(phase.isActive || phase == .failed ? color : .secondary)
        .padding(.horizontal, showBadge ? 7.5 : 0)
        .padding(.vertical, showBadge ? 2 : 0)
        .background {
            if showBadge {
                Capsule().fill(appearsActive ? fill : LauncherPalette.badgeFill)
            }
        }
        .overlay {
            if showBadge {
                Capsule().strokeBorder(appearsActive ? edge : LauncherPalette.badgeEdge)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("运行状态：\(phase.rawValue)")
    }
}

struct PortStatusLabel: View {
    let port: UInt16
    var interval: Duration = .seconds(2)
    @State private var status: TCPPortStatus?
    @State private var appActive = NSApp?.isActive ?? true

    private var presentation: (text: String, icon: String?, ink: Color, fill: Color, edge: Color) {
        switch status {
        case .available:
            ("端口可用", "checkmark.circle.fill", LauncherPalette.running, LauncherPalette.runningFill, LauncherPalette.runningEdge)
        case .occupied:
            ("端口已被占用", "exclamationmark.triangle.fill", LauncherPalette.warning, LauncherPalette.warningFill, LauncherPalette.warningEdge)
        case .unknown:
            ("无法检测端口", "questionmark.circle", .secondary, LauncherPalette.surfaceSubtle, LauncherPalette.line)
        case nil:
            ("检测中…", nil, .secondary, LauncherPalette.surfaceSubtle, LauncherPalette.line)
        }
    }

    var body: some View {
        let style = presentation
        HStack(spacing: 4.5) {
            if let icon = style.icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(style.text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(style.ink)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 2)
        .background(style.fill, in: Capsule())
        .overlay { Capsule().strokeBorder(style.edge) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TCP 端口 \(port) 状态：\(style.text)")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
        }
        .task(id: "\(port)-\(appActive)") {
            status = await TCPPortStatus.checkAsync(port)
            guard appActive else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                status = await TCPPortStatus.checkAsync(port)
            }
        }
    }
}

struct ProjectIDEMenuItems: View {
    let project: Project
    let model: LauncherModel

    var body: some View {
        if model.installedIDEs.isEmpty {
            Text("未检测到已安装的 IDE")
        } else {
            ForEach(model.installedIDEs) { ide in
                Button {
                    Task { await model.openProject(project, in: ide) }
                } label: {
                    Label {
                        Text(ide.name)
                    } icon: {
                        Image(nsImage: ide.menuIcon)
                    }
                }
            }
        }
    }
}

struct ProjectTerminalMenuItems: View {
    let model: LauncherModel
    let onLaunch: (ProjectTerminal, ProjectAICLI?) -> Void

    var body: some View {
        let terminals = model.installedTerminals

        Section("直接打开终端") {
            ForEach(terminals, id: \.self) { terminal in
                Button {
                    onLaunch(terminal, nil)
                } label: {
                    Label("在 \(terminal.rawValue) 中打开", systemImage: "terminal")
                }
            }
        }

        Section("打开 AI CLI") {
            if model.installedAICLIs.isEmpty {
                Text("未检测到已安装的 AI CLI")
            } else if terminals.count == 1, let terminal = terminals.first {
                ForEach(model.installedAICLIs) { cli in
                    Button {
                        onLaunch(terminal, cli)
                    } label: {
                        Label(cli.name, systemImage: "sparkles")
                    }
                }
            } else {
                ForEach(model.installedAICLIs) { cli in
                    Menu {
                        ForEach(terminals, id: \.self) { terminal in
                            Button("在 \(terminal.rawValue) 中打开") {
                                onLaunch(terminal, cli)
                            }
                        }
                    } label: {
                        Label(cli.name, systemImage: "sparkles")
                    }
                }
            }
        }
    }
}
