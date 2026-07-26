import SwiftUI

/// The Claude mark, alive: it breathes when idle, spins while working,
/// bounces when it wants you, and blinks whenever it feels like it.
struct Mascot: View {
    let status: SessionStatus
    var size: CGFloat = 48
    var eyes: Bool = true

    @State private var blink: Double = 1
    @State private var gaze: CGSize = .zero

    private var spinSpeed: Double {
        switch status {
        case .runningTool: return 150
        case .processing: return 80
        case .compacting: return 55
        default: return 0
        }
    }

    private var bounces: Bool { status == .waitingForInput || status == .waitingForApproval }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.035 * sin(t * 1.5)
            let bounce = bounces ? abs(sin(t * 2.3)) * size * 0.09 : 0
            let angle = spinSpeed > 0 ? t * spinSpeed : sin(t * 0.42) * 7
            let ring = status == .waitingForApproval ? (sin(t * 2.6) + 1) / 2 : 0

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [status.tint.opacity(0.38), .clear],
                                         center: .center, startRadius: size * 0.1, endRadius: size * 0.78))
                    .frame(width: size * 1.62, height: size * 1.62)
                    .blur(radius: 3)

                if ring > 0 {
                    Circle()
                        .stroke(status.tint.opacity(0.5 * (1 - ring)), lineWidth: 1.5)
                        .frame(width: size * (0.9 + 0.5 * ring), height: size * (0.9 + 0.5 * ring))
                }

                ClaudeMark()
                    .fill(LinearGradient(colors: [status.tint, status.tint.opacity(0.82), Theme.claudeDeep.opacity(0.9)],
                                         startPoint: .top, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(angle))
                    .scaleEffect(breathe)
                    .shadow(color: status.tint.opacity(0.45), radius: 6)

                if eyes {
                    Eyes(blink: blink, gaze: gaze, size: size)
                        .scaleEffect(breathe)
                }
            }
            .offset(y: -bounce)
            .frame(width: size * 1.62, height: size * 1.62)
        }
        .task { await liven() }
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    private func liven() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...5_400_000_000))
            withAnimation(.easeInOut(duration: 0.07)) { blink = 0.1 }
            try? await Task.sleep(nanoseconds: 95_000_000)
            withAnimation(.easeInOut(duration: 0.1)) { blink = 1 }
            if Bool.random() {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
                    gaze = CGSize(width: .random(in: -1.3...1.3), height: .random(in: -0.8...0.8))
                }
            }
        }
    }
}

/// Two small eyes riding on the mark's solid centre. They never rotate with it.
private struct Eyes: View {
    let blink: Double
    let gaze: CGSize
    let size: CGFloat

    var body: some View {
        let eyeW = size * 0.075
        HStack(spacing: size * 0.115) {
            eye(eyeW)
            eye(eyeW)
        }
        .offset(x: gaze.width, y: gaze.height - size * 0.012)
    }

    private func eye(_ width: CGFloat) -> some View {
        Capsule()
            .fill(Color.black.opacity(0.78))
            .frame(width: width, height: max(1, width * 1.35 * blink))
    }
}
