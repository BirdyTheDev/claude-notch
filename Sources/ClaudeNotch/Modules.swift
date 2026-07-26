import SwiftUI

/// Everything the notch can show. Order and enabled-state are user controlled.
enum ModuleKind: String, CaseIterable, Codable, Identifiable {
    case claude
    case usage
    case actions
    case unity
    case mcp
    case shelf
    case system
    case memory
    case power
    case battery
    case timer
    case commands
    case media
    case calendar
    case weather

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .usage: return "Usage"
        case .actions: return "Actions"
        case .unity: return "Unity"
        case .mcp: return "MCP"
        case .memory: return "Memory"
        case .power: return "Awake"
        case .shelf: return "Shelf"
        case .system: return "System"
        case .battery: return "Battery"
        case .timer: return "Timer"
        case .commands: return "Commands"
        case .media: return "Music"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .usage: return "chart.bar"
        case .actions: return "bolt.horizontal"
        case .unity: return "cube.transparent"
        case .mcp: return "app.connected.to.app.below.fill"
        case .memory: return "memorychip"
        case .power: return "cup.and.saucer"
        case .shelf: return "tray.full"
        case .system: return "cpu"
        case .battery: return "battery.100"
        case .timer: return "timer"
        case .commands: return "terminal"
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        }
    }

    var blurb: String {
        switch self {
        case .claude: return "Live sessions, token usage, launch from a folder"
        case .usage: return "Daily and weekly tokens, split by model and project"
        case .unity: return "Hub projects, the open editor, compile errors"
        case .mcp: return "Configured MCP servers and whether they answer"
        case .actions: return "Run slash commands and prompts in one click"
        case .memory: return "Memory pressure, swap, the biggest offenders"
        case .power: return "Keep awake, automatically while Claude works"
        case .shelf: return "Park files in the notch for a moment"
        case .system: return "CPU, memory, disk, network"
        case .battery: return "Charge state and time left"
        case .timer: return "Pomodoro and countdown"
        case .commands: return "Your own shortcut commands"
        case .media: return "Control the Music app"
        case .calendar: return "What is coming up"
        case .weather: return "Weather for your city"
        }
    }

    /// Height of the module's body inside the open panel.
    var bodyHeight: CGFloat {
        switch self {
        case .claude: return 118
        case .usage: return 128
        case .unity: return 126
        case .mcp: return 124
        case .actions: return 124
        case .memory: return 126
        case .power: return 118
        case .shelf: return 118
        case .system: return 118
        case .battery: return 104
        case .timer: return 110
        case .commands: return 118
        case .media: return 104
        case .calendar: return 118
        case .weather: return 110
        }
    }

    /// Modules that need a macOS permission the first time they are used.
    var needsPermission: String? {
        switch self {
        case .calendar: return "Calendar access"
        case .media: return "Automation permission"
        default: return nil
        }
    }

    static let defaultOrder: [ModuleKind] = [.claude, .usage, .actions, .unity, .mcp, .shelf, .power,
                                             .system, .memory, .timer, .commands, .battery, .media,
                                             .calendar, .weather]
    static let defaultEnabled: Set<ModuleKind> = [.claude, .usage, .actions, .unity, .mcp, .shelf, .power, .system, .timer]
}

/// What the collapsed notch shows on either side of the hardware cutout.
enum PeekSlot: String, CaseIterable, Codable, Identifiable {
    case none, claude, battery, cpu, memory, network, timer, media, clock, weather, caffeine, agenda, mcp, tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .claude: return "Claude status"
        case .battery: return "Battery"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .timer: return "Timer"
        case .media: return "Music"
        case .clock: return "Clock"
        case .weather: return "Temperature"
        case .caffeine: return "Keep awake"
        case .mcp: return "MCP bridge"
        case .tokens: return "Tokens today"
        case .agenda: return "Next event"
        }
    }

    var width: CGFloat {
        switch self {
        case .none: return 0
        case .claude: return 34
        case .media: return 34
        case .caffeine: return 34
        case .mcp: return 34
        case .tokens: return 62
        case .agenda: return 72
        case .network: return 70
        case .clock: return 56
        default: return 60
        }
    }
}
