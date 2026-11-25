import Foundation

enum ProjectFiles {
    private struct Manifest: Decodable {
        var name: String?
        var packageManager: String?
        var scripts: [String: String]?
        var engines: [String: String]?
        var dependencies: [String: String]?
        var devDependencies: [String: String]?
    }

    private static let ignored: Set<String> = [
        "node_modules", "bower_components", "jspm_packages",
        "dist", "build", "out", "target", "coverage", "DerivedData",
        "Pods", "Carthage", "vendor",
        "venv", "env", "virtualenv", "__pycache__", "site-packages", "eggs",
    ]
    private static let pythonMarkers: Set<String> = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "manage.py"]
    private static let pythonEntrypoints = ["manage.py", "__main__.py", "main.py", "app.py"]

    private static let portVarRegex = try! NSRegularExpression(pattern: #"\$(?:PORT\b|\{PORT\b)"#)
    private static let envAssignRegex = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*="#)
    private static let shortPortRegex = try! NSRegularExpression(pattern: #"^-p[0-9]+$"#)
    private static let pythonVersionedRegex = try! NSRegularExpression(pattern: #"^python3\.\d+$"#)
    private static let installHintRegex = try! NSRegularExpression(
        pattern: #"(?m)\b(?:run|execute|try|using|with)\s+[`'"“‘]?(?:npm|pnpm|yarn|bun) (?:install|i)\b|package\.json exists, but node_modules missing"#
    )
    private static let missingPackagesRegex = try! NSRegularExpression(
        pattern: #"(?i)cannot find (?:module|package) ['"]([^'"]+)['"]"#
    )
    private static let commandNotFoundRegex = try! NSRegularExpression(
        pattern: #"(?m)^(?:sh|zsh|bash):[^\n]*(?:command not found|: not found)\b"#
    )
    private static let pkgMgrNotFoundRegex = try! NSRegularExpression(
        pattern: #"(?m)^.*(?:command not found: (?:npm|pnpm|yarn|bun)\b|\b(?:npm|pnpm|yarn|bun): (?:command )?not found)"#
    )

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

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

    static func detectPackageManager(at projectPath: String, manifestPackageManager: String? = nil) -> NodePackageManager {
        let directory = URL(fileURLWithPath: projectPath, isDirectory: true)
        let declared: String? = manifestPackageManager ?? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
            return manifest.packageManager
        }()

        if let raw = declared?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            let prefix = raw.split(separator: "@", maxSplits: 1).first.map(String.init) ?? raw
            if let manager = NodePackageManager(rawValue: prefix) {
                return manager
            }
        }

        let fileManager = FileManager.default
        var current = directory
        for _ in 0..<4 {
            if fileManager.fileExists(atPath: current.appendingPathComponent("pnpm-lock.yaml").path) {
                return .pnpm
            }
            if fileManager.fileExists(atPath: current.appendingPathComponent("yarn.lock").path) {
                return .yarn
            }
            if fileManager.fileExists(atPath: current.appendingPathComponent("bun.lock").path)
                || fileManager.fileExists(atPath: current.appendingPathComponent("bun.lockb").path) {
                return .bun
            }
            if fileManager.fileExists(atPath: current.appendingPathComponent("package-lock.json").path)
                || fileManager.fileExists(atPath: current.appendingPathComponent("npm-shrinkwrap.json").path) {
                return .npm
            }
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || ["/Users", "/var", "/tmp", "/private", "/Volumes", "/"].contains(parent.path) {
                break
            }
            current = parent
        }
        return .npm
    }

    private static func nodeCandidate(at url: URL) throws -> ProjectCandidate {
        let directory = URL(fileURLWithPath: canonicalPath(url.deletingLastPathComponent()))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageManager = detectPackageManager(at: directory.path, manifestPackageManager: manifest.packageManager)
        let suggestedCommand: String
        if manifest.scripts?["dev"] != nil {
            suggestedCommand = packageManager.runScriptCommand("dev")
        } else if manifest.scripts?["start"] != nil {
            suggestedCommand = packageManager.runScriptCommand("start")
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

    static func pythonBootstrapArguments(command: String, token: String) -> [String] {
        ["-fc", pythonBootstrap, "devlauncher", command, token]
    }

    private static let pythonBootstrap = #"""
    py_ver="$(python3 --version 2>/dev/null || python --version 2>/dev/null || true)"
    if [[ -z "$py_ver" ]]; then
      py_ver="Python"
    fi
    if [[ -n "${VIRTUAL_ENV-}" ]]; then
      py_ver="${py_ver} (${VIRTUAL_ENV:t})"
    fi
    printf '%s\tRUNTIME\t%s\n' "$2" "$py_ver"
    exec /bin/zsh -fc "$1"
    """#

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
        matches(portVarRegex, in: command)
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
        matches(envAssignRegex, in: token)
    }

    private static func hasPortFlag(_ args: [String]) -> Bool {
        args.contains { token in
            token == "--port" || token == "-p" || token.hasPrefix("--port=") || token.hasPrefix("-p=")
                || matches(shortPortRegex, in: token)
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
            } else if ["pnpm", "yarn", "bun"].contains(executable),
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
            } else if ["npm", "pnpm", "yarn"].contains(runner), slice.dropFirst().first == "exec" {
                slice = slice.dropFirst(2)
                if runner == "npm", slice.first == "--" {
                    slice = slice.dropFirst()
                }
            } else if runner == "bun", slice.dropFirst().first == "x" {
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
                $0 == "-b" || $0 == "--bind" || $0.hasPrefix("-b") || $0.hasPrefix("--bind=")
            }) else { return nil }
            return ["--bind", "127.0.0.1:\(port)"]
        case "http.server":
            return hasHTTPServerPort(args) ? nil : [String(port)]
        default:
            return nil
        }
    }

    private static func isPythonExecutable(_ name: String) -> Bool {
        name == "python" || name == "python3" || matches(pythonVersionedRegex, in: name)
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
        if matches(installHintRegex, in: output) { return true }

        let dependencies = Set((manifest.dependencies ?? [:]).keys).union((manifest.devDependencies ?? [:]).keys)
        let whole = NSRange(log.startIndex..., in: log)
        for match in missingPackagesRegex.matches(in: log, range: whole) {
            guard let range = Range(match.range(at: 1), in: log) else { continue }
            let specifier = log[range]
            guard !specifier.hasPrefix("."), !specifier.hasPrefix("/") else { continue }
            let components = specifier.split(separator: "/")
            let name = components.prefix(specifier.hasPrefix("@") ? 2 : 1).joined(separator: "/")
            if dependencies.contains(name) { return true }
        }

        guard matches(commandNotFoundRegex, in: output),
              !matches(pkgMgrNotFoundRegex, in: output) else { return false }

        let boundaryRoots: Set<String> = ["/Users", "/var", "/tmp", "/private", "/Volumes", "/"]
        let fileManager = FileManager.default
        return dependencies.contains { package in
            var parent = directory
            for _ in 0..<8 {
                let pkgManifest = parent.appendingPathComponent("node_modules/\(package)/package.json")
                if fileManager.isReadableFile(atPath: pkgManifest.path) { return false }
                if fileManager.fileExists(atPath: parent.appendingPathComponent(".git").path) { return true }
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path || boundaryRoots.contains(next.path) { return true }
                parent = next
            }
            return true
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
