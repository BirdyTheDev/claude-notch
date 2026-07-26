import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global ⌥Space hotkey via Carbon — unlike an NSEvent key monitor, this needs no
/// Accessibility permission.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        guard ref == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x434E4348), id: 1)   // 'CNCH'
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            if pressed.id == 1 {
                let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotkey.action() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { unregister() }
}

/// The app lives as an `.accessory` (menu-bar-only) process, which cannot take keyboard
/// focus — its windows never become key and clicks land nowhere. Whenever real UI is on
/// screen we temporarily become a regular app, then drop back so no Dock icon lingers.
@MainActor
enum Activation {
    private static var depth = 0

    static func beginForeground() {
        depth += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func endForeground() {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Folder picker that actually receives clicks.
    static func pickFolder() -> URL? {
        beginForeground()
        defer { endForeground() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open with Claude"
        panel.level = .modalPanel
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Passes the activating click through to the control under the cursor. Without it,
/// the first click on an inactive window is consumed by the activation itself.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor @preconcurrency required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Settings live in a floating non-activating panel so they work without the
/// menu-bar-only app ever becoming the frontmost application.
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
