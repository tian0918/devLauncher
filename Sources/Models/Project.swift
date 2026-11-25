import Foundation

enum ProjectKind: String, Codable, Sendable {
    case node = "Node.js"
    case python = "Python"
}

enum NodePackageManager: String, Sendable {
    case npm
    case pnpm
    case yarn
    case bun

    func runScriptCommand(_ script: String) -> String {
        switch self {
        case .npm: "npm run \(script)"
        case .pnpm: "pnpm run \(script)"
        case .yarn: "yarn \(script)"
        case .bun: "bun run \(script)"
        }
    }

    var installCommand: String {
        "\(rawValue) install"
    }
}

struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var path: String
    var name: String
    var listAlias: String?
    var isPinned: Bool?
    var nodeRequirement: String?
    var nodeVersion: String?
    var command: String
    var launchPort: UInt16?
    private var projectKind: ProjectKind?

    var listName: String { listAlias ?? name }
    var pinned: Bool { isPinned == true }
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
