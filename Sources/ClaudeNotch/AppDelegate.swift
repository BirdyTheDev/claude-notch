import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private let usage = UsageStore()
    private let sensors = SystemMonitor()

    private var window: NotchWindow?
    private var server: SessionServer?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var hotkey: Hotkey?

    private var monitors: [Any] = []
    private var slowTimer: Timer?
    private var fastTimer: Timer?
    private var pointerTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?

    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NotchWindow(state: state)
        self.window = window

        server = SessionServer { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated { self.state.apply(event: event) }
        }
        server?.start()

        Launcher.onError = { [weak self] message in
            MainActor.assumeIsolated {
                self?.state.flash(message)
                self?.state.expanded = true
            }
        }
        Launcher.sweepOldLaunchScripts()

        installMenuBarItem()
        installMouseMonitors()
        applyHotkeyPreference()

        NotificationCenter.default.addObserver(forName: .openPreferences, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionWindow() }
        }

        state.recents = ProjectScanner.recents()
        refreshFast()
        refreshSlow()

        // Sensors and the clock tick often; transcripts and projects can lag behind.
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFast() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSlow() }
        }

        if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SHOW_PREFS"] != nil { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        PowerStore.shared.releaseEverything()
        // Drops the sentinel so the privileged helper restores lid sleep within seconds,
        // instead of leaving it off until its deadline with no UI left to cancel it.
        PowerStore.shared.enableLidSleep()
        [slowTimer, fastTimer, pointerTimer].forEach { $0?.invalidate() }
        hotkey?.unregister()
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: refresh

    private func refreshFast() {
        state.clockText = clockFormatter.string(from: Date())

        // Keep-awake follows Claude: any session that is thinking or running a tool counts.
        let busy = state.liveSessions.contains {
            $0.status == .processing || $0.status == .runningTool || $0.status == .compacting
        }
        PowerStore.shared.tick(claudeBusy: busy)
        updateStatusIcon()
        if state.expanded && state.activeModule == .memory { MemoryStore.shared.refresh() }
        let monitor = sensors
        Task.detached(priority: .utility) {
            let system = monitor.read()
            let battery = BatteryReader.read()
            await MainActor.run {
                self.state.system = system
                self.state.battery = battery
            }
        }
    }

    private func refreshSlow() {
        state.pruneDeadSessions()
        state.recents = ProjectScanner.recents()
        Task { [usage] in
            let snapshot = await usage.refresh()
            await MainActor.run { self.state.usage = snapshot }
        }
        MediaStore.shared.refresh()
        PowerStore.shared.refreshLidState()
        let enabled = Prefs.shared.enabledModules
        if enabled.contains(.memory) { MemoryStore.shared.refresh() }
        if enabled.contains(.unity) { UnityStore.shared.reload() }
        if enabled.contains(.mcp) || enabled.contains(.unity) || Prefs.shared.peekLeft == .mcp || Prefs.shared.peekRight == .mcp {
            MCPStore.shared.reload()
            MCPStore.shared.probe()
        }
        if enabled.contains(.actions) { ActionsStore.shared.discover() }
        Task { await WeatherStore.shared.refresh(city: Prefs.shared.weatherCity) }
        CalendarStore.shared.refreshIfAuthorized()
    }

    /// The menu-bar icon carries the session colour — it is the only part of the app
    /// visible while the panel is closed and the pointer is elsewhere.
    private var lastIconStatus: SessionStatus?

    private func updateStatusIcon() {
        let status = state.status
        guard status != lastIconStatus, let button = statusItem?.button else { return }
        lastIconStatus = status
        let name = status == .waitingForApproval ? "sparkle.magnifyingglass" : "sparkle"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Claude Notch") else { return }
        if status == .idle {
            base.isTemplate = true
            button.image = base
        } else {
            let tinted = base.withSymbolConfiguration(.init(paletteColors: [status.nsTint])) ?? base
            tinted.isTemplate = false
            button.image = tinted
        }
    }

    private func repositionWindow() {
        guard let window else { return }
        let screen = NotchMetrics.screen
        let size = window.frame.size
        window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2,
                                      y: screen.frame.maxY - size.height))
        window.orderFrontRegardless()
    }

    // MARK: hover + hotkey

    private func installMouseMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluatePointer() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            MainActor.assumeIsolated { self.evaluatePointer() }
            return event
        }) {
            monitors.append(local)
        }
        // Catches drags in progress, where mouseMoved events are not delivered.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluatePointer() }
        }
    }

    private func evaluatePointer() {
        guard let window else { return }
        let point = NSEvent.mouseLocation

        // The window is grown before the panel opens and shrunk once it has closed, so it
        // never covers more of the screen than it draws on.
        let open = state.expanded || state.dragging
        if open {
            shrinkWork?.cancel()
            shrinkWork = nil
            window.applyFrame(expanded: true)
        } else if shrinkWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window else { return }
                if !self.state.expanded && !self.state.dragging { window.applyFrame(expanded: false) }
                self.shrinkWork = nil
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        if state.expanded {
            if !window.panelZone.contains(point) { scheduleCollapse() } else { cancelCollapse() }
        } else if Prefs.shared.hoverToOpen, window.hoverZone.contains(point) {
            cancelCollapse()
            let delay = Prefs.shared.hoverDelay
            if delay <= 0 {
                state.expanded = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let window = self.window else { return }
                    if window.hoverZone.contains(NSEvent.mouseLocation) { self.state.expanded = true }
                }
            }
        }
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func scheduleCollapse() {
        guard collapseWork == nil, !state.pinned else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            if !window.panelZone.contains(NSEvent.mouseLocation), !self.state.dragging, !self.state.pinned {
                self.state.expanded = false
            }
            self.collapseWork = nil
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func applyHotkeyPreference() {
        if Prefs.shared.hotkeyEnabled {
            if hotkey == nil {
                hotkey = Hotkey { [weak self] in
                    guard let self else { return }
                    self.state.pinned.toggle()
                    self.state.expanded = self.state.pinned
                }
            }
            hotkey?.register()
        } else {
            hotkey?.unregister()
        }
    }

    // MARK: menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Notch")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "New session (skip permissions)", action: #selector(newChat), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Choose folder…", action: #selector(chooseFolder), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pin / unpin panel", action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(reloadAll), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func newChat() {
        Launcher.openClaude(in: state.recents.first?.path ?? NSHomeDirectory())
    }

    @objc private func chooseFolder() {
        if let url = Activation.pickFolder() { Launcher.openClaude(in: url.path) }
    }

    @objc private func togglePanel() {
        state.pinned.toggle()
        state.expanded = state.pinned
    }

    @objc private func reloadAll() {
        refreshSlow()
        refreshFast()
    }

    @objc private func showSettingsMenu() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            // A menu-bar-only app is not allowed to bring itself to the front on macOS 26,
            // so a plain window would never become key and every click would be swallowed.
            // A non-activating panel can take key focus without the app activating at all.
            let panel = SettingsPanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 470),
                                      styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            panel.title = "Claude Notch Settings"
            panel.contentView = ClickThroughHostingView(rootView: SettingsView())
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .floating
            panel.delegate = self
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        applyHotkeyPreference()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
