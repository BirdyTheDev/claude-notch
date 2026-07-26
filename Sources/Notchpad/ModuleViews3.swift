import AppKit
import SwiftUI

// MARK: - Usage

struct UsageModuleView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let usage = state.usage
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.tokens(usage.todayTotal)).font(.mono(20, .bold)).foregroundStyle(.white)
                    Text("today").font(.ui(10)).foregroundStyle(Color.white.opacity(0.45))
                }
                Text("\(usage.todayMessages) messages · \(Fmt.tokens(usage.todayOutput)) out")
                    .font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.45))

                if usage.blockStart != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10)).frame(width: 128, height: 5)
                            Capsule()
                                .fill(LinearGradient(colors: [prefs.accentColor, Theme.amber],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(5, 128 * usage.blockProgress), height: 5)
                        }
                        Text("5h block · \(Fmt.tokens(usage.blockTotal)) · \(Fmt.duration(usage.blockRemaining ?? 0)) left")
                            .font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
                    }
                    .padding(.top, 3)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    let models = usage.todayByModel
                        .filter { $0.value > 0 && !$0.key.hasPrefix("<") }
                        .sorted { $0.value > $1.value }
                        .prefix(2)
                    ForEach(models, id: \.key) { model, tokens in
                        Text("\(Fmt.model(model)) \(Fmt.tokens(tokens))")
                            .font(.ui(9))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.chip))
                    }
                }
            }
            .frame(width: 150, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Last 7 days").font(.ui(10, .medium)).foregroundStyle(Color.white.opacity(0.5))
                    Spacer()
                    Text("\(Fmt.tokens(usage.weekTotal)) · \(Fmt.tokens(usage.dailyAverage))/day")
                        .font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
                }
                WeekChart(days: usage.week, accent: prefs.accentColor)
                    .frame(height: 42)

                if !usage.topProjects.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(usage.topProjects.prefix(3), id: \.name) { project in
                            HStack(spacing: 6) {
                                Text(project.name).font(.ui(10)).foregroundStyle(Color.white.opacity(0.75))
                                    .lineLimit(1).frame(width: 116, alignment: .leading)
                                GeometryReader { geo in
                                    let maxTotal = usage.topProjects.first?.total ?? 1
                                    Capsule()
                                        .fill(prefs.accentColor.opacity(0.65))
                                        .frame(width: max(3, geo.size.width * CGFloat(project.total) / CGFloat(max(1, maxTotal))),
                                               height: 6)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 10)
                                Text(Fmt.tokens(project.total)).font(.mono(9))
                                    .foregroundStyle(Color.white.opacity(0.5))
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct WeekChart: View {
    let days: [DayUsage]
    let accent: Color

    var body: some View {
        let peak = max(1, days.map(\.total).max() ?? 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { day in
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(day.total > 0 ? accent.opacity(0.85) : Color.white.opacity(0.10))
                                .frame(height: max(2, geo.size.height * CGFloat(day.total) / CGFloat(peak)))
                        }
                    }
                    Text(Fmt.weekday(day.day)).font(.ui(8)).foregroundStyle(Color.white.opacity(0.35))
                }
                .help("\(day.day): \(Fmt.tokens(day.total)) token · \(day.messages) mesaj")
            }
        }
    }
}

// MARK: - Unity

struct UnityModuleView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var unity = UnityStore.shared
    @ObservedObject private var mcp = MCPStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 12)).foregroundStyle(unity.editorRunning ? prefs.accentColor : Color.white.opacity(0.4))
                Text(unity.editorRunning
                     ? ((unity.openProject as NSString?)?.lastPathComponent ?? "Editor open")
                     : "Unity is closed")
                    .font(.ui(12, .semibold)).foregroundStyle(.white)
                if let bridge = mcp.unityBridge {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bridge.reachable == true ? Theme.green : (bridge.reachable == false ? Color.red.opacity(0.8) : Color.white.opacity(0.3)))
                            .frame(width: 6, height: 6)
                        Text(bridge.reachable == true ? "MCP up" : (bridge.reachable == false ? "MCP down" : "MCP ?"))
                            .font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                Spacer()
                if !unity.issues.isEmpty {
                    Text("\(unity.issues.count) sorun").font(.ui(9.5)).foregroundStyle(Theme.amber)
                }
            }

            if !unity.installed {
                Text("No Unity Hub found").font(.ui(10)).foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !unity.issues.isEmpty {
                issueList
            } else {
                projectList
            }
        }
        .onAppear {
            unity.reload()
            mcp.probe()
        }
    }

    private var issueList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(unity.issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.kind.symbol).font(.system(size: 8))
                            .foregroundStyle(issue.kind == .warning ? Theme.amber : Color.red.opacity(0.85))
                            .padding(.top, 2)
                        Text(issue.text).font(.mono(9))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(2)
                    }
                }
                projectList.padding(.top, 4)
            }
        }
    }

    private var projectList: some View {
        VStack(spacing: 2) {
            ForEach(unity.projects.prefix(4)) { project in
                HStack(spacing: 7) {
                    Circle().fill(project.isOpen ? Theme.green : Color.white.opacity(0.22))
                        .frame(width: 5, height: 5)
                    Text(project.title).font(.ui(11, .medium)).foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)
                    Text(project.version).font(.mono(8.5)).foregroundStyle(Color.white.opacity(0.35))
                    Spacer(minLength: 6)
                    if let size = unity.librarySizes[project.path] {
                        Text("Library \(Bytes.gigabytes(size))").font(.mono(8.5))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    Button { unity.measureLibrary(project) } label: {
                        Image(systemName: "internaldrive").font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    .buttonStyle(.plain).help("Measure the Library folder")
                    Button { unity.revealLibrary(project) } label: {
                        Image(systemName: "folder").font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    .buttonStyle(.plain).help("Reveal Library in Finder")
                    Button { Launcher.openClaude(in: project.path) } label: {
                        ClaudeMark().fill(prefs.accentColor.opacity(0.85)).frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain).help("Open in Claude")
                    Button { unity.open(project) } label: {
                        Image(systemName: "play.circle").font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .buttonStyle(.plain).help("Open in Unity")
                }
                .frame(height: 19)
            }
        }
    }
}

// MARK: - MCP

struct MCPModuleView: View {
    @ObservedObject private var mcp = MCPStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("MCP servers").font(.ui(12, .semibold)).foregroundStyle(.white)
                Text("\(mcp.servers.count)").font(.ui(10)).foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                if mcp.downCount > 0 {
                    Text("\(mcp.downCount) down").font(.ui(9.5)).foregroundStyle(Color.red.opacity(0.85))
                }
                Button { mcp.reload(); mcp.probe() } label: {
                    Image(systemName: mcp.probing ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain).help("Check again")
            }

            if mcp.servers.isEmpty {
                Text("No MCP servers configured")
                    .font(.ui(10)).foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(mcp.servers) { server in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(server.reachable == true ? Theme.green
                                          : (server.reachable == false ? Color.red.opacity(0.85) : Color.white.opacity(0.25)))
                                    .frame(width: 6, height: 6)
                                Text(server.name).font(.ui(11, .medium))
                                    .foregroundStyle(Color.white.opacity(0.9)).lineLimit(1)
                                Text(server.kind.label).font(.ui(8.5))
                                    .foregroundStyle(Color.white.opacity(0.35))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.chip))
                                Text(server.target).font(.mono(9))
                                    .foregroundStyle(Color.white.opacity(0.4))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                if let project = server.projects.first {
                                    Button { Launcher.openClaude(in: project) } label: {
                                        Text(server.projects.count > 1
                                             ? "\(server.projectNames[0]) +\(server.projects.count - 1)"
                                             : server.projectNames[0])
                                            .font(.ui(9)).foregroundStyle(prefs.accentColor.opacity(0.9))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open Claude in \(project)")
                                }
                            }
                            .frame(height: 19)
                        }
                    }
                }
            }
        }
        .onAppear {
            mcp.reload()
            mcp.probe()
        }
    }
}
