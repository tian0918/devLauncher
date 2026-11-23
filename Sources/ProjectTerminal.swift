import AppKit
import Foundation

struct ProjectAICLI: Identifiable, Hashable, Sendable {
    let name: String
    let command: String
    let executablePath: String

    var id: String { command }

    private struct Definition {
        let name: String
        let command: String
        let extraHomeRelativePaths: [String]
    }

    private static let knownCLIs: [Definition] = [
        Definition(name: "Claude Code", command: "claude", extraHomeRelativePaths: [
            ".claude/local/claude",
            ".claude/local/node_modules/.bin/claude",
        ]),
        Definition(name: "Codex", command: "codex", extraHomeRelativePaths: []),
        Definition(name: "Gemini CLI", command: "gemini", extraHomeRelativePaths: []),
        Definition(name: "Antigravity", command: "agy", extraHomeRelativePaths: [
            ".antigravity/antigravity/bin/agy",
        ]),
        Definition(name: "OpenCode", command: "opencode", extraHomeRelativePaths: [
            ".opencode/bin/opencode",
        ]),
        Definition(name: "Aider", command: "aider", extraHomeRelativePaths: []),
        Definition(name: "GitHub Copilot", command: "copilot", extraHomeRelativePaths: []),
        Definition(name: "Cursor Agent", command: "cursor-agent", extraHomeRelativePaths: []),
        Definition(name: "Kiro CLI", command: "kiro-cli", extraHomeRelativePaths: []),
        Definition(name: "Qwen Code", command: "qwen", extraHomeRelativePaths: []),
        Definition(name: "Amp", command: "amp", extraHomeRelativePaths: []),
        Definition(name: "Goose", command: "goose", extraHomeRelativePaths: []),
        Definition(name: "Cline", command: "cline", extraHomeRelativePaths: []),
        Definition(name: "Droid", command: "droid", extraHomeRelativePaths: []),
        Definition(name: "Kimi", command: "kimi", extraHomeRelativePaths: []),
        Definition(name: "Pi", command: "pi", extraHomeRelativePaths: []),
    ]

    static func discover(
        searchDirectories: [URL]? = nil,
        shellPath: String? = nil,
        nvmDirectory: String? = nil
    ) -> [ProjectAICLI] {
        let fileManager = FileManager.default
        let directories = searchDirectories ?? defaultSearchDirectories(
            shellPath: shellPath,
            nvmDirectory: nvmDirectory,
            fileManager: fileManager
        )
        let home = fileManager.homeDirectoryForCurrentUser

        var discovered: [ProjectAICLI] = []
        for definition in knownCLIs {
            var resolvedPath: String?
            for directory in directories {
                let candidate = directory.appendingPathComponent(definition.command)
                if isExecutableBinary(at: candidate, fileManager: fileManager) {
                    resolvedPath = ProjectFiles.canonicalPath(candidate)
                    break
                }
            }
            if resolvedPath == nil, searchDirectories == nil {
                for relative in definition.extraHomeRelativePaths {
                    let candidate = home.appendingPathComponent(relative)
                    if isExecutableBinary(at: candidate, fileManager: fileManager) {
                        resolvedPath = ProjectFiles.canonicalPath(candidate)
                        break
                    }
                }
            }
            if let resolvedPath {
                discovered.append(ProjectAICLI(
                    name: definition.name,
                    command: definition.command,
                    executablePath: resolvedPath
                ))
            }
        }

        return discovered.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.command < rhs.command : order == .orderedAscending
        }
    }

    private static func isExecutableBinary(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    private static func defaultSearchDirectories(
        shellPath: String?,
        nvmDirectory: String?,
        fileManager: FileManager
    ) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var rawPaths: [String] = []
        if let shellPath {
            rawPaths.append(contentsOf: shellPath.split(separator: ":").map(String.init))
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            rawPaths.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        rawPaths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".npm/bin").path,
            home.appendingPathComponent("Library/pnpm").path,
            home.appendingPathComponent(".pnpm-global/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".fnm/current/bin").path,
            home.appendingPathComponent(".asdf/shims").path,
            home.appendingPathComponent(".mise/shims").path,
            home.appendingPathComponent(".cargo/bin").path,
            home.appendingPathComponent("go/bin").path,
            home.appendingPathComponent(".opencode/bin").path,
            home.appendingPathComponent(".claude/local").path,
            home.appendingPathComponent(".claude/local/node_modules/.bin").path,
            home.appendingPathComponent(".antigravity/antigravity/bin").path,
        ])

        let nvmRoot = URL(fileURLWithPath: nvmDirectory ?? home.appendingPathComponent(".nvm").path, isDirectory: true)
        rawPaths.append(nvmRoot.appendingPathComponent("current/bin").path)
        let versionsRoot = nvmRoot.appendingPathComponent("versions/node", isDirectory: true)
        if let folders = try? fileManager.contentsOfDirectory(at: versionsRoot, includingPropertiesForKeys: nil) {
            let sorted = folders.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }
            for folder in sorted {
                rawPaths.append(folder.appendingPathComponent("bin").path)
            }
        }

        var seen: Set<String> = []
        var directories: [URL] = []
        for path in rawPaths where !path.isEmpty {
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if seen.insert(normalized.path).inserted {
                directories.append(normalized)
            }
        }
        return directories
    }
}

enum ProjectTerminal: String, CaseIterable, Sendable {
    case terminal = "Terminal"
    case iTerm2 = "iTerm2"

    private var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm2: "com.googlecode.iterm2"
        }
    }

    @MainActor
    static func installed() -> [ProjectTerminal] {
        let available = allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
        return available.isEmpty ? [.terminal] : available
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
    func open(at directory: String, running cli: ProjectAICLI? = nil) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalLaunchError.unavailableDirectory
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw TerminalLaunchError.unavailableApp(rawValue)
        }
        let command = try cli.map { try Self.launchCommand(for: $0, at: directory) }
            ?? Self.directoryCommand(at: directory)
        let script = self.script(for: application)
        let name = rawValue
        let target = cli?.name
        try await Task.detached(priority: .userInitiated) {
            try Self.run(script: script, command: command, terminal: name, target: target)
        }.value
    }

    static func directoryCommand(at directory: String) throws -> String {
        "cd -- \(try quotedDirectory(directory))"
    }

    static func launchCommand(for cli: ProjectAICLI, at directory: String) throws -> String {
        try launchCommand(executable: cli.command, at: directory)
    }

    static func launchCommand(executable: String, at directory: String) throws -> String {
        guard !executable.isEmpty,
              executable.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw TerminalLaunchError.unsupportedCommand(executable)
        }
        return "\(try directoryCommand(at: directory)) && \(executable)"
    }

    private static func quotedDirectory(_ directory: String) throws -> String {
        // Keep control characters out of text sent to the interactive terminal.
        guard !directory.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
            throw TerminalLaunchError.unsupportedDirectory
        }
        return "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(script: String, command: String, terminal: String, target: String?) throws {
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
            throw TerminalLaunchError.scriptFailed(terminal, target, detail)
        }
    }
}

private enum TerminalLaunchError: LocalizedError {
    case unavailableDirectory
    case unsupportedDirectory
    case unsupportedCommand(String)
    case unavailableApp(String)
    case automationDenied(String)
    case scriptFailed(String, String?, String)

    var errorDescription: String? {
        switch self {
        case .unavailableDirectory:
            return "项目目录不可用。请连接磁盘或重新定位项目。"
        case .unsupportedDirectory:
            return "项目路径含有终端控制字符，无法在终端中打开。"
        case .unsupportedCommand(let command):
            return "无效的终端启动命令：\(command)。"
        case .unavailableApp(let name):
            return "找不到 \(name)。"
        case .automationDenied(let name):
            return "请在「系统设置 → 隐私与安全性 → 自动化」中允许 Dev Launcher 控制 \(name)，然后重试。"
        case .scriptFailed(let name, let target, let detail):
            let summary = target.map { "无法在 \(name) 中启动 \($0)。" } ?? "无法打开 \(name)。"
            return detail.isEmpty ? summary : "\(summary)\n\(detail)"
        }
    }
}
