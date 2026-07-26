import AppKit
import SwiftUI

struct AppMemoryEntry: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bytes: Double
    let bundleID: String?

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: id)?.icon
    }

    static func == (a: AppMemoryEntry, b: AppMemoryEntry) -> Bool {
        a.id == b.id && a.bytes == b.bytes
    }
}

/// Memory pressure, swap and per-app usage. Lists applications only, and the one
/// action is `terminate()` — nothing here kills a process by pid.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var pressureLevel = 1        // 1 normal · 2 warn · 4 critical
    @Published private(set) var swapUsed: Double = 0
    @Published private(set) var swapTotal: Double = 0
    @Published private(set) var apps: [AppMemoryEntry] = []
    @Published private(set) var purging = false
    @Published private(set) var lastPurgeResult: String?

    var pressureTitle: String {
        switch pressureLevel {
        case 4: return "Critical"
        case 2: return "High"
        default: return "Normal"
        }
    }

    var pressureColor: Color {
        switch pressureLevel {
        case 4: return Color(red: 0.95, green: 0.35, blue: 0.35)
        case 2: return Theme.amber
        default: return Theme.green
        }
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "?", bundle: $0.bundleIdentifier) }

        Task.detached(priority: .utility) {
            let level = Self.sysctlInt("kern.memorystatus_vm_pressure_level")
            let (used, total) = Self.swap()
            let tree = Self.processTree()
            let entries = running.map { app in
                AppMemoryEntry(id: app.pid,
                               name: app.name,
                               bytes: Self.totalBytes(for: app.pid, in: tree),
                               bundleID: app.bundle)
            }
            .sorted { $0.bytes > $1.bytes }

            await MainActor.run {
                self.pressureLevel = level
                self.swapUsed = used
                self.swapTotal = total
                self.apps = Array(entries.prefix(8))
            }
        }
    }

    func quit(_ entry: AppMemoryEntry) {
        guard let app = NSRunningApplication(processIdentifier: entry.id) else { return }
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// `purge` needs root and frees very little on Apple Silicon.
    func purgeInactive() {
        guard !purging else { return }
        purging = true
        let before = swapUsed
        Task.detached {
            let script = "do shell script \"/usr/sbin/purge\" with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            await MainActor.run {
                self.purging = false
                self.lastPurgeResult = ok ? "Purged" : "Cancelled"
                self.refresh()
                _ = before
            }
        }
    }

    // MARK: reading the system

    /// pid → (ppid, resident bytes) for every process.
    nonisolated private static func processTree() -> [pid_t: (ppid: pid_t, rss: Double)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [:] }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var tree: [pid_t: (ppid: pid_t, rss: Double)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]), let rss = Double(parts[2])
            else { continue }
            tree[pid] = (ppid, rss * 1024)
        }
        return tree
    }

    /// An app's own memory plus everything it is responsible for — browser content
    /// processes are launched by launchd, so a parent/child walk alone misses them.
    nonisolated private static func totalBytes(for pid: pid_t, in tree: [pid_t: (ppid: pid_t, rss: Double)]) -> Double {
        var children: [pid_t: [pid_t]] = [:]
        for (child, info) in tree { children[info.ppid, default: []].append(child) }

        var total = tree[pid]?.rss ?? 0
        var visited: Set<pid_t> = [pid]
        var queue = children[pid] ?? []
        while let next = queue.popLast() {
            guard visited.insert(next).inserted else { continue }
            total += tree[next]?.rss ?? 0
            queue.append(contentsOf: children[next] ?? [])
        }

        // XPC helpers (WebKit content, extensions) hang off launchd but stay "responsible"
        // to the app that spawned them, which is how Activity Monitor attributes them too.
        if responsiblePID != nil {
            for (other, info) in tree where !visited.contains(other) {
                if responsible(for: other) == pid { total += info.rss }
            }
        }
        return total
    }

    /// `responsibility_get_pid_responsible_for_pid` is not in any header; resolve it at
    /// runtime and simply skip the attribution if it is unavailable.
    nonisolated private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    nonisolated private static func responsible(for pid: pid_t) -> pid_t {
        guard let fn = responsiblePID else { return pid }
        let result = fn(pid)
        return result > 0 ? result : pid
    }

    nonisolated private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 1 }
        return Int(value)
    }

    nonisolated private static func swap() -> (Double, Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(usage.xsu_used), Double(usage.xsu_total))
    }
}

