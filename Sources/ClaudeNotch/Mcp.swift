import Foundation

struct MCPServer: Identifiable, Equatable {
    enum Kind: String {
        case http, sse, stdio

        var label: String {
            switch self {
            case .http: return "HTTP"
            case .sse: return "SSE"
            case .stdio: return "stdio"
            }
        }
    }

    var id: String { name + target }
    let name: String
    let kind: Kind
    /// URL for http/sse servers, the command line for stdio ones.
    let target: String
    var projects: [String]
    /// nil while unknown or not probeable (stdio).
    var reachable: Bool?

    var host: String? {
        guard kind != .stdio, let url = URL(string: target) else { return nil }
        return url.host
    }

    var isLocal: Bool {
        guard let host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    var projectNames: [String] {
        projects.map { ($0 as NSString).lastPathComponent }
    }
}

/// Reads every MCP server Claude Code knows about and pings the reachable ones.
/// A local HTTP bridge that is down (Unity's, typically) is the thing worth seeing
/// before a session starts, so the check is a plain connectivity probe rather than
/// a shell-out to `claude mcp list`.
@MainActor
final class MCPStore: ObservableObject {
    static let shared = MCPStore()

    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var lastProbe: Date?
    @Published private(set) var probing = false

    private init() { reload() }

    /// The local bridge Unity projects talk to, if one is configured.
    var unityBridge: MCPServer? {
        servers.first { $0.isLocal && ($0.name.lowercased().contains("unity") || $0.target.contains(":8080")) }
    }

    var downCount: Int { servers.filter { $0.reachable == false }.count }

    func reload() {
        var found: [String: MCPServer] = [:]

        func add(name: String, config: [String: Any], project: String?) {
            let typeString = (config["type"] as? String) ?? (config["url"] != nil ? "http" : "stdio")
            let kind = MCPServer.Kind(rawValue: typeString) ?? .stdio
            let target: String
            switch kind {
            case .http, .sse:
                target = (config["url"] as? String) ?? ""
            case .stdio:
                let command = (config["command"] as? String) ?? ""
                let args = (config["args"] as? [String])?.joined(separator: " ") ?? ""
                target = ([command, args].filter { !$0.isEmpty }).joined(separator: " ")
            }
            guard !target.isEmpty else { return }
            let key = name + target
            if var existing = found[key] {
                if let project, !existing.projects.contains(project) { existing.projects.append(project) }
                found[key] = existing
            } else {
                found[key] = MCPServer(name: name, kind: kind, target: target,
                                       projects: project.map { [$0] } ?? [], reachable: nil)
            }
        }

        // ~/.claude.json — global block plus every project block.
        let claudeJSON = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        if let data = try? Data(contentsOf: claudeJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let global = json["mcpServers"] as? [String: Any] {
                for (name, config) in global {
                    if let config = config as? [String: Any] { add(name: name, config: config, project: nil) }
                }
            }
            if let projects = json["projects"] as? [String: Any] {
                for (path, value) in projects {
                    guard let entry = value as? [String: Any],
                          let servers = entry["mcpServers"] as? [String: Any] else { continue }
                    for (name, config) in servers {
                        if let config = config as? [String: Any] { add(name: name, config: config, project: path) }
                    }
                }
            }
        }

        // Committed .mcp.json files inside the projects Claude Code has seen.
        for project in ProjectScanner.recents(limit: 12) {
            let url = URL(fileURLWithPath: project.path + "/.mcp.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any] else { continue }
            for (name, config) in servers {
                if let config = config as? [String: Any] { add(name: name, config: config, project: project.path) }
            }
        }

        let previous = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.reachable) })
        servers = found.values
            .map { server in
                var copy = server
                copy.reachable = previous[server.id] ?? nil
                return copy
            }
            .sorted { a, b in
                if a.isLocal != b.isLocal { return a.isLocal }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// HEAD each http/sse endpoint with a short timeout. Any HTTP answer counts as up —
    /// MCP endpoints legitimately reply 405/406 to a bare HEAD.
    func probe() {
        guard !probing else { return }
        probing = true
        let targets = servers.enumerated().compactMap { index, server -> (Int, URL)? in
            guard server.kind != .stdio, let url = URL(string: server.target) else { return nil }
            return (index, url)
        }
        guard !targets.isEmpty else {
            probing = false
            return
        }

        Task {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1.5
            config.timeoutIntervalForResource = 2
            let session = URLSession(configuration: config)

            var results: [Int: Bool] = [:]
            await withTaskGroup(of: (Int, Bool).self) { group in
                for (index, url) in targets {
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.httpMethod = "HEAD"
                        do {
                            _ = try await session.data(for: request)
                            return (index, true)
                        } catch {
                            let code = (error as NSError).code
                            // A refused connection means down; a protocol-level complaint
                            // still proves something answered.
                            let down = code == NSURLErrorCannotConnectToHost
                                || code == NSURLErrorTimedOut
                                || code == NSURLErrorCannotFindHost
                                || code == NSURLErrorNetworkConnectionLost
                            return (index, !down)
                        }
                    }
                }
                for await (index, up) in group { results[index] = up }
            }

            for (index, up) in results where index < servers.count {
                servers[index].reachable = up
            }
            lastProbe = Date()
            probing = false
        }
    }
}
