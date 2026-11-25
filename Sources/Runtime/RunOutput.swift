import Foundation

struct LogSnapshot: Equatable, Sendable {
    var text = ""
    var generation: UInt64 = 0
    var revision: UInt64 = 0
    var droppedUTF16 = 0

    var isEmpty: Bool { text.isEmpty }
}

final class RunOutput: @unchecked Sendable {
    struct Update {
        var snapshot: LogSnapshot
        var node: String?
        var detectedURL: URL?
        var error: String?
        var installCommand: String?

        var log: String { snapshot.text }
    }

    private static let capacity = 1024 * 1024
    private static let terminalControls = try! NSRegularExpression(
        pattern: "\\x1b\\[[0-?]*[ -/]*[@-~]|\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)"
    )
    private static let localServerURLRegex = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):([0-9]{1,5})(?:/[^\s"'<>)\],;]*)?"#,
        options: [.caseInsensitive]
    )
    private static let generationLock = NSLock()
    private static var generationSeed: UInt64 = 0

    private static func nextGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        generationSeed &+= 1
        return generationSeed
    }

    private let lock = NSLock()
    private let token: String
    private var pending = Data()
    private var carry: [UInt8] = []
    private var cleanBytes = Data()
    private var precedingBytes = 0
    private var droppedUTF16 = 0
    private var generation: UInt64
    private var revision: UInt64 = 0
    private var startup: Bool
    private var changed = false
    private var node: String?
    private var detectedURL: URL?
    private var urlScanTail = ""
    private var error: String?
    private var installCommand: String?

    init(token: String, precedingLog: String = "", expectsNodeStartup: Bool = true) {
        self.token = token
        startup = expectsNodeStartup
        generation = Self.nextGeneration()
        if !precedingLog.isEmpty {
            let cleaned = Self.stripTerminalControlsIfNeeded(precedingLog, checkEscape: precedingLog.utf8.contains(0x1B))
            appendCleanText(cleaned)
            detectedURL = nil
            urlScanTail = ""
            changed = false
        }
        precedingBytes = cleanBytes.count
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        guard startup else {
            processRawBytes(chunk, flushIncomplete: false)
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
                        appendCleanText("Node \(value)\n")
                        startup = false
                        changed = true
                    case "RUNTIME":
                        node = value
                        startup = false
                        changed = true
                    case "ERROR":
                        error = value
                        changed = true
                    case "INSTALL":
                        installCommand = value
                        changed = true
                    default:
                        break
                    }
                }
            } else {
                processRawBytes(Data(line), flushIncomplete: false)
            }
            pending.removeFirst(line.count)
            if !startup {
                if !pending.isEmpty {
                    processRawBytes(pending, flushIncomplete: false)
                    pending.removeAll(keepingCapacity: false)
                }
                break
            }
        }
        if startup && pending.count > 8192 {
            processRawBytes(pending, flushIncomplete: false)
            pending.removeAll(keepingCapacity: false)
        }
    }

    func snapshot(final: Bool = false) -> Update? {
        lock.lock()
        if final {
            if !pending.isEmpty {
                processRawBytes(pending, flushIncomplete: true)
                pending.removeAll(keepingCapacity: false)
            } else if !carry.isEmpty {
                processRawBytes(Data(), flushIncomplete: true)
            }
            if !startup && detectedURL == nil && !urlScanTail.isEmpty {
                if let found = Self.extractLocalServerURL(from: urlScanTail) {
                    detectedURL = found
                    changed = true
                }
                urlScanTail = ""
            }
        } else if !startup && !carry.isEmpty {
            // Flush complete UTF-8 characters when no incomplete ANSI sequence is waiting;
            // if a partial sequence stalled before final, snapshot still exposes already-clean bytes.
            flushReadyCarry()
        }
        guard changed else {
            lock.unlock()
            return nil
        }
        changed = false
        let data = Data(cleanBytes)
        let generation = generation
        let revision = revision
        let droppedUTF16 = droppedUTF16
        let node = node
        let detectedURL = detectedURL
        let error = error
        let installCommand = installCommand
        lock.unlock()

        let logSnapshot = LogSnapshot(
            text: String(decoding: data, as: UTF8.self),
            generation: generation,
            revision: revision,
            droppedUTF16: droppedUTF16
        )
        return Update(
            snapshot: logSnapshot,
            node: node,
            detectedURL: detectedURL,
            error: error,
            installCommand: installCommand
        )
    }

    func commandLog() -> String {
        lock.lock()
        let data = Data(cleanBytes.dropFirst(precedingBytes))
        lock.unlock()
        return String(decoding: data, as: UTF8.self)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cleanBytes.removeAll(keepingCapacity: false)
        carry.removeAll(keepingCapacity: false)
        precedingBytes = 0
        droppedUTF16 = 0
        generation = Self.nextGeneration()
        revision &+= 1
        changed = true
    }

    private func processRawBytes(_ raw: Data, flushIncomplete: Bool) {
        if !raw.isEmpty {
            carry.append(contentsOf: raw)
        }
        guard !carry.isEmpty else { return }

        if flushIncomplete {
            let hasEscape = carry.contains(0x1B)
            let decoded = String(decoding: carry, as: UTF8.self)
            carry.removeAll(keepingCapacity: false)
            appendCleanText(Self.stripTerminalControlsIfNeeded(decoded, checkEscape: hasEscape))
        } else {
            flushReadyCarry()
        }
    }

    private func flushReadyCarry() {
        guard !carry.isEmpty else { return }
        let escapeBoundary = Self.incompleteEscapeStart(in: carry) ?? carry.count
        let readyLimit = Self.validUTF8PrefixLimit(in: carry, limit: escapeBoundary)
        guard readyLimit > 0 else { return }

        let slice = carry[0..<readyLimit]
        let hasEscape = slice.contains(0x1B)
        let decoded = String(decoding: slice, as: UTF8.self)
        carry.removeFirst(readyLimit)
        appendCleanText(Self.stripTerminalControlsIfNeeded(decoded, checkEscape: hasEscape))
    }

    private func appendCleanText(_ text: String) {
        guard !text.isEmpty else { return }
        cleanBytes.append(contentsOf: text.utf8)
        if cleanBytes.count > Self.capacity {
            var cutoff = cleanBytes.count - Self.capacity
            while cutoff < cleanBytes.count && cleanBytes[cleanBytes.startIndex + cutoff] & 0b1100_0000 == 0b1000_0000 {
                cutoff += 1
            }
            let dropped = String(decoding: cleanBytes.prefix(cutoff), as: UTF8.self).utf16.count
            droppedUTF16 += dropped
            cleanBytes.removeFirst(cutoff)
            precedingBytes = max(0, precedingBytes - cutoff)
        }
        if !startup && detectedURL == nil {
            scanForLocalURL(in: text)
        }
        revision &+= 1
        changed = true
    }

    private func scanForLocalURL(in chunk: String) {
        let combined = urlScanTail + chunk
        // Only match tokens already terminated by whitespace or newline so split chunks
        // (e.g. "http://0.0.0.0:51" + "74/dashboard\n") never match a partial port/path.
        guard let boundary = combined.lastIndex(where: { $0.isWhitespace || $0.isNewline }) else {
            urlScanTail = String(combined.suffix(256))
            return
        }
        let completeSegment = String(combined[...boundary])
        if let found = Self.extractLocalServerURL(from: completeSegment) {
            detectedURL = found
            urlScanTail = ""
            return
        }
        let remainder = combined[combined.index(after: boundary)...]
        urlScanTail = String(remainder.suffix(256))
    }

    static func extractLocalServerURL(from text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        for match in localServerURLRegex.matches(in: text, range: range) {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let portRange = Range(match.range(at: 1), in: text),
                  let port = UInt16(text[portRange]), port != 0 else {
                continue
            }
            var raw = String(text[fullRange])
            while let last = raw.last, ".,;:!?)]}".contains(last) {
                raw.removeLast()
            }
            guard var components = URLComponents(string: raw) else { continue }
            let loweredHost = (components.host ?? "").lowercased()
            if loweredHost == "0.0.0.0" || loweredHost == "::" || loweredHost == "[::]" {
                components.host = "localhost"
            }
            components.port = Int(port)
            if let normalized = components.url {
                return normalized
            }
        }
        return nil
    }

    private static func stripTerminalControlsIfNeeded(_ raw: String, checkEscape: Bool) -> String {
        guard checkEscape else { return raw }
        return terminalControls.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: ""
        )
    }

    private static func incompleteEscapeStart(in bytes: [UInt8]) -> Int? {
        let start = max(0, bytes.count - 512)
        var i = start
        while i < bytes.count {
            guard bytes[i] == 0x1B else { i += 1; continue }
            let esc = i
            guard esc + 1 < bytes.count else { return esc }
            switch bytes[esc + 1] {
            case 0x5B: // CSI: ESC [ [0-?]* [ -/]* [@-~]
                i = esc + 2
                while i < bytes.count && (0x30...0x3F).contains(bytes[i]) { i += 1 }
                while i < bytes.count && (0x20...0x2F).contains(bytes[i]) { i += 1 }
                if i == bytes.count { return esc }
                i += 1
            case 0x5D: // OSC: ESC ] ... (BEL | ESC \)
                i = esc + 2
                var closed = false
                while i < bytes.count {
                    if bytes[i] == 0x07 { i += 1; closed = true; break }
                    if bytes[i] == 0x1B {
                        guard i + 1 < bytes.count else { return esc }
                        if bytes[i + 1] == 0x5C { i += 2; closed = true }
                        break
                    }
                    i += 1
                }
                if !closed && i == bytes.count { return esc }
            default:
                i = esc + 2
            }
        }
        return nil
    }

    private static func validUTF8PrefixLimit(in bytes: [UInt8], limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        var lead = limit - 1
        let minLead = max(0, limit - 4)
        while lead > minLead && (bytes[lead] & 0b1100_0000) == 0b1000_0000 {
            lead -= 1
        }
        let byte = bytes[lead]
        if byte < 0x80 { return limit }
        let expectedLength: Int
        if (byte & 0b1110_0000) == 0b1100_0000 && byte >= 0xC2 {
            expectedLength = 2
        } else if (byte & 0b1111_0000) == 0b1110_0000 {
            expectedLength = 3
        } else if (byte & 0b1111_1000) == 0b1111_0000 && byte <= 0xF4 {
            expectedLength = 4
        } else {
            return limit
        }
        return (limit - lead) < expectedLength ? lead : limit
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
