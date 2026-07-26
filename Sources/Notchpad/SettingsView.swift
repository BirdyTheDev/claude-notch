import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, modules, appearance, claude, actions, commands, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .modules: return "Modules"
        case .appearance: return "Appearance"
        case .claude: return "Claude"
        case .actions: return "Actions"
        case .commands: return "Commands"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .modules: return "square.grid.2x2"
        case .appearance: return "paintbrush"
        case .claude: return "sparkle"
        case .actions: return "bolt.horizontal"
        case .commands: return "terminal"
        case .about: return "info.circle"
        }
    }
}

/// Tabs sit in the content view rather than the title bar; title-bar accessory clicks
/// are not delivered reliably to a panel owned by an accessory app.
struct SettingsView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol).font(.system(size: 14))
                            Text(item.title).font(.ui(10.5, .medium))
                        }
                        .frame(width: 78, height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(tab == item ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            Group {
                switch tab {
                case .general: GeneralTab()
                case .modules: ModulesTab()
                case .appearance: AppearanceTab()
                case .claude: ClaudeTab()
                case .actions: ActionsTab()
                case .commands: CommandsTab()
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 470)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var power = PowerStore.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        let actual = LoginItem.set(enabled: value)
                        if actual != value { launchAtLogin = actual }
                    }
                Toggle("Open on hover", isOn: $prefs.hoverToOpen)
                HStack {
                    Text("Hover delay")
                    Slider(value: $prefs.hoverDelay, in: 0...1.0, step: 0.05)
                    Text(String(format: "%.2fs", prefs.hoverDelay)).font(.mono(11)).frame(width: 62, alignment: .trailing)
                }
                Toggle("Toggle with ⌥Space", isOn: $prefs.hotkeyEnabled)
            } header: { Text("Behaviour") }

            Section {
                Picker("Left", selection: $prefs.peekLeft) {
                    ForEach(PeekSlot.allCases) { Text($0.title).tag($0) }
                }
                Picker("Right", selection: $prefs.peekRight) {
                    ForEach(PeekSlot.allCases) { Text($0.title).tag($0) }
                }
                Text("Small readouts shown either side of the closed notch.")
                    .font(.ui(10)).foregroundStyle(.secondary)
            } header: { Text("Notch edges") }

            Section {
                TextField("City", text: $prefs.weatherCity)
                HStack {
                    Text("Pomodoro")
                    Slider(value: $prefs.pomodoroMinutes, in: 5...90, step: 5)
                    Text("\(Int(prefs.pomodoroMinutes)) min").font(.mono(11)).frame(width: 50, alignment: .trailing)
                }
                HStack {
                    Text("Break")
                    Slider(value: $prefs.breakMinutes, in: 1...30, step: 1)
                    Text("\(Int(prefs.breakMinutes)) min").font(.mono(11)).frame(width: 50, alignment: .trailing)
                }
            } header: { Text("Module settings") }

            Section {
                Toggle("Stay awake while Claude works", isOn: Binding(
                    get: { power.mode == .whileClaude },
                    set: { $0 ? power.setWhileClaude() : power.turnOff() }))
                Toggle("Keep the display on too", isOn: $power.keepDisplayAwake)
                if power.lidSleepDisabled {
                    HStack {
                        Label("Lid sleep is currently disabled", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Undo") { power.enableLidSleep() }
                    }
                }
            } header: { Text("Keep awake") } footer: {
                Text("Sleep prevention ends by itself when the app quits. Keeping the Mac awake with the lid closed changes a system setting: it asks for an admin password and reverts itself when the time is up.")
                    .font(.ui(10))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Modules

private struct ModulesTab: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enabled modules become tabs in the notch. Drag to reorder.")
                .font(.ui(11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)

            List {
                ForEach(prefs.moduleOrder) { module in
                    HStack(spacing: 10) {
                        Image(systemName: module.symbol)
                            .frame(width: 20)
                            .foregroundStyle(prefs.enabledModules.contains(module) ? prefs.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.title).font(.ui(12, .medium))
                            Text(module.blurb).font(.ui(10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let permission = module.needsPermission {
                            Text(permission).font(.ui(9)).foregroundStyle(.orange)
                        }
                        Toggle("", isOn: Binding(
                            get: { prefs.enabledModules.contains(module) },
                            set: { on in
                                if on { prefs.enabledModules.insert(module) } else { prefs.enabledModules.remove(module) }
                            }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { indices, destination in
                    prefs.moduleOrder.move(fromOffsets: indices, toOffset: destination)
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { prefs.accent = choice } label: {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(prefs.accent == choice ? 0.9 : 0), lineWidth: 2)
                                        .padding(-3)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(choice.title)
                    }
                    Spacer()
                }
            } header: { Text("Accent colour") }

            Section {
                HStack {
                    Text("Panel width")
                    Slider(value: $prefs.panelWidth, in: 420...760, step: 10)
                    Text("\(Int(prefs.panelWidth))").font(.mono(11)).frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Corner radius")
                    Slider(value: $prefs.cornerRadius, in: 8...40, step: 1)
                    Text("\(Int(prefs.cornerRadius))").font(.mono(11)).frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Opacity")
                    Slider(value: $prefs.panelOpacity, in: 0.5...1, step: 0.05)
                    Text(String(format: "%.0f%%", prefs.panelOpacity * 100)).font(.mono(11)).frame(width: 40, alignment: .trailing)
                }
                Toggle("Blur the background", isOn: $prefs.useBlur)
                Toggle("Mascot eyes", isOn: $prefs.mascotEyes)
            } header: { Text("Panel") }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Claude

private struct ClaudeTab: View {
    @ObservedObject private var prefs = Prefs.shared
    private let terminals = Terminals.installed()

    var body: some View {
        Form {
            Section {
                Picker("Terminal", selection: $prefs.terminalBundleID) {
                    Text("Automatic").tag("")
                    ForEach(terminals, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                TextField("Extra arguments", text: $prefs.extraArgs, prompt: Text("--model opus"))
                Toggle("Show token usage", isOn: $prefs.showUsage)
            } header: { Text("Sessions") } footer: {
                Text("Every session starts with --dangerously-skip-permissions. The terminal is opened through a throwaway .command file instead of AppleScript, so macOS never asks for Automation permission.")
                    .font(.ui(10))
            }

            Section {
                LabeledContent("claude") { Text(Launcher.claudeBinary).font(.mono(10)).foregroundStyle(.secondary) }
                LabeledContent("hook") { Text("~/.claude/hooks/notchpad-hook.py").font(.mono(10)).foregroundStyle(.secondary) }
                LabeledContent("socket") { Text(SessionServer.socketPath).font(.mono(10)).foregroundStyle(.secondary) }
            } header: { Text("Paths") }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Commands

private struct CommandsTab: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($prefs.commands) { $command in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: command.symbol.isEmpty ? "terminal" : command.symbol)
                                .foregroundStyle(prefs.accentColor).frame(width: 18)
                            TextField("Name", text: $command.name).textFieldStyle(.plain).font(.ui(12, .medium))
                            Toggle("In terminal", isOn: $command.inTerminal)
                                .toggleStyle(.checkbox).controlSize(.mini).font(.ui(10))
                            Button {
                                prefs.commands.removeAll { $0.id == command.id }
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            TextField("SF Symbol", text: $command.symbol)
                                .textFieldStyle(.roundedBorder).font(.mono(10)).frame(width: 110)
                            TextField("Command", text: $command.command)
                                .textFieldStyle(.roundedBorder).font(.mono(10))
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onMove { prefs.commands.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)

            HStack {
                Button {
                    prefs.commands.append(QuickCommand(name: "New command", symbol: "bolt", command: "echo hello", inTerminal: true))
                } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Text("With “In terminal” off, the command runs quietly in the background.")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

// MARK: - Actions

private struct ActionsTab: View {
    @ObservedObject private var store = ActionsStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($store.actions) { $action in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: action.symbol.isEmpty ? "bolt" : action.symbol)
                                .foregroundStyle(prefs.accentColor).frame(width: 18)
                            TextField("Name", text: $action.name).textFieldStyle(.plain).font(.ui(12, .medium))
                            Button {
                                store.actions.removeAll { $0.id == action.id }
                            } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            TextField("SF Symbol", text: $action.symbol)
                                .textFieldStyle(.roundedBorder).font(.mono(10)).frame(width: 110)
                            TextField("/command or prompt", text: $action.prompt)
                                .textFieldStyle(.roundedBorder).font(.mono(10))
                        }
                        HStack(spacing: 6) {
                            TextField("Folder (empty = last project)", text: $action.folder)
                                .textFieldStyle(.roundedBorder).font(.mono(10))
                            Button("Choose…") {
                                if let url = Activation.pickFolder() { action.folder = url.path }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onMove { store.actions.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)

            HStack {
                Button {
                    store.actions.append(ClaudeAction(name: "New action", symbol: "bolt",
                                                      prompt: "/code-review", folder: ""))
                } label: { Label("Add", systemImage: "plus") }
                Button("Restore defaults") { store.actions = ClaudeAction.seeds }
                    .controlSize(.small)
                Spacer()
                Text("\(store.discovered.count) found in ~/.claude")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            ClaudeMark().fill(Prefs.shared.accentColor).frame(width: 54, height: 54)
            Text("Notchpad").font(.ui(17, .semibold))
            Text("version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.ui(11)).foregroundStyle(.secondary)
            Text("Turns the MacBook notch into a Claude Code panel, a file shelf, a system monitor and a timer.")
                .font(.ui(11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            HStack(spacing: 10) {
                Button("Reveal app") {
                    NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "/Applications")
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
