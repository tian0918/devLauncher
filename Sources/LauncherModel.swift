import AppKit
import Foundation

enum RunPhase: String {
    case idle = "待启动"
    case starting = "正在启动"
    case installing = "正在安装"
    case running = "运行中"
    case stopping = "正在停止"
    case stopped = "已停止"
    case finished = "已退出"
    case failed = "失败"

    var isActive: Bool { self == .starting || self == .installing || self == .running || self == .stopping }
}

struct InstallAction {
    let operation: NVM.Operation
    let installation: NVMInstallation?
    let command: String
}

struct RunState {
    var phase: RunPhase = .idle
    var log = ""
    var node: String?
    var message: String?
    var install: InstallAction?
    var installCommand: String? { install?.command }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var selection: UUID?
    @Published private(set) var saved = SavedState()
    @Published private(set) var runs: [UUID: RunState] = [:]
    @Published private(set) var installation: NVMInstallation?
    @Published private(set) var versions: [String] = []
    @Published private(set) var detecting = false
    @Published private(set) var scanning = false
    @Published private(set) var scanResult: ScanResult?
    @Published var alert: String?

    private struct ActiveRun {
        let id: UUID
        let process: ManagedProcess
        let output: RunOutput
        let project: Project
        let installation: NVMInstallation?
        let install: InstallAction?
        var restart = false
    }

    private let stateFile: StateFile
    private var canSave = true
    private var processes: [UUID: ActiveRun] = [:]
    private var waitingForNVM: [UUID: Project] = [:]
    private var shellPath: String?
    private var probe: ManagedProcess?
    private var scanTask: Task<ScanResult, Never>?
    private var scanID: UUID?
    private var refreshTimer: Timer?
    private var terminating = false
    private var terminateReply: (() -> Void)?

    init(stateFile: StateFile = .local) {
        self.stateFile = stateFile
        do {
            saved = try stateFile.load()
            selection = saved.projects.first?.id
        } catch {
            canSave = false
            alert = "无法读取已保存的项目。请检查 \(stateFile.url.path)。\n\(error.localizedDescription)"
        }
        refreshNVM()
    }

    var projects: [Project] {
        saved.projects.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    func runState(_ id: UUID) -> RunState { runs[id] ?? RunState() }

    func refreshInstalledVersions() {
        versions = installation?.installedVersions ?? []
    }

    func scan(_ urls: [URL]) {
        cancelScan()
        let id = UUID()
        scanID = id
        scanning = true
        let task = Task.detached(priority: .userInitiated) {
            ProjectFiles.scan(urls) { Task.isCancelled }
        }
        scanTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.scanID == id else { return }
            self.scanTask = nil
            self.scanning = false
            self.scanResult = result
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
        scanning = false
        scanResult = nil
    }

    func add(_ candidates: [ProjectCandidate]) -> Bool {
        var paths = Set(saved.projects.map(\.path))
        let new = candidates.filter { paths.insert($0.path).inserted }.map(Project.init)
        guard !new.isEmpty else { return true }
        var next = saved
        next.projects.append(contentsOf: new)
        guard commit(next) else { return false }
        selection = new.first?.id
        return true
    }

    func relocate(_ project: Project, to url: URL) {
        guard !runState(project.id).phase.isActive else { return }
        guard let candidate = ProjectFiles.candidate(in: url, kind: project.kind) else {
            alert = project.kind == .node ? "所选文件夹中没有可读取的 package.json。"
                : "所选文件夹中没有可读取的 Python 项目文件。"
            return
        }
        guard !saved.projects.contains(where: { $0.id != project.id && $0.path == candidate.path }) else {
            alert = "所选文件夹已作为另一个项目导入。"
            return
        }
        var updated = project
        updated.path = candidate.path
        updated.nodeRequirement = candidate.nodeRequirement
        if update(updated) { runs[project.id] = nil }
    }

    func update(_ project: Project) -> Bool {
        guard !runState(project.id).phase.isActive,
              let index = saved.projects.firstIndex(where: { $0.id == project.id }) else { return false }
        var next = saved
        var updated = project
        updated.listAlias = next.projects[index].listAlias
        let settingsChanged = next.projects[index] != updated
        next.projects[index] = updated
        guard commit(next) else { return false }
        if settingsChanged { runs[project.id]?.install = nil }
        return true
    }

    func setListAlias(_ alias: String, for id: UUID) -> Bool {
        guard let index = saved.projects.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard saved.projects[index].listAlias != value else { return true }
        var next = saved
        next.projects[index].listAlias = value
        return commit(next)
    }

    func remove(_ id: UUID) {
        guard !runState(id).phase.isActive else { return }
        var next = saved
        next.projects.removeAll { $0.id == id }
        guard commit(next) else { return }
        runs[id] = nil
        if selection == id { selection = projects.first?.id }
    }

    func setNVMScript(_ path: String?) {
        guard saved.nvmScript != path else { return }
        var next = saved
        next.nvmScript = path
        if commit(next) {
            for id in Array(runs.keys) { runs[id]?.install = nil }
            refreshNVM()
        }
    }

    func refreshNVM() {
        if let manual = saved.nvmScript.flatMap(NVM.manual) {
            completeDetection(manual)
            return
        }
        let inherited = saved.nvmScript == nil ? NVM.inherited() : nil
        if let inherited, !inherited.installedVersions.isEmpty {
            completeDetection(inherited)
        } else {
            detecting = true
            installation = nil
            versions = []
            guard probe == nil else { return }
            let output = ProbeOutput()
            do {
                probe = try ManagedProcess(
                    shellArguments: NVM.probeArguments,
                    directory: FileManager.default.homeDirectoryForCurrentUser.path,
                    environment: ManagedProcess.environment(), timeout: 4,
                    onOutput: { output.append($0) },
                    onExit: { [weak self] _ in
                        let text = output.text()
                        let result = NVM.resolvedInstallation(probed: NVM.probed(text), inherited: inherited)
                        let path = NVM.probedPath(text)
                        Task { @MainActor in
                            guard let self else { return }
                            self.probe = nil
                            self.shellPath = path
                            if self.saved.nvmScript == nil {
                                self.completeDetection(result)
                            } else if self.detecting {
                                self.completeDetection(self.saved.nvmScript.flatMap(NVM.manual))
                            }
                            self.finishTerminationIfReady()
                        }
                    }
                )
            } catch {
                completeDetection(saved.nvmScript == nil
                                  ? NVM.resolvedInstallation(probed: nil, inherited: inherited) : nil)
            }
        }
    }

    func start(_ project: Project) {
        guard !terminating, !runState(project.id).phase.isActive else { return }
        guard !project.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(project.id, "请先填写启动命令。")
            return
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else {
            fail(project.id, "项目文件夹不可用。请重新定位，或连接项目所在磁盘。")
            return
        }
        if project.kind == .python {
            launch(project, using: nil)
            return
        }
        if let installation, FileManager.default.isReadableFile(atPath: installation.script) {
            if saved.nvmScript != nil || !installation.installedVersions.isEmpty {
                launch(project, using: installation)
                return
            }
        }
        if !detecting && installation == nil {
            launch(project, using: nil)
        } else {
            runs[project.id] = RunState(phase: .starting)
            waitingForNVM[project.id] = project
            if !detecting { refreshNVM() }
        }
    }

    func installAndRestart(_ id: UUID) {
        let state = runState(id)
        guard !terminating, state.phase == .failed, let action = state.install,
              let project = saved.projects.first(where: { $0.id == id }) else { return }
        let log = state.log + "\n$ " + action.command + "\n"
        launch(project, using: action.installation, install: action, precedingLog: log)
    }

    func stop(_ id: UUID) {
        if waitingForNVM.removeValue(forKey: id) != nil {
            runs[id] = RunState(phase: .stopped, message: "已取消启动。")
        } else if let session = processes[id] {
            processes[id]?.restart = false
            runs[id]?.phase = .stopping
            session.process.stop()
        }
    }

    func restart(_ id: UUID) {
        if let session = processes[id], runState(id).phase == .running {
            processes[id]?.restart = true
            runs[id]?.phase = .stopping
            session.process.stop()
        }
    }

    func terminate(reply: @escaping () -> Void) -> Bool {
        terminating = true
        cancelScan()
        waitingForNVM.removeAll()
        guard !processes.isEmpty || probe != nil else { return true }
        terminateReply = reply
        probe?.stop()
        for id in Array(processes.keys) { stop(id) }
        return false
    }

    private func completeDetection(_ result: NVMInstallation?) {
        detecting = false
        installation = result
        refreshInstalledVersions()
        let queued = waitingForNVM
        waitingForNVM.removeAll()
        for project in queued.values { launch(project, using: result) }
    }

    private func launch(
        _ project: Project, using installation: NVMInstallation?, install: InstallAction? = nil,
        precedingLog: String = ""
    ) {
        guard !terminating else { return }
        let id = UUID()
        let isPython = project.kind == .python
        let output = RunOutput(token: id.uuidString, precedingLog: precedingLog, expectsNodeStartup: !isPython)
        var environment = ManagedProcess.environment(shellPath: installation == nil ? shellPath : nil)
        let arguments: [String]
        if isPython {
            if let virtualEnvironment = ProjectFiles.pythonVirtualEnvironment(at: project.path),
               let path = environment["PATH"] {
                environment["PATH"] = virtualEnvironment.appendingPathComponent("bin").path + ":" + path
                environment["VIRTUAL_ENV"] = virtualEnvironment.path
            }
            environment["PYTHONUNBUFFERED"] = environment["PYTHONUNBUFFERED"] ?? "1"
            arguments = ["-fc", project.command]
        } else {
            arguments = NVM.arguments(
                installation: installation, selector: project.nodeVersion,
                command: project.command, token: id.uuidString, operation: install?.operation ?? .start
            )
        }
        runs[project.id] = RunState(phase: install == nil ? .starting : .installing, log: precedingLog)
        do {
            let process = try ManagedProcess(
                shellArguments: arguments, directory: project.path, environment: environment,
                projectLock: stateFile.url.deletingLastPathComponent()
                    .appendingPathComponent("RunLocks/\(project.id.uuidString).lock"),
                onOutput: { output.append($0) },
                onExit: { [weak self] outcome in
                    Task { @MainActor in self?.processEnded(project.id, sessionID: id, outcome: outcome) }
                }
            )
            processes[project.id] = ActiveRun(id: id, process: process, output: output, project: project,
                                             installation: installation, install: install)
            if isPython { runs[project.id]?.phase = .running }
            beginLogRefresh()
        } catch {
            runs[project.id] = RunState(phase: .failed, log: precedingLog,
                                       message: "无法启动进程。\(error.localizedDescription)", install: install)
        }
    }

    private func beginLogRefresh() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLogs() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshLogs() {
        for (id, session) in processes {
            apply(session.output.snapshot(), to: id, installation: session.installation)
        }
    }

    private func apply(_ update: RunOutput.Update?, to id: UUID, installation: NVMInstallation?) {
        guard let update, var state = runs[id] else { return }
        state.log = update.log
        state.node = update.node
        state.message = update.error
        if let command = update.installCommand {
            state.install = InstallAction(operation: .installNode, installation: installation, command: command)
        }
        if state.phase == .starting && state.node != nil { state.phase = .running }
        runs[id] = state
    }

    private func processEnded(_ id: UUID, sessionID: UUID, outcome: ProcessOutcome) {
        guard let session = processes[id], session.id == sessionID else { return }
        apply(session.output.snapshot(final: true), to: id, installation: session.installation)
        processes[id] = nil
        var state = runState(id)
        let stopped = outcome.stopped || (state.phase == .stopping && !session.restart)
        if !stopped && outcome.exitCode == 0 && session.install != nil && !terminating {
            refreshInstalledVersions()
            let log = state.log + "\n安装完成，正在重新启动…\n"
            launch(session.project, using: session.installation, precedingLog: log)
            if processes.isEmpty {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
            return
        }
        if stopped {
            state.phase = .stopped
            state.message = "进程已停止。"
            state.install = nil
        } else if outcome.exitCode == 0 {
            state.phase = .finished
            state.message = "退出码 0"
        } else {
            state.phase = .failed
            let detail = outcome.signal.map { "退出信号 \($0)" } ?? "退出码 \(outcome.exitCode)"
            let message: String?
            if let install = session.install {
                message = state.message ?? "安装失败。"
                state.install = state.install ?? install
            } else if state.install != nil {
                message = "缺少项目所需的 Node 版本。"
            } else if state.node != nil && outcome.signal == nil &&
                        ProjectFiles.needsInstall(at: session.project.path, log: session.output.commandLog()) {
                message = "项目依赖缺失，可以先安装依赖再启动。"
                state.install = InstallAction(operation: .installDependencies, installation: session.installation,
                                              command: "npm install")
            } else {
                message = state.message
            }
            state.message = [message, detail].compactMap { $0 }.joined(separator: " ")
        }
        runs[id] = state
        if session.restart, let project = saved.projects.first(where: { $0.id == id }) { start(project) }
        if processes.isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        finishTerminationIfReady()
    }

    private func finishTerminationIfReady() {
        guard processes.isEmpty, probe == nil, let reply = terminateReply else { return }
        terminateReply = nil
        reply()
    }

    private func fail(_ id: UUID, _ message: String) {
        runs[id] = RunState(phase: .failed, message: message)
    }

    private func commit(_ next: SavedState) -> Bool {
        guard canSave else {
            alert = "项目设置暂时无法保存。请检查 \(stateFile.url.path) 后重新打开 App。"
            return false
        }
        do {
            try stateFile.save(next)
            saved = next
            return true
        } catch {
            alert = "无法保存项目设置。\(error.localizedDescription)"
            return false
        }
    }
}
