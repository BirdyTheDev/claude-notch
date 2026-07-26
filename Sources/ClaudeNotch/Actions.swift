import AppKit
import SwiftUI

/// Something to send Claude Code: a slash command, a skill, or a plain prompt.
struct ClaudeAction: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case builtin, user, command, skill, agent

        var label: String {
            switch self {
            case .builtin: return "built-in"
            case .user: return "yours"
            case .command: return "command"
            case .skill: return "skill"
            case .agent: return "agent"
            }
        }
    }

    var id = UUID()
    var name: String
    var symbol: String
    /// Sent to Claude as the first message — "/security-review", "fix the tests", …
    var prompt: String
    /// Empty means "use the last project".
    var folder: String
    var source: Source = .user
    var detail: String?

    static let seeds: [ClaudeAction] = [
        ClaudeAction(name: "Review code", symbol: "checklist", prompt: "/code-review", folder: "", source: .builtin,
                     detail: "Review the changes in the working directory"),
        ClaudeAction(name: "Security", symbol: "lock.shield", prompt: "/security-review", folder: "", source: .builtin,
                     detail: "Security pass over the changes on this branch"),
        ClaudeAction(name: "Simplify", symbol: "wand.and.stars", prompt: "/simplify", folder: "", source: .builtin,
                     detail: "Tidy up the code that changed"),
        ClaudeAction(name: "CLAUDE.md", symbol: "doc.text", prompt: "/init", folder: "", source: .builtin,
                     detail: "Write a CLAUDE.md for this project"),
        ClaudeAction(name: "Fix tests", symbol: "checkmark.seal", prompt: "Run the tests and fix whatever is broken.",
                     folder: "", source: .builtin, detail: "Example of a plain prompt"),
    ]
}

/// User actions are persisted; discovered ones are rescanned from ~/.claude at launch.
@MainActor
final class ActionsStore: ObservableObject {
    static let shared = ActionsStore()

    @Published var actions: [ClaudeAction] { didSet { persist() } }
    @Published private(set) var discovered: [ClaudeAction] = []

    private let key = "claudeActions"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ClaudeAction].self, from: data) {
            actions = saved
        } else {
            actions = ClaudeAction.seeds
        }
        discover()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(actions) { UserDefaults.standard.set(data, forKey: key) }
    }

    func run(_ action: ClaudeAction, fallbackFolder: String) {
        let folder = action.folder.isEmpty ? fallbackFolder : action.folder
        Launcher.openClaude(in: folder, initialPrompt: action.prompt)
    }

    func adopt(_ action: ClaudeAction) {
        guard !actions.contains(where: { $0.prompt == action.prompt }) else { return }
        var copy = action
        copy.id = UUID()
        actions.append(copy)
    }

    /// Walks the places Claude Code actually loads things from: personal slash commands,
    /// personal agents, and the commands/skills inside *installed* plugins.
    func discover() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var found: [ClaudeAction] = []

        func frontmatter(_ url: URL) -> (name: String?, description: String?) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
            var name: String?
            var description: String?
            var inHeader = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) {
                if line == "---" {
                    if inHeader { break }
                    inHeader = true
                    continue
                }
                guard inHeader else { break }
                if line.hasPrefix("name:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("description:") { description = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
            }
            return (name, description)
        }

        // ~/.claude/commands/foo.md → /foo
        let commandsDir = URL(fileURLWithPath: home + "/.claude/commands")
        for url in (try? fm.contentsOfDirectory(at: commandsDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "md" {
            let slug = url.deletingPathExtension().lastPathComponent
            found.append(ClaudeAction(name: "/" + slug, symbol: "chevron.left.forwardslash.chevron.right",
                                      prompt: "/" + slug, folder: "", source: .command,
                                      detail: frontmatter(url).description))
        }

        // ~/.claude/agents/foo.md → run through the Task tool
        let agentsDir = URL(fileURLWithPath: home + "/.claude/agents")
        for url in (try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "md" {
            let info = frontmatter(url)
            let slug = info.name ?? url.deletingPathExtension().lastPathComponent
            found.append(ClaudeAction(name: slug, symbol: "person.2",
                                      prompt: "Run the \(slug) agent", folder: "", source: .agent,
                                      detail: info.description))
        }

        // Installed plugins only — the marketplace catalog is not loaded by Claude Code,
        // so listing it would offer commands that resolve to "unknown command".
        for path in installedPluginPaths() {
            let base = URL(fileURLWithPath: path)
            for url in (try? fm.contentsOfDirectory(at: base.appendingPathComponent("commands"),
                                                    includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "md" {
                let slug = url.deletingPathExtension().lastPathComponent
                found.append(ClaudeAction(name: "/" + slug, symbol: "puzzlepiece.extension",
                                          prompt: "/" + slug, folder: "", source: .command,
                                          detail: frontmatter(url).description))
            }
            let skillsDir = base.appendingPathComponent("skills")
            for dir in (try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil)) ?? [] {
                let skill = dir.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skill.path) else { continue }
                let info = frontmatter(skill)
                let slug = info.name ?? dir.lastPathComponent
                found.append(ClaudeAction(name: slug, symbol: "sparkles",
                                          prompt: "/\(slug)", folder: "", source: .skill,
                                          detail: info.description))
            }
        }

        var seen = Set<String>()
        discovered = found.filter { seen.insert($0.prompt).inserted }
    }

    private func installedPluginPaths() -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return [] }
        return plugins.values.compactMap { value in
            (value as? [[String: Any]])?.first?["installPath"] as? String
        }
    }
}
