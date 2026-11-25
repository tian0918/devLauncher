import Darwin
import Foundation

struct ProcessOutcome: Sendable {
    let exitCode: Int32
    let signal: Int32?
    let stopped: Bool
}

enum SpawnFailure: LocalizedError {
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .system(let code): String(cString: strerror(code))
        }
    }
}

/// Owns the group leader until the whole group has been signalled and its output drained.
final class ManagedProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "devlauncher.process")
    private let fdLock = NSLock()
    private let pid: pid_t
    private let outputFD: Int32
    private let supervised: Bool
    private var keepAliveFD: Int32?
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (ProcessOutcome) -> Void
    private var reader: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var timeoutTimer: DispatchSourceTimer?
    private var shutdownTimer: DispatchSourceTimer?
    private var stopDeadline: DispatchTime?
    private var killDeadline: DispatchTime?
    private var stopRequested = false
    private var finished = false

    static func environment(shellPath: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userFallbacks = [
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".cargo/bin").path,
            home.appendingPathComponent(".pyenv/shims").path,
            home.appendingPathComponent(".mise/shims").path,
            home.appendingPathComponent(".asdf/shims").path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]
        let systemFallbacks = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var ordered: [String] = []
        var seen: Set<String> = []
        func appendUnique(_ entries: [String]) {
            for entry in entries where !entry.isEmpty && seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }

        if let shellPath, !shellPath.isEmpty {
            appendUnique(shellPath.split(separator: ":").map(String.init))
            appendUnique(userFallbacks)
            appendUnique(systemFallbacks)
        } else {
            let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let defaultSystemEntries: Set<String> = [
                "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/System/Cryptexes/App/usr/bin",
            ]
            let isBareSystemPath = inherited.allSatisfy { defaultSystemEntries.contains($0) }
            if isBareSystemPath {
                appendUnique(userFallbacks)
                appendUnique(inherited)
                appendUnique(systemFallbacks)
            } else {
                appendUnique(inherited)
                appendUnique(userFallbacks)
                appendUnique(systemFallbacks)
            }
        }

        environment["PATH"] = ordered.joined(separator: ":")
        return environment
    }

    init(
        shellArguments: [String],
        directory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval? = nil,
        projectLock: URL? = nil,
        launchPort: UInt16? = nil,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ProcessOutcome) -> Void
    ) throws {
        (pid, outputFD, keepAliveFD) = try Self.spawn(
            shellArguments: shellArguments, directory: directory, environment: environment,
            projectLock: projectLock, launchPort: launchPort
        )
        supervised = projectLock != nil
        self.onOutput = onOutput
        self.onExit = onExit

        let reader = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: queue)
        reader.setEventHandler { [weak self] in self?.drainOutput(untilEOF: false) }
        reader.setCancelHandler { [outputFD] in close(outputFD) }
        self.reader = reader

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in self?.checkExit() }
        self.exitSource = exitSource

        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self, !self.finished else { return }
                self.timeoutTimer?.cancel()
                self.timeoutTimer = nil
                self.stopRequested = true
                self.terminateGroup()
            }
            self.timeoutTimer = timer
            timer.resume()
        }

        reader.resume()
        exitSource.resume()
        // Catch processes that exited in the window between posix_spawn and exitSource registration.
        queue.async { [weak self] in self?.checkExit() }
    }

    func stop() {
        queue.async { [self] in
            guard !finished else { return }
            stopRequested = true
            terminateGroup()
        }
    }

    deinit {
        closeKeepAlive()
        let pid = self.pid
        let supervised = self.supervised
        let wasFinished = self.finished
        let reader = self.reader
        let exitSource = self.exitSource
        let timeoutTimer = self.timeoutTimer
        let shutdownTimer = self.shutdownTimer
        queue.async {
            reader?.cancel()
            exitSource?.cancel()
            timeoutTimer?.cancel()
            shutdownTimer?.cancel()
            if !wasFinished {
                if !supervised {
                    kill(-pid, SIGTERM)
                }
                _ = waitpid(pid, nil, WNOHANG)
            }
        }
    }

    private func startShutdownPollingIfNeeded() {
        guard shutdownTimer == nil, !finished else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(60), repeating: .milliseconds(60), leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in self?.checkExit() }
        shutdownTimer = timer
        timer.resume()
    }

    private func terminateGroup() {
        if supervised {
            closeKeepAlive()
            return
        }
        guard stopDeadline == nil else { return }
        kill(-pid, SIGTERM)
        stopDeadline = .now() + .seconds(3)
        startShutdownPollingIfNeeded()
    }

    private func checkExit() {
        guard !finished else { return }

        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == -1 {
            if errno == ECHILD { finish(exitCode: 1, signal: nil) }
            return
        }

        let leaderExited = info.si_pid != 0
        let groupExited = leaderExited && (supervised || !groupHasOtherMembers())
        if groupExited || (leaderExited && killDeadline.map { $0 <= .now() } == true) {
            reapLeader()
            finish(exitCode: info.si_code == CLD_EXITED ? info.si_status : 1,
                   signal: info.si_code == CLD_EXITED ? nil : info.si_status)
            return
        }

        if leaderExited {
            terminateGroup()
            startShutdownPollingIfNeeded()
        }
        guard killDeadline == nil, let deadline = stopDeadline, deadline <= .now() else { return }
        kill(-pid, SIGKILL)
        killDeadline = .now() + .milliseconds(500)
        startShutdownPollingIfNeeded()
    }

    private func groupHasOtherMembers() -> Bool {
        var members = [pid_t](repeating: 0, count: 32)
        let bytes = members.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return false }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        return members.prefix(count).contains { $0 > 0 && $0 != pid }
    }

    private func reapLeader() {
        while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
    }

    private func drainOutput(untilEOF: Bool) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Yield periodically during live streaming so a noisy command cannot starve process control,
        // while draining completely to EOF on process exit so final stack traces are never truncated.
        let maxReads = untilEOF ? Int.max : 32
        var reads = 0
        while reads < maxReads {
            reads += 1
            let count = bytes.withUnsafeMutableBytes { read(outputFD, $0.baseAddress, $0.count) }
            if count > 0 {
                onOutput(Data(bytes.prefix(count)))
            } else if count == 0 {
                reader?.cancel()
                reader = nil
                return
            } else if errno != EINTR {
                return
            }
        }
    }

    private func finish(exitCode: Int32, signal: Int32?) {
        guard !finished else { return }
        finished = true
        closeKeepAlive()
        exitSource?.cancel()
        exitSource = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
        shutdownTimer?.cancel()
        shutdownTimer = nil
        if reader != nil {
            drainOutput(untilEOF: true)
            reader?.cancel()
            reader = nil
        }
        onExit(ProcessOutcome(exitCode: exitCode, signal: signal, stopped: stopRequested))
    }

    private func closeKeepAlive() {
        fdLock.lock()
        let fd = keepAliveFD
        keepAliveFD = nil
        fdLock.unlock()
        if let fd { close(fd) }
    }

    private static func spawn(
        shellArguments: [String], directory: String?, environment: [String: String],
        projectLock: URL?, launchPort: UInt16?
    ) throws -> (pid_t, Int32, Int32?) {
        let executable: String
        let command: [String]
        if let projectLock {
            guard let main = Bundle.main.executableURL else { throw SpawnFailure.system(ENOENT) }
            try FileManager.default.createDirectory(at: projectLock.deletingLastPathComponent(), withIntermediateDirectories: true)
            executable = main.path
            command = ProcessSupervisor.arguments(lock: projectLock, launchPort: launchPort, shellArguments: shellArguments)
        } else {
            executable = "/bin/zsh"
            command = shellArguments
        }
        let (readFD, writeFD) = try makePipe()
        var success = false
        defer {
            close(writeFD)
            if !success { close(readFD) }
        }
        try check(fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 ? 0 : errno)
        let control = try projectLock.map { _ in try makePipe() }
        defer {
            if let (read, write) = control {
                close(read)
                if !success { close(write) }
            }
        }

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGHUP] { sigaddset(&defaults, signal) }
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
            POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        )))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        if let (read, _) = control {
            try check(posix_spawn_file_actions_adddup2(&actions, read, STDIN_FILENO))
            try check(posix_spawn_file_actions_addclose(&actions, read))
        } else {
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try check(posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, writeFD))
        if let directory {
            if #available(macOS 26, *) {
                try check(posix_spawn_file_actions_addchdir(&actions, directory))
            } else {
                try check(posix_spawn_file_actions_addchdir_np(&actions, directory))
            }
        }

        var arguments = ([executable] + command).map { strdup($0) } + [nil]
        var variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }),
              variables.dropLast().allSatisfy({ $0 != nil }) else { throw SpawnFailure.system(ENOMEM) }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, &arguments, &variables))
        success = true
        return (pid, readFD, control?.1)
    }

    private static func makePipe() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        try check(pipe(&descriptors) == 0 ? 0 : errno)
        do {
            for fd in descriptors {
                try check(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 ? 0 : errno)
            }
        } catch {
            descriptors.forEach { close($0) }
            throw error
        }
        return (descriptors[0], descriptors[1])
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw SpawnFailure.system(result) }
    }
}
