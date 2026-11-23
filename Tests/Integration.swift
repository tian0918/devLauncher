import Darwin
import Foundation

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct Integration {
    @MainActor
    static func main() async throws {
        ProcessSupervisor.runIfRequested()
        if CommandLine.arguments.dropFirst().first == "--test-process-owner" {
            try await runTestProcessOwner()
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try verifyTerminalAndAICLI(from: root)
        try verifyLaunchPortCommandAdaptation(at: root)
        try await verifyIDECommands(from: root)
        try verifyGitSupport(from: root)
        try await verifyPythonLaunch(at: root)

        let homeProjects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/txby项目")
        if FileManager.default.fileExists(atPath: homeProjects.path) {
            let realResult = ProjectFiles.scan([homeProjects]) { false }
            try expect(!realResult.candidates.isEmpty, "Local project scan found no manifests")
            if let node = realResult.candidates.first(where: { $0.kind == .node }) {
                let selected = URL(fileURLWithPath: node.path).appendingPathComponent("package.json")
                try expect(ProjectFiles.scan([selected]) { false }.candidates.count == 1, "Single-file import failed")
            }
            print("Scanned \(realResult.candidates.count) local projects without running them")
        }

        let fixture = root.appendingPathComponent("项目 with spaces")
        let alpha = fixture.appendingPathComponent("nested/alpha")
        let beta = fixture.appendingPathComponent("beta")
        let commandless = fixture.appendingPathComponent("commandless")
        for directory in [alpha, beta, commandless, fixture.appendingPathComponent("broken"),
                          fixture.appendingPathComponent("build"), fixture.appendingPathComponent(".hidden"),
                          fixture.appendingPathComponent("node_modules")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write(#"{"name":"alpha","scripts":{"dev":"node server.cjs","start":"exit 2"},"engines":{"node":">=18"}}"#,
                  to: alpha.appendingPathComponent("package.json"))
        try write(#"{"name":"beta","scripts":{"start":"node other.cjs"}}"#, to: beta.appendingPathComponent("package.json"))
        try write("{}", to: commandless.appendingPathComponent("package.json"))
        try write("{", to: fixture.appendingPathComponent("broken/package.json"))
        for directory in ["build", ".hidden", "node_modules"] {
            try write("{}", to: fixture.appendingPathComponent("\(directory)/package.json"))
        }
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("linked"), withDestinationURL: alpha)

        let scan = ProjectFiles.scan([fixture, alpha.appendingPathComponent("package.json")]) { false }
        try expect(scan.candidates.map(\.name) == ["alpha", "beta", "commandless"], "Scan, pruning or deduplication failed")
        try expect(scan.skipped.count == 1, "Invalid manifest was not reported")
        try expect(scan.candidates.map(\.suggestedCommand) == ["npm run dev", "npm run start", ""], "Script defaults differ")

        let file = StateFile(url: root.appendingPathComponent("state/projects.json"))
        let model = LauncherModel(stateFile: file)
        try await until("nvm detection") { !model.detecting }
        if let expectedNVM = ProcessInfo.processInfo.environment["DEVLAUNCHER_EXPECT_NVM"] {
            try expect(model.installation?.directory == expectedNVM, "nvm detection selected \(model.installation?.directory ?? "none")")
        }
        guard let installation = model.installation, model.versions.count >= 2 else {
            throw CheckFailure(message: "Integration requires an nvm installation with at least two Node versions")
        }
        print("Detected nvm at \(installation.directory)")

        let explicitVersion = model.versions[0]
        let explicitSelector = String(explicitVersion.dropFirst().prefix(while: { $0.isNumber }))
        let rcVersion = model.versions[1]
        try await verifyForcedQuit(root: root, installation: installation, version: explicitVersion)
        try write("# fixture\n\(rcVersion)\n", to: fixture.appendingPathComponent(".nvmrc"))
        try write("console.error('stderr 测试'); console.log('node:' + process.version); setInterval(() => {}, 1000);",
                  to: beta.appendingPathComponent("other.cjs"))
        try write("""
        const net = require('net');
        const fs = require('fs');
        process.on('SIGTERM', () => {});
        console.log('node:' + process.version);
        console.error('stderr 测试');
        const server = net.createServer();
        server.on('error', err => {
          if (err.code !== 'EPERM' && err.code !== 'EACCES') throw err;
          console.log('loopback unavailable');
          fs.writeFileSync('pid', String(process.pid));
        });
        server.listen(0, '127.0.0.1', () => {
          fs.writeFileSync('port', String(server.address().port));
          fs.writeFileSync('pid', String(process.pid));
        });
        setInterval(() => {}, 1000);
        """, to: alpha.appendingPathComponent("server.cjs"))

        try expect(model.add(Array(scan.candidates.prefix(2))), "Import failed")
        guard let first = model.projects.first, var second = model.projects.last else {
            throw CheckFailure(message: "Projects missing after import")
        }
        defer { model.stop(first.id); model.stop(second.id) }

        let withoutAlias = try file.load().projects.first { $0.id == second.id }
        try expect(withoutAlias?.listAlias == nil && withoutAlias?.listName == second.name,
                   "Projects saved without an alias did not keep their original display name")
        try expect(model.setListAlias("  测试项目  ", for: second.id), "Could not save list alias")
        second.nodeVersion = explicitSelector
        try expect(model.update(second), "Could not persist explicit version")
        try expect(model.add(scan.candidates.filter { $0.name == "beta" }), "Duplicate import failed")
        let saved = try file.load()
        var withAlias = second
        withAlias.listAlias = "测试项目"
        try expect(saved.projects.count == 2 && saved.projects.first { $0.id == second.id } == withAlias,
                   "Reload or duplicate import overwrote settings")
        try expect(withAlias.listName == "测试项目", "List did not use the saved alias")

        model.start(first)
        model.start(first)
        model.start(second)
        let pidFile = alpha.appendingPathComponent("pid")
        try await until("parallel launches and stderr", describe: {
            "\(model.runState(first.id))\n\(model.runState(second.id))"
        }) {
            model.runState(first.id).log.contains("stderr 测试") &&
                model.runState(second.id).log.contains("stderr 测试") && FileManager.default.fileExists(atPath: pidFile.path)
        }
        try expect(model.runState(first.id).node == rcVersion, "Parent .nvmrc did not set Node")
        try expect(model.runState(second.id).node == explicitVersion, "Explicit version did not override .nvmrc")
        try expect(model.runState(second.id).log.contains("nvm: \(installation.directory)"),
                   "Launch did not log the selected nvm directory")
        try expect(model.runState(second.id).log.components(separatedBy: "node:").count == 2, "Unexpected duplicate command output")
        try expect(model.setListAlias("   ", for: second.id), "Could not clear alias during a run")
        let cleared = try file.load().projects.first { $0.id == second.id }
        try expect(cleared == second && cleared?.listName == second.name && model.runState(second.id).phase == .running,
                   "Clearing the alias affected project settings or the active run")

        let previousPID = try readPID(pidFile)
        try expect(isAlive(previousPID), "Could not observe the running npm child")
        let portFile = alpha.appendingPathComponent("port")
        let port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap(UInt16.init)
        try FileManager.default.removeItem(at: pidFile)
        model.restart(first.id)
        try await until("restart process", seconds: 12) {
            model.runState(first.id).phase == .running && (try? readPID(pidFile)) != nil
        }
        let restartedPID = try readPID(pidFile)
        try expect(restartedPID != previousPID, "Restart kept the same child")
        try await until("original child exit") { !isAlive(previousPID) }
        if let port { try expect(canBind(port), "Restart did not release the old child port") }
        try expect(model.runState(second.id).phase == .running, "Restart affected another project")

        model.stop(first.id)
        try await until("stop process", seconds: 10) {
            model.runState(first.id).phase == .stopped && !isAlive(restartedPID)
        }

        var missing = second
        model.stop(second.id)
        try await until("stop second project") { model.runState(second.id).phase == .stopped }
        missing.nodeVersion = "v999.999.999"
        missing.command = "echo SHOULD_NOT_RUN"
        model.start(missing)
        try await until("missing version handling") { model.runState(second.id).phase == .failed }
        try expect(model.runState(second.id).installCommand?.contains("v999.999.999") == true, "Missing install command")
        try expect(!model.runState(second.id).log.contains("SHOULD_NOT_RUN"), "Command ran despite nvm failure")

        var defaultProject = first
        defaultProject.nodeVersion = nil
        defaultProject.command = "printf 'ending without newline'; exit 7"
        try FileManager.default.removeItem(at: fixture.appendingPathComponent(".nvmrc"))
        model.start(defaultProject)
        try await until("default version and exit code") { model.runState(first.id).phase == .failed }
        try expect(model.runState(first.id).node != nil && model.runState(first.id).message == "退出码 7",
                   "Default version or exit code did not propagate")
        try expect(model.runState(first.id).log.hasSuffix("ending without newline"), "Final output was lost")

        model.setNVMScript(root.appendingPathComponent("disconnected/nvm.sh").path)
        var fallback = first
        fallback.command = "node --version"
        fallback.nodeVersion = "v999.999.999"
        model.start(fallback)
        try await until("PATH Node fallback") { model.runState(first.id).phase == .finished }
        try expect(model.runState(first.id).node != nil && model.runState(first.id).log.contains("PATH"),
                   "Unavailable nvm did not fall back to PATH Node")
        try await verifyInstallRecovery(model: model, root: root)

        model.setNVMScript(installation.script)
        model.start(second)
        try await until("ready before quit") { model.runState(second.id).phase == .running }
        var replied = false
        try expect(!model.terminate { replied = true }, "Quit did not wait for active process")
        try await until("quit cleanup") { replied && model.runState(second.id).phase == .stopped }

        let token = "startup-token"
        let log = RunOutput(token: token)
        log.append(Data("\(token)\tNO".utf8))
        log.append(Data("DE\tv22\n\u{001B}[31m标准输出\u{001B}[0m".utf8))
        try expect(log.snapshot()?.log == "Node v22\n标准输出", "Partial marker, UTF-8, or ANSI handling failed")
        log.append(Data(repeating: 97, count: 1_100_000))
        try expect(log.snapshot()?.log.utf8.count == 1_048_576, "Log retention exceeded its bound")
        print("Core integration checks passed. Loopback port checks: \(port == nil ? "unavailable in this session" : "passed").")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw CheckFailure(message: message) }
    }

    @MainActor
    private static func verifyPythonLaunch(at root: URL) async throws {
        let workspace = root.appendingPathComponent("Python projects")
        let django = workspace.appendingPathComponent("django")
        let script = workspace.appendingPathComponent("单独的项目")
        let interpreter = script.appendingPathComponent(".venv/bin/python3")
        let mixed = workspace.appendingPathComponent("mixed")
        let nvm = root.appendingPathComponent("broken-nvm")
        for directory in [django, interpreter.deletingLastPathComponent(), mixed, nvm] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("", to: django.appendingPathComponent("manage.py"))
        try write("{}", to: mixed.appendingPathComponent("package.json"))
        let manifest = mixed.appendingPathComponent("pyproject.toml")
        try write("[project]\nname = 'mixed'\n", to: manifest)
        let entrypoint = script.appendingPathComponent("main.py")
        try write("""
        import os, sys, time
        print(f"python pid={os.getpid()}", flush=True)
        print(f"port={os.environ['PORT']}", flush=True)
        assert os.path.isfile("main.py")
        assert os.environ["VIRTUAL_ENV"].endswith("/.venv")
        assert os.environ["PYTHON_VENV_TEST"] == "1"
        sys.stdout.write("live output without newline")
        time.sleep(30)
        """, to: entrypoint)
        try write("#!/bin/sh\nexport PYTHON_VENV_TEST=1\nexec /usr/bin/python3 \"$@\"\n", to: interpreter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        let arbitraryScript = script.appendingPathComponent("test's 入口.py")
        try write("print('selected script')\n", to: arbitraryScript)

        let scan = ProjectFiles.scan([workspace]) { false }
        try expect(scan.candidates.first { $0.name == "django" }?.suggestedCommand == "python3 manage.py runserver",
                   "Django entrypoint was not detected")
        try expect(scan.candidates.first { $0.name == "mixed" }?.kind == .node, "Mixed project default changed")
        let mixedImport = ProjectFiles.scan([workspace, manifest]) { false }
        try expect(mixedImport.candidates.first { $0.name == "mixed" }?.kind == .python,
                   "Explicit Python manifest did not override the folder scan")
        let direct = ProjectFiles.scan([script]) { false }
        guard let candidate = direct.candidates.first else { throw CheckFailure(message: "Python folder import failed") }
        try expect(candidate.kind == .python && candidate.suggestedCommand == "python3 main.py",
                   "Python entrypoint was not suggested")

        let nvmScript = nvm.appendingPathComponent("nvm.sh")
        try write("return 1\n", to: nvmScript)
        let file = StateFile(url: root.appendingPathComponent("python-state/projects.json"))
        try file.save(SavedState(nvmScript: nvmScript.path))
        let model = LauncherModel(stateFile: file)
        try expect(model.add([candidate]), "Python project could not be saved")
        guard var project = model.projects.first else { throw CheckFailure(message: "Python project was not imported") }
        let saved = try file.load()
        try expect(saved.projects.first?.kind == .python, "Python kind was not persisted")
        try expect(saved.projects.first?.launchPort == nil, "Imported projects should use their default port")
        let listener = try openLoopbackListener()
        let port = listener?.port ?? UInt16.random(in: 49152...65535)
        project.launchPort = port
        let savedPort = model.update(project)
        if let listener {
            defer { close(listener.descriptor) }
            try expect(TCPPortStatus.check(port) == .occupied, "The TCP listener was not detected")
            model.start(project)
            try await until("occupied launch port") { model.runState(project.id).phase == .failed }
            let log = model.runState(project.id).log
            try expect(log.contains("TCP 端口 \(port) 已被占用") && !log.contains("python pid="),
                       "Port conflict did not stop the launch with a clear message")
        }
        try expect(savedPort, "The launch port could not be saved")
        let reloaded = try file.load()
        try expect(reloaded.projects.first?.launchPort == port, "The launch port was not persisted")
        if listener != nil {
            try expect(TCPPortStatus.check(port) == .available, "The released port did not become available")
        } else {
            print("TCP port conflict checks skipped because loopback binding is unavailable")
        }
        defer { model.stop(project.id) }
        model.start(project)
        try await until("Python startup and unbuffered output", describe: { model.runState(project.id).log }) {
            model.runState(project.id).phase == .running && model.runState(project.id).log.contains("live output without newline")
        }
        let firstRun = model.runState(project.id).log
        try expect(firstRun.contains("port=\(port)\n"), "The selected port was not passed to Python")
        model.restart(project.id)
        try await until("Python restart") {
            let state = model.runState(project.id)
            return state.phase == .running && state.log.contains("live output without newline") && state.log != firstRun
        }
        model.stop(project.id)
        try await until("Python stop") { model.runState(project.id).phase == .stopped }

        guard let custom = ProjectFiles.scan([arbitraryScript], isCancelled: { false }).candidates.first else {
            throw CheckFailure(message: "Single Python script import failed")
        }
        project.command = custom.suggestedCommand
        project.launchPort = nil
        try expect(model.update(project), "Python custom command was not saved")
        model.start(project)
        try await until("Python script with quotes and spaces") { model.runState(project.id).phase == .finished }
        try expect(model.runState(project.id).log == "selected script\n", "Selected Python script did not run")

        let manageScript = script.appendingPathComponent("manage.py")
        try write("""
        import os, sys
        print("args=" + " ".join(sys.argv[1:]), flush=True)
        print("env=" + os.environ.get("PORT", ""), flush=True)
        """, to: manageScript)
        project.command = "python3 manage.py runserver"
        project.launchPort = port
        try expect(model.update(project), "Django command with launchPort was not saved")
        model.start(project)
        try await until("Django runserver end-to-end port injection") { model.runState(project.id).phase == .finished }
        let djangoLog = model.runState(project.id).log
        try expect(djangoLog.contains("args=runserver \(port)\n") && djangoLog.contains("env=\(port)\n"),
                   "Django runserver did not receive adapted port argument and PORT env: \(djangoLog)")
        print("Python integration checks passed")
    }

    private static func runTestProcessOwner() async throws {
        let args = CommandLine.arguments
        let process = try ManagedProcess(
            shellArguments: NVM.arguments(
                installation: NVMInstallation(script: args[4], directory: args[5]),
                selector: args[6], command: "npm run dev -- \(args[7])",
                token: UUID().uuidString, operation: .start
            ),
            directory: args[2], projectLock: URL(fileURLWithPath: args[3]), onOutput: { _ in }, onExit: { _ in }
        )
        defer { withExtendedLifetime(process) {} }
        try await Task.sleep(for: .seconds(90))
    }

    @MainActor
    private static func verifyForcedQuit(root: URL, installation: NVMInstallation, version: String) async throws {
        let project = root.appendingPathComponent("forced-quit")
        let lock = root.appendingPathComponent("test-lock/owned.lock")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write(#"{"name":"forced-quit","scripts":{"dev":"node dev.cjs"}}"#, to: project.appendingPathComponent("package.json"))
        try write("""
        const fs = require('fs');
        const net = require('net');
        const label = process.argv[2];
        const port = fs.existsSync('owned-port') ? Number(fs.readFileSync('owned-port')) : 0;
        process.on('SIGTERM', () => {});
        const ready = () => fs.writeFileSync(label + '.pid', String(process.pid));
        const server = net.createServer();
        server.on('error', error => {
          if (error.code === 'EACCES' || error.code === 'EPERM') { ready(); return; }
          throw error;
        });
        server.listen(port, '127.0.0.1', () => {
          fs.writeFileSync('owned-port', String(server.address().port));
          ready();
        });
        setInterval(() => console.log('still running'), 25);
        """, to: project.appendingPathComponent("dev.cjs"))

        func launchOwner(label: String) throws -> Process {
            let owner = Process()
            owner.executableURL = Bundle.main.executableURL
            owner.arguments = ["--test-process-owner", project.path, lock.path,
                               installation.script, installation.directory, version, label]
            try owner.run()
            return owner
        }

        let owner = try launchOwner(label: "before")
        defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL) } }
        let firstPIDFile = project.appendingPathComponent("before.pid")
        try await until("project starts before forced quit", seconds: 12) { (try? readPID(firstPIDFile)) != nil }
        let oldPID = try readPID(firstPIDFile)
        try expect(isAlive(oldPID), "Could not observe the first running server")
        kill(owner.processIdentifier, SIGKILL)

        let restartedOwner = try launchOwner(label: "after")
        defer { if restartedOwner.isRunning { kill(restartedOwner.processIdentifier, SIGKILL) } }
        let secondPIDFile = project.appendingPathComponent("after.pid")
        try await until("project restarts after force quit", seconds: 15) { (try? readPID(secondPIDFile)) != nil }
        let newPID = try readPID(secondPIDFile)
        try expect(newPID != oldPID && isAlive(newPID) && !isAlive(oldPID),
                   "The reopened App started a second server before the original stopped")

        kill(restartedOwner.processIdentifier, SIGKILL)
        try await until("server exits after second force quit") { !isAlive(newPID) }
        let portFile = project.appendingPathComponent("owned-port")
        if let port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap(UInt16.init) {
            try expect(canBind(port), "Force quit did not release the project port")
        }
        print("Forced-quit recovery passed, including immediate relaunch and a SIGTERM-resistant npm child")
    }

    @MainActor
    static func verifyInstallRecovery(model: LauncherModel, root: URL) async throws {
        let projectDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let dependency = root.appendingPathComponent("fixture-dep", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        let manifest = projectDirectory.appendingPathComponent("package.json")
        let metadata = #"{"name":"recovery","scripts":{"start":"node app.cjs"},"dependencies":{"fixture-dep":"file:../fixture-dep"}}"#
        try write(metadata, to: manifest)
        try write(#"{"name":"fixture-dep","version":"1.0.0","main":"index.js"}"#, to: dependency.appendingPathComponent("package.json"))
        try write("module.exports = 'RECOVERED';", to: dependency.appendingPathComponent("index.js"))
        try write("console.log(require('fixture-dep'));", to: projectDirectory.appendingPathComponent("app.cjs"))
        let candidates = ProjectFiles.scan([manifest]) { false }.candidates
        try expect(candidates.count == 1 && model.add(candidates), "Could not import dependency recovery project")
        guard var project = model.projects.first(where: { $0.name == "recovery" }) else {
            throw CheckFailure(message: "Dependency recovery project missing")
        }
        try expect(ProjectFiles.needsInstall(at: project.path, log: "sh: fixture-dep: command not found") &&
                   !ProjectFiles.needsInstall(at: project.path, log: "sh: npm: command not found"),
                   "Install detection did not distinguish a missing project binary from a missing npm binary")
        model.start(project)
        try await until("missing npm dependency") { model.runState(project.id).phase == .failed }
        try expect(model.runState(project.id).installCommand == "npm install", "Missing npm dependency had no install action")
        model.installAndRestart(project.id)
        model.installAndRestart(project.id)
        try await until("npm install and restart", seconds: 25, describe: { "\(model.runState(project.id))" }) {
            model.runState(project.id).phase == .finished
        }
        let log = model.runState(project.id).log
        try expect(log.contains("安装完成") && log.contains("RECOVERED") &&
                   log.components(separatedBy: "$ npm install").count == 2,
                   "Install did not run once and retry the saved start command")

        let fakeNVM = root.appendingPathComponent("fake-nvm.sh")
        try write("""
        nvm_find_nvmrc() { return 1; }
        nvm() {
          case "$1" in
            use) [[ -e .node-installed ]] || return 3 ;;
            install)
              [[ "$2" == v99.0.0 ]] || return 8
              if [[ -e .slow-install ]]; then
                echo INSTALL_STARTED
                sleep 15
              fi
              touch .node-installed ;;
          esac
        }
        """, to: fakeNVM)
        project.nodeVersion = "v99.0.0"
        try expect(model.update(project), "Could not save nvm installation fixture")
        model.setNVMScript(fakeNVM.path)
        model.start(project)
        try await until("nvm install action") { model.runState(project.id).phase == .failed }
        try expect(model.runState(project.id).install?.operation == .installNode, "No Node install action")
        let slowInstall = projectDirectory.appendingPathComponent(".slow-install")
        try write("", to: slowInstall)
        model.installAndRestart(project.id)
        try await until("installer starts") { model.runState(project.id).log.contains("INSTALL_STARTED") }
        model.stop(project.id)
        try await until("installer stops") { model.runState(project.id).phase == .stopped }
        try expect(!model.runState(project.id).log.contains("安装完成"), "Cancelled installation restarted the project")
        try FileManager.default.removeItem(at: slowInstall)
        model.start(project)
        try await until("nvm install action after cancellation") { model.runState(project.id).phase == .failed }
        model.installAndRestart(project.id)
        try await until("nvm installation and restart") { model.runState(project.id).phase == .finished }
        try expect(model.runState(project.id).log.contains("RECOVERED"), "Project was not run after Node installation")

        model.setNVMScript(root.appendingPathComponent("disconnected/nvm.sh").path)
        let missingDirectory = projectDirectory.appendingPathComponent("node_modules")
        try FileManager.default.removeItem(at: missingDirectory)
        try write(#"{"name":"recovery","scripts":{"start":"node app.cjs","preinstall":"exit 9"},"dependencies":{"fixture-dep":"file:../fixture-dep"}}"#,
                  to: manifest)
        model.start(project)
        try await until("failed-install fixture initial launch") { model.runState(project.id).installCommand == "npm install" }
        model.installAndRestart(project.id)
        try await until("npm install failure", seconds: 25) { model.runState(project.id).phase == .failed }
        let failed = model.runState(project.id)
        try expect(failed.message?.contains("安装失败") == true && failed.installCommand == "npm install" &&
                   !failed.log.contains("安装完成") && !failed.log.contains("RECOVERED"), "Failed install restarted the project")
    }

    @MainActor
    private static func verifyIDECommands(from root: URL) async throws {
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let toolbox = apps.appendingPathComponent("JetBrains Toolbox", isDirectory: true)
        let project = root.appendingPathComponent("IDE 项目 'with spaces'", isDirectory: true)
        try FileManager.default.createDirectory(at: toolbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        func makeApp(
            in parent: URL, filename: String, bundleID: String, displayName: String? = nil,
            vscodeFork: Bool = false
        ) throws -> URL {
            let app = parent.appendingPathComponent(filename, isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
            if let displayName { plist["CFBundleName"] = displayName }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            if vscodeFork {
                let appResources = contents.appendingPathComponent("Resources/app", isDirectory: true)
                let bin = appResources.appendingPathComponent("bin", isDirectory: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try write("{}", to: appResources.appendingPathComponent("product.json"))
                let cli = bin.appendingPathComponent("future")
                try write("#!/bin/sh\nexit 0\n", to: cli)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
            }
            return app
        }

        let vscode = try makeApp(in: apps, filename: "Visual Studio Code.app", bundleID: "com.microsoft.VSCode", displayName: "Code")
        _ = try makeApp(in: apps, filename: "Antigravity.app", bundleID: "com.google.antigravity", displayName: "Antigravity")
        _ = try makeApp(in: toolbox, filename: "PyCharm.app", bundleID: "com.jetbrains.pycharm", displayName: "PyCharm")
        _ = try makeApp(in: apps, filename: "Xcode-27.2.0.app", bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        _ = try makeApp(in: apps, filename: "Xcode-16.4.app", bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        _ = try makeApp(in: apps, filename: "FutureCode.app", bundleID: "com.example.futurecode", displayName: "Code", vscodeFork: true)
        _ = try makeApp(in: apps, filename: "wechatwebdevtools.app", bundleID: "com.github.Electron", displayName: "wechatwebdevtools")
        // Non-IDE apps must be excluded.
        _ = try makeApp(in: apps, filename: "Docker.app", bundleID: "com.docker.docker", displayName: "Docker")
        _ = try makeApp(in: apps, filename: "Google Chrome.app", bundleID: "com.google.Chrome", displayName: "Google Chrome")
        _ = try makeApp(in: toolbox, filename: "JetBrains Toolbox.app", bundleID: "com.jetbrains.toolbox", displayName: "JetBrains Toolbox")
        _ = try makeApp(in: apps, filename: "Dev Launcher.app", bundleID: "local.devlauncher.mac", displayName: "Dev Launcher")

        let discovered = ProjectIDE.discover(searchDirectories: [apps], includeWorkspaceLookup: false)
        let names = discovered.map(\.name)
        let expected = [
            "Antigravity", "FutureCode", "PyCharm", "Visual Studio Code", "Xcode-16.4", "Xcode-27.2.0", "微信开发者工具",
        ].sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        try expect(names == expected, "Discovered IDEs differed: \(names)")

        guard let discoveredVSCode = discovered.first(where: { $0.name == "Visual Studio Code" }) else {
            throw CheckFailure(message: "Visual Studio Code was not discovered")
        }
        var opened: (URL, URL)?
        try await discoveredVSCode.open(at: project.path) { directory, application in
            opened = (directory, application)
        }
        try expect(opened?.0.path == project.path && opened?.1.path == ProjectFiles.canonicalPath(vscode),
                   "IDE launch did not pass exact directory and application bundle URLs")

        do {
            try await discoveredVSCode.open(at: root.appendingPathComponent("missing-dir").path) { _, _ in }
            throw CheckFailure(message: "Opening a missing directory succeeded unexpectedly")
        } catch {
            try expect(error.localizedDescription.contains("项目目录不可用"),
                       "Missing directory error did not explain the issue")
        }

        try FileManager.default.removeItem(at: vscode)
        do {
            try await discoveredVSCode.open(at: project.path) { _, _ in }
            throw CheckFailure(message: "Opening with a removed app succeeded unexpectedly")
        } catch {
            try expect(error.localizedDescription.contains("Visual Studio Code"),
                       "Missing app error did not identify the IDE")
        }

        let localIDEs = ProjectIDE.discover()
        print("IDE auto-discovery checks passed. Local installed IDEs: \(localIDEs.map(\.name).joined(separator: ", "))")
    }

    static func verifyTerminalAndAICLI(from root: URL) throws {
        let directory = root.appendingPathComponent("项目 with 'quote' and $(pwd)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonicalDirectory = ProjectFiles.canonicalPath(directory)

        let directCommand = try ProjectTerminal.directoryCommand(at: canonicalDirectory)
        let directShell = Process()
        directShell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        directShell.arguments = ["-fc", directCommand + " && printf '%s' \"$PWD\""]
        let directOutput = Pipe()
        directShell.standardOutput = directOutput
        try directShell.run()
        let directResult = directOutput.fileHandleForReading.readDataToEndOfFile()
        directShell.waitUntilExit()
        try expect(directShell.terminationStatus == 0 && String(decoding: directResult, as: UTF8.self) == canonicalDirectory,
                   "Direct terminal command did not enter the exact project directory")

        let binDir = root.appendingPathComponent("ai-cli-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        for name in ["codex", "claude", "agy", "unknown-tool"] {
            let binary = binDir.appendingPathComponent(name)
            try write("#!/bin/sh\nexit 0\n", to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        // Non-executable file and directory with known names must be ignored.
        try write("#!/bin/sh\n", to: binDir.appendingPathComponent("gemini"))
        try FileManager.default.createDirectory(at: binDir.appendingPathComponent("kimi"), withIntermediateDirectories: true)

        let discovered = ProjectAICLI.discover(searchDirectories: [binDir])
        try expect(discovered.map(\.command) == ["agy", "claude", "codex"],
                   "AI CLI discovery differed: \(discovered.map(\.command))")

        guard let codex = discovered.first(where: { $0.command == "codex" }) else {
            throw CheckFailure(message: "Codex CLI was not discovered")
        }
        let cliCommand = try ProjectTerminal.launchCommand(for: codex, at: canonicalDirectory)
        let cliShell = Process()
        cliShell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        cliShell.arguments = ["-fc", "codex() { printf '%s' \"$PWD\"; }; " + cliCommand]
        let cliOutput = Pipe()
        cliShell.standardOutput = cliOutput
        try cliShell.run()
        let cliResult = cliOutput.fileHandleForReading.readDataToEndOfFile()
        cliShell.waitUntilExit()
        try expect(cliShell.terminationStatus == 0 && String(decoding: cliResult, as: UTF8.self) == canonicalDirectory,
                   "AI CLI command did not enter the exact project directory")

        let localCLIs = ProjectAICLI.discover()
        print("Terminal & AI CLI checks passed. Local installed AI CLIs: \(localCLIs.map(\.name).joined(separator: ", "))")
    }

    static func verifyGitSupport(from root: URL) throws {
        let nonRepo = root.appendingPathComponent("not-a-git-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        try expect(ProjectGit.inspect(at: nonRepo.path) == nil, "Non-git directory reported a git status")

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        let repo = root.appendingPathComponent("git-fixture", isDirectory: true)
        let peer = root.appendingPathComponent("git-peer", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        func git(_ args: [String], in dir: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = dir
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "git \(args.joined(separator: " ")) failed in \(dir.lastPathComponent)")
        }

        try git(["init", "--bare"], in: remote)
        try git(["init", "-b", "main"], in: repo)
        try git(["config", "user.name", "DevLauncher Test"], in: repo)
        try git(["config", "user.email", "test@devlauncher.local"], in: repo)
        try write("hello\n", to: repo.appendingPathComponent("README.md"))
        try git(["add", "README.md"], in: repo)
        try git(["commit", "-m", "Initial commit"], in: repo)
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-u", "origin", "main"], in: repo)

        guard let clean = ProjectGit.inspect(at: repo.path) else {
            throw CheckFailure(message: "Failed to inspect git repository")
        }
        try expect(clean.branch == "main" && !clean.isDirty && clean.ahead == 0 && clean.behind == 0,
                   "Unexpected initial git status: \(clean)")
        try expect(clean.recentCommits.first?.subject == "Initial commit", "Recent commit log missing")

        try write("untracked\n", to: repo.appendingPathComponent("draft.txt"))
        guard let dirty = ProjectGit.inspect(at: repo.path) else {
            throw CheckFailure(message: "Failed to inspect dirty repository")
        }
        try expect(dirty.isDirty && dirty.untrackedCount == 1, "Dirty working tree was not detected")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("draft.txt"))

        try ProjectGit.createBranch("feat/l1-git", at: repo.path)
        guard let created = ProjectGit.inspect(at: repo.path) else {
            throw CheckFailure(message: "Failed to inspect created branch")
        }
        try expect(created.branch == "feat/l1-git" && created.branches.contains("main") && created.branches.contains("feat/l1-git"),
                   "Branch creation did not switch to feat/l1-git")
        try ProjectGit.push(at: repo.path, currentStatus: created)

        try ProjectGit.switchBranch("main", at: repo.path)
        try expect(ProjectGit.inspect(at: repo.path)?.branch == "main", "Branch switch back to main failed")

        try git(["clone", remote.path, peer.path], in: root)
        try git(["config", "user.name", "Peer"], in: peer)
        try git(["config", "user.email", "peer@devlauncher.local"], in: peer)
        try write("remote update\n", to: peer.appendingPathComponent("remote.txt"))
        try git(["add", "remote.txt"], in: peer)
        try git(["commit", "-m", "Remote update"], in: peer)
        try git(["push", "origin", "main"], in: peer)

        try ProjectGit.fetch(at: repo.path)
        try expect(ProjectGit.inspect(at: repo.path)?.behind == 1, "Fetch did not detect 1 behind commit")
        try ProjectGit.pull(at: repo.path)
        let pulled = ProjectGit.inspect(at: repo.path)
        try expect(pulled?.behind == 0 && pulled?.recentCommits.first?.subject == "Remote update",
                   "Pull did not bring in remote commit")
        print("Git L1 support checks passed")
    }

    static func verifyLaunchPortCommandAdaptation(at root: URL) throws {
        let viteDir = root.appendingPathComponent("vite-port-fixture")
        try FileManager.default.createDirectory(at: viteDir, withIntermediateDirectories: true)
        try write(#"""
        {
          "name": "vite-port-fixture",
          "scripts": {
            "dev": "vite --host 127.0.0.1",
            "preview": "vite preview",
            "build": "vite build",
            "fixed": "vite --port 3000",
            "envport": "vite --port $PORT",
            "start": "astro dev"
          }
        }
        """#, to: viteDir.appendingPathComponent("package.json"))

        func nodeProject(command: String, port: UInt16?) -> Project {
            var project = Project(candidate: ProjectCandidate(
                path: viteDir.path, name: "vite-port-fixture", kind: .node,
                nodeRequirement: nil, suggestedCommand: command
            ))
            project.launchPort = port
            return project
        }

        func pythonProject(command: String, port: UInt16?) -> Project {
            var project = Project(candidate: ProjectCandidate(
                path: viteDir.path, name: "py-port-fixture", kind: .python,
                nodeRequirement: nil, suggestedCommand: command
            ))
            project.launchPort = port
            return project
        }

        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run dev", port: nil)) == "npm run dev",
                   "Command without launchPort should remain unchanged")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run dev", port: 5175))
                   == "npm run dev -- --port 5175 --strictPort",
                   "npm run dev for Vite did not append --port and --strictPort")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run dev -- --open", port: 5175))
                   == "npm run dev -- --open --port 5175 --strictPort",
                   "npm run dev with existing separator duplicated --")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run preview", port: 4173))
                   == "npm run preview -- --port 4173 --strictPort",
                   "npm run preview for Vite did not append --port and --strictPort")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run build", port: 5175)) == "npm run build",
                   "vite build should not receive a port flag")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run fixed", port: 5175)) == "npm run fixed",
                   "Script with explicit --port should not receive a duplicate --port")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run envport", port: 5175)) == "npm run envport",
                   "Script referencing $PORT should not receive a duplicate --port")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm start", port: 4321))
                   == "npm start -- --port 4321",
                   "npm start for Astro did not append --port")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "pnpm dev", port: 8848))
                   == "pnpm dev --port 8848 --strictPort",
                   "pnpm dev for Vite did not append --port without --")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "yarn dev", port: 8848))
                   == "yarn dev --port 8848 --strictPort",
                   "yarn dev for Vite did not append --port without --")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npx vite --host", port: 8848))
                   == "npx vite --host --port 8848 --strictPort",
                   "npx vite did not append --port and --strictPort")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run dev -- --port 9000", port: 8848))
                   == "npm run dev -- --port 9000",
                   "Command with explicit --port should remain unchanged")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "npm run dev -- --port $PORT", port: 8848))
                   == "npm run dev -- --port $PORT",
                   "Command referencing $PORT should remain unchanged")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "echo hi && vite", port: 8848))
                   == "echo hi && vite",
                   "Compound shell command should remain unchanged")
        try expect(ProjectFiles.launchCommand(for: nodeProject(command: "vite # comment", port: 8848))
                   == "vite # comment",
                   "Command with shell comment should remain unchanged")

        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "python3 manage.py runserver", port: 8008))
                   == "python3 manage.py runserver 8008",
                   "Django runserver did not append port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "python3 manage.py runserver --noreload", port: 8008))
                   == "python3 manage.py runserver --noreload 8008",
                   "Django runserver with flags did not append port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "python3 manage.py runserver 0.0.0.0:9000", port: 8008))
                   == "python3 manage.py runserver 0.0.0.0:9000",
                   "Django runserver with explicit addrport should remain unchanged")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "python3 -m uvicorn main:app --reload", port: 8008))
                   == "python3 -m uvicorn main:app --reload --port 8008",
                   "uvicorn did not append --port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "uv run fastapi dev main.py", port: 8008))
                   == "uv run fastapi dev main.py --port 8008",
                   "uv run fastapi dev did not append --port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "flask run", port: 8008))
                   == "flask run --port 8008",
                   "flask run did not append --port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "streamlit run app.py", port: 8502))
                   == "streamlit run app.py --server.port 8502",
                   "streamlit run did not append --server.port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "python3 -m http.server --directory public", port: 8008))
                   == "python3 -m http.server --directory public 8008",
                   "http.server did not append port")
        try expect(ProjectFiles.launchCommand(for: pythonProject(command: "python3 main.py", port: 8008))
                   == "python3 main.py",
                   "Arbitrary python script should remain unchanged")
        print("Launch port command adaptation checks passed")
    }

    @MainActor
    static func until(_ name: String, seconds: Double = 8, describe: () -> String = { "" },
                      _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { throw CheckFailure(message: "Timed out: \(name). \(describe())") }
            try await Task.sleep(for: .milliseconds(45))
        }
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    static func readPID(_ url: URL) throws -> pid_t {
        guard let pid = try pid_t(String(contentsOf: url, encoding: .utf8)) else {
            throw CheckFailure(message: "Invalid PID file")
        }
        return pid
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return count > 0 && info.pbi_status != 5 // SZOMB
    }

    static func canBind(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor != -1 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func openLoopbackListener() throws -> (descriptor: Int32, port: UInt16)? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            if errno == EPERM || errno == EACCES { return nil }
            throw SpawnFailure.system(errno)
        }
        var listening = false
        defer { if !listening { close(descriptor) } }
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw SpawnFailure.system(errno) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(descriptor, pointer, size) == 0, listen(descriptor, 1) == 0 else { return errno }
                return getsockname(descriptor, pointer, &size) == 0 ? 0 : errno
            }
        }
        if result == EPERM || result == EACCES { return nil }
        guard result == 0 else { throw SpawnFailure.system(result) }
        listening = true
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }
}
