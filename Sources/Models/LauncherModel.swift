import AppKit
import Foundation
import Observation

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

struct InstallAction: Equatable {
    let operation: NVM.Operation
    let installation: NVMInstallation?
    let command: String
}

struct RunMetadata: Equatable {
    var phase: RunPhase = .idle
    var node: String?
    var detectedURL: URL?
    var message: String?
    var install: InstallAction?
    var installCommand: String? { install?.command }
}

struct RunState {
    var phase: RunPhase = .idle
    var log = ""
    var node: String?
    var detectedURL: URL?
    var message: String?
    var install: InstallAction?
    var installCommand: String? { install?.command }
}

@Observable
@MainActor
final class LauncherModel {
    var selection: UUID?
    private(set) var saved = SavedState()
    private(set) var projects: [Project] = []
    private var projectsByID: [UUID: Project] = [:]
    private var runMetadata: [UUID: RunMetadata] = [:]
    private var runLogs: [UUID: LogSnapshot] = [:]
    private(set) var installation: NVMInstallation?
    private(set) var versions: [String] = []
    private(set) var detecting = false
    private(set) var scanning = false
    private(set) var scanResult: ScanResult?
    private(set) var installedIDEs: [ProjectIDE] = []
    private(set) var installedTerminals: [ProjectTerminal] = ProjectTerminal.installed()
    private(set) var installedAICLIs: [ProjectAICLI] = []
    private(set) var gitStatuses: [UUID: GitRepositoryStatus] = [:]
    private(set) var gitBusy: Set<UUID> = []
    private(set) var gitNotices: [UUID: String] = [:]
    var alert: String?

    private struct ActiveRun {
        let id: UUID
        let process: ManagedProcess
        let output: RunOutput
        let project: Project
        let installation: NVMInstallation?
        let install: InstallAction?
        var restart = false
    }

    @ObservationIgnored private let stateFile: StateFile
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var processes: [UUID: ActiveRun] = [:]
    @ObservationIgnored private var waitingForNVM: [UUID: Project] = [:]
    @ObservationIgnored private var shellPath: String?
    @ObservationIgnored private var probe: ManagedProcess?
    @ObservationIgnored private var pathProbe: ManagedProcess?
    @ObservationIgnored private var scanTask: Task<ScanResult, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var gitRefreshAllTask: Task<Void, Never>?
    @ObservationIgnored private var gitRefreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var gitGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var gitNoticeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastToolDiscoveryAt: Date?
    @ObservationIgnored private var lastGitRefreshAllAt: Date?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var terminateReply: (() -> Void)?

    init(stateFile: StateFile = .local) {
        self.stateFile = stateFile
        do {
            let loaded = try stateFile.load()
            applySavedState(loaded)
            selection = loaded.projects.first?.id
        } catch {
            canSave = false
            alert = "无法读取已保存的项目。请检查 \(stateFile.url.path)。\n\(error.localizedDescription)"
        }
        refreshNVM()
        lastToolDiscoveryAt = Date()
        refreshInstalledIDEs()
        refreshTerminalTools()
        refreshAllGit()
    }

    private func applySavedState(_ state: SavedState) {
        saved = state
        projects = state.projects.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        projectsByID = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
    }

    func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projectsByID[id]
    }

    var runningCount: Int {
        runMetadata.values.reduce(into: 0) { count, meta in
            if meta.phase == .running { count += 1 }
        }
    }

    var pinnedProjects: [Project] {
        projects.filter(\.pinned)
    }

    var startablePinnedProjects: [Project] {
        projects.filter { $0.pinned && !runPhase($0.id).isActive && $0.hasLaunchCommand }
    }

    func browserURL(for project: Project) -> URL? {
        guard runPhase(project.id) == .running else { return nil }
        if let detected = runMetadata[project.id]?.detectedURL {
            return detected
        }
        guard let port = project.launchPort else { return nil }
        return URL(string: "http://localhost:\(port)")
    }

    func effectivePort(for project: Project) -> UInt16? {
        if runPhase(project.id) == .running,
           let port = runMetadata[project.id]?.detectedURL?.port,
           let valid = UInt16(exactly: port), valid != 0 {
            return valid
        }
        return project.launchPort
    }

    func runPhase(_ id: UUID) -> RunPhase {
        runMetadata[id]?.phase ?? .idle
    }

    func runMetadataState(_ id: UUID) -> RunMetadata {
        runMetadata[id] ?? RunMetadata()
    }

    func logSnapshot(_ id: UUID) -> LogSnapshot {
        runLogs[id] ?? LogSnapshot()
    }

    func runState(_ id: UUID) -> RunState {
        let meta = runMetadata[id] ?? RunMetadata()
        let log = runLogs[id]?.text ?? ""
        return RunState(
            phase: meta.phase,
            log: log,
            node: meta.node,
            detectedURL: meta.detectedURL,
            message: meta.message,
            install: meta.install
        )
    }

    private func setRunState(
        _ id: UUID,
        phase: RunPhase,
        log: LogSnapshot? = nil,
        node: String? = nil,
        detectedURL: URL? = nil,
        message: String? = nil,
        install: InstallAction? = nil
    ) {
        let nextMeta = RunMetadata(
            phase: phase,
            node: node,
            detectedURL: detectedURL,
            message: message,
            install: install
        )
        if runMetadata[id] != nextMeta {
            runMetadata[id] = nextMeta
        }
        if let log {
            if runLogs[id] != log {
                runLogs[id] = log
            }
        } else if runLogs[id] != nil {
            runLogs[id] = nil
        }
    }

    private func clearRunState(_ id: UUID) {
        runMetadata[id] = nil
        runLogs[id] = nil
    }

    func refreshOnAppActivation() {
        let now = Date()
        if lastToolDiscoveryAt == nil || now.timeIntervalSince(lastToolDiscoveryAt!) >= 20 {
            lastToolDiscoveryAt = now
            refreshInstalledIDEs()
            refreshTerminalTools()
        }
        if lastGitRefreshAllAt == nil || now.timeIntervalSince(lastGitRefreshAllAt!) >= 5 {
            refreshAllGit()
        }
    }

    func refreshInstalledIDEs() {
        Task.detached(priority: .utility) {
            let discovered = ProjectIDE.discover()
            await MainActor.run { [weak self] in
                guard let self, self.installedIDEs != discovered else { return }
                self.installedIDEs = discovered
            }
        }
    }

    func refreshTerminalTools() {
        let terminals = ProjectTerminal.installed()
        if installedTerminals != terminals {
            installedTerminals = terminals
        }
        let currentShellPath = shellPath
        let nvmDirectory = installation?.directory
        Task.detached(priority: .utility) {
            let discovered = ProjectAICLI.discover(shellPath: currentShellPath, nvmDirectory: nvmDirectory)
            await MainActor.run { [weak self] in
                guard let self, self.installedAICLIs != discovered else { return }
                self.installedAICLIs = discovered
            }
        }
    }

    func openProject(_ project: Project, in ide: ProjectIDE) async {
        do {
            try await ide.open(at: project.path)
        } catch {
            refreshInstalledIDEs()
            alert = error.localizedDescription
        }
    }

    func gitStatus(_ id: UUID) -> GitRepositoryStatus? { gitStatuses[id] }
    func isGitBusy(_ id: UUID) -> Bool { gitBusy.contains(id) }

    func refreshGit(for project: Project, detail: ProjectGit.DetailLevel = .full) {
        let projectID = project.id
        let path = project.path
        let existing = gitStatuses[projectID]
        let expectedGeneration = gitGenerations[projectID, default: 0]
        gitRefreshTasks[projectID]?.cancel()
        gitRefreshTasks[projectID] = Task { [weak self] in
            let status = await ProjectGit.inspectAsync(at: path, detail: detail, existing: existing)
            guard !Task.isCancelled, let self else { return }
            self.gitRefreshTasks[projectID] = nil
            guard self.projectsByID[projectID]?.path == path,
                  self.gitGenerations[projectID, default: 0] == expectedGeneration else { return }
            if self.gitStatuses[projectID] != status {
                self.gitStatuses[projectID] = status
            }
        }
    }

    func refreshAllGit() {
        gitRefreshAllTask?.cancel()
        lastGitRefreshAllAt = Date()
        let selectedID = selection
        let ordered = projects.sorted { lhs, rhs in
            if lhs.id == selectedID { return true }
            if rhs.id == selectedID { return false }
            return false
        }
        let targets: [(UUID, String, ProjectGit.DetailLevel, GitRepositoryStatus?, UInt64)] = ordered.map { project in
            let detail: ProjectGit.DetailLevel = project.id == selectedID ? .full : .summary
            return (
                project.id,
                project.path,
                detail,
                gitStatuses[project.id],
                gitGenerations[project.id, default: 0]
            )
        }
        guard !targets.isEmpty else { return }

        gitRefreshAllTask = Task { [weak self] in
            for (projectID, path, detail, existing, expectedGeneration) in targets {
                if Task.isCancelled { break }
                let status = await ProjectGit.inspectAsync(at: path, detail: detail, existing: existing)
                guard !Task.isCancelled, let self else { break }
                guard self.projectsByID[projectID]?.path == path,
                      self.gitGenerations[projectID, default: 0] == expectedGeneration else { continue }
                if self.gitStatuses[projectID] != status {
                    self.gitStatuses[projectID] = status
                }
            }
        }
    }

    func gitSwitchBranch(_ branch: String, for project: Project) {
        Task {
            _ = await runGitAction(for: project, successNotice: "已切换到 \(branch)") {
                try ProjectGit.switchBranch(branch, at: project.path)
            }
        }
    }

    func gitCreateBranch(_ name: String, for project: Project) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await runGitAction(for: project, successNotice: "已创建并切换到 \(trimmed)") {
            try ProjectGit.createBranch(trimmed, at: project.path)
        }
    }

    func gitFetch(for project: Project) {
        Task {
            _ = await runGitAction(for: project, successNotice: "已同步远程引用") {
                try ProjectGit.fetch(at: project.path)
            }
        }
    }

    func gitPull(for project: Project) {
        Task {
            _ = await runGitAction(for: project, successNotice: "已拉取最新代码") {
                try ProjectGit.pull(at: project.path)
            }
        }
    }

    func gitPush(for project: Project) {
        let currentStatus = gitStatuses[project.id]
        Task {
            _ = await runGitAction(for: project, successNotice: "已推送到远程") {
                try ProjectGit.push(at: project.path, currentStatus: currentStatus)
            }
        }
    }

    private func runGitAction(
        for project: Project,
        successNotice: String,
        operation: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        guard !gitBusy.contains(project.id) else { return false }
        gitRefreshTasks[project.id]?.cancel()
        gitRefreshTasks[project.id] = nil
        gitGenerations[project.id, default: 0] &+= 1
        gitBusy.insert(project.id)
        defer { gitBusy.remove(project.id) }

        let path = project.path
        do {
            try await ProjectGit.performAsync(operation)
            let updated = await ProjectGit.inspectAsync(at: path, detail: .full)
            gitGenerations[project.id, default: 0] &+= 1
            if projectsByID[project.id]?.path == path {
                gitStatuses[project.id] = updated
                showGitNotice(successNotice, for: project.id)
            }
            return true
        } catch {
            let updated = await ProjectGit.inspectAsync(at: path, detail: .full)
            gitGenerations[project.id, default: 0] &+= 1
            if projectsByID[project.id]?.path == path {
                gitStatuses[project.id] = updated
            }
            alert = error.localizedDescription
            return false
        }
    }

    private func showGitNotice(_ message: String, for id: UUID) {
        gitNoticeTasks[id]?.cancel()
        gitNotices[id] = message
        gitNoticeTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.gitNotices[id] == message {
                    self?.gitNotices[id] = nil
                }
            }
        }
    }

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
        for project in new { refreshGit(for: project) }
        return true
    }

    func relocate(_ project: Project, to url: URL) {
        guard !runPhase(project.id).isActive else { return }
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
        if update(updated) {
            clearRunState(project.id)
            gitStatuses[project.id] = nil
            refreshGit(for: updated)
        }
    }

    func update(_ project: Project) -> Bool {
        guard !runPhase(project.id).isActive,
              let index = saved.projects.firstIndex(where: { $0.id == project.id }) else { return false }
        guard project.launchPort != 0 else {
            alert = "请输入 1–65535 之间的端口号。"
            return false
        }
        var next = saved
        var updated = project
        updated.listAlias = next.projects[index].listAlias
        updated.isPinned = next.projects[index].isPinned
        let settingsChanged = next.projects[index] != updated
        next.projects[index] = updated
        guard commit(next) else { return false }
        if settingsChanged, var meta = runMetadata[project.id], meta.install != nil {
            meta.install = nil
            runMetadata[project.id] = meta
        }
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

    @discardableResult
    func setPinned(_ pinned: Bool, for id: UUID) -> Bool {
        guard let index = saved.projects.firstIndex(where: { $0.id == id }) else { return false }
        let value: Bool? = pinned ? true : nil
        guard saved.projects[index].isPinned != value else { return true }
        var next = saved
        next.projects[index].isPinned = value
        return commit(next)
    }

    @discardableResult
    func togglePinned(_ id: UUID) -> Bool {
        guard let current = projectsByID[id] else { return false }
        return setPinned(!current.pinned, for: id)
    }

    func startPinnedProjects() {
        for project in startablePinnedProjects {
            start(project)
        }
    }

    func remove(_ id: UUID) {
        guard !runPhase(id).isActive else { return }
        var next = saved
        next.projects.removeAll { $0.id == id }
        guard commit(next) else { return }
        clearRunState(id)
        gitRefreshTasks[id]?.cancel()
        gitRefreshTasks[id] = nil
        gitGenerations[id] = nil
        gitStatuses[id] = nil
        gitBusy.remove(id)
        gitNoticeTasks[id]?.cancel()
        gitNoticeTasks[id] = nil
        gitNotices[id] = nil
        let lockURL = stateFile.url.deletingLastPathComponent()
            .appendingPathComponent("RunLocks/\(id.uuidString).lock")
        try? FileManager.default.removeItem(at: lockURL)
        if selection == id { selection = projects.first?.id }
    }

    func setNVMScript(_ path: String?) {
        guard saved.nvmScript != path else { return }
        var next = saved
        next.nvmScript = path
        if commit(next) {
            for id in Array(runMetadata.keys) {
                if var meta = runMetadata[id], meta.install != nil {
                    meta.install = nil
                    runMetadata[id] = meta
                }
            }
            refreshNVM()
        }
    }

    func refreshNVM() {
        if let manualScript = saved.nvmScript {
            probe?.stop()
            probe = nil
            completeDetection(NVM.manual(manualScript))
            probeShellPathIfNeeded()
            return
        }
        let inherited = NVM.inherited()
        if let inherited, !inherited.installedVersions.isEmpty {
            completeDetection(inherited)
            probeShellPathIfNeeded()
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
                            if let path, !path.isEmpty {
                                self.shellPath = path
                            }
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
                completeDetection(NVM.resolvedInstallation(probed: nil, inherited: inherited))
            }
        }
    }

    private func probeShellPathIfNeeded() {
        guard !terminating, shellPath == nil, probe == nil, pathProbe == nil else { return }
        let output = ProbeOutput()
        pathProbe = try? ManagedProcess(
            shellArguments: NVM.probeArguments,
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            environment: ManagedProcess.environment(), timeout: 4,
            onOutput: { output.append($0) },
            onExit: { [weak self] _ in
                let path = NVM.probedPath(output.text())
                Task { @MainActor in
                    guard let self else { return }
                    self.pathProbe = nil
                    if let path, !path.isEmpty, self.shellPath != path {
                        self.shellPath = path
                        self.refreshTerminalTools()
                    }
                    self.finishTerminationIfReady()
                }
            }
        )
    }

    func start(_ project: Project) {
        guard !terminating, !runPhase(project.id).isActive else { return }
        guard project.hasLaunchCommand else {
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
        if detecting {
            setRunState(project.id, phase: .starting)
            waitingForNVM[project.id] = project
            return
        }
        if let installation,
           FileManager.default.isReadableFile(atPath: installation.script),
           saved.nvmScript != nil || !installation.installedVersions.isEmpty {
            launch(project, using: installation)
        } else {
            launch(project, using: nil)
        }
    }

    func installAndRestart(_ id: UUID) {
        let meta = runMetadataState(id)
        guard !terminating, meta.phase == .failed, let action = meta.install,
              let project = projectsByID[id] else { return }
        let log = logSnapshot(id).text + "\n$ " + action.command + "\n"
        launch(project, using: action.installation, install: action, precedingLog: log)
    }

    func stop(_ id: UUID) {
        if waitingForNVM.removeValue(forKey: id) != nil {
            setRunState(id, phase: .stopped, message: "已取消启动。")
        } else if let session = processes[id] {
            processes[id]?.restart = false
            runMetadata[id]?.phase = .stopping
            session.process.stop()
        }
    }

    func stopAll() {
        for id in Set(waitingForNVM.keys).union(processes.keys) {
            stop(id)
        }
    }

    func restart(_ id: UUID) {
        if let session = processes[id], runPhase(id) == .running {
            processes[id]?.restart = true
            runMetadata[id]?.phase = .stopping
            session.process.stop()
        }
    }

    func clearLog(_ id: UUID) {
        if let session = processes[id] {
            session.output.clear()
            if let update = session.output.snapshot() {
                runLogs[id] = update.snapshot
            } else {
                runLogs[id] = LogSnapshot()
            }
        } else {
            var cleared = runLogs[id] ?? LogSnapshot()
            cleared.text = ""
            cleared.droppedUTF16 = 0
            cleared.generation &+= 1
            cleared.revision &+= 1
            runLogs[id] = cleared
        }
    }

    func terminate(reply: @escaping () -> Void) -> Bool {
        terminating = true
        cancelScan()
        waitingForNVM.removeAll()
        guard !processes.isEmpty || probe != nil || pathProbe != nil else { return true }
        terminateReply = reply
        probe?.stop()
        pathProbe?.stop()
        for id in Array(processes.keys) { stop(id) }
        return false
    }

    private func completeDetection(_ result: NVMInstallation?) {
        detecting = false
        installation = result
        refreshInstalledVersions()
        refreshTerminalTools()
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
        let output = RunOutput(token: id.uuidString, precedingLog: precedingLog, expectsNodeStartup: true)
        var environment = ManagedProcess.environment(shellPath: installation == nil ? shellPath : nil)
        let launchCommand: String
        if let install {
            launchCommand = install.operation == .installDependencies ? install.command : project.command
        } else {
            launchCommand = ProjectFiles.launchCommand(for: project)
        }
        let arguments: [String]
        if isPython {
            if let virtualEnvironment = ProjectFiles.pythonVirtualEnvironment(at: project.path),
               let path = environment["PATH"] {
                environment["PATH"] = virtualEnvironment.appendingPathComponent("bin").path + ":" + path
                environment["VIRTUAL_ENV"] = virtualEnvironment.path
            }
            environment["PYTHONUNBUFFERED"] = environment["PYTHONUNBUFFERED"] ?? "1"
            arguments = ProjectFiles.pythonBootstrapArguments(command: launchCommand, token: id.uuidString)
        } else {
            arguments = NVM.arguments(
                installation: installation, selector: project.nodeVersion,
                command: launchCommand, token: id.uuidString, operation: install?.operation ?? .start
            )
        }
        let initialLog = precedingLog.isEmpty ? nil : LogSnapshot(text: precedingLog)
        setRunState(project.id, phase: install == nil ? .starting : .installing, log: initialLog)
        do {
            let process = try ManagedProcess(
                shellArguments: arguments, directory: project.path, environment: environment,
                projectLock: stateFile.url.deletingLastPathComponent()
                    .appendingPathComponent("RunLocks/\(project.id.uuidString).lock"),
                launchPort: install == nil ? project.launchPort : nil,
                onOutput: { output.append($0) },
                onExit: { [weak self] outcome in
                    Task { @MainActor in self?.processEnded(project.id, sessionID: id, outcome: outcome) }
                }
            )
            processes[project.id] = ActiveRun(id: id, process: process, output: output, project: project,
                                             installation: installation, install: install)
            beginLogRefresh()
        } catch {
            setRunState(project.id, phase: .failed, log: initialLog,
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
        guard let update, var meta = runMetadata[id] else { return }
        if runLogs[id] != update.snapshot {
            runLogs[id] = update.snapshot
        }
        if let node = update.node { meta.node = node }
        if let detectedURL = update.detectedURL { meta.detectedURL = detectedURL }
        if let error = update.error { meta.message = error }
        if let command = update.installCommand {
            meta.install = InstallAction(operation: .installNode, installation: installation, command: command)
        }
        if meta.phase == .starting && (meta.node != nil || meta.detectedURL != nil) {
            meta.phase = .running
        }
        if runMetadata[id] != meta {
            runMetadata[id] = meta
        }
    }

    private func processEnded(_ id: UUID, sessionID: UUID, outcome: ProcessOutcome) {
        guard let session = processes[id], session.id == sessionID else { return }
        apply(session.output.snapshot(final: true), to: id, installation: session.installation)
        processes[id] = nil
        var meta = runMetadataState(id)
        let currentLog = logSnapshot(id).text
        let stopped = outcome.stopped || (meta.phase == .stopping && !session.restart)
        if !stopped && outcome.exitCode == 0 && session.install != nil && !terminating {
            refreshInstalledVersions()
            let log = currentLog + "\n安装完成，正在重新启动…\n"
            launch(session.project, using: session.installation, precedingLog: log)
            if processes.isEmpty {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
            return
        }
        if stopped {
            meta.phase = .stopped
            meta.detectedURL = nil
            meta.message = "进程已停止。"
            meta.install = nil
        } else if outcome.exitCode == 0 {
            meta.phase = .finished
            meta.detectedURL = nil
            meta.message = "退出码 0"
        } else {
            meta.phase = .failed
            meta.detectedURL = nil
            let detail = outcome.signal.map { "退出信号 \($0)" } ?? "退出码 \(outcome.exitCode)"
            let message: String?
            if let install = session.install {
                message = meta.message ?? "安装失败。"
                meta.install = meta.install ?? install
            } else if meta.install != nil {
                message = "缺少项目所需的 Node 版本。"
            } else if session.project.kind == .node && meta.node != nil && outcome.signal == nil &&
                        ProjectFiles.needsInstall(at: session.project.path, log: session.output.commandLog()) {
                let manager = ProjectFiles.detectPackageManager(at: session.project.path)
                message = "项目依赖缺失，可以先安装依赖再启动。"
                meta.install = InstallAction(operation: .installDependencies, installation: session.installation,
                                             command: manager.installCommand)
            } else {
                message = meta.message
            }
            meta.message = [message, detail].compactMap { $0 }.joined(separator: " ")
        }
        if runMetadata[id] != meta {
            runMetadata[id] = meta
        }
        if session.restart, let project = projectsByID[id] { start(project) }
        if processes.isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        finishTerminationIfReady()
    }

    private func finishTerminationIfReady() {
        guard processes.isEmpty, probe == nil, pathProbe == nil, let reply = terminateReply else { return }
        terminateReply = nil
        reply()
    }

    private func fail(_ id: UUID, _ message: String) {
        setRunState(id, phase: .failed, message: message)
    }

    private func commit(_ next: SavedState) -> Bool {
        guard canSave else {
            alert = "项目设置暂时无法保存。请检查 \(stateFile.url.path) 后重新打开 App。"
            return false
        }
        do {
            try stateFile.save(next)
            applySavedState(next)
            return true
        } catch {
            alert = "无法保存项目设置。\(error.localizedDescription)"
            return false
        }
    }
}
