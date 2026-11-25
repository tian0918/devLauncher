import Darwin
import Foundation

struct GitCommit: Identifiable, Equatable, Sendable {
    let hash: String
    let subject: String
    let author: String
    let relativeDate: String

    var id: String { hash }
}

struct GitRepositoryStatus: Equatable, Sendable {
    let branch: String
    let isDetached: Bool
    let isUnborn: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let conflictedCount: Int
    let branches: [String]
    let recentCommits: [GitCommit]

    var changedCount: Int {
        stagedCount + unstagedCount + untrackedCount + conflictedCount
    }

    var isDirty: Bool { changedCount > 0 }

    var changeSummary: String {
        var parts: [String] = []
        if conflictedCount > 0 { parts.append("\(conflictedCount) 冲突") }
        if stagedCount > 0 { parts.append("\(stagedCount) 已暂存") }
        if unstagedCount > 0 { parts.append("\(unstagedCount) 未暂存") }
        if untrackedCount > 0 { parts.append("\(untrackedCount) 未跟踪") }
        return parts.isEmpty ? "无未提交变更" : "未提交变更：" + parts.joined(separator: " · ")
    }

    var overviewSummary: String {
        var parts: [String] = ["分支 \(branch)"]
        if conflictedCount > 0 {
            parts.append("\(conflictedCount) 处冲突")
        } else if isDirty {
            parts.append("\(changedCount) 项未提交")
        }
        if behind > 0 { parts.append("待拉取 \(behind)") }
        if ahead > 0 { parts.append("待推送 \(ahead)") }
        if parts.count == 1 {
            parts.append(upstream != nil ? "已同步" : "无未提交")
        }
        return parts.joined(separator: " · ")
    }
}

enum ProjectGit {
    enum DetailLevel: Sendable {
        case summary
        case full
    }

    static let resolvedGitExecutable: String = {
        let fileManager = FileManager.default
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()

    private static let ioQueue = DispatchQueue(
        label: "devlauncher.git",
        qos: .utility,
        attributes: .concurrent
    )

    static func inspectAsync(
        at directory: String,
        detail: DetailLevel = .full,
        existing: GitRepositoryStatus? = nil,
        commitLimit: Int = 15
    ) async -> GitRepositoryStatus? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: inspect(
                    at: directory,
                    detail: detail,
                    existing: existing,
                    commitLimit: commitLimit
                ))
            }
        }
    }

    static func performAsync(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async(qos: .userInitiated) {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func inspect(
        at directory: String,
        detail: DetailLevel = .full,
        existing: GitRepositoryStatus? = nil,
        commitLimit: Int = 15
    ) -> GitRepositoryStatus? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        guard let statusResult = try? run(
            arguments: ["--no-optional-locks", "-c", "core.quotepath=false", "status", "--porcelain=v2", "--branch"],
            at: directory,
            timeout: 8
        ), statusResult.exitCode == 0 else {
            return nil
        }

        let parsed = parsePorcelainV2(statusResult.stdout)

        if detail == .summary {
            let reusable = existing?.branch == parsed.branch ? existing : nil
            let fallbackBranches = parsed.isDetached || parsed.isUnborn ? [] : [parsed.branch]
            return GitRepositoryStatus(
                branch: parsed.branch,
                isDetached: parsed.isDetached,
                isUnborn: parsed.isUnborn,
                upstream: parsed.upstream,
                ahead: parsed.ahead,
                behind: parsed.behind,
                stagedCount: parsed.stagedCount,
                unstagedCount: parsed.unstagedCount,
                untrackedCount: parsed.untrackedCount,
                conflictedCount: parsed.conflictedCount,
                branches: reusable?.branches ?? fallbackBranches,
                recentCommits: reusable?.recentCommits ?? []
            )
        }

        let branchesResult = try? run(
            arguments: ["--no-optional-locks", "for-each-ref", "--format=%(refname:short)", "refs/heads"],
            at: directory,
            timeout: 6
        )
        let branches: [String]
        if let output = branchesResult?.stdout, branchesResult?.exitCode == 0 {
            let names = output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            branches = names.sorted { lhs, rhs in
                if lhs == parsed.branch { return true }
                if rhs == parsed.branch { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        } else {
            branches = parsed.isDetached || parsed.isUnborn ? [] : [parsed.branch]
        }

        let recentCommits: [GitCommit]
        if !parsed.isUnborn,
           let logResult = try? run(
               arguments: [
                   "--no-optional-locks", "log", "-n", String(max(1, commitLimit)),
                   "--format=%h%x1f%s%x1f%an%x1f%ct%x1f%cr",
               ],
               at: directory,
               timeout: 6
           ),
           logResult.exitCode == 0 {
            recentCommits = parseCommits(logResult.stdout)
        } else {
            recentCommits = []
        }

        return GitRepositoryStatus(
            branch: parsed.branch,
            isDetached: parsed.isDetached,
            isUnborn: parsed.isUnborn,
            upstream: parsed.upstream,
            ahead: parsed.ahead,
            behind: parsed.behind,
            stagedCount: parsed.stagedCount,
            unstagedCount: parsed.unstagedCount,
            untrackedCount: parsed.untrackedCount,
            conflictedCount: parsed.conflictedCount,
            branches: branches,
            recentCommits: recentCommits
        )
    }

    static func switchBranch(_ branch: String, at directory: String) throws {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            throw GitError.invalidBranchName(branch)
        }
        let result = try run(arguments: ["switch", trimmed], at: directory, timeout: 15)
        try ensureSuccess(result, action: "切换分支「\(trimmed)」")
    }

    static func createBranch(_ name: String, at directory: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBranchName(trimmed) else {
            throw GitError.invalidBranchName(name)
        }
        let check = try run(arguments: ["check-ref-format", "--branch", trimmed], at: directory, timeout: 6)
        guard check.exitCode == 0 else {
            throw GitError.invalidBranchName(trimmed)
        }
        let result = try run(arguments: ["switch", "-c", trimmed], at: directory, timeout: 15)
        try ensureSuccess(result, action: "创建分支「\(trimmed)」")
    }

    static func fetch(at directory: String) throws {
        let result = try run(arguments: ["fetch", "--prune"], at: directory, timeout: 35)
        try ensureSuccess(result, action: "拉取远程引用")
    }

    static func pull(at directory: String) throws {
        let result = try run(arguments: ["pull", "--no-edit"], at: directory, timeout: 45)
        try ensureSuccess(result, action: "拉取代码")
    }

    static func push(at directory: String, currentStatus: GitRepositoryStatus? = nil) throws {
        var arguments = ["push"]
        if let status = currentStatus, status.upstream == nil, !status.isDetached, !status.branch.isEmpty {
            if let remote = preferredRemote(at: directory) {
                arguments = ["push", "-u", remote, status.branch]
            }
        }
        let result = try run(arguments: arguments, at: directory, timeout: 45)
        try ensureSuccess(result, action: "推送代码")
    }

    static func isValidBranchName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains(".."),
              !name.contains("@{"), !name.contains("//"), !name.contains("/."), name != "@" else {
            return false
        }
        let forbidden: Set<Character> = [" ", "\t", "\n", "\r", "~", "^", ":", "?", "*", "[", "\\"]
        if name.contains(where: { forbidden.contains($0) }) { return false }
        return !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    // MARK: - Parsing

    private struct ParsedStatus {
        var branch = "HEAD"
        var isDetached = false
        var isUnborn = false
        var upstream: String?
        var ahead = 0
        var behind = 0
        var stagedCount = 0
        var unstagedCount = 0
        var untrackedCount = 0
        var conflictedCount = 0
    }

    private static func parsePorcelainV2(_ output: String) -> ParsedStatus {
        var parsed = ParsedStatus()
        var shortOID: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.oid ") {
                let value = String(line.dropFirst("# branch.oid ".count))
                if value == "(initial)" {
                    parsed.isUnborn = true
                } else {
                    shortOID = String(value.prefix(7))
                }
            } else if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                if value == "(detached)" {
                    parsed.isDetached = true
                } else {
                    parsed.branch = value
                }
            } else if line.hasPrefix("# branch.upstream ") {
                parsed.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+"), let value = Int(part.dropFirst()) {
                        parsed.ahead = value
                    } else if part.hasPrefix("-"), let value = Int(part.dropFirst()) {
                        parsed.behind = value
                    }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let fields = line.split(separator: " ", maxSplits: 2)
                if fields.count >= 2 {
                    let xy = Array(fields[1])
                    if xy.count == 2 {
                        if xy[0] != "." { parsed.stagedCount += 1 }
                        if xy[1] != "." { parsed.unstagedCount += 1 }
                    }
                }
            } else if line.hasPrefix("u ") {
                parsed.conflictedCount += 1
            } else if line.hasPrefix("? ") {
                parsed.untrackedCount += 1
            }
        }

        if parsed.isDetached {
            parsed.branch = shortOID.map { "HEAD@\($0)" } ?? "HEAD"
        }
        return parsed
    }

    private static func parseCommits(_ output: String) -> [GitCommit] {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.unitsStyle = .full
        let now = Date()

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> GitCommit? in
                let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
                guard fields.count == 5 || fields.count == 4 else { return nil }
                let relativeDate: String
                if fields.count == 5, let timestamp = TimeInterval(fields[3]) {
                    let commitDate = Date(timeIntervalSince1970: timestamp)
                    if abs(now.timeIntervalSince(commitDate)) < 5 {
                        relativeDate = "刚刚"
                    } else {
                        relativeDate = formatter.localizedString(for: commitDate, relativeTo: now)
                    }
                } else {
                    relativeDate = String(fields.last ?? "")
                }
                return GitCommit(
                    hash: String(fields[0]),
                    subject: String(fields[1]),
                    author: String(fields[2]),
                    relativeDate: relativeDate
                )
            }
    }

    private static func preferredRemote(at directory: String) -> String? {
        guard let result = try? run(arguments: ["--no-optional-locks", "remote"], at: directory, timeout: 6),
              result.exitCode == 0 else { return nil }
        let remotes = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if remotes.contains("origin") { return "origin" }
        return remotes.count == 1 ? remotes.first : nil
    }

    // MARK: - Execution

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(arguments: [String], at directory: String, timeout: TimeInterval) throws -> CommandResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.unavailableDirectory
        }
        guard FileManager.default.isExecutableFile(atPath: resolvedGitExecutable) else {
            throw GitError.gitNotInstalled
        }

        let (stdoutRead, stdoutWrite) = try makePipe()
        var closeStdoutRead = true
        defer { if closeStdoutRead { close(stdoutRead) } }

        let (stderrRead, stderrWrite) = try makePipe()
        var closeStderrRead = true
        defer { if closeStderrRead { close(stderrRead) } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedGitExecutable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)

        var environment = ManagedProcess.environment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["GCM_INTERACTIVE"] = "never"
        // Keep English diagnostics for error classification without breaking UTF-8 in Git hooks.
        environment.removeValue(forKey: "LC_ALL")
        environment["LC_MESSAGES"] = "C"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        process.environment = environment

        let stdoutWriteHandle = FileHandle(fileDescriptor: stdoutWrite, closeOnDealloc: false)
        let stderrWriteHandle = FileHandle(fileDescriptor: stderrWrite, closeOnDealloc: false)
        process.standardOutput = stdoutWriteHandle
        process.standardError = stderrWriteHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            close(stdoutWrite)
            close(stderrWrite)
            throw error
        }
        close(stdoutWrite)
        close(stderrWrite)

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutOpen = true
        var stderrOpen = true
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false

        func drain(_ fd: Int32, into target: inout Data) -> Bool {
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    target.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    return false
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return true
                } else if errno != EINTR {
                    return false
                }
            }
        }

        while stdoutOpen || stderrOpen {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                break
            }
            var fds: [pollfd] = []
            if stdoutOpen { fds.append(pollfd(fd: stdoutRead, events: Int16(POLLIN), revents: 0)) }
            if stderrOpen { fds.append(pollfd(fd: stderrRead, events: Int16(POLLIN), revents: 0)) }
            let waitMs = Int32(min(max(1, Int(ceil(remaining * 1000))), 250))
            let ready = poll(&fds, nfds_t(fds.count), waitMs)
            if ready < 0 && errno != EINTR { break }
            if stdoutOpen { stdoutOpen = drain(stdoutRead, into: &stdoutData) }
            if stderrOpen { stderrOpen = drain(stderrRead, into: &stderrData) }
        }

        if !timedOut && process.isRunning {
            let remaining = deadline.timeIntervalSinceNow
            let end = Date().addingTimeInterval(max(0, remaining))
            while process.isRunning && Date() < end {
                usleep(10_000)
            }
            if process.isRunning {
                timedOut = true
            }
        }

        if timedOut {
            process.terminate()
            let killEnd = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killEnd {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw GitError.timedOut
        }

        process.waitUntilExit()
        close(stdoutRead)
        closeStdoutRead = false
        close(stderrRead)
        closeStderrRead = false

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func makePipe() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else { throw SpawnFailure.system(errno) }
        if fcntl(fds[0], F_SETFL, O_NONBLOCK) != 0
            || fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0
            || fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0 {
            let err = errno
            close(fds[0])
            close(fds[1])
            throw SpawnFailure.system(err)
        }
        return (fds[0], fds[1])
    }

    private static func ensureSuccess(_ result: CommandResult, action: String) throws {
        guard result.exitCode == 0 else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if detail.localizedCaseInsensitiveContains("permission denied")
                || detail.localizedCaseInsensitiveContains("authentication failed")
                || detail.localizedCaseInsensitiveContains("could not read username")
                || detail.localizedCaseInsensitiveContains("host key verification failed") {
                throw GitError.authenticationRequired(action, detail)
            }
            throw GitError.commandFailed(action, detail)
        }
    }
}

private enum GitError: LocalizedError {
    case unavailableDirectory
    case gitNotInstalled
    case invalidBranchName(String)
    case timedOut
    case authenticationRequired(String, String)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unavailableDirectory:
            return "项目目录不可用。请连接磁盘或重新定位项目。"
        case .gitNotInstalled:
            return "未检测到可用的系统 Git。"
        case .invalidBranchName(let name):
            return "无效的分支名称「\(name)」。"
        case .timedOut:
            return "Git 操作超时，请检查网络连接或改在终端中执行。"
        case .authenticationRequired(let action, let detail):
            return "\(action)需要身份认证或 SSH 密钥解锁，建议在终端中执行。\n\(detail)"
        case .commandFailed(let action, let detail):
            return detail.isEmpty ? "\(action)失败。" : "\(action)失败。\n\(detail)"
        }
    }
}
