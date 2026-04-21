import SwiftUI

/// Receiver's unlock flow. Shows blurred preview, runs a countdown bar matching
/// the sender's exact duration, lets `ZoomDriver` force-replay the sender's
/// zoom curve while the user tries to reproduce the pan/tilt/shake motion.
/// On stop, runs `Matcher.compare` locally for instant score feedback.
struct UnlockAttemptView: View {
    @ObservedObject var session: AppSession
    let message: InboxMessage

    @StateObject private var attempt = UnlockCoordinator()

    var body: some View {
        ZStack {
            CameraPreviewView(capture: attempt.capture).ignoresSafeArea()
            if let blurred = attempt.blurredVideoLayer {
                blurred.ignoresSafeArea().opacity(0.6)
            }
            VStack {
                ProgressView(value: attempt.progress).tint(.white).padding(.horizontal)
                Spacer()
                if let score = attempt.lastResult?.dtwScore {
                    Text(String(format: "Score %.2f — %@",
                                score,
                                attempt.lastResult?.passed == true ? "unlocked!" : "try again"))
                        .foregroundColor(.white)
                }
                Button("Record attempt") {
                    Task { await attempt.run(session: session, message: message) }
                }
                .padding()
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .task { await attempt.prepare(session: session, message: message) }
    }
}

@MainActor
final class UnlockCoordinator: ObservableObject {
    let capture = CaptureSession()
    @Published var progress: Double = 0
    @Published var lastResult: MatchResult?
    @Published var blurredVideoLayer: AnyView?

    private var senderSignature: Signature?

    func prepare(session: AppSession, message: InboxMessage) async {
        try? await capture.configure()
        capture.startRunning()
        senderSignature = try? await session.api.fetchSignature(messageId: message.id)
    }

    func run(session: AppSession, message: InboxMessage) async {
        guard let sender = senderSignature else { return }
        let duration = TimeInterval(message.requiredDurationMs) / 1000.0
        progress = 0
        let ticker = Task {
            let start = Date()
            while !Task.isCancelled, Date().timeIntervalSince(start) < duration {
                progress = Date().timeIntervalSince(start) / duration
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            progress = 1.0
        }
        defer { ticker.cancel() }

        do {
            let res = try await capture.startRecording(mode: .attempt(senderSignature: sender), duration: duration)
            let match = Matcher.compare(
                sender: sender, receiver: res.signature, receiverZoomActual: res.receiverZoomActual
            )
            lastResult = match
            if match.passed {
                try await session.api.submitResponse(
                    messageId: message.id,
                    videoURL: res.videoURL,
                    signature: res.signature,
                    zoomActual: res.receiverZoomActual,
                    clientScore: match
                )
            }
        } catch {
            lastResult = MatchResult(passed: false, dtwScore: .infinity, zoomDeviation: .infinity)
        }
    }
}
