import Darwin
import Foundation

/// Runs outside the GUI process so it can stop the project even when the GUI is killed.
enum ProcessSupervisor {
    private static let mode = "--devlauncher-project-supervisor"

    static func arguments(lock: URL, shellArguments: [String]) -> [String] {
        [mode, lock.path] + shellArguments
    }

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.dropFirst().first == mode else { return }
        guard arguments.count >= 4 else { _exit(64) }

        // The GUI's output pipe has no reader after a forced quit.
        signal(SIGPIPE, SIG_IGN)
        let lock = open(arguments[2], O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { fail("无法打开项目运行锁", errno) }
        acquireLock(lock)
        if ownerDisconnected(waiting: 0) { _exit(0) }

        do {
            let project = try ManagedProcess(
                shellArguments: Array(arguments.dropFirst(3)),
                onOutput: { forwardOutput($0) },
                onExit: { result in
                    if let signalNumber = result.signal {
                        signal(signalNumber, SIG_DFL)
                        kill(getpid(), signalNumber)
                    }
                    _exit(result.exitCode)
                }
            )
            let owner = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO,
                                                      queue: DispatchQueue(label: "devlauncher.owner"))
            owner.setEventHandler {
                owner.cancel()
                project.stop()
            }
            owner.resume()
            // The callback exits only after the project group has stopped. Exiting
            // here releases the lock so a reopened App can start the project.
            withExtendedLifetime((project, owner)) {
                DispatchSemaphore(value: 0).wait()
            }
        } catch {
            forwardOutput(Data("无法启动项目。\(error.localizedDescription)\n".utf8))
            _exit(1)
        }
    }

    private static func acquireLock(_ descriptor: Int32) {
        // A newer App instance waits here while the previous project shuts down.
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { fail("无法获取项目运行锁", errno) }
            if ownerDisconnected(waiting: 100) { _exit(0) }
        }
    }

    private static func ownerDisconnected(waiting milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0
    }

    private static func forwardOutput(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = write(STDOUT_FILENO, start.advanced(by: sent), buffer.count - sent)
                if count > 0 {
                    sent += count
                } else if count == 0 || errno != EINTR {
                    return
                }
            }
        }
    }

    private static func fail(_ message: String, _ error: Int32) -> Never {
        forwardOutput(Data("\(message)。\(String(cString: strerror(error)))\n".utf8))
        _exit(1)
    }
}
