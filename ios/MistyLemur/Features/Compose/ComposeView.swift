import SwiftUI

/// Record-and-send screen. The sender taps and holds to record; the recorded
/// duration becomes the thread's `required_duration_ms`. They may pinch-zoom
/// during recording — the curve is captured as the cinematography track.
struct ComposeView: View {
    @ObservedObject var session: AppSession
    @StateObject private var recorder = CaptureCoordinator()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(capture: recorder.capture).ignoresSafeArea()

            VStack {
                Spacer()
                if recorder.isRecording {
                    ProgressView("Recording \(recorder.elapsedSeconds, specifier: "%.1f") s")
                        .foregroundColor(.white)
                }
                Button {
                    Task { await recorder.toggle(session: session) }
                } label: {
                    Circle().fill(recorder.isRecording ? .red : .white).frame(width: 80, height: 80)
                }
                .padding(.bottom, 40)
            }
        }
        .task { await recorder.prepare() }
    }
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    let capture = CaptureSession()
    @Published var isRecording = false
    @Published var elapsedSeconds: TimeInterval = 0

    private var startTime: Date?
    private var task: Task<Void, Never>?

    func prepare() async {
        try? await capture.configure()
        capture.startRunning()
    }

    func toggle(session: AppSession) async {
        if isRecording {
            capture.stopRecording()
            isRecording = false
        } else {
            startTime = Date()
            isRecording = true
            task = Task { await tickTimer() }
            do {
                let result = try await capture.startRecording(mode: .compose, duration: 15)
                let trace = MotionPath.project(signature: result.signature)
                try await session.api.sendMessage(
                    videoURL: result.videoURL,
                    signature: result.signature,
                    tracePreview: trace,
                    soundtrackId: nil   // soundtrack picker UI is a separate task
                )
            } catch {
                isRecording = false
            }
        }
    }

    private func tickTimer() async {
        while !Task.isCancelled && isRecording {
            if let start = startTime { elapsedSeconds = Date().timeIntervalSince(start) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Thin AVCaptureVideoPreviewLayer wrapper — filled in by the Xcode project.
struct CameraPreviewView: UIViewRepresentable {
    let capture: CaptureSession
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
