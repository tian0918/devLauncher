import AppKit
import SwiftUI

struct ConsoleView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ConsoleTypography.storageKey) private var consoleFontSize = ConsoleTypography.defaultSize

    let projectID: UUID
    var model: LauncherModel
    let clearLog: () -> Void
    let installAndRestart: () -> Void
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    private var clampedFontSize: CGFloat {
        CGFloat(ConsoleTypography.clamp(consoleFontSize))
    }

    var body: some View {
        let state = model.runMetadataState(projectID)
        let snapshot = model.logSnapshot(projectID)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: LauncherPalette.consoleMuted))
                    .accessibilityHidden(true)
                Text("运行日志")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: LauncherPalette.consoleText))

                if state.phase == .running || state.phase == .starting || state.phase == .installing {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(state.phase == .running ? LauncherPalette.running : LauncherPalette.pending)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(state.phase == .running ? "实时输出" : state.phase.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(nsColor: LauncherPalette.consoleMuted))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }

                Spacer()

                ConsoleFontSizeMenu(fontSize: $consoleFontSize)

                ConsoleHeaderButton(
                    title: "清空",
                    systemImage: "trash",
                    tint: Color(nsColor: LauncherPalette.consoleMuted),
                    disabled: snapshot.isEmpty,
                    action: clearLog
                )
                .help("清空日志（⌘K）")

                ConsoleHeaderButton(
                    title: copied ? "已复制" : "复制日志",
                    systemImage: copied ? "checkmark" : "document.on.document",
                    tint: copied ? LauncherPalette.running : Color(nsColor: LauncherPalette.consoleText),
                    disabled: snapshot.isEmpty
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshot.text, forType: .string)
                    copyResetTask?.cancel()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { copied = true }
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) { copied = false }
                        }
                    }
                }
                .help("复制全部运行日志")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LauncherPalette.consoleHeader)

            Rectangle().fill(LauncherPalette.consoleLine).frame(height: 1)

            ConsoleText(
                snapshot: snapshot,
                placeholder: placeholder(for: state.phase),
                fontSize: clampedFontSize
            )
            .frame(minHeight: 120, maxHeight: .infinity)

            if let message = state.message {
                Rectangle().fill(LauncherPalette.consoleLine).frame(height: 1)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: state.phase == .failed ? "exclamationmark.circle.fill" : "info.circle.fill")
                        .font(.callout)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .font(.callout.weight(.medium))
                        if let command = state.installCommand {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Spacer()
                    if state.phase == .failed && state.install != nil {
                        Button("安装并重启", action: installAndRestart)
                            .buttonStyle(ProjectActionStyle(tone: .primary, size: .compact))
                    }
                }
                .foregroundStyle(
                    state.phase == .failed
                        ? LauncherPalette.consoleErrorInk
                        : Color(nsColor: LauncherPalette.consoleText)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    state.phase == .failed
                        ? LauncherPalette.consoleErrorFill
                        : LauncherPalette.consoleInfoFill
                )
            }
        }
        .background(LauncherPalette.consoleBody)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(LauncherPalette.consoleBorder)
        }
        .shadow(color: LauncherPalette.cardShadow(colorScheme, contrast: colorSchemeContrast), radius: 6, y: 2)
    }

    private func placeholder(for phase: RunPhase) -> String {
        switch phase {
        case .starting: "正在准备启动环境…"
        case .installing: "正在安装…"
        case .running, .stopping: "尚无输出。"
        default: "启动项目后，输出将显示在这里。"
        }
    }
}

private struct ConsoleFontSizeMenu: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var fontSize: Double
    @State private var hovering = false

    private var isDefault: Bool {
        Int(fontSize.rounded()) == Int(ConsoleTypography.defaultSize)
    }

    var body: some View {
        Menu {
            Button("放大日志字号（⌘=）") {
                fontSize = ConsoleTypography.clamp(fontSize + ConsoleTypography.step)
            }
            .disabled(fontSize >= ConsoleTypography.maxSize)

            Button("缩小日志字号（⌘-）") {
                fontSize = ConsoleTypography.clamp(fontSize - ConsoleTypography.step)
            }
            .disabled(fontSize <= ConsoleTypography.minSize)

            Divider()

            Button("默认大小（12pt）") {
                fontSize = ConsoleTypography.defaultSize
            }
            .disabled(isDefault)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "textformat.size")
                    .font(.caption.weight(.medium))
                if !isDefault {
                    Text("\(Int(fontSize.rounded()))pt")
                        .font(.caption2.monospacedDigit().weight(.medium))
                }
            }
            .foregroundStyle(Color(nsColor: LauncherPalette.consoleMuted))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                hovering ? LauncherPalette.consoleActionHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help("调整日志字号（当前 \(Int(fontSize.rounded()))pt）")
        .accessibilityLabel("日志字号")
    }
}

private struct ConsoleHeaderButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    hovering && !disabled ? LauncherPalette.consoleActionHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .opacity(disabled ? 0.4 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct ConsoleText: NSViewRepresentable {
    let snapshot: LogSnapshot
    let placeholder: String
    let fontSize: CGFloat

    private static func makeFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func makeParagraphStyle(fontSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(3.0, round(fontSize * 0.28 * 2) / 2)
        return style
    }

    final class Coordinator {
        var lastPlaceholder: String?
        var lastGeneration: UInt64 = 0
        var lastRevision: UInt64 = 0
        var lastDroppedUTF16 = 0
        var lastLengthUTF16 = 0
        var lastFontSize: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.knobStyle = .light
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.font = Self.makeFont(size: fontSize)
        view.textColor = LauncherPalette.consoleText
        view.setAccessibilityLabel("运行日志")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }

        let font = Self.makeFont(size: fontSize)
        let paragraphStyle = Self.makeParagraphStyle(fontSize: fontSize)
        let fontChanged = context.coordinator.lastFontSize != fontSize
        if fontChanged {
            context.coordinator.lastFontSize = fontSize
            view.font = font
        }

        if snapshot.isEmpty {
            guard context.coordinator.lastPlaceholder != placeholder || fontChanged else { return }
            context.coordinator.lastPlaceholder = placeholder
            context.coordinator.lastLengthUTF16 = 0
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: LauncherPalette.consoleMuted,
                .paragraphStyle: paragraphStyle,
            ]
            storage.setAttributedString(NSAttributedString(string: placeholder, attributes: attributes))
            return
        }

        let wasPlaceholder = context.coordinator.lastPlaceholder != nil
        let textChanged = wasPlaceholder
            || context.coordinator.lastGeneration != snapshot.generation
            || context.coordinator.lastRevision != snapshot.revision

        if !textChanged {
            if fontChanged, storage.length > 0 {
                storage.beginEditing()
                let fullRange = NSRange(location: 0, length: storage.length)
                storage.addAttributes([.font: font, .paragraphStyle: paragraphStyle], range: fullRange)
                storage.endEditing()
            }
            return
        }

        let bounds = scroll.contentView.bounds
        let follow = view.bounds.maxY - bounds.maxY < 26 && view.selectedRange().length == 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: LauncherPalette.consoleText,
            .paragraphStyle: paragraphStyle,
        ]

        let nsText = snapshot.text as NSString
        let newLength = nsText.length
        let deltaDrop = snapshot.droppedUTF16 - context.coordinator.lastDroppedUTF16
        let kept = context.coordinator.lastLengthUTF16 - deltaDrop

        if !wasPlaceholder,
           context.coordinator.lastGeneration == snapshot.generation,
           deltaDrop >= 0,
           kept >= 0,
           kept <= newLength {
            storage.beginEditing()
            if deltaDrop > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: deltaDrop))
            }
            if fontChanged, storage.length > 0 {
                storage.addAttributes(
                    [.font: font, .paragraphStyle: paragraphStyle],
                    range: NSRange(location: 0, length: storage.length)
                )
            }
            if newLength > kept {
                let tail = nsText.substring(from: kept)
                storage.append(NSAttributedString(string: tail, attributes: attributes))
            }
            storage.endEditing()
        } else {
            storage.setAttributedString(NSAttributedString(string: snapshot.text, attributes: attributes))
        }

        context.coordinator.lastPlaceholder = nil
        context.coordinator.lastGeneration = snapshot.generation
        context.coordinator.lastRevision = snapshot.revision
        context.coordinator.lastDroppedUTF16 = snapshot.droppedUTF16
        context.coordinator.lastLengthUTF16 = newLength

        if follow {
            view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }
}
