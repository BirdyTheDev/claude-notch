import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac awake. Two very different mechanisms:
///
/// * A power assertion (`IOPMAssertion`) prevents idle sleep and dies with this process —
///   safe, no password, no lasting effect.
/// * Lid-close sleep can only be disabled with `pmset -a disablesleep 1`, which is a
///   *persistent system setting*. It is handled by a privileged helper that restores the
///   setting itself, so a crash here can never leave the machine unable to sleep.
@MainActor
final class PowerStore: ObservableObject {
    static let shared = PowerStore()

    enum Mode: String, CaseIterable {
        case off, indefinite, timed, whileClaude

        var title: String {
            switch self {
            case .off: return "Off"
            case .indefinite: return "Indefinite"
            case .timed: return "Timed"
            case .whileClaude: return "While Claude works"
            }
        }
    }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var expiry: Date?
    @Published private(set) var holdingAssertion = false
    @Published var keepDisplayAwake = false {
        didSet {
            UserDefaults.standard.set(keepDisplayAwake, forKey: "keepDisplayAwake")
            if holdingAssertion { reassert() }
        }
    }
    /// True while the privileged helper is holding lid-close sleep off.
    @Published private(set) var lidSleepDisabled = false
    @Published private(set) var lidExpiry: Date?

    private var assertionID: IOPMAssertionID = 0
    private let sentinel = "/tmp/claude-notch-lid-awake"

    private init() {
        keepDisplayAwake = UserDefaults.standard.bool(forKey: "keepDisplayAwake")
        refreshLidState()
    }

    var remaining: TimeInterval? {
        guard let expiry else { return nil }
        return max(0, expiry.timeIntervalSinceNow)
    }

    var statusLine: String {
        switch mode {
        case .off: return "Sleep is normal"
        case .indefinite: return "Awake indefinitely"
        case .timed:
            guard let remaining else { return "Timed" }
            return "\(Fmt.duration(remaining)) left"
        case .whileClaude:
            return holdingAssertion ? "Claude is working — awake" : "Claude is idle"
        }
    }

    // MARK: modes

    func setIndefinite() {
        mode = .indefinite
        expiry = nil
        assert(true)
    }

    func setTimed(minutes: Double) {
        mode = .timed
        expiry = Date().addingTimeInterval(minutes * 60)
        assert(true)
    }

    func setWhileClaude() {
        mode = .whileClaude
        expiry = nil
        assert(false)
    }

    func turnOff() {
        mode = .off
        expiry = nil
        assert(false)
    }

    /// Called on every sensor tick: expires timed mode and follows Claude's state.
    func tick(claudeBusy: Bool) {
        switch mode {
        case .timed:
            if let expiry, Date() >= expiry { turnOff() }
        case .whileClaude:
            if claudeBusy != holdingAssertion { assert(claudeBusy) }
        default:
            break
        }
        if lidSleepDisabled, let lidExpiry, Date() >= lidExpiry {
            refreshLidState()
        }
    }

    // MARK: assertion

    private func assert(_ on: Bool) {
        if on {
            guard !holdingAssertion else { return }
            let type = (keepDisplayAwake ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                         : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Claude Notch — keep awake" as CFString,
                                                     &id)
            guard result == kIOReturnSuccess else {
                Launcher.onError?("Could not keep the Mac awake")
                return
            }
            assertionID = id
            holdingAssertion = true
        } else {
            guard holdingAssertion else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            holdingAssertion = false
        }
    }

    private func reassert() {
        assert(false)
        assert(true)
    }

    /// Always called on quit — the assertion would die with the process anyway,
    /// this just makes it explicit.
    func releaseEverything() {
        assert(false)
    }

    // MARK: lid close

    /// Disables lid-close sleep for a bounded time using one privileged helper.
    /// The helper restores the setting when the sentinel file disappears or the
    /// deadline passes, so neither a crash nor a force-quit can leave it on.
    func disableLidSleep(hours: Double) {
        let seconds = Int(hours * 3600)
        FileManager.default.createFile(atPath: sentinel, contents: Data())

        // The helper is written to disk rather than inlined, so nothing has to survive
        // three levels of shell/AppleScript quoting.
        let helperPath = NSTemporaryDirectory() + "claude-notch-lid-helper.sh"
        let helper = """
        #!/bin/sh
        /usr/bin/pmset -a disablesleep 1
        deadline=$(( $(date +%s) + \(seconds) ))
        while [ -f "\(sentinel)" ] && [ $(date +%s) -lt $deadline ]; do sleep 5; done
        /usr/bin/pmset -a disablesleep 0
        rm -f "\(sentinel)"
        """
        do {
            try helper.write(toFile: helperPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)
        } catch {
            Launcher.onError?("Could not write the helper script")
            return
        }
        let script = "do shell script \"nohup \(helperPath) >/dev/null 2>&1 &\" with administrator privileges"
        Task.detached {
            let ok = Self.runOSA(script)
            await MainActor.run {
                if ok {
                    self.lidExpiry = Date().addingTimeInterval(hours * 3600)
                } else {
                    try? FileManager.default.removeItem(atPath: self.sentinel)
                    Launcher.onError?("Could not change the lid setting")
                }
                self.refreshLidState()
            }
        }
    }

    /// Early cancel: removing the sentinel makes the helper restore the setting itself.
    func enableLidSleep() {
        try? FileManager.default.removeItem(atPath: sentinel)
        lidExpiry = nil
        // The helper polls every 5s; reflect the intent immediately.
        lidSleepDisabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.refreshLidState() }
    }

    func refreshLidState() {
        let sentinelExists = FileManager.default.fileExists(atPath: sentinel)
        Task.detached {
            let out = Self.run("/usr/bin/pmset", ["-g"])
            let disabled = out.range(of: "SleepDisabled[ \t]+1\\b", options: .regularExpression) != nil
            await MainActor.run {
                self.lidSleepDisabled = disabled
                if !disabled { self.lidExpiry = nil }
                // Setting is on but nobody is holding it: offer a one-tap fix in the UI.
                if disabled && !sentinelExists { self.lidExpiry = nil }
            }
        }
    }

    /// True when lid sleep is off with no helper watching it — a state worth shouting about.
    var lidLeftOnUnmanaged: Bool {
        lidSleepDisabled && !FileManager.default.fileExists(atPath: sentinel)
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func runOSA(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
