import Foundation

enum ProjectKind: String, Codable, Sendable {
    case node = "Node.js"
    case python = "Python"
}

struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var path: String
    var name: String
    var listAlias: String?
    var nodeRequirement: String?
    var nodeVersion: String?
    var command: String
    private var projectKind: ProjectKind?

    var listName: String { listAlias ?? name }
    var kind: ProjectKind { projectKind ?? .node }

    init(candidate: ProjectCandidate) {
        id = UUID()
        path = candidate.path
        name = candidate.name
        nodeRequirement = candidate.nodeRequirement
        command = candidate.suggestedCommand
        if candidate.kind == .python { projectKind = .python }
    }
}

struct ProjectCandidate: Identifiable, Sendable, Equatable {
    let path: String
    let name: String
    let kind: ProjectKind
    let nodeRequirement: String?
    let suggestedCommand: String

    var id: String { path }
}

struct ScanResult: Sendable {
    var candidates: [ProjectCandidate] = []
    var skipped: [String] = []
}

enum ProjectFiles {
    private struct Manifest: Decodable {
        var name: String?
        var scripts: [String: String]?
        var engines: [String: String]?
        var dependencies: [String: String]?
        var devDependencies: [String: String]?
    }

    private static let ignored: Set<String> = [
        "node_modules", "dist", "build", "out", "coverage", "DerivedData", "venv", "__pycache__", "site-packages"
    ]
    private static let pythonMarkers: Set<String> = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "manage.py"]
    private static let pythonEntrypoints = ["manage.py", "__main__.py", "main.py", "app.py"]

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isImportFile(_ url: URL) -> Bool {
        url.lastPathComponent == "package.json" || pythonMarkers.contains(url.lastPathComponent)
            || url.pathExtension.lowercased() == "py"
    }

    private static func isReadableFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func nodeCandidate(at url: URL) throws -> ProjectCandidate {
        let directory = URL(fileURLWithPath: canonicalPath(url.deletingLastPathComponent()))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedCommand: String
        if manifest.scripts?["dev"] != nil {
            suggestedCommand = "npm run dev"
        } else if manifest.scripts?["start"] != nil {
            suggestedCommand = "npm run start"
        } else {
            suggestedCommand = ""
        }
        return ProjectCandidate(path: directory.path, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? directory.lastPathComponent,
                                kind: .node, nodeRequirement: manifest.engines?["node"], suggestedCommand: suggestedCommand)
    }

    private static func pythonCandidate(in directory: URL, script: String? = nil) -> ProjectCandidate {
        let entrypoint = script ?? pythonEntrypoints.first { isReadableFile(directory.appendingPathComponent($0)) }
        let command: String
        if let entrypoint {
            if entrypoint == "manage.py" {
                command = "python3 manage.py runserver"
            } else if pythonEntrypoints.contains(entrypoint) {
                command = "python3 \(entrypoint)"
            } else {
                let quotedPath = "./" + entrypoint.replacingOccurrences(of: "'", with: "'\\''")
                command = "python3 '\(quotedPath)'"
            }
        } else {
            command = ""
        }
        return ProjectCandidate(path: directory.path, name: directory.lastPathComponent,
                                kind: .python, nodeRequirement: nil, suggestedCommand: command)
    }

    static func candidate(in directory: URL, kind: ProjectKind) -> ProjectCandidate? {
        let directory = URL(fileURLWithPath: canonicalPath(directory), isDirectory: true)
        switch kind {
        case .node:
            return try? nodeCandidate(at: directory.appendingPathComponent("package.json"))
        case .python:
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ), files.contains(where: {
                (pythonMarkers.contains($0.lastPathComponent) || $0.pathExtension.lowercased() == "py") && isReadableFile($0)
            }) else { return nil }
            return pythonCandidate(in: directory)
        }
    }

    static func pythonVirtualEnvironment(at path: String) -> URL? {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        return [".venv", "venv"]
            .map { directory.appendingPathComponent($0, isDirectory: true) }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/python3").path) }
    }

    static func needsInstall(at path: String, log: String) -> Bool {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return false }

        let output = log.lowercased()
        if output.range(of: #"(?m)\b(?:run|execute|try|using|with)\s+[`'"“‘]?npm (?:install|i)\b|package\.json exists, but node_modules missing"#,
                        options: .regularExpression) != nil { return true }

        let dependencies = Set((manifest.dependencies ?? [:]).keys).union((manifest.devDependencies ?? [:]).keys)
        let missingPackages = try! NSRegularExpression(pattern: #"(?i)cannot find (?:module|package) ['"]([^'"]+)['"]"#)
        let whole = NSRange(log.startIndex..., in: log)
        for match in missingPackages.matches(in: log, range: whole) {
            guard let range = Range(match.range(at: 1), in: log) else { continue }
            let specifier = log[range]
            guard !specifier.hasPrefix("."), !specifier.hasPrefix("/") else { continue }
            let components = specifier.split(separator: "/")
            let name = components.prefix(specifier.hasPrefix("@") ? 2 : 1).joined(separator: "/")
            if dependencies.contains(name) { return true }
        }

        guard output.range(of: #"(?m)^(?:sh|zsh|bash):[^\n]*(?:command not found|: not found)\b"#,
                           options: .regularExpression) != nil,
              output.range(of: #"(?m)^.*(?:command not found: npm\b|\bnpm: (?:command )?not found)"#,
                           options: .regularExpression) == nil else { return false }
        return dependencies.contains { package in
            var parent = directory
            while true {
                let manifest = parent.appendingPathComponent("node_modules/\(package)/package.json")
                if FileManager.default.isReadableFile(atPath: manifest.path) { return false }
                if parent.path == "/" || parent.path.isEmpty { return true }
                parent.deleteLastPathComponent()
            }
        }
    }

    static func scan(_ selections: [URL], isCancelled: () -> Bool) -> ScanResult {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var result = ScanResult()
        var candidates: [String: ProjectCandidate] = [:]
        var explicitPaths: Set<String> = []

        func read(_ url: URL, explicit: Bool = false) {
            let directory = URL(fileURLWithPath: canonicalPath(url.deletingLastPathComponent()), isDirectory: true)
            let path = directory.path
            let isNode = url.lastPathComponent == "package.json"
            // Prefer Node in a mixed directory unless a file was selected directly.
            guard !explicitPaths.contains(path), explicit || candidates[path] == nil ||
                    (isNode && candidates[path]?.kind == .python) else { return }
            do {
                guard isReadableFile(url) else {
                    result.skipped.append(url.path)
                    return
                }
                let script = explicit && url.lastPathComponent != "setup.py" && url.pathExtension.lowercased() == "py"
                    ? url.lastPathComponent : nil
                candidates[path] = isNode ? try nodeCandidate(at: url) : pythonCandidate(in: directory, script: script)
                if explicit { explicitPaths.insert(path) }
            } catch {
                result.skipped.append(url.path)
            }
        }

        for selection in selections {
            if isCancelled() { break }
            let url = URL(fileURLWithPath: canonicalPath(selection))
            guard let values = try? url.resourceValues(forKeys: keys) else {
                result.skipped.append(url.path)
                continue
            }
            if values.isDirectory == true {
                for entrypoint in pythonEntrypoints {
                    let file = url.appendingPathComponent(entrypoint)
                    if isReadableFile(file) {
                        read(file)
                        break
                    }
                }
                guard let files = fileManager.enumerator(
                    at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
                    errorHandler: { failedURL, _ in
                        result.skipped.append(failedURL.path)
                        return true
                    }
                ) else {
                    result.skipped.append(url.path)
                    continue
                }
                for case let file as URL in files {
                    if isCancelled() { break }
                    guard let properties = try? file.resourceValues(forKeys: keys) else {
                        if isImportFile(file) { result.skipped.append(file.path) }
                        continue
                    }
                    if properties.isSymbolicLink == true ||
                        (properties.isDirectory == true && ignored.contains(file.lastPathComponent)) {
                        files.skipDescendants()
                        continue
                    }
                    let filename = file.lastPathComponent
                    if properties.isRegularFile == true &&
                        (filename == "package.json" || pythonMarkers.contains(filename)) {
                        read(file)
                    }
                }
            } else if isImportFile(url) {
                read(url, explicit: true)
            } else {
                result.skipped.append(url.path)
            }
        }

        result.skipped = Array(Set(result.skipped)).sorted()
        result.candidates = candidates.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        return result
    }
}

struct SavedState: Codable {
    var projects: [Project] = []
    var nvmScript: String?
}

struct StateFile {
    let url: URL

    static var local: StateFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StateFile(url: support.appendingPathComponent("DevLauncher/projects.json"))
    }

    func load() throws -> SavedState {
        do {
            return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return SavedState()
        }
    }

    func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
