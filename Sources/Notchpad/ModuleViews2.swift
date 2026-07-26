import AppKit
import SwiftUI

// MARK: - Actions

struct ActionsModuleView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var store = ActionsStore.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var showDiscovered = false
    /// Set by the folder picker: where the next action runs.
    @State private var overrideFolder: String?

    private var targetFolder: String {
        overrideFolder ?? state.liveSessions.first?.cwd ?? state.recents.first?.path ?? NSHomeDirectory()
    }

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(showDiscovered ? "Discovered" : "Actions")
                    .font(.ui(12, .semibold)).foregroundStyle(.white)
                Text((targetFolder as NSString).lastPathComponent)
                    .font(.ui(10)).foregroundStyle(prefs.accentColor.opacity(0.9))
                    .help(targetFolder)
                if overrideFolder != nil {
                    Button { overrideFolder = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Back to the last project")
                }
                Spacer()
                if !store.discovered.isEmpty {
                    Button { showDiscovered.toggle() } label: {
                        Text(showDiscovered ? "back" : "\(store.discovered.count) found")
                            .font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                Button { if let url = Activation.pickFolder() { overrideFolder = url.path } } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Run somewhere else")
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(showDiscovered ? store.discovered : store.actions) { action in
                        ActionChip(action: action, accent: prefs.accentColor) {
                            store.run(action, fallbackFolder: targetFolder)
                            state.flash("\(action.name) → \((targetFolder as NSString).lastPathComponent)")
                        } onAdopt: {
                            store.adopt(action)
                            showDiscovered = false
                        }
                    }
                }
            }
        }
        .onAppear { store.discover() }
    }

}

private struct ActionChip: View {
    let action: ClaudeAction
    let accent: Color
    let onRun: () -> Void
    let onAdopt: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 6) {
                Image(systemName: action.symbol).font(.system(size: 11)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(action.name).font(.ui(11, .medium))
                        .foregroundStyle(Color.white.opacity(0.9)).lineLimit(1)
                    if action.source != .user && action.source != .builtin {
                        Text(action.source.label).font(.ui(8.5)).foregroundStyle(Color.white.opacity(0.35))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? accent.opacity(0.18) : Theme.chip))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // A Button nested inside another Button never receives the click, so the pin
        // rides on top as an overlay.
        .overlay(alignment: .topTrailing) {
            if hovering, action.source != .user, action.source != .builtin {
                Button(action: onAdopt) {
                    Image(systemName: "pin.circle.fill").font(.system(size: 12))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Pin to actions")
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
        .help(action.detail ?? action.prompt)
    }
}

// MARK: - Power / caffeine

struct PowerModuleView: View {
    @ObservedObject private var power = PowerStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(power.holdingAssertion ? prefs.accentColor.opacity(0.22) : Color.white.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Image(systemName: power.holdingAssertion ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 18))
                        .foregroundStyle(power.holdingAssertion ? prefs.accentColor : Color.white.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(power.statusLine).font(.ui(12, .semibold)).foregroundStyle(.white)
                    Text(power.mode == .whileClaude
                         ? "sleep is blocked while a session runs"
                         : (power.keepDisplayAwake ? "display stays on too" : "display may sleep, the system will not"))
                        .font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
            }

            HStack(spacing: 6) {
                modeButton("Off", "xmark", active: power.mode == .off) { power.turnOff() }
                modeButton("Claude", "sparkle", active: power.mode == .whileClaude) { power.setWhileClaude() }
                modeButton("1 hour", "clock", active: power.mode == .timed) { power.setTimed(minutes: 60) }
                modeButton("Forever", "infinity", active: power.mode == .indefinite) { power.setIndefinite() }
                Spacer()
            }

            HStack(spacing: 8) {
                Toggle("Display too", isOn: $power.keepDisplayAwake)
                    .toggleStyle(.checkbox).controlSize(.mini)
                    .font(.ui(10)).foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                lidControl
            }
        }
    }

    @ViewBuilder
    private var lidControl: some View {
        if power.lidSleepDisabled {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(Theme.amber)
                Text(power.lidLeftOnUnmanaged ? "Lid sleep off (unmanaged)" : "Awake with the lid closed")
                    .font(.ui(9.5)).foregroundStyle(Theme.amber)
                MiniButton(icon: "arrow.uturn.backward", label: "Undo", tint: Theme.amber) {
                    power.enableLidSleep()
                }
            }
        } else {
            MiniButton(icon: "laptopcomputer", label: "Lid closed, 2h", tint: Theme.blue) {
                power.disableLidSleep(hours: 2)
            }
        }
    }

    private func modeButton(_ label: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(label).font(.ui(10, .medium))
            }
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.6))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(active ? prefs.accentColor.opacity(0.3) : Theme.chip))
            .overlay(Capsule().stroke(active ? prefs.accentColor.opacity(0.55) : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Memory

struct MemoryModuleView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var memory = MemoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(memory.pressureColor).frame(width: 7, height: 7)
                        Text("Pressure: \(memory.pressureTitle)").font(.ui(11, .semibold)).foregroundStyle(.white)
                    }
                    Text("\(Bytes.gigabytes(state.system.memoryUsed)) / \(Bytes.gigabytes(state.system.memoryTotal)) · swap \(Bytes.gigabytes(memory.swapUsed))")
                        .font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                MiniButton(icon: memory.purging ? "hourglass" : "trash",
                           label: memory.lastPurgeResult ?? "Free memory", tint: Theme.dim) {
                    memory.purgeInactive()
                }
                .help("Runs purge — asks for an admin password, and does little on Apple Silicon")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(memory.apps) { app in
                        HStack(spacing: 7) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            }
                            Text(app.name).font(.ui(11)).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Bytes.gigabytes(app.bytes)).font(.mono(10)).foregroundStyle(Color.white.opacity(0.55))
                            Button { memory.quit(app) } label: {
                                Image(systemName: "xmark.circle").font(.system(size: 10))
                                    .foregroundStyle(Color.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .help("Quit \(app.name)")
                        }
                        .frame(height: 18)
                    }
                    if memory.apps.isEmpty {
                        Text("reading…").font(.ui(10)).foregroundStyle(Color.white.opacity(0.3))
                    }
                }
            }
        }
        .onAppear { memory.refresh() }
    }
}
