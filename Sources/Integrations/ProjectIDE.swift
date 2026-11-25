import AppKit
import Foundation

struct ProjectIDE: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let applicationURL: URL

    var id: String { applicationURL.standardizedFileURL.path }

    @MainActor
    private static var menuIconCache: [String: NSImage] = [:]

    @MainActor
    var menuIcon: NSImage {
        let key = id
        if let cached = Self.menuIconCache[key] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        let resized = (icon.copy() as? NSImage) ?? icon
        resized.size = NSSize(width: 16, height: 16)
        Self.menuIconCache[key] = resized
        return resized
    }

    @MainActor
    func open(
        at directory: String,
        opener: @MainActor (URL, URL) async throws -> Void = Self.openWithWorkspace
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IDELaunchError.unavailableDirectory
        }
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw IDELaunchError.applicationNotFound(name)
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try await opener(directoryURL, applicationURL)
        } catch let error as IDELaunchError {
            throw error
        } catch {
            throw IDELaunchError.launchFailed(name, error.localizedDescription)
        }
    }

    @MainActor
    private static func openWithWorkspace(directoryURL: URL, applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
    }

    static func discover(
        searchDirectories: [URL]? = nil,
        includeWorkspaceLookup: Bool = true
    ) -> [ProjectIDE] {
        let fileManager = FileManager.default
        let roots = searchDirectories ?? defaultSearchDirectories()
        var candidateURLs: [URL] = []

        for root in roots {
            candidateURLs.append(contentsOf: applicationBundles(in: root, maxDepth: 2, fileManager: fileManager))
        }
        if includeWorkspaceLookup {
            for bundleID in knownBundleIdentifiers.keys {
                candidateURLs.append(contentsOf: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID))
            }
        }

        var seenPaths: Set<String> = []
        var discovered: [(baseName: String, fileStem: String, bundleID: String?, url: URL)] = []

        for rawURL in candidateURLs {
            let canonical = ProjectFiles.canonicalPath(rawURL)
            guard !shouldIgnorePath(canonical), seenPaths.insert(canonical).inserted else { continue }
            let url = URL(fileURLWithPath: canonical, isDirectory: true)
            guard let info = ideMetadata(for: url, fileManager: fileManager) else { continue }
            discovered.append((info.baseName, info.fileStem, info.bundleID, url))
        }

        var nameCounts: [String: Int] = [:]
        for item in discovered {
            nameCounts[item.baseName, default: 0] += 1
        }

        return discovered.map { item in
            let displayName = (nameCounts[item.baseName] ?? 0) > 1 ? item.fileStem : item.baseName
            return ProjectIDE(name: displayName, bundleIdentifier: item.bundleID, applicationURL: item.url)
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.applicationURL.path < rhs.applicationURL.path : order == .orderedAscending
        }
    }

    private static func defaultSearchDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    private static func applicationBundles(in directory: URL, maxDepth: Int, fileManager: FileManager) -> [URL] {
        guard maxDepth > 0,
              let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var bundles: [URL] = []
        for entry in entries {
            if entry.pathExtension.lowercased() == "app" {
                bundles.append(entry)
            } else if maxDepth > 1 {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true && values?.isSymbolicLink != true {
                    bundles.append(contentsOf: applicationBundles(in: entry, maxDepth: maxDepth - 1, fileManager: fileManager))
                }
            }
        }
        return bundles
    }

    private static func shouldIgnorePath(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    private static func ideMetadata(
        for appURL: URL, fileManager: FileManager
    ) -> (baseName: String, fileStem: String, bundleID: String?)? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let rawBundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = rawBundleID.flatMap { $0.isEmpty ? nil : $0 }
        let loweredID = bundleID?.lowercased()
        if let loweredID, excludedBundleIdentifiers.contains(loweredID) { return nil }

        let fileStem = appURL.deletingPathExtension().lastPathComponent
        let plistName = ((plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let loweredID, let preferredName = knownBundleIdentifiers[loweredID] {
            let name = preferredName ?? resolvedName(plistName: plistName, fileStem: fileStem)
            return (name, fileStem, bundleID)
        }

        if let loweredID, loweredID.hasPrefix("com.jetbrains.") {
            return (resolvedName(plistName: plistName, fileStem: fileStem), fileStem, bundleID)
        }

        if let specialName = specialAppNames[fileStem.lowercased()]
            ?? plistName.flatMap({ specialAppNames[$0.lowercased()] }) {
            return (specialName, fileStem, bundleID)
        }

        if isVSCodeCompatibleBundle(appURL, fileManager: fileManager) {
            return (resolvedName(plistName: plistName, fileStem: fileStem), fileStem, bundleID)
        }

        return nil
    }

    private static func resolvedName(plistName: String?, fileStem: String) -> String {
        guard let plistName, !plistName.isEmpty,
              !genericBundleNames.contains(plistName.lowercased()) else {
            return fileStem
        }
        return plistName
    }

    private static func isVSCodeCompatibleBundle(_ appURL: URL, fileManager: FileManager) -> Bool {
        let productJSON = appURL.appendingPathComponent("Contents/Resources/app/product.json")
        guard fileManager.fileExists(atPath: productJSON.path) else { return false }
        let binDirectory = appURL.appendingPathComponent("Contents/Resources/app/bin")
        guard let files = try? fileManager.contentsOfDirectory(at: binDirectory, includingPropertiesForKeys: nil) else {
            return false
        }
        return files.contains { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static let genericBundleNames: Set<String> = ["code", "electron"]

    private static let excludedBundleIdentifiers: Set<String> = [
        "local.devlauncher.mac",
        "com.jetbrains.toolbox",
        "com.jetbrains.gateway",
        "com.jetbrains.jetclient",
    ]

    private static let specialAppNames: [String: String] = [
        "wechatwebdevtools": "微信开发者工具",
    ]

    /// Lowercased bundle identifier -> optional preferred display name (nil uses Info.plist / app name).
    private static let knownBundleIdentifiers: [String: String?] = [
        // VS Code & AI IDEs
        "com.microsoft.vscode": "Visual Studio Code",
        "com.microsoft.vscodeinsiders": "Visual Studio Code - Insiders",
        "com.vscodium": "VSCodium",
        "com.visualstudio.code.oss": "Code - OSS",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.exafunction.windsurf-next": "Windsurf Next",
        "com.google.antigravity": "Antigravity",
        "com.trae.app": "Trae",
        "com.trae.cn.app": "Trae",
        "com.bytedance.trae": "Trae",
        "dev.kiro.desktop": "Kiro",
        "com.qoder.ide": "Qoder",
        "com.alibaba.qoder": "Qoder",
        "com.voideditor.void": "Void",
        "com.posit.positron": "Positron",
        "com.pearai.app": "PearAI",
        // Native & lightweight editors
        "dev.zed.zed": "Zed",
        "dev.zed.zed-preview": "Zed Preview",
        "com.sublimetext.4": "Sublime Text",
        "com.sublimetext.3": "Sublime Text",
        "com.sublimetext.2": "Sublime Text",
        "com.panic.nova": "Nova",
        "com.barebones.bbedit": "BBEdit",
        "com.coteditor.coteditor": "CotEditor",
        "com.macromates.textmate": "TextMate",
        "com.macromates.textmate.preview": "TextMate",
        "org.vim.macvim": "MacVim",
        "com.neovide.neovide": "Neovide",
        "org.gnu.emacs": "Emacs",
        "io.lapce": "Lapce",
        "dev.pulsar-edit.pulsar": "Pulsar",
        // Apple & mobile IDEs
        "com.apple.dt.xcode": "Xcode",
        "com.google.android.studio": "Android Studio",
        "com.google.android.studio-eap": "Android Studio",
        // JetBrains IDEs
        "com.jetbrains.webstorm": nil,
        "com.jetbrains.pycharm": nil,
        "com.jetbrains.pycharm.ce": nil,
        "com.jetbrains.intellij": nil,
        "com.jetbrains.intellij.ce": nil,
        "com.jetbrains.goland": nil,
        "com.jetbrains.clion": nil,
        "com.jetbrains.phpstorm": nil,
        "com.jetbrains.rubymine": nil,
        "com.jetbrains.rider": nil,
        "com.jetbrains.rustrover": nil,
        "com.jetbrains.datagrip": nil,
        "com.jetbrains.dataspell": nil,
        "com.jetbrains.aqua": nil,
        "com.jetbrains.appcode": nil,
        "com.jetbrains.fleet": nil,
        "fleet.app": "Fleet",
        // Other IDEs
        "io.dcloud.hbuilderx": "HBuilderX",
        "org.eclipse.platform.ide": "Eclipse",
        "org.apache.netbeans": "Apache NetBeans",
        "org.spyder-ide.spyder": "Spyder",
        "com.rstudio.desktop": "RStudio",
        "org.rstudio.rstudio": "RStudio",
    ]
}

private enum IDELaunchError: LocalizedError {
    case unavailableDirectory
    case applicationNotFound(String)
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unavailableDirectory:
            "项目目录不可用。请连接磁盘或重新定位项目。"
        case .applicationNotFound(let name):
            "找不到已安装的 \(name)。请确认应用仍在应用程序目录中。"
        case .launchFailed(let name, let detail):
            "无法在 \(name) 中打开项目。\n\(detail)"
        }
    }
}
