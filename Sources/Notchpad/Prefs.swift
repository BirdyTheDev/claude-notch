import SwiftUI

enum AccentChoice: String, CaseIterable, Identifiable {
    case claude, blue, green, purple, pink, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .blue: return "Blue"
        case .green: return "Green"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .mono: return "Grey"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.851, green: 0.467, blue: 0.341)
        case .blue: return Color(red: 0.36, green: 0.62, blue: 0.98)
        case .green: return Color(red: 0.36, green: 0.80, blue: 0.52)
        case .purple: return Color(red: 0.66, green: 0.51, blue: 0.96)
        case .pink: return Color(red: 0.95, green: 0.46, blue: 0.68)
        case .mono: return Color(white: 0.78)
        }
    }
}

/// Everything the user can change, persisted in UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    // Modules
    @Published var moduleOrder: [ModuleKind] { didSet { save(moduleOrder.map(\.rawValue), "moduleOrder") } }
    @Published var enabledModules: Set<ModuleKind> { didSet { save(enabledModules.map(\.rawValue).sorted(), "enabledModules") } }
    @Published var lastModule: ModuleKind { didSet { d.set(lastModule.rawValue, forKey: "lastModule") } }

    // Peek
    @Published var peekLeft: PeekSlot { didSet { d.set(peekLeft.rawValue, forKey: "peekLeft") } }
    @Published var peekRight: PeekSlot { didSet { d.set(peekRight.rawValue, forKey: "peekRight") } }

    // Appearance
    @Published var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }
    @Published var panelWidth: Double { didSet { d.set(panelWidth, forKey: "panelWidth") } }
    @Published var cornerRadius: Double { didSet { d.set(cornerRadius, forKey: "cornerRadius") } }
    @Published var panelOpacity: Double { didSet { d.set(panelOpacity, forKey: "panelOpacity") } }
    @Published var useBlur: Bool { didSet { d.set(useBlur, forKey: "useBlur") } }

    // Behaviour
    @Published var hoverToOpen: Bool { didSet { d.set(hoverToOpen, forKey: "hoverToOpen") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var mascotEyes: Bool { didSet { d.set(mascotEyes, forKey: "mascotEyes") } }

    // Claude module
    @Published var terminalBundleID: String { didSet { d.set(terminalBundleID, forKey: "terminalBundleID") } }
    @Published var extraArgs: String { didSet { d.set(extraArgs, forKey: "extraArgs") } }
    @Published var showUsage: Bool { didSet { d.set(showUsage, forKey: "showUsage") } }

    // Timer module
    @Published var pomodoroMinutes: Double { didSet { d.set(pomodoroMinutes, forKey: "pomodoroMinutes") } }
    @Published var breakMinutes: Double { didSet { d.set(breakMinutes, forKey: "breakMinutes") } }

    // Weather module
    @Published var weatherCity: String { didSet { d.set(weatherCity, forKey: "weatherCity") } }

    // Commands module
    @Published var commands: [QuickCommand] { didSet { saveCommands() } }

    private init() {
        Prefs.migrateFromLegacyDomain(into: d)
        d.register(defaults: [
            "hoverToOpen": true, "showUsage": true, "mascotEyes": true, "hotkeyEnabled": true,
            "panelWidth": 580.0, "cornerRadius": 26.0, "panelOpacity": 1.0, "hoverDelay": 0.0,
            "pomodoroMinutes": 25.0, "breakMinutes": 5.0, "useBlur": false,
        ])

        let order = (d.array(forKey: "moduleOrder") as? [String])?.compactMap(ModuleKind.init) ?? ModuleKind.defaultOrder
        // Any module added in a later version lands at the end rather than disappearing.
        moduleOrder = order + ModuleKind.allCases.filter { !order.contains($0) }
        if let saved = d.array(forKey: "enabledModules") as? [String] {
            enabledModules = Set(saved.compactMap(ModuleKind.init))
        } else {
            enabledModules = ModuleKind.defaultEnabled
        }
        lastModule = ModuleKind(rawValue: d.string(forKey: "lastModule") ?? "") ?? .claude
        peekLeft = PeekSlot(rawValue: d.string(forKey: "peekLeft") ?? "") ?? .claude
        peekRight = PeekSlot(rawValue: d.string(forKey: "peekRight") ?? "") ?? .battery
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .claude
        panelWidth = d.double(forKey: "panelWidth")
        cornerRadius = d.double(forKey: "cornerRadius")
        panelOpacity = d.double(forKey: "panelOpacity")
        useBlur = d.bool(forKey: "useBlur")
        hoverToOpen = d.bool(forKey: "hoverToOpen")
        hoverDelay = d.double(forKey: "hoverDelay")
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        mascotEyes = d.bool(forKey: "mascotEyes")
        terminalBundleID = d.string(forKey: "terminalBundleID") ?? ""
        extraArgs = d.string(forKey: "extraArgs") ?? ""
        showUsage = d.bool(forKey: "showUsage")
        pomodoroMinutes = d.double(forKey: "pomodoroMinutes")
        breakMinutes = d.double(forKey: "breakMinutes")
        weatherCity = d.string(forKey: "weatherCity") ?? ""
        commands = Prefs.loadCommands(d) ?? QuickCommand.samples
    }

    /// The app was called Claude Notch until 2.3. Carry the old preferences and support
    /// folder over so an existing setup survives the rename.
    private static func migrateFromLegacyDomain(into d: UserDefaults) {
        guard d.object(forKey: "migratedFromClaudeNotch") == nil else { return }
        let legacy = "com.claudenotch.app"
        if let old = UserDefaults(suiteName: legacy)?.persistentDomain(forName: legacy) {
            for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent("ClaudeNotch")
        let to = support.appendingPathComponent("Notchpad")
        if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
            try? FileManager.default.moveItem(at: from, to: to)
        }
        d.set(true, forKey: "migratedFromClaudeNotch")
    }

    /// Enabled modules in the user's order — what the tab bar shows.
    var activeModules: [ModuleKind] {
        let list = moduleOrder.filter { enabledModules.contains($0) }
        return list.isEmpty ? [.claude] : list
    }

    var accentColor: Color { accent.color }

    private func save(_ value: [String], _ key: String) { d.set(value, forKey: key) }

    private func saveCommands() {
        if let data = try? JSONEncoder().encode(commands) { d.set(data, forKey: "commands") }
    }

    private static func loadCommands(_ d: UserDefaults) -> [QuickCommand]? {
        guard let data = d.data(forKey: "commands") else { return nil }
        return try? JSONDecoder().decode([QuickCommand].self, from: data)
    }
}

struct QuickCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var command: String
    /// Run in a terminal window instead of silently in the background.
    var inTerminal: Bool

    static let samples: [QuickCommand] = [
        QuickCommand(name: "Restart Finder", symbol: "arrow.clockwise", command: "killall Finder", inTerminal: false),
        QuickCommand(name: "Flush DNS", symbol: "network", command: "sudo dscacheutil -flushcache", inTerminal: true),
        QuickCommand(name: "Empty trash", symbol: "trash", command: "osascript -e 'tell application \"Finder\" to empty trash'", inTerminal: false),
    ]
}
