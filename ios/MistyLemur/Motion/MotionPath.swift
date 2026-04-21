import Foundation

/// A normalized 2D point in [0, 1] × [0, 1]. Used by the inbox thumbnail.
public struct TracePoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Derives a viewer-friendly 2D scribble from the gyro signal so the inbox can
/// render an animated thumbnail of the gesture's *shape* without revealing the
/// video. The phone's yaw rate maps to horizontal motion, pitch to vertical.
///
/// Algorithm:
///  1. Cumulatively integrate gy (yaw) and gx (pitch) using dt = 1/sampleRateHz.
///  2. Take (yaw, -pitch) as a continuous 2D path.
///  3. Resample uniformly to `targetPoints` points.
///  4. Normalize to [0,1]² so the bounding box fills the rendering surface.
///
/// Output is intended to be POSTed alongside the message as `trace_preview`.
public enum MotionPath {

    public static let defaultPointCount = 64

    public static func project(
        signature: Signature, targetPoints: Int = defaultPointCount
    ) -> [TracePoint] {
        let dt = 1.0 / Double(signature.sampleRateHz)
        var rawX: [Double] = []
        var rawY: [Double] = []
        rawX.reserveCapacity(signature.samples.count)
        rawY.reserveCapacity(signature.samples.count)

        var yaw = 0.0
        var pitch = 0.0
        for s in signature.samples {
            yaw += s.gy * dt
            pitch += s.gx * dt
            rawX.append(yaw)
            rawY.append(-pitch)         // negate so positive pitch (nose up) renders upward
        }

        let resampledX = resample(rawX, toLength: targetPoints)
        let resampledY = resample(rawY, toLength: targetPoints)
        return normalizeToUnitBox(x: resampledX, y: resampledY)
    }

    // MARK: - Helpers

    private static func resample(_ input: [Double], toLength n: Int) -> [Double] {
        guard input.count >= 2, n >= 2 else { return input }
        var out: [Double] = []
        out.reserveCapacity(n)
        let scale = Double(input.count - 1) / Double(n - 1)
        for i in 0..<n {
            let xi = Double(i) * scale
            let lo = Int(xi)
            let hi = min(lo + 1, input.count - 1)
            let u = xi - Double(lo)
            out.append(input[lo] + (input[hi] - input[lo]) * u)
        }
        return out
    }

    private static func normalizeToUnitBox(x: [Double], y: [Double]) -> [TracePoint] {
        guard !x.isEmpty, x.count == y.count else { return [] }
        let minX = x.min()!, maxX = x.max()!
        let minY = y.min()!, maxY = y.max()!
        let rangeX = maxX - minX
        let rangeY = maxY - minY
        // Preserve aspect ratio by scaling against the larger range and centering.
        let range = max(rangeX, rangeY, 1e-9)
        let padding = 0.1
        let scale = (1.0 - 2.0 * padding) / range
        let cx = padding + (1.0 - 2.0 * padding - rangeX * scale) * 0.5
        let cy = padding + (1.0 - 2.0 * padding - rangeY * scale) * 0.5
        return zip(x, y).map { px, py in
            TracePoint(x: cx + (px - minX) * scale, y: cy + (py - minY) * scale)
        }
    }
}
