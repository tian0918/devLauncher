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

    var body: some Scene {
        Window("Dev Launcher", id: "projects") {
            MainView(model: delegate.model)
                .frame(minWidth: 810, minHeight: 575)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加项目…") { selectProjects(delegate.model) }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            NVMSettings(model: delegate.model)
        }
    }
}

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()

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
