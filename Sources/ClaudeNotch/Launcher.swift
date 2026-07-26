import AppKit
import ServiceManagement

struct TerminalApp: Equatable {
    let name: String
    let bundleID: String
    let url: URL
}

enum Terminals {
    private static let known: [(String, String)] = [
        ("Ghostty", "com.mitchellh.ghostty"),
        ("iTerm", "com.googlecode.iterm2"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    static func installed() -> [TerminalApp] {
        known.compactMap { name, id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                TerminalApp(name: name, bundleID: id, url: $0)
            }
        }
    }

    /// The terminal to launch into: the user's pick if it is still installed, else the first found.
    @MainActor
    static func preferred() -> TerminalApp? {
        let list = installed()
        let chosen = Prefs.shared.terminalBundleID
        if !chosen.isEmpty, let match = list.first(where: { $0.bundleID == chosen }) { return match }
        return list.first
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the state that actually took effect — registration can fail for
    /// ad-hoc signed builds, and the toggle must not lie about it.
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudeNotch: login item → \(error)")
            Launcher.onError?(enabled ? "Could not enable launch at login" : "Could not disable launch at login")
        }
        return isEnabled
    }
}

enum Launcher {
    /// Called with a user-facing message when a launch fails.
    nonisolated(unsafe) static var onError: ((String) -> Void)?

    /// Where the `claude` binary lives. Resolved once, with the usual install spots as fallbacks.
    static let claudeBinary: String = {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }()

    private static var launchDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeNotch/launch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Opens a terminal window running Claude Code in `directory`, always in skip-permissions mode.
    ///
    /// Uses a throwaway `.command` script opened through LaunchServices rather than AppleScript,
    /// so macOS never asks for Automation permission.
    @MainActor
    static func openClaude(in directory: String, initialPrompt: String? = nil) {
        var target = (directory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), !isDir.boolValue {
            target = (target as NSString).deletingLastPathComponent
        }
        guard FileManager.default.fileExists(atPath: target) else {
            onError?("Folder not found")
            return
        }
        guard let terminal = Terminals.preferred() else {
            onError?("No terminal app found")
            return
        }

        let extra = Prefs.shared.extraArgs.trimmingCharacters(in: .whitespaces)
        let prompt = initialPrompt.map { " " + sh($0) } ?? ""
        let script = """
        #!/bin/zsh
        cd \(sh(target)) || exit 1
        clear
        exec \(sh(claudeBinary)) --dangerously-skip-permissions \(extra)\(prompt)
        """

        let name = (target as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let file = launchDir.appendingPathComponent("\(name.isEmpty ? "claude" : name)-\(UUID().uuidString.prefix(6)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            NSLog("ClaudeNotch: could not write launch script — \(error)")
            onError?("Could not write the launch script")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal.url, configuration: config) { _, error in
            guard let error else { return }
            NSLog("ClaudeNotch: launch failed — \(error)")
            DispatchQueue.main.async { onError?("Could not open \(terminal.name)") }
        }
    }

    /// Runs an arbitrary shell command in a terminal window and keeps it open afterwards.
    @MainActor
    static func openShell(command: String) {
        guard let terminal = Terminals.preferred() else {
            onError?("No terminal app found")
            return
        }
        let script = """
        #!/bin/zsh
        cd "$HOME"
        \(command)
        echo
        echo "— done, press Enter to close —"
        read
        """
        let file = launchDir.appendingPathComponent("cmd-\(UUID().uuidString.prefix(6)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            onError?("Could not write the command script")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal.url, configuration: config) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { onError?("Could not run the command") }
        }
    }

    /// Removes launch scripts left behind by earlier runs.
    static func sweepOldLaunchScripts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: launchDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    /// POSIX single-quote escaping for the shell.
    private static func sh(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ProjectScanner {
    /// Recent working directories, read from the `cwd` recorded in each project's newest transcript.
    static func recents(limit: Int = 6) -> [ProjectEntry] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let sorted = dirs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }

        var out: [ProjectEntry] = []
        var seen = Set<String>()
        for dir in sorted.prefix(limit * 3) {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            let newest = files.filter { $0.pathExtension == "jsonl" }.max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a < b
            }
            guard let newest,
                  let modified = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let cwd = firstCwd(in: newest),
                  fm.fileExists(atPath: cwd),
                  !seen.contains(cwd)
            else { continue }
            seen.insert(cwd)
            out.append(ProjectEntry(path: cwd, modified: modified))
            if out.count >= limit { break }
        }
        return out
    }

    private static func firstCwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64_000), let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(40) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }
}
