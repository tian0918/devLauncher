import Foundation

struct NVMInstallation: Equatable, Sendable {
    private static let versionRegex = try! NSRegularExpression(
        pattern: #"^v[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$"#
    )

    let script: String
    let directory: String

    var installedVersions: [String] {
        let versions = URL(fileURLWithPath: directory).appendingPathComponent("versions/node")
        let roots = [versions, URL(fileURLWithPath: directory)]
        let fileManager = FileManager.default
        let installed = roots.flatMap { root in
            let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return folders.compactMap { folder -> String? in
                let version = folder.lastPathComponent
                let range = NSRange(version.startIndex..., in: version)
                guard Self.versionRegex.firstMatch(in: version, range: range) != nil,
                      fileManager.isExecutableFile(atPath: folder.appendingPathComponent("bin/node").path)
                else { return nil }
                return version
            }
        }
        return Set(installed).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }
}

enum NVM {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let shellMarker = "__DEV_LAUNCHER_NVM_DIR__="
    private static let pathMarker = "__DEV_LAUNCHER_PATH__="
    private static let brewScripts = ["/opt/homebrew/opt/nvm/nvm.sh", "/usr/local/opt/nvm/nvm.sh"]
    private static let profileAssignment = try! NSRegularExpression(
        pattern: #"^\s*(?:export\s+)?NVM_DIR=(?:"([^"]*)"|'([^']*)'|([^\s;'"]+))\s*;?\s*(?:#.*)?$"#
    )

    static var probeArguments: [String] {
        ["-ilc", #"printf '\n%s%s\n%s%s\n' "$1" "${NVM_DIR-}" "$2" "$PATH""#, "devlauncher", shellMarker, pathMarker]
    }

    static func manual(_ script: String) -> NVMInstallation? {
        let parent = URL(fileURLWithPath: script).deletingLastPathComponent().path
        let directory = script.contains("/Cellar/nvm/") || brewScripts.contains(script)
            ? home.appendingPathComponent(".nvm").path : parent
        return readable(script: script, directory: directory)
    }

    static func inherited() -> NVMInstallation? {
        installation(in: ProcessInfo.processInfo.environment["NVM_DIR"])
    }

    static func probed(_ output: String) -> NVMInstallation? {
        let line = output.split(separator: "\n").last { $0.hasPrefix(shellMarker) }
        return installation(in: line.map { String($0.dropFirst(shellMarker.count)) })
    }

    static func probedPath(_ output: String) -> String? {
        output.split(separator: "\n").last { $0.hasPrefix(pathMarker) }.map { String($0.dropFirst(pathMarker.count)) }
    }

    private static func common() -> NVMInstallation? {
        installation(in: home.appendingPathComponent(".nvm").path)
    }

    private static func configuredInProfiles() -> [NVMInstallation] {
        let profileRoot = ProcessInfo.processInfo.environment["ZDOTDIR"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil } ?? home
        var seen: Set<String> = []
        var installations: [NVMInstallation] = []
        // Look at literal assignments when the login shell didn't report a usable installation.
        for name in [".zlogin", ".zshrc", ".zprofile", ".zshenv"] {
            guard let contents = try? String(contentsOf: profileRoot.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            for line in contents.split(whereSeparator: \.isNewline).reversed() {
                let text = String(line)
                guard let match = profileAssignment.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let capture = (1...3).first(where: { match.range(at: $0).location != NSNotFound }),
                      let range = Range(match.range(at: capture), in: text)
                else { continue }
                var directory = String(text[range])
                let homePrefixes = capture == 3 ? ["$HOME/", "${HOME}/", "~/"] : ["$HOME/", "${HOME}/"]
                if capture != 2, let prefix = homePrefixes.first(where: directory.hasPrefix) {
                    directory = home.path + "/" + directory.dropFirst(prefix.count)
                }
                if let candidate = installation(in: directory), seen.insert(candidate.directory).inserted {
                    installations.append(candidate)
                }
            }
        }
        return installations
    }

    static func resolvedInstallation(probed: NVMInstallation?, inherited: NVMInstallation?) -> NVMInstallation? {
        if let probed, !probed.installedVersions.isEmpty { return probed }
        let candidates = configuredInProfiles() + [inherited, common()].compactMap { $0 }
        return candidates.first { !$0.installedVersions.isEmpty } ?? probed ?? candidates.first
    }

    private static func installation(in directory: String?) -> NVMInstallation? {
        guard let directory, directory.hasPrefix("/") else { return nil }
        let script = URL(fileURLWithPath: directory).appendingPathComponent("nvm.sh").path
        return readable(script: script, directory: directory)
            ?? brewScripts.lazy.compactMap { readable(script: $0, directory: directory) }.first
    }

    private static func readable(script: String, directory: String) -> NVMInstallation? {
        guard FileManager.default.isReadableFile(atPath: script) else { return nil }
        return NVMInstallation(script: script, directory: directory)
    }

    private static let selectorRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.*+/-]+$"#)

    static func validSelector(_ selector: String) -> Bool {
        guard !selector.hasPrefix("-") else { return false }
        return selectorRegex.firstMatch(in: selector, range: NSRange(selector.startIndex..., in: selector)) != nil
    }

    enum Operation: String {
        case start, installNode, installDependencies
    }

    static func arguments(
        installation: NVMInstallation?, selector: String?, command: String, token: String,
        operation: Operation
    ) -> [String] {
        ["-fc", bootstrap, "devlauncher", installation?.script ?? "", installation?.directory ?? "",
         selector ?? "", command, token, operation.rawValue]
    }

    private static let bootstrap = #"""
    if [[ -n "$1" ]]; then
      export NVM_DIR="$2"
      unset NVM_SYMLINK_CURRENT
      printf 'nvm: %s\n' "$NVM_DIR"
      if ! source "$1" --no-use || ! command -v nvm >/dev/null; then
        printf '\n%s\tERROR\t%s\n' "$5" '无法加载 nvm.sh，请检查设置中的路径。'
        exit 126
      fi
      selector="$3"
      from_rc=0
      if [[ -z "$selector" ]]; then
        if [[ -n "$(nvm_find_nvmrc)" ]]; then
          from_rc=1
        else
          selector=default
        fi
      fi

      default_target() {
        local target
        target="$(nvm_alias default 2>/dev/null)"
        [[ -n "$target" && "$target" != -* ]] && printf '%s' "$target"
      }

      if [[ "$6" == installNode ]]; then
        if (( from_rc )); then
          nvm install
        elif [[ "$selector" == default ]]; then
          if target="$(default_target)"; then
            nvm install "$target"
          else
            nvm install node && nvm alias default node
          fi
        else
          nvm install "$selector"
        fi
        exit $?
      fi

      if (( from_rc )); then
        nvm use
      else
        nvm use "$selector"
      fi
      result=$?
      if (( result != 0 )); then
        if (( result == 3 )); then
          if (( from_rc )); then
            printf '\n%s\tINSTALL\t%s\n' "$5" 'nvm install'
          elif [[ "$selector" == default ]]; then
            if target="$(default_target)"; then
              printf '\n%s\tINSTALL\tnvm install %s\n' "$5" "${(qq)target}"
            else
              printf '\n%s\tINSTALL\t%s\n' "$5" 'nvm install node && nvm alias default node'
            fi
          else
            printf '\n%s\tINSTALL\tnvm install %s\n' "$5" "${(qq)selector}"
          fi
        else
          printf '\n%s\tERROR\t%s\n' "$5" '无法切换 Node 版本，请查看日志中的 nvm 输出。'
        fi
        exit "$result"
      fi
    else
      if [[ "$6" == installNode ]]; then
        printf '\n%s\tERROR\t%s\n' "$5" '找不到 nvm.sh，无法安装此 Node 版本。'
        exit 127
      fi
      printf '找不到 nvm，使用 PATH 中的默认 Node。\n'
      if ! command -v node >/dev/null; then
        printf '\n%s\tERROR\t%s\n' "$5" '找不到 Node，请先安装 Node.js 或在设置中指定 nvm。'
        exit 127
      fi
    fi
    if ! node_version="$(node --version)"; then
      printf '\n%s\tERROR\t%s\n' "$5" '所选 Node 无法执行，请检查该版本是否适用于此 Mac。'
      exit 126
    fi
    printf '\n%s\tNODE\t%s\n' "$5" "$node_version"
    if [[ "$6" == installDependencies ]]; then
      pkg_mgr="${4%% *}"
      case "$pkg_mgr" in
        npm|pnpm|yarn|bun) ;;
        *) pkg_mgr=npm ;;
      esac
      if ! command -v "$pkg_mgr" >/dev/null; then
        printf '找不到 %s。\n' "$pkg_mgr"
        exit 127
      fi
      exec "$pkg_mgr" install
    fi
    exec /bin/zsh -fc "$4"
    """#
}
