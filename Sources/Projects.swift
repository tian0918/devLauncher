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
    var launchPort: UInt16?
    private var projectKind: ProjectKind?

    var listName: String { listAlias ?? name }
    var kind: ProjectKind { projectKind ?? .node }
    var hasLaunchCommand: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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

    static func launchCommand(for project: Project) -> String {
        let trimmed = project.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = project.launchPort, port != 0, !trimmed.isEmpty else { return project.command }
        guard !referencesPortVariable(trimmed), let tokens = simpleShellTokens(trimmed), !tokens.isEmpty else {
            return project.command
        }
        let portArgs: [String]
        let needsSeparator: Bool
        switch project.kind {
        case .node:
            guard let resolution = nodePortArguments(tokens: tokens, port: port, projectPath: project.path) else {
                return project.command
            }
            portArgs = resolution.arguments
            needsSeparator = resolution.needsSeparator
        case .python:
            guard let args = pythonPortArguments(tokens: tokens, port: port) else {
                return project.command
            }
            portArgs = args
            needsSeparator = false
        }
        guard !portArgs.isEmpty else { return project.command }
        let suffix = (needsSeparator ? ["--"] + portArgs : portArgs).joined(separator: " ")
        return trimmed + " " + suffix
    }

    private static func referencesPortVariable(_ command: String) -> Bool {
        command.range(of: #"\$(?:PORT\b|\{PORT\b)"#, options: .regularExpression) != nil
    }

    private static func simpleShellTokens(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false

        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inSingleQuote {
                if char == "'" {
                    inSingleQuote = false
                } else {
                    current.append(char)
                }
            } else if inDoubleQuote {
                if escaping {
                    current.append(char)
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inDoubleQuote = false
                } else if char == "`" || (char == "$" && next == "(") {
                    return nil
                } else {
                    current.append(char)
                }
            } else if escaping {
                current.append(char)
                escaping = false
            } else {
                switch char {
                case "|", "&", ";", "\n", "\r", "<", ">", "`":
                    return nil
                case "$" where next == "(":
                    return nil
                case "#" where !hasToken:
                    return nil
                case "\\":
                    escaping = true
                    hasToken = true
                case "'":
                    inSingleQuote = true
                    hasToken = true
                case "\"":
                    inDoubleQuote = true
                    hasToken = true
                case _ where char.isWhitespace:
                    if hasToken {
                        tokens.append(current)
                        current = ""
                        hasToken = false
                    }
                default:
                    current.append(char)
                    hasToken = true
                }
            }
            index += 1
        }
        guard !inSingleQuote && !inDoubleQuote && !escaping else { return nil }
        if hasToken { tokens.append(current) }
        return tokens
    }

    private static func stripLeadingEnv(_ tokens: [String]) -> ArraySlice<String> {
        var slice = tokens[...]
        while let first = slice.first {
            let name = URL(fileURLWithPath: first).lastPathComponent
            if isEnvAssignment(first) || name == "cross-env" || name == "env" {
                slice = slice.dropFirst()
            } else {
                break
            }
        }
        return slice
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    private static func hasPortFlag(_ args: [String]) -> Bool {
        args.contains { token in
            token == "--port" || token == "-p" || token.hasPrefix("--port=") || token.hasPrefix("-p=")
                || token.range(of: #"^-p[0-9]+$"#, options: .regularExpression) != nil
        }
    }

    private static func packageScripts(at projectPath: String) -> [String: String]? {
        let url = URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest.scripts
    }

    private static func nodePortArguments(
        tokens: [String], port: UInt16, projectPath: String
    ) -> (arguments: [String], needsSeparator: Bool)? {
        let command = Array(stripLeadingEnv(tokens))
        guard let first = command.first else { return nil }
        let executable = URL(fileURLWithPath: first).lastPathComponent
        let rest = Array(command.dropFirst())

        if ["npm", "pnpm", "yarn", "bun"].contains(executable) {
            let separatorIndex = rest.firstIndex(of: "--")
            let beforeSeparator = separatorIndex.map { Array(rest[..<$0]) } ?? rest
            let scripts = packageScripts(at: projectPath)
            let scriptName: String?
            if let sub = beforeSeparator.first, sub == "run" || sub == "run-script" {
                scriptName = beforeSeparator.dropFirst().first { !$0.hasPrefix("-") }
            } else if executable == "npm", beforeSeparator.first == "start" {
                scriptName = "start"
            } else if (executable == "pnpm" || executable == "yarn"),
                      let candidate = beforeSeparator.first, !candidate.hasPrefix("-"),
                      scripts?[candidate] != nil {
                scriptName = candidate
            } else {
                scriptName = nil
            }
            if let scriptName {
                guard !hasPortFlag(rest),
                      let script = scripts?[scriptName],
                      !referencesPortVariable(script),
                      let scriptTokens = simpleShellTokens(script),
                      let args = directNodePortArguments(tokens: scriptTokens, port: port) else {
                    return nil
                }
                return (args, executable == "npm" && separatorIndex == nil)
            }
        }

        guard let args = directNodePortArguments(tokens: command, port: port) else { return nil }
        return (args, false)
    }

    private static func directNodePortArguments(tokens: [String], port: UInt16) -> [String]? {
        var slice = stripLeadingEnv(tokens)
        if let first = slice.first {
            let runner = URL(fileURLWithPath: first).lastPathComponent
            if ["npx", "pnpx", "bunx"].contains(runner) {
                slice = slice.dropFirst()
                while let flag = slice.first, ["-y", "--yes", "--no-install"].contains(flag) {
                    slice = slice.dropFirst()
                }
            } else if ["pnpm", "yarn"].contains(runner), slice.dropFirst().first == "exec" {
                slice = slice.dropFirst(2)
            }
        }
        guard let first = slice.first else { return nil }
        let tool = URL(fileURLWithPath: first).lastPathComponent
        let rest = Array(slice.dropFirst())
        guard !hasPortFlag(rest) else { return nil }
        let subcommand = rest.first

        switch tool {
        case "vite":
            guard subcommand != "build" && subcommand != "optimize" else { return nil }
            return ["--port", String(port), "--strictPort"]
        case "astro", "vitepress", "rsbuild", "nuxt", "nuxi":
            guard subcommand == "dev" || subcommand == "preview" else { return nil }
            return ["--port", String(port)]
        case "next":
            guard subcommand == nil || subcommand?.hasPrefix("-") == true
                    || subcommand == "dev" || subcommand == "start" else { return nil }
            return ["--port", String(port)]
        case "ng":
            guard subcommand == "serve" || subcommand == "s" else { return nil }
            return ["--port", String(port)]
        case "vue-cli-service":
            guard subcommand == "serve" else { return nil }
            return ["--port", String(port)]
        case "webpack-dev-server":
            return ["--port", String(port)]
        case "webpack":
            guard subcommand == "serve" || subcommand == "s" else { return nil }
            return ["--port", String(port)]
        case "docusaurus":
            guard subcommand == "start" || subcommand == "serve" else { return nil }
            return ["--port", String(port)]
        case "react-router", "storybook", "wrangler":
            guard subcommand == "dev" else { return nil }
            return ["--port", String(port)]
        default:
            return nil
        }
    }

    private static func pythonPortArguments(tokens: [String], port: UInt16) -> [String]? {
        var slice = stripLeadingEnv(tokens)
        if let first = slice.first {
            let runner = URL(fileURLWithPath: first).lastPathComponent
            if ["uv", "poetry", "pipenv"].contains(runner), slice.dropFirst().first == "run" {
                slice = slice.dropFirst(2)
            }
        }
        guard let first = slice.first else { return nil }
        let executable = URL(fileURLWithPath: first).lastPathComponent
        var rest = slice.dropFirst()

        let tool: String
        let args: [String]
        if isPythonExecutable(executable) {
            while let flag = rest.first, ["-u", "-B", "-E", "-O", "-s", "-S", "-I"].contains(flag) {
                rest = rest.dropFirst()
            }
            if rest.first == "-m", let module = rest.dropFirst().first {
                tool = module
                args = Array(rest.dropFirst(2))
            } else if let script = rest.first,
                      URL(fileURLWithPath: script).lastPathComponent == "manage.py",
                      rest.dropFirst().first == "runserver" {
                let runserverArgs = Array(rest.dropFirst(2))
                return hasDjangoAddrPort(runserverArgs) ? nil : [String(port)]
            } else {
                return nil
            }
        } else {
            tool = executable
            args = Array(rest)
        }

        switch tool {
        case "uvicorn":
            guard !hasPortFlag(args) else { return nil }
            return ["--port", String(port)]
        case "flask":
            guard args.contains("run"), !hasPortFlag(args) else { return nil }
            return ["--port", String(port)]
        case "fastapi":
            guard args.contains("dev") || args.contains("run"), !hasPortFlag(args) else { return nil }
            return ["--port", String(port)]
        case "streamlit":
            guard args.contains("run"),
                  !args.contains(where: { $0 == "--server.port" || $0.hasPrefix("--server.port=") }) else { return nil }
            return ["--server.port", String(port)]
        case "gunicorn":
            guard !args.contains(where: {
                $0 == "-b" || $0 == "--bind" || $0.hasPrefix("-b=") || $0.hasPrefix("--bind=")
            }) else { return nil }
            return ["--bind", "127.0.0.1:\(port)"]
        case "http.server":
            return hasHTTPServerPort(args) ? nil : [String(port)]
        default:
            return nil
        }
    }

    private static func isPythonExecutable(_ name: String) -> Bool {
        name == "python" || name == "python3"
            || name.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil
    }

    private static func hasDjangoAddrPort(_ args: [String]) -> Bool {
        let valueOptions: Set<String> = ["--settings", "--pythonpath", "--verbosity", "-v"]
        var index = 0
        while index < args.count {
            let token = args[index]
            if valueOptions.contains(token) {
                index += 2
            } else if token.hasPrefix("-") {
                index += 1
            } else {
                return true
            }
        }
        return false
    }

    private static func hasHTTPServerPort(_ args: [String]) -> Bool {
        let valueOptions: Set<String> = ["-b", "--bind", "-d", "--directory", "-p", "--protocol"]
        var index = 0
        while index < args.count {
            let token = args[index]
            if valueOptions.contains(token) {
                index += 2
            } else if token.hasPrefix("-") {
                index += 1
            } else {
                return true
            }
        }
        return false
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
