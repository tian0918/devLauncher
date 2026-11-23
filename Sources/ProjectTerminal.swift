import AppKit
import Foundation

enum ProjectTerminal: String, CaseIterable, Sendable {
    case terminal = "Terminal"
    case iTerm2 = "iTerm2"

    private var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm2: "com.googlecode.iterm2"
        }
    }

    func script(for application: URL) -> String {
        let applicationPath = application.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        switch self {
        case .terminal:
            return """
            on run argv
                set launchCommand to item 1 of argv
                tell application "\(applicationPath)"
                    do script launchCommand
                    activate
                end tell
            end run
            """
        case .iTerm2:
            return """
            on run argv
                set launchCommand to item 1 of argv
                tell application "\(applicationPath)"
                    set launchWindow to (create window with default profile)
                    tell current session of launchWindow
                        write text launchCommand
                    end tell
                    activate
                end tell
            end run
            """
        }
    }

    @MainActor
    func openCodex(at directory: String) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalLaunchError.unavailableDirectory
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw TerminalLaunchError.unavailableApp(rawValue)
        }
        let command = try Self.codexCommand(at: directory)
        let script = self.script(for: application)
        let name = rawValue
        try await Task.detached(priority: .userInitiated) {
            try Self.run(script: script, command: command, terminal: name)
        }.value
    }

    static func codexCommand(at directory: String) throws -> String {
        // Keep control characters out of text sent to the interactive terminal.
        guard !directory.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
            throw TerminalLaunchError.unsupportedDirectory
        }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd -- \(quoted) && codex"
    }

    private static func run(script: String, command: String, terminal: String) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("(-1743)") {
                throw TerminalLaunchError.automationDenied(terminal)
            }
            throw TerminalLaunchError.scriptFailed(terminal, detail)
        }
    }
}

private enum TerminalLaunchError: LocalizedError {
    case unavailableDirectory
    case unsupportedDirectory
    case unavailableApp(String)
    case automationDenied(String)
    case scriptFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unavailableDirectory:
            "项目目录不可用。请连接磁盘或重新定位项目。"
        case .unsupportedDirectory:
            "项目路径含有终端控制字符，无法在终端中打开。"
        case .unavailableApp(let name):
            "找不到 \(name)。"
        case .automationDenied(let name):
            "请在「系统设置 → 隐私与安全性 → 自动化」中允许 Dev Launcher 控制 \(name)，然后重试。"
        case .scriptFailed(let name, let detail):
            detail.isEmpty ? "无法在 \(name) 中启动 Codex。" : "无法在 \(name) 中启动 Codex。\n\(detail)"
        }
    }
}
