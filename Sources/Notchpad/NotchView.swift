import AppKit
import SwiftUI

struct NotchShape: Shape {
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let br = min(bottomRadius, rect.height / 2, rect.width / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - br), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    let notchSize: CGSize
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared

    private var open: Bool { state.expanded || state.dragging }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.33, dampingFraction: 0.84), value: open)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: state.activeModule)
        .animation(.easeInOut(duration: 0.18), value: state.dropTarget)
    }

    private var shape: NotchShape {
        NotchShape(bottomRadius: open ? prefs.cornerRadius : min(12, prefs.cornerRadius))
    }

    private var island: some View {
        ZStack(alignment: .top) {
            if open && prefs.useBlur { VisualEffectBackdrop() }
            Color.black.opacity(open ? prefs.panelOpacity : 1)
            if open { openContent } else { collapsed }
        }
        .frame(width: open ? prefs.panelWidth : state.collapsedWidth(notch: notchSize),
               height: open ? state.expandedHeight : notchSize.height)
        // Clip to the island so nothing spills out while the panel is resizing.
        .clipShape(shape)
        .overlay(shape.stroke(state.dragging ? prefs.accentColor : Theme.stroke,
                              lineWidth: state.dragging ? 2 : 1))
        .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 20, y: 8)
    }

    // MARK: collapsed

    private var collapsed: some View {
        HStack(spacing: 0) {
            PeekView(slot: prefs.peekLeft, alignment: .trailing)
                .frame(width: prefs.peekLeft.width)
            Spacer(minLength: notchSize.width)
            PeekView(slot: prefs.peekRight, alignment: .leading)
                .frame(width: prefs.peekRight.width)
        }
        .frame(height: notchSize.height)
        .overlay(alignment: .bottom) {
            if state.status != .idle && prefs.peekLeft != .claude && prefs.peekRight != .claude {
                Capsule()
                    .fill(state.status.tint)
                    .frame(width: notchSize.width * 0.3, height: 3)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Rectangle())
        // Clicking the notch pins the panel open, for when hover-to-open is off.
        .onTapGesture {
            state.pinned = true
            state.expanded = true
        }
    }

    // MARK: open

    private var openContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchSize.height)
            if state.dragging {
                dropZones
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            } else {
                tabBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                moduleBody
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(prefs.activeModules) { module in
                Button {
                    state.activeModule = module
                    prefs.lastModule = module
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: module.symbol).font(.system(size: 10, weight: .semibold))
                        if state.activeModule == module {
                            Text(module.title).font(.ui(10.5, .semibold))
                        }
                    }
                    .foregroundStyle(state.activeModule == module ? Color.white : Color.white.opacity(0.45))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        Capsule().fill(state.activeModule == module ? prefs.accentColor.opacity(0.28) : Color.clear)
                    )
                    .overlay(
                        Capsule().stroke(state.activeModule == module ? prefs.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
                    .buttonStyle(.plain)
                    .help(module.title)
                    }
                }
            }
            if state.pinned {
                Button {
                    state.pinned = false
                    state.expanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            Button { NotificationCenter.default.post(name: .openPreferences, object: nil) } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .frame(height: 26)
    }

    @ViewBuilder
    private var moduleBody: some View {
        Group {
            switch state.activeModule {
            case .claude: ClaudeModuleView()
            case .usage: UsageModuleView()
            case .actions: ActionsModuleView()
            case .unity: UnityModuleView()
            case .mcp: MCPModuleView()
            case .power: PowerModuleView()
            case .memory: MemoryModuleView()
            case .shelf: ShelfModuleView()
            case .system: SystemModuleView()
            case .battery: BatteryModuleView()
            case .timer: TimerModuleView()
            case .commands: CommandsModuleView()
            case .media: MediaModuleView()
            case .calendar: CalendarModuleView()
            case .weather: WeatherModuleView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dropZones: some View {
        HStack(spacing: 10) {
            DropZoneCard(title: "Open in Claude",
                         subtitle: "new session, skip-permissions",
                         symbol: "sparkle",
                         tint: prefs.accentColor,
                         active: state.dropTarget == .claude)
            DropZoneCard(title: "Drop on the shelf",
                         subtitle: "drag it back out later",
                         symbol: "tray.and.arrow.down",
                         tint: Theme.blue,
                         active: state.dropTarget == .shelf)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropZoneCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            Text(title).font(.ui(12, .semibold))
            Text(subtitle).font(.ui(9.5)).foregroundStyle(Color.white.opacity(0.5))
        }
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.65))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(active ? 0.28 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(active ? 0.9 : 0.3),
                              style: StrokeStyle(lineWidth: active ? 2 : 1.2, dash: active ? [] : [5, 4]))
        )
        .scaleEffect(active ? 1.02 : 1)
    }
}

/// Small always-visible readouts flanking the hardware notch.
struct PeekView: View {
    let slot: PeekSlot
    let alignment: HorizontalAlignment
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: 4) {
            if alignment == .leading { content; Spacer(minLength: 0) } else { Spacer(minLength: 0); content }
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch slot {
        case .none:
            EmptyView()
        case .claude:
            ClaudeMark()
                .fill(state.status.tint)
                .frame(width: 13, height: 13)
                .shadow(color: state.status.tint.opacity(0.7), radius: 3)
        case .battery:
            label(icon: state.battery.symbol, text: "\(state.battery.percent)%",
                  tint: state.battery.charging ? Theme.green : Color.white.opacity(0.75))
        case .cpu:
            label(icon: "cpu", text: String(format: "%.0f%%", state.system.cpu * 100), tint: Theme.blue)
        case .memory:
            label(icon: "memorychip", text: String(format: "%.0f%%", state.system.memoryFraction * 100), tint: Theme.claude)
        case .network:
            VStack(alignment: .trailing, spacing: 0) {
                Text("↓\(Bytes.short(state.system.netDown))").font(.mono(8.5)).lineLimit(1).fixedSize()
                Text("↑\(Bytes.short(state.system.netUp))").font(.mono(8.5)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Color.white.opacity(0.72))
        case .timer:
            label(icon: "timer", text: TimerStore.shared.phase == .idle ? "—" : TimerStore.shared.display,
                  tint: prefs.accentColor)
        case .media:
            Image(systemName: MediaStore.shared.snapshot.playing ? "waveform" : "music.note")
                .font(.system(size: 11))
                .foregroundStyle(MediaStore.shared.snapshot.playing ? prefs.accentColor : Color.white.opacity(0.5))
        case .clock:
            Text(state.clockText).font(.mono(11, .medium)).foregroundStyle(Color.white.opacity(0.8))
        case .weather:
            label(icon: WeatherStore.shared.snapshot.symbol,
                  text: String(format: "%.0f°", WeatherStore.shared.snapshot.temperature),
                  tint: Theme.amber)
        case .mcp:
            let bridge = MCPStore.shared.unityBridge
            Image(systemName: "app.connected.to.app.below.fill")
                .font(.system(size: 11))
                .foregroundStyle(bridge?.reachable == true ? Theme.green
                                 : (bridge?.reachable == false ? Color.red.opacity(0.8) : Color.white.opacity(0.3)))
        case .tokens:
            label(icon: "chart.bar", text: Fmt.tokens(state.usage.todayTotal), tint: prefs.accentColor)
        case .caffeine:
            Image(systemName: PowerStore.shared.holdingAssertion ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 11))
                .foregroundStyle(PowerStore.shared.holdingAssertion ? prefs.accentColor : Color.white.opacity(0.35))
        case .agenda:
            if let next = CalendarStore.shared.events.first {
                VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 0) {
                    Text(next.title).font(.ui(9)).lineLimit(1)
                    Text(next.relative).font(.mono(9, .medium)).foregroundStyle(prefs.accentColor)
                }
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(maxWidth: 66, alignment: alignment == .leading ? .leading : .trailing)
            } else {
                Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.3))
            }
        }
    }

    private func label(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .medium)).foregroundStyle(tint)
            Text(text).font(.mono(10, .medium)).foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1).fixedSize()
        }
    }
}

/// NSVisualEffectView wrapper for the optional blurred panel background.
struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Notification.Name {
    static let openPreferences = Notification.Name("Notchpad.openPreferences")
}
