import AppKit
import SwiftUI

enum SessionStatus: String {
    case idle
    case processing
    case runningTool = "running_tool"
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case compacting
    case notification
    case ended

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .processing: return "Thinking"
        case .runningTool: return "Working"
        case .waitingForInput: return "Your turn"
        case .waitingForApproval: return "Needs approval"
        case .compacting: return "Compacting"
        case .notification: return "Notification"
        case .ended: return "Ended"
        }
    }

    /// Ordering weight for the sessions list — the ones that need you float to the top.
    var urgency: Int {
        switch self {
        case .waitingForApproval: return 5
        case .waitingForInput: return 4
        case .runningTool: return 3
        case .processing, .compacting: return 2
        case .notification: return 1
        case .idle, .ended: return 0
        }
    }

    /// AppKit twin of `tint`, for the menu-bar icon.
    var nsTint: NSColor {
        switch self {
        case .idle: return NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        case .ended: return NSColor(white: 0.55, alpha: 1)
        case .processing, .compacting: return NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        case .runningTool: return NSColor(srgbRed: 0.42, green: 0.64, blue: 0.95, alpha: 1)
        case .waitingForInput: return NSColor(srgbRed: 0.42, green: 0.80, blue: 0.51, alpha: 1)
        case .waitingForApproval, .notification: return NSColor(srgbRed: 0.98, green: 0.76, blue: 0.35, alpha: 1)
        }
    }

    var tint: Color {
        switch self {
        case .idle: return Theme.claude
        case .ended: return Theme.dim
        case .processing, .compacting: return Theme.claude
        case .runningTool: return Theme.blue
        case .waitingForInput: return Theme.green
        case .waitingForApproval, .notification: return Theme.amber
        }
    }
}

struct SessionInfo: Identifiable, Equatable {
    let id: String
    var cwd: String
    var status: SessionStatus
    var tool: String?
    var toolDetail: String?
    var tty: String?
    var pid: Int?
    var updated: Date

    var folderName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "claude" : name
    }

    var detailLine: String {
        [tool, toolDetail].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ProjectEntry: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let modified: Date
    var name: String { (path as NSString).lastPathComponent }
}

enum DropTarget: Equatable { case claude, shelf }

@MainActor
final class AppState: ObservableObject {
    @Published var expanded = false
    @Published var dragging = false
    @Published var dropTarget: DropTarget?
    @Published var activeModule: ModuleKind = Prefs.shared.lastModule
    @Published var system = SystemSnapshot()
    @Published var battery = BatterySnapshot()
    @Published var clockText = ""
    /// Held open by the hotkey or the menu, ignoring hover.
    @Published var pinned = false

    /// Panel height: notch + tab bar + the active module's body.
    var expandedHeight: CGFloat {
        let notch = NotchMetrics.notchSize(for: NotchMetrics.screen).height
        if dragging { return notch + 104 }
        return notch + 26 + 8 + activeModule.bodyHeight + 16
    }

    /// Collapsed island grows to fit whatever the peek slots show.
    func collapsedWidth(notch: CGSize) -> CGFloat {
        notch.width + Prefs.shared.peekLeft.width + Prefs.shared.peekRight.width
    }

    @Published var sessions: [SessionInfo] = []
    @Published var usage = UsageSnapshot()
    @Published var recents: [ProjectEntry] = []
    @Published var toast: String?

    /// Sessions still alive, most urgent first.
    var liveSessions: [SessionInfo] {
        sessions.filter { $0.status != .ended }.sorted { a, b in
            if a.status.urgency != b.status.urgency { return a.status.urgency > b.status.urgency }
            return a.updated > b.updated
        }
    }

    /// Aggregate status across live sessions — drives the mascot.
    var status: SessionStatus {
        let live = sessions.filter { $0.status != .ended }
        if live.contains(where: { $0.status == .waitingForApproval }) { return .waitingForApproval }
        if live.contains(where: { $0.status == .runningTool }) { return .runningTool }
        if live.contains(where: { $0.status == .processing || $0.status == .compacting }) { return .processing }
        if live.contains(where: { $0.status == .waitingForInput }) { return .waitingForInput }
        return .idle
    }

    var busySession: SessionInfo? { liveSessions.first }

    func apply(event: HookEvent) {
        let now = Date()
        let status = SessionStatus(rawValue: event.status) ?? .idle
        var detail: String?
        if let input = event.toolInput {
            detail = ToolFormatter.summary(tool: event.tool, input: input)
        }
        if let idx = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            sessions[idx].status = status
            sessions[idx].tool = event.tool
            sessions[idx].toolDetail = detail ?? sessions[idx].toolDetail
            if !event.cwd.isEmpty { sessions[idx].cwd = event.cwd }
            sessions[idx].updated = now
            if status == .ended {
                sessions.remove(at: idx)
            }
        } else if status != .ended {
            sessions.append(SessionInfo(id: event.sessionId,
                                        cwd: event.cwd,
                                        status: status,
                                        tool: event.tool,
                                        toolDetail: detail,
                                        tty: event.tty,
                                        pid: event.pid,
                                        updated: now))
        }
        // Drop sessions that went silent for over an hour.
        sessions.removeAll { now.timeIntervalSince($0.updated) > 3600 }
    }

    /// Sessions whose Claude process is gone (terminal closed, crash) never send SessionEnd.
    func pruneDeadSessions() {
        sessions.removeAll { session in
            guard let pid = session.pid, pid > 1 else { return false }
            if kill(pid_t(pid), 0) == 0 { return false }
            return errno != EPERM
        }
    }

    func flash(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toast == message { toast = nil }
        }
    }
}

enum ToolFormatter {
    static func summary(tool: String?, input: [String: Any]) -> String? {
        guard let tool else { return nil }
        func str(_ key: String) -> String? { input[key] as? String }
        switch tool {
        case "Bash":
            return str("command").map { shorten($0, 48) }
        case "Read", "Write", "Edit", "NotebookEdit":
            return str("file_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            return str("pattern").map { shorten($0, 32) }
        case "WebFetch", "WebSearch":
            return str("url") ?? str("query")
        case "Task", "Agent":
            return str("description")
        default:
            return nil
        }
    }

    private static func shorten(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= n ? flat : String(flat.prefix(n)) + "…"
    }
}
