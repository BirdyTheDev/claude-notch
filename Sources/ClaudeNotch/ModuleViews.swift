import AppKit
import SwiftUI

// MARK: - Claude

struct ClaudeModuleView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Mascot(status: state.status, size: 36, eyes: prefs.mascotEyes)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.ui(13, .semibold))
                        .foregroundStyle(state.toast == nil ? Color.white : prefs.accentColor)
                    Text(subhead)
                        .font(.ui(10.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        MiniButton(icon: "plus", label: "New", tint: prefs.accentColor) {
                            Launcher.openClaude(in: state.recents.first?.path ?? NSHomeDirectory())
                        }
                        MiniButton(icon: "folder", label: "Folder", tint: Theme.blue) { pickFolder() }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 6)
                if prefs.showUsage { usage }
            }

            Divider().overlay(Theme.stroke)

            if state.liveSessions.isEmpty {
                recents
            } else {
                sessions
            }
        }
    }

    private var headline: String {
        if let toast = state.toast { return toast }
        let live = state.liveSessions.count
        return state.status == .idle ? (live > 0 ? "\(live) sessions open" : "Claude is ready") : state.status.title
    }

    private var subhead: String {
        if let session = state.busySession {
            return [session.folderName, session.tool, session.toolDetail].compactMap { $0 }.joined(separator: " · ")
        }
        return "drag a folder onto the notch"
    }

    private var usage: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Fmt.tokens(state.usage.todayTotal)).font(.mono(14, .semibold)).foregroundStyle(.white)
                Text("token").font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
            }
            Text("today · \(state.usage.todayMessages) messages")
                .font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
            if state.usage.blockStart != nil {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(width: 104, height: 4)
                    Capsule()
                        .fill(LinearGradient(colors: [Prefs.shared.accentColor, Theme.amber], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, 104 * state.usage.blockProgress), height: 4)
                }
                Text("5s · \(Fmt.tokens(state.usage.blockTotal)) · \(Fmt.duration(state.usage.blockRemaining ?? 0))")
                    .font(.ui(8.5)).foregroundStyle(Color.white.opacity(0.38))
            }
        }
    }

    private var sessions: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(state.liveSessions) { session in
                    HStack(spacing: 7) {
                        Circle().fill(session.status.tint).frame(width: 6, height: 6)
                            .shadow(color: session.status.tint.opacity(0.8), radius: 3)
                        Text(session.folderName).font(.ui(11, .semibold)).foregroundStyle(Color.white.opacity(0.9))
                        Text(session.detailLine).font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.42))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(session.status.title).font(.ui(9, .medium)).foregroundStyle(session.status.tint.opacity(0.9))
                    }
                    .frame(height: 20)
                }
            }
        }
    }

    private var recents: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.recents) { project in
                    Button { Launcher.openClaude(in: project.path) } label: {
                        Text(project.name)
                            .font(.ui(11, .medium)).foregroundStyle(Color.white.opacity(0.8))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.chip))
                            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(project.path)
                }
                if state.recents.isEmpty {
                    Text("no projects yet").font(.ui(10)).foregroundStyle(Color.white.opacity(0.3))
                }
            }
        }
        .frame(height: 26)
    }

    private func pickFolder() {
        if let url = Activation.pickFolder() { Launcher.openClaude(in: url.path) }
    }
}

// MARK: - Shelf

struct ShelfModuleView: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shelf").font(.ui(12, .semibold)).foregroundStyle(.white)
                Text("\(shelf.items.count) files").font(.ui(10)).foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                if !shelf.items.isEmpty {
                    Button { shelf.clear() } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.ui(10)).foregroundStyle(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .overlay(
                        VStack(spacing: 3) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 15))
                            Text("drop files here, then drag them anywhere")
                                .font(.ui(10))
                        }
                        .foregroundStyle(Color.white.opacity(0.35))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfChip(item: item) { shelf.remove(item) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct ShelfChip: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 34, height: 34)
            Text(item.name)
                .font(.ui(9))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 62)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.chip : Color.clear))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .help(item.url.path)
    }
}

// MARK: - System

struct SystemModuleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.system
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                StatTile(title: "CPU", value: String(format: "%.0f%%", s.cpu * 100), fraction: s.cpu, tint: Theme.blue) {
                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(Array(s.cpuPerCore.prefix(12).enumerated()), id: \.offset) { _, load in
                            Capsule()
                                .fill(Theme.blue.opacity(0.85))
                                .frame(width: 3, height: max(2, 16 * load))
                        }
                    }
                    .frame(height: 16, alignment: .bottom)
                }
                StatTile(title: "RAM", value: Bytes.gigabytes(s.memoryUsed), fraction: s.memoryFraction, tint: Theme.claude) {
                    Text("/ \(Bytes.gigabytes(s.memoryTotal))")
                        .font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
                }
            }
            HStack(spacing: 8) {
                StatTile(title: "Disk", value: Bytes.gigabytes(s.diskTotal - s.diskUsed) + " free",
                         fraction: s.diskFraction, tint: Theme.green) {
                    Text("\(Int(s.diskFraction * 100))% used")
                        .font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
                }
                StatTile(title: "Network", value: "↓ \(Bytes.short(s.netDown))/s", fraction: nil, tint: Theme.amber) {
                    Text("↑ \(Bytes.short(s.netUp))/s")
                        .font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
    }
}

private struct StatTile<Accessory: View>: View {
    let title: String
    let value: String
    let fraction: Double?
    let tint: Color
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.ui(9.5, .medium)).foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                accessory()
            }
            Text(value).font(.mono(13, .semibold)).foregroundStyle(.white)
            if let fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09)).frame(height: 4)
                    GeometryReader { geo in
                        Capsule().fill(tint).frame(width: max(3, geo.size.width * fraction), height: 4)
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Battery

struct BatteryModuleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let b = state.battery
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(b.percent) / 100)
                    .stroke(ringColor(b), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(b.percent)").font(.mono(17, .bold)).foregroundStyle(.white)
                    Text("%").font(.ui(8)).foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: b.symbol).font(.system(size: 12)).foregroundStyle(ringColor(b))
                    Text(statusText(b)).font(.ui(12, .semibold)).foregroundStyle(.white)
                }
                if let minutes = b.minutesRemaining {
                    Text("\(minutes / 60)h \(minutes % 60)m \(b.charging ? "to full" : "left")")
                        .font(.ui(10)).foregroundStyle(Color.white.opacity(0.5))
                }
                HStack(spacing: 12) {
                    if let health = b.health { infoPair("Health", "\(health)%") }
                    if let cycles = b.cycles { infoPair("Cycles", "\(cycles)") }
                }
            }
            Spacer()
        }
    }

    private func infoPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.ui(9)).foregroundStyle(Color.white.opacity(0.4))
            Text(value).font(.mono(11, .medium)).foregroundStyle(Color.white.opacity(0.85))
        }
    }

    private func statusText(_ b: BatterySnapshot) -> String {
        if !b.present { return "No battery" }
        if b.charging { return "Charging" }
        if b.pluggedIn { return "Plugged in" }
        return "On battery"
    }

    private func ringColor(_ b: BatterySnapshot) -> Color {
        if b.charging { return Theme.green }
        switch b.percent {
        case ..<15: return Color(red: 0.95, green: 0.35, blue: 0.35)
        case ..<30: return Theme.amber
        default: return Theme.green
        }
    }
}

// MARK: - Timer

struct TimerModuleView: View {
    @ObservedObject private var timer = TimerStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: timer.progress)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: timer.progress)
                Text(timer.phase == .idle ? "—" : timer.display)
                    .font(.mono(15, .bold)).foregroundStyle(.white)
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 6) {
                Text(phaseLabel).font(.ui(12, .semibold)).foregroundStyle(.white)
                Text("\(timer.completedRounds) rounds done")
                    .font(.ui(10)).foregroundStyle(Color.white.opacity(0.45))
                HStack(spacing: 6) {
                    if timer.phase == .idle {
                        MiniButton(icon: "play.fill", label: "\(Int(prefs.pomodoroMinutes))m", tint: prefs.accentColor) {
                            timer.start(minutes: prefs.pomodoroMinutes)
                        }
                        MiniButton(icon: "cup.and.saucer", label: "\(Int(prefs.breakMinutes))m break", tint: Theme.green) {
                            timer.start(minutes: prefs.breakMinutes, phase: .rest)
                        }
                    } else {
                        MiniButton(icon: timer.isRunning ? "pause.fill" : "play.fill",
                                   label: timer.isRunning ? "Pause" : "Resume",
                                   tint: prefs.accentColor) {
                            timer.isRunning ? timer.pause() : timer.resume()
                        }
                        MiniButton(icon: "stop.fill", label: "Stop", tint: Theme.dim) { timer.stop() }
                    }
                }
            }
            Spacer()
        }
    }

    private var phaseLabel: String {
        switch timer.phase {
        case .idle: return "Timer ready"
        case .focus: return "Focus"
        case .rest: return "Break"
        }
    }

    private var phaseColor: Color {
        timer.phase == .rest ? Theme.green : prefs.accentColor
    }
}

// MARK: - Commands

struct CommandsModuleView: View {
    @ObservedObject private var prefs = Prefs.shared

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 200), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Quick commands").font(.ui(12, .semibold)).foregroundStyle(.white)
                Spacer()
                Text("Edit in Settings").font(.ui(9)).foregroundStyle(Color.white.opacity(0.35))
            }
            if prefs.commands.isEmpty {
                Text("No commands yet — Settings › Commands")
                    .font(.ui(10)).foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(prefs.commands) { command in
                            Button { CommandRunner.run(command) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: command.symbol).font(.system(size: 11))
                                        .foregroundStyle(prefs.accentColor)
                                    Text(command.name).font(.ui(11, .medium))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chip))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help(command.command)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Media

struct MediaModuleView: View {
    @ObservedObject private var media = MediaStore.shared

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07))
                Image(systemName: media.snapshot.playing ? "waveform" : "music.note")
                    .font(.system(size: 22))
                    .foregroundStyle(Prefs.shared.accentColor)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text(media.snapshot.available ? media.snapshot.title : "Nothing playing")
                    .font(.ui(12, .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(media.snapshot.available ? media.snapshot.artist : "Controls appear when Music is open")
                    .font(.ui(10)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
                HStack(spacing: 10) {
                    control("backward.fill") { media.previous() }
                    control(media.snapshot.playing ? "pause.fill" : "play.fill") { media.toggle() }
                    control("forward.fill") { media.next() }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .onAppear { media.refresh(force: true) }
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar

struct CalendarModuleView: View {
    @ObservedObject private var calendar = CalendarStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if calendar.authorized {
                if calendar.events.isEmpty {
                    Text("Nothing in the next 24 hours")
                        .font(.ui(11)).foregroundStyle(Color.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 3) {
                            ForEach(calendar.events) { event in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 20)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(event.title).font(.ui(11, .medium))
                                            .foregroundStyle(Color.white.opacity(0.9)).lineLimit(1)
                                        Text(event.timeLabel).font(.ui(9)).foregroundStyle(Color.white.opacity(0.42))
                                    }
                                    Spacer()
                                    Text(event.relative).font(.ui(10, .medium))
                                        .foregroundStyle(Color.white.opacity(0.55))
                                }
                                .frame(height: 24)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 18)).foregroundStyle(Color.white.opacity(0.4))
                    Text(calendar.denied ? "Calendar access denied" : "Calendar access needed")
                        .font(.ui(11)).foregroundStyle(Color.white.opacity(0.6))
                    if calendar.denied {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                        .buttonStyle(.plain)
                        .font(.ui(10, .medium))
                        .foregroundStyle(Prefs.shared.accentColor)
                    } else {
                        Button("Grant access") { Task { await calendar.requestAccess() } }
                            .buttonStyle(.plain)
                            .font(.ui(10, .medium))
                            .foregroundStyle(Prefs.shared.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { calendar.refreshIfAuthorized() }
    }
}

// MARK: - Weather

struct WeatherModuleView: View {
    @ObservedObject private var weather = WeatherStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        if prefs.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "cloud.sun").font(.system(size: 18))
                    .foregroundStyle(Color.white.opacity(0.4))
                Text("Set your city in Settings › General")
                    .font(.ui(11)).foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            forecast
        }
    }

    private var forecast: some View {
        HStack(spacing: 16) {
            Image(systemName: weather.snapshot.symbol)
                .font(.system(size: 34))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.amber, Color.white.opacity(0.8))
                .frame(width: 62)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.0f°", weather.snapshot.temperature))
                        .font(.mono(22, .bold)).foregroundStyle(.white)
                    Text(weather.snapshot.city.isEmpty ? prefs.weatherCity : weather.snapshot.city)
                        .font(.ui(11)).foregroundStyle(Color.white.opacity(0.55))
                }
                Text(weather.snapshot.summary).font(.ui(11)).foregroundStyle(Color.white.opacity(0.6))
                Text(String(format: "feels %.0f° · ↑%.0f° ↓%.0f° · wind %.0f km/h",
                            weather.snapshot.apparent, weather.snapshot.high, weather.snapshot.low, weather.snapshot.wind))
                    .font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.4))
                if let error = weather.error {
                    Text(error).font(.ui(9.5)).foregroundStyle(Theme.amber)
                }
            }
            Spacer()
        }
        .task { await weather.refresh(city: prefs.weatherCity) }
    }
}

// MARK: - Shared bits

struct MiniButton: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(label).font(.ui(10, .medium))
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(hovering ? 0.34 : 0.18)))
            .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
