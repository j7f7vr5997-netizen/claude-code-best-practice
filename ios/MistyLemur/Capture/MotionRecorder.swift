import CoreMotion
import Foundation

/// 100 Hz `CMDeviceMotion` sampler. Emits gravity-aligned world-frame samples —
/// the IMU is grip-orientation-invariant because CoreMotion pre-rotates via the
/// attitude quaternion. Samples are timestamped against mach_absolute_time so
/// they share a clock with `AVCaptureSession`.
public final class MotionRecorder {

    public struct TimedSample {
        public let timestampNs: UInt64
        public let sample: MotionSample
    }

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "mistylemur.motionrecorder"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var buffer: [TimedSample] = []
    private let bufferLock = NSLock()

    public init() {
        manager.deviceMotionUpdateInterval = 1.0 / 100.0  // 100 Hz
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Begin sampling. `CMAttitudeReferenceFrame.xArbitraryCorrectedZVertical`
    /// gives a gravity-aligned frame without magnetometer (faster startup, no
    /// outdoor dependency).
    public func start() {
        bufferLock.lock(); buffer.removeAll(keepingCapacity: true); bufferLock.unlock()
        manager.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical, to: queue
        ) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let s = MotionSample(
                ax: m.userAcceleration.x, ay: m.userAcceleration.y, az: m.userAcceleration.z,
                gx: m.rotationRate.x,     gy: m.rotationRate.y,     gz: m.rotationRate.z
            )
            let tNs = UInt64(m.timestamp * 1_000_000_000)
            self.bufferLock.lock()
            self.buffer.append(TimedSample(timestampNs: tNs, sample: s))
            self.bufferLock.unlock()
        }
    }

    /// Stop and return the accumulated samples. Caller is expected to convert
    /// timestamps to the session-relative origin.
    public func stop() -> [TimedSample] {
        manager.stopDeviceMotionUpdates()
        bufferLock.lock(); defer { bufferLock.unlock() }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }
}
