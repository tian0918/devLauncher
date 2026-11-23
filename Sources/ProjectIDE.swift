import AppKit
import Foundation

enum ProjectIDE: String, CaseIterable, Sendable {
    case vscode = "VS Code"
    case sublimeText = "Sublime Text"

    private var command: String {
        switch self {
        case .vscode: "code"
        case .sublimeText: "subl"
        }
    }

    private var bundleIdentifiers: [String] {
        switch self {
        case .vscode: ["com.microsoft.VSCode"]
        case .sublimeText: ["com.sublimetext.4", "com.sublimetext.3"]
        }
    }

    private var bundledCommandPath: String {
        switch self {
        case .vscode: "Contents/Resources/app/bin/code"
        case .sublimeText: "Contents/SharedSupport/bin/subl"
        }
    }

    @MainActor
    func open(at directory: String, shellPath: String?) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IDELaunchError.unavailableDirectory
        }
        let environment = ManagedProcess.environment(shellPath: shellPath)
        guard let executable = executable(in: environment["PATH"] ?? "") else {
            throw IDELaunchError.commandNotFound(rawValue, command)
        }
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            process.arguments = ["."]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw IDELaunchError.launchFailed(rawValue, error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw IDELaunchError.launchFailed(rawValue, "命令退出状态 \(process.terminationStatus)。")
            }
        }.value
    }

    @MainActor
    private func executable(in path: String) -> URL? {
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(command)
            if Self.isExecutable(candidate) { return candidate }
        }
        for identifier in bundleIdentifiers {
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { continue }
            let candidate = application.appendingPathComponent(bundledCommandPath)
            if Self.isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let files = FileManager.default
        return files.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && files.isExecutableFile(atPath: url.path)
    }
}

private enum IDELaunchError: LocalizedError {
    case unavailableDirectory
    case commandNotFound(String, String)
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unavailableDirectory:
            "项目目录不可用。请连接磁盘或重新定位项目。"
        case .commandNotFound(let name, let command):
            "找不到 \(name) 的「\(command)」命令。请安装 \(name)，或将「\(command)」加入 PATH 后重试。"
        case .launchFailed(let name, let detail):
            "无法在 \(name) 中打开项目。\n\(detail)"
        }
    }
}
