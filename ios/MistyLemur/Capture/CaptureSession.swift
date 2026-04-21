import AVFoundation
import Foundation

/// Unified wrapper around AVCaptureSession + MotionRecorder + zoom capture/replay.
/// Two modes:
///
/// - `.compose`: the sender is recording a new message. Records video,
///   samples IMU + videoZoomFactor at 100 Hz, produces a Signature.
/// - `.attempt(senderSignature)`: the receiver is attempting to unlock.
///   Records video, samples IMU, and lets a ZoomDriver force the camera
///   to follow the sender's zoom curve. Returns the receiver's signature
///   plus an actual-zoom trace for server-side deviation checking.
///
/// All three streams (video frames, IMU, zoom) share mach_absolute_time,
/// so no manual clock alignment is needed.
public final class CaptureSession: NSObject {

    public enum Mode {
        case compose
        case attempt(senderSignature: Signature)
    }

    public struct Result {
        public let videoURL: URL
        public let signature: Signature
        public let receiverZoomActual: [ZoomCurve.Point]   // empty for .compose
    }

    // MARK: - Config

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "mistylemur.capture")

    private let motionRecorder = MotionRecorder()
    private var zoomSampler: DispatchSourceTimer?
    private var zoomDriver: ZoomDriver?
    private var zoomCurve = ZoomCurve()

    private var mode: Mode = .compose
    private var recordingStartNs: UInt64 = 0
    private var outputURL: URL?
    private var continuation: CheckedContinuation<Result, Error>?

    // MARK: - Setup

    public func configure() async throws {
        try await sessionQueue.performAsync {
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            // Wide-lens only for MVP — avoids the 0.5x / 3x lens-switch jump.
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                throw CaptureError.deviceUnavailable
            }
            self.session.addInput(input)
            self.device = device

            if let mic = AVCaptureDevice.default(for: .audio),
               let audioIn = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(audioIn) {
                self.session.addInput(audioIn)
            }

            guard self.session.canAddOutput(self.movieOutput) else {
                throw CaptureError.outputUnavailable
            }
            self.session.addOutput(self.movieOutput)
        }
    }

    public func startRunning() {
        sessionQueue.async { self.session.startRunning() }
    }

    // MARK: - Record

    /// Begin capturing. For `.attempt`, the ZoomDriver starts simultaneously —
    /// the receiver's camera will follow the sender's curve from t=0.
    public func startRecording(mode: Mode, duration: TimeInterval) async throws -> Result {
        self.mode = mode
        zoomCurve = ZoomCurve()
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mov")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            sessionQueue.async {
                self.recordingStartNs = DispatchTime.now().uptimeNanoseconds
                self.motionRecorder.start()
                self.startZoomTrack(mode: mode)
                self.movieOutput.startRecording(to: self.outputURL!, recordingDelegate: self)

                // Auto-stop after the scheduled duration. Tolerance is enforced
                // at upload time by checking `required_duration_ms ± 150 ms`.
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    self?.stopRecording()
                }
            }
        }
    }

    public func stopRecording() {
        sessionQueue.async {
            self.movieOutput.stopRecording()
            self.zoomSampler?.cancel(); self.zoomSampler = nil
            _ = self.zoomDriver?.stop()
        }
    }

    // MARK: - Zoom track (sender samples, receiver drives)

    private func startZoomTrack(mode: Mode) {
        switch mode {
        case .compose:
            let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, let d = self.device else { return }
                let tMs = Int((DispatchTime.now().uptimeNanoseconds &- self.recordingStartNs) / 1_000_000)
                self.zoomCurve.append(t: tMs, factor: Double(d.videoZoomFactor))
            }
            zoomSampler = timer; timer.resume()
        case .attempt(let senderSignature):
            guard let device else { return }
            let driver = ZoomDriver(device: device, curve: senderSignature.zoom)
            driver.start(referenceStart: DispatchTime(uptimeNanoseconds: recordingStartNs))
            zoomDriver = driver
        }
    }

    public enum CaptureError: Error {
        case deviceUnavailable
        case outputUnavailable
        case recordingFailed(Error)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CaptureSession: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let actualTrace = zoomDriver?.stop() ?? []
        let timed = motionRecorder.stop()
        let relSamples = timed.map { t -> MotionSample in t.sample }  // already relative via delta-time in stored curve
        let durationMs = timed.last.map { Int(($0.timestampNs &- (timed.first?.timestampNs ?? $0.timestampNs)) / 1_000_000) } ?? 0
        let signature = Signature(
            durationMs: durationMs, sampleRateHz: 100, samples: relSamples, zoom: zoomCurve
        )
        if let error {
            continuation?.resume(throwing: CaptureError.recordingFailed(error))
        } else {
            continuation?.resume(returning: Result(
                videoURL: outputFileURL, signature: signature, receiverZoomActual: actualTrace
            ))
        }
        continuation = nil
    }
}

// MARK: - Small async bridge

private extension DispatchQueue {
    func performAsync<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            async {
                do { cont.resume(returning: try block()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
