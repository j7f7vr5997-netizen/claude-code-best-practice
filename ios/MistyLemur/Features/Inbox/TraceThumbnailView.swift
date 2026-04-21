import SwiftUI

/// Animated motion-trace thumbnail. Draws the gesture's 2D scribble over the
/// course of `requiredDurationMs` so the receiver sees both the *shape* and the
/// *tempo* of the original gesture before attempting to match it.
///
/// Snapchat-inspired iconography overlay: a small chevron in the corner whose
/// fill state mirrors the message's state (locked/unlocked/viewed). Color also
/// reflects state — red while locked, white once unlocked, gray once viewed.
struct TraceThumbnailView: View {
    let trace: [TracePoint]
    let durationMs: Int
    let state: ThumbnailState

    enum ThumbnailState { case locked, unlocked, viewed }

    @State private var progress: Double = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Canvas { context, size in
                guard trace.count > 1 else { return }
                let cutoff = max(2, Int(Double(trace.count) * progress))
                var path = Path()
                path.move(to: CGPoint(x: trace[0].x * size.width, y: trace[0].y * size.height))
                for i in 1..<cutoff {
                    path.addLine(to: CGPoint(x: trace[i].x * size.width, y: trace[i].y * size.height))
                }
                context.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            chevron
                .padding(4)
        }
        .frame(width: 56, height: 56)
        .onAppear { startReveal() }
        .onDisappear { animationTask?.cancel() }
    }

    private var chevron: some View {
        Image(systemName: state == .viewed ? "chevron.right" : "chevron.right.square.fill")
            .font(.caption2.weight(.bold))
            .foregroundColor(strokeColor)
    }

    private var strokeColor: Color {
        switch state {
        case .locked:   return .red
        case .unlocked: return .white
        case .viewed:   return .gray
        }
    }

    private func startReveal() {
        animationTask?.cancel()
        progress = 0
        animationTask = Task { @MainActor in
            let frames = 60
            let frameDelay = UInt64(durationMs * 1_000_000 / frames)
            for i in 1...frames {
                if Task.isCancelled { return }
                progress = Double(i) / Double(frames)
                try? await Task.sleep(nanoseconds: frameDelay)
            }
        }
    }
}
