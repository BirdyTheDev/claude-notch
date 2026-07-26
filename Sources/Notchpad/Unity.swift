import AppKit

struct UnityProject: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let title: String
    let version: String
    let modified: Date
    var isOpen: Bool
}

struct UnityIssue: Identifiable, Equatable {
    enum Kind {
        case error, warning, exception

        var symbol: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .exception: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// Unity Hub's project list, which editor is actually open, and the tail of Editor.log.
@MainActor
final class UnityStore: ObservableObject {
    static let shared = UnityStore()

    @Published private(set) var projects: [UnityProject] = []
    @Published private(set) var issues: [UnityIssue] = []
    @Published private(set) var editorRunning = false
    @Published private(set) var openProject: String?
    @Published private(set) var librarySizes: [String: Double] = [:]
    @Published private(set) var installed = false

    private let hubProjects = NSHomeDirectory() + "/Library/Application Support/UnityHub/projects-v1.json"
    private let editorLog = NSHomeDirectory() + "/Library/Logs/Unity/Editor.log"

    private init() {
        installed = FileManager.default.fileExists(atPath: "/Applications/Unity/Hub/Editor")
    }

    func reload() {
        let hubPath = hubProjects
        let logPath = editorLog

        Task.detached(priority: .utility) {
            let list = Self.readHubProjects(hubPath)
            // Match by path against the full command line: `-createproject` and paths
            // containing spaces make argv parsing unreliable.
            let commands = Self.runningUnityCommands()
            let open = list.first { project in commands.contains { $0.contains(project.path) } }
            let issues = Self.tailIssues(logPath)

            await MainActor.run {
                self.projects = list.map { project in
                    var copy = project
                    copy.isOpen = project.path == open?.path
                    return copy
                }
                self.openProject = open?.path
                self.editorRunning = !commands.isEmpty
                self.issues = issues
            }
        }
    }

    func open(_ project: UnityProject) {
        let editor = "/Applications/Unity/Hub/Editor/\(project.version)/Unity.app"
        guard FileManager.default.fileExists(atPath: editor) else {
            // Fall back to the Hub, which will offer to install the right version.
            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["-projectPath", project.path]
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: editor), configuration: config) { _, error in
            if error != nil {
                DispatchQueue.main.async { Launcher.onError?("Could not open Unity") }
            }
        }
    }

    func revealLibrary(_ project: UnityProject) {
        let library = project.path + "/Library"
        guard FileManager.default.fileExists(atPath: library) else { return }
        NSWorkspace.shared.selectFile(library, inFileViewerRootedAtPath: project.path)
    }

    /// `du` on a Unity Library can take a while, so it is opt-in per project.
    func measureLibrary(_ project: UnityProject) {
        let path = project.path + "/Library"
        Task.detached(priority: .utility) {
            let out = Self.run("/usr/bin/du", ["-sk", path])
            let kilobytes = Double(out.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            await MainActor.run { self.librarySizes[project.path] = kilobytes * 1024 }
        }
    }

    // MARK: reading

    nonisolated private static func readHubProjects(_ path: String) -> [UnityProject] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (json["data"] as? [String: Any]) else { return [] }

        return entries.compactMap { path, value -> UnityProject? in
            guard let entry = value as? [String: Any],
                  FileManager.default.fileExists(atPath: path) else { return nil }
            let millis = (entry["lastModified"] as? Double) ?? 0
            return UnityProject(path: path,
                                title: (entry["title"] as? String) ?? (path as NSString).lastPathComponent,
                                version: (entry["version"] as? String) ?? "",
                                modified: Date(timeIntervalSince1970: millis / 1000),
                                isOpen: false)
        }
        .sorted { $0.modified > $1.modified }
    }

    nonisolated private static func runningUnityCommands() -> [String] {
        run("/bin/ps", ["-Ao", "command="])
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("/Unity.app/Contents/MacOS/Unity") && !$0.contains("AssetImportWorker") }
    }

    /// Reads only the tail of Editor.log — it grows into the megabytes.
    nonisolated private static func tailIssues(_ path: String) -> [UnityIssue] {
        guard let handle = try? FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 96_000
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }

        var issues: [UnityIssue] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.count > 8, text.count < 400 else { continue }
            let kind: UnityIssue.Kind?
            if text.contains("): error CS") || text.hasPrefix("error ") {
                kind = .error
            } else if text.contains("Exception:") || text.contains("Assertion failed") {
                kind = .exception
            } else if text.contains("): warning CS") {
                kind = .warning
            } else {
                kind = nil
            }
            guard let kind, seen.insert(text).inserted else { continue }
            issues.append(UnityIssue(kind: kind, text: text))
            if issues.count >= 5 { break }
        }
        return issues
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
