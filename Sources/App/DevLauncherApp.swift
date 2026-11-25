import AppKit
import SwiftUI

@main
enum DevLauncherMain {
    @MainActor
    static func main() {
        ProcessSupervisor.runIfRequested()
        DevLauncherApp.main()
    }
}

struct DevLauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherDelegate.self) private var delegate
    @AppStorage(LauncherPreferences.showMenuBarExtraKey) private var showMenuBarExtra = true

    var body: some Scene {
        Window("Dev Launcher", id: "projects") {
            MainView(model: delegate.model, delegate: delegate)
                .frame(minWidth: 810, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            LauncherMenuCommands(model: delegate.model)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarPopoverView(model: delegate.model, delegate: delegate)
        } label: {
            if delegate.model.runningCount > 0 {
                Label("\(delegate.model.runningCount)", systemImage: "terminal.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Dev Launcher", systemImage: "terminal")
                    .labelStyle(.iconOnly)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            NVMSettings(model: delegate.model)
        }
    }
}

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled icon directly so the Dock uses this build's image.
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.terminate { sender.reply(toApplicationShouldTerminate: true) }
            ? .terminateNow : .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let activeProjects = model.projects.filter { model.runPhase($0.id).isActive }
        let idleProjects = model.projects.filter { !model.runPhase($0.id).isActive && $0.hasLaunchCommand }

        if !activeProjects.isEmpty {
            menu.addItem(.sectionHeader(title: "运行中（\(activeProjects.count)）"))
            for project in activeProjects {
                let item = NSMenuItem(title: project.listName, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: project.listName)

                let showItem = NSMenuItem(title: "显示项目详情", action: #selector(dockSelectProject(_:)), keyEquivalent: "")
                showItem.target = self
                showItem.representedObject = project.id
                sub.addItem(showItem)

                if let url = model.browserURL(for: project) {
                    let portSuffix = url.port.map { " (:\($0))" } ?? ""
                    let browserItem = NSMenuItem(
                        title: "在浏览器中打开\(portSuffix)",
                        action: #selector(dockOpenURL(_:)),
                        keyEquivalent: ""
                    )
                    browserItem.target = self
                    browserItem.representedObject = url
                    sub.addItem(browserItem)
                }

                sub.addItem(.separator())

                if model.runPhase(project.id) == .running {
                    let restartItem = NSMenuItem(title: "重启", action: #selector(dockRestartProject(_:)), keyEquivalent: "")
                    restartItem.target = self
                    restartItem.representedObject = project.id
                    sub.addItem(restartItem)
                }

                let stopItem = NSMenuItem(title: "停止", action: #selector(dockStopProject(_:)), keyEquivalent: "")
                stopItem.target = self
                stopItem.representedObject = project.id
                sub.addItem(stopItem)

                item.submenu = sub
                menu.addItem(item)
            }

            if activeProjects.count > 1 {
                let stopAllItem = NSMenuItem(title: "停止全部运行中的项目", action: #selector(dockStopAll), keyEquivalent: "")
                stopAllItem.target = self
                menu.addItem(stopAllItem)
            }
            menu.addItem(.separator())
        }

        if model.startablePinnedProjects.count > 1 {
            let startPinnedItem = NSMenuItem(
                title: "启动全部置顶项目（\(model.startablePinnedProjects.count)）",
                action: #selector(dockStartPinned),
                keyEquivalent: ""
            )
            startPinnedItem.target = self
            menu.addItem(startPinnedItem)
            menu.addItem(.separator())
        }

        if !idleProjects.isEmpty {
            menu.addItem(.sectionHeader(title: "快速启动"))
            for project in idleProjects.prefix(8) {
                let prefix = project.pinned ? "★ " : ""
                let startItem = NSMenuItem(
                    title: "\(prefix)启动 \(project.listName)",
                    action: #selector(dockStartProject(_:)),
                    keyEquivalent: ""
                )
                startItem.target = self
                startItem.representedObject = project.id
                menu.addItem(startItem)
            }
            menu.addItem(.separator())
        }

        let addItem = NSMenuItem(title: "添加项目…", action: #selector(dockAddProjects), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        return menu
    }

    private func activateAndShowMainWindow() {
        NSApp.activate()
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("projects") == true }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    @objc private func dockSelectProject(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            model.selection = id
        }
        activateAndShowMainWindow()
    }

    @objc private func dockOpenURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func dockStartPinned() {
        model.startPinnedProjects()
    }

    @objc private func dockStartProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let project = model.project(for: id) else { return }
        model.selection = id
        model.start(project)
    }

    @objc private func dockRestartProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.restart(id)
    }

    @objc private func dockStopProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.stop(id)
    }

    @objc private func dockStopAll() {
        model.stopAll()
    }

    @objc private func dockAddProjects() {
        activateAndShowMainWindow()
        Task { @MainActor in
            selectProjects(model)
        }
    }
}

@MainActor
func presentOpenPanel(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
    let didClose: (NSApplication.ModalResponse) -> Void = { response in
        if response == .OK { completion(panel.urls) }
    }
    if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window, completionHandler: didClose)
    } else {
        panel.begin(completionHandler: didClose)
    }
}

@MainActor
func selectProjects(_ model: LauncherModel) {
    let panel = NSOpenPanel()
    panel.title = "添加项目"
    panel.message = "选择 Node.js 或 Python 项目文件，或选择要扫描的文件夹。"
    panel.prompt = "扫描"
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.delegate = PackagePanelFilter.shared
    presentOpenPanel(panel) { model.scan($0) }
}

@MainActor
private final class PackagePanelFilter: NSObject, NSOpenSavePanelDelegate {
    static let shared = PackagePanelFilter()

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        ProjectFiles.isImportFile(url) ||
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
