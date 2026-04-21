import AVFoundation
import Foundation

/// Drives the receiver's `AVCaptureDevice.videoZoomFactor` along a sender-recorded
/// `ZoomCurve` during a matching attempt. Samples the actually-reached factor
/// every 50 ms so the server can compute a zoom_deviation for the attempt.
///
/// Lifecycle: ``start(referenceStart:)`` when the receiver begins recording,
/// ``stop()`` when recording ends. The driver is single-use.
public final class ZoomDriver {

    private let device: AVCaptureDevice
    private let curve: ZoomCurve
    private let tickInterval: DispatchTimeInterval = .milliseconds(50)
    private let rampRate: Float = 8.0   // log2 zoom units per second — "fast but not snappy"

    private var timer: DispatchSourceTimer?
    private var referenceStart: DispatchTime = .now()
    private var actualTrace: [ZoomCurve.Point] = []
    private let queue = DispatchQueue(label: "mistylemur.zoomdriver")

    public init(device: AVCaptureDevice, curve: ZoomCurve) {
        self.device = device
        self.curve = curve
    }

    /// Begin driving. `referenceStart` should be the same clock reference used
    /// by the `AVCaptureSession` recording start — typically `DispatchTime.now()`
    /// captured immediately before `startRecording`.
    public func start(referenceStart: DispatchTime) {
        self.referenceStart = referenceStart
        actualTrace.removeAll(keepingCapacity: true)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: tickInterval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() -> [ZoomCurve.Point] {
        timer?.cancel()
        timer = nil
        return actualTrace
    }

    // MARK: -

    private func tick() {
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- referenceStart.uptimeNanoseconds) / 1_000_000)
        let target = curve.factor(at: elapsedMs)

        // Log what actually happened BEFORE issuing the next ramp — this captures
        // the reached value (including any cases where the device couldn't keep up).
        actualTrace.append(.init(t: elapsedMs, f: Double(device.videoZoomFactor)))

        // Ramp toward the target. `rampToVideoZoomFactor` smooths the transition
        // even when our ticks are only 50 ms apart, preventing visible stepping.
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: CGFloat(target), withRate: rampRate)
            device.unlockForConfiguration()
        } catch {
            // If lock fails (e.g., device taken by another session), skip this tick.
            // The resulting gap shows up as high zoom_deviation server-side.
        }
    }
}
