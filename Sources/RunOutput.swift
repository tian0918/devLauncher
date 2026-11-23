import Foundation

final class RunOutput: @unchecked Sendable {
    struct Update {
        var log: String
        var node: String?
        var error: String?
        var installCommand: String?
    }

    private static let capacity = 1024 * 1024
    private static let terminalControls = try! NSRegularExpression(
        pattern: "\\x1b\\[[0-?]*[ -/]*[@-~]|\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)"
    )
    private let lock = NSLock()
    private let token: String
    private var pending = Data()
    private var bytes = Data()
    private var precedingBytes = 0
    private var startup: Bool
    private var changed = false
    private var node: String?
    private var error: String?
    private var installCommand: String?

    init(token: String, precedingLog: String = "", expectsNodeStartup: Bool = true) {
        self.token = token
        startup = expectsNodeStartup
        retain(Data(precedingLog.utf8))
        precedingBytes = bytes.count
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        changed = true

        guard startup else {
            retain(chunk)
            return
        }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(through: newline)
            let content = String(decoding: line.dropLast(), as: UTF8.self)
            if content.hasPrefix(token + "\t") {
                let fields = content.split(separator: "\t", maxSplits: 2)
                if fields.count == 3 {
                    let value = String(fields[2])
                    switch fields[1] {
                    case "NODE":
                        node = value
                        retain(Data("Node \(value)\n".utf8))
                        startup = false
                    case "ERROR": error = value
                    case "INSTALL": installCommand = value
                    default: break
                    }
                }
            } else {
                retain(Data(line))
            }
            pending.removeFirst(line.count)
            if !startup {
                retain(pending)
                pending.removeAll(keepingCapacity: false)
                break
            }
        }
        if pending.count > 8192 {
            retain(pending)
            pending.removeAll(keepingCapacity: false)
        }
    }

    func snapshot(final: Bool = false) -> Update? {
        lock.lock()
        if final && !pending.isEmpty {
            retain(pending)
            pending.removeAll()
            changed = true
        }
        guard changed else {
            lock.unlock()
            return nil
        }
        changed = false
        let data = Data(bytes)
        let node = node
        let error = error
        let installCommand = installCommand
        lock.unlock()

        return Update(log: Self.decoded(data), node: node, error: error, installCommand: installCommand)
    }

    func commandLog() -> String {
        lock.lock()
        let data = Data(bytes.dropFirst(precedingBytes))
        lock.unlock()
        return Self.decoded(data)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        bytes.removeAll(keepingCapacity: false)
        precedingBytes = 0
        changed = true
    }

    private static func decoded(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        return terminalControls.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: ""
        )
    }

    private func retain(_ chunk: Data) {
        bytes.append(chunk)
        if bytes.count > Self.capacity {
            var cutoff = bytes.count - Self.capacity
            while cutoff < bytes.count && bytes[bytes.startIndex + cutoff] & 0b1100_0000 == 0b1000_0000 {
                cutoff += 1
            }
            bytes.removeFirst(cutoff)
            precedingBytes = max(0, precedingBytes - cutoff)
        }
    }
}

final class ProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(chunk)
        if bytes.count > 32_768 { bytes.removeFirst(bytes.count - 32_768) }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
