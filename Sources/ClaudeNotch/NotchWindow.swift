import AppKit
import SwiftUI

enum NotchMetrics {
    /// Physical notch size on the built-in display, with a sane fallback for notch-less Macs.
    static func notchSize(for screen: NSScreen) -> CGSize {
        let height = max(screen.safeAreaInsets.top, 32)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 40 { return CGSize(width: width, height: height) }
        }
        return CGSize(width: 200, height: height)
    }

    static var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The window is sized once, generously; each module drives the visible panel height.
    static let maxPanelWidth: CGFloat = 760
    static let maxExpandedHeight: CGFloat = 260
    static let windowPadding: CGFloat = 24
}

/// Borderless panel pinned over the notch. Transparent while collapsed, so the
/// hardware notch itself is what you see.
final class NotchWindow: NSPanel {
    private let passthrough = PassthroughView()
    private var state: AppState

    init(state: AppState) {
        self.state = state
        let screen = NotchMetrics.screen
        let size = CGSize(width: NotchMetrics.maxPanelWidth + NotchMetrics.windowPadding * 2,
                          height: NotchMetrics.maxExpandedHeight + NotchMetrics.windowPadding)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - size.height)

        super.init(contentRect: CGRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Just above the menu bar — high enough to cover the notch, low enough that
        // AppKit still routes drag sessions to this panel.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true   // flipped on only while the pointer is over the island
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let notch = NotchMetrics.notchSize(for: screen)
        let hosting = NSHostingView(rootView: NotchView(notchSize: notch).environmentObject(state))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        passthrough.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: passthrough.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: passthrough.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: passthrough.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: passthrough.bottomAnchor),
        ])
        contentView = passthrough

        passthrough.activeRect = { [weak self] in
            guard let self else { return .zero }
            let bounds = self.passthrough.bounds
            if self.state.expanded || self.state.dragging {
                let height = self.state.expandedHeight
                let width = self.state.dragging ? Prefs.shared.panelWidth : Prefs.shared.panelWidth
                return CGRect(x: (bounds.width - width) / 2 - 8,
                              y: bounds.height - height - 8,
                              width: width + 16,
                              height: height + 8)
            }
            // Collapsed: only the island itself is live, so the menu bar keeps working.
            let width = self.state.collapsedWidth(notch: notch)
            return CGRect(x: (bounds.width - width) / 2 - 6,
                          y: bounds.height - notch.height,
                          width: width + 12,
                          height: notch.height)
        }

        passthrough.onDragState = { [weak self] active in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.state.dragging = active
                if !active { self.state.dropTarget = nil }
            }
        }
        passthrough.onDragMove = { [weak self] point in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Left half opens Claude, right half stashes on the shelf.
                let midX = self.passthrough.bounds.midX
                self.state.dropTarget = point.x < midX ? .claude : .shelf
            }
        }
        passthrough.onDropURLs = { [weak self] urls in
            guard let self, let first = urls.first else { return }
            MainActor.assumeIsolated {
                let target = self.state.dropTarget ?? .claude
                switch target {
                case .claude:
                    Launcher.openClaude(in: first.path)
                    self.state.flash("Opening \(first.lastPathComponent)")
                    self.state.recents = ProjectScanner.recents()
                case .shelf:
                    ShelfStore.shared.add(urls)
                    self.state.activeModule = .shelf
                    self.state.flash("\(urls.count) files on the shelf")
                }
                self.state.dropTarget = nil
            }
        }

        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Screen-space rect of the hover zone that opens the panel.
    @MainActor
    var hoverZone: CGRect {
        let screen = NotchMetrics.screen
        let notch = NotchMetrics.notchSize(for: screen)
        let width = state.collapsedWidth(notch: notch)
        return CGRect(x: screen.frame.midX - width / 2 - 10,
                      y: screen.frame.maxY - notch.height - 2,
                      width: width + 20,
                      height: notch.height + 2)
    }

    /// Screen-space rect of the open panel, used to decide when to collapse again.
    @MainActor
    var panelZone: CGRect {
        let screen = NotchMetrics.screen
        let height = state.expandedHeight
        let width = Prefs.shared.panelWidth
        return CGRect(x: screen.frame.midX - width / 2 - 4,
                      y: screen.frame.maxY - height - 4,
                      width: width + 8,
                      height: height + 4)
    }
}

/// Lets clicks fall through everywhere except the currently live region.
/// Also accepts folder drops itself, as a backstop in case the SwiftUI drop target misses.
final class PassthroughView: NSView {
    var activeRect: () -> CGRect = { .zero }
    var onDropURLs: (([URL]) -> Void)?
    var onDragState: ((Bool) -> Void)?
    var onDragMove: ((CGPoint) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard activeRect().contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragState?(true)
        onDragMove?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragMove?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragState?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else {
            onDragState?(false)
            return false
        }
        onDropURLs?(urls)
        onDragState?(false)
        return true
    }
}
