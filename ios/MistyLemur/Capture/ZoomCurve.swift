import Foundation

/// A sampled `videoZoomFactor` timeline captured alongside the IMU signature.
/// Stored in the signature JSON as `zoom: [{t, f}]`. Linearly interpolated
/// on replay. Clamped to the wide-lens-only range [1.0, 5.0] for MVP to
/// avoid the lens-switch frame jump on multi-lens iPhones.
public struct ZoomCurve: Sendable, Equatable, Codable {

    public struct Point: Sendable, Equatable, Codable {
        /// Relative timestamp in milliseconds since capture start.
        public var t: Int
        /// Zoom factor, clamped to [1.0, 5.0] on append.
        public var f: Double
        public init(t: Int, f: Double) { self.t = t; self.f = f }
    }

    public static let minFactor: Double = 1.0
    public static let maxFactor: Double = 5.0

    /// Monotonically increasing in `t`. Always starts with `t == 0`.
    public private(set) var points: [Point]

    public init(points: [Point] = [Point(t: 0, f: 1.0)]) {
        precondition(!points.isEmpty && points[0].t == 0, "curve must start at t=0")
        self.points = points
    }

    /// Append a sample. Rejects out-of-order timestamps and clamps zoom factor.
    public mutating func append(t: Int, factor: Double) {
        guard t >= (points.last?.t ?? -1) else { return }
        let clamped = min(max(factor, Self.minFactor), Self.maxFactor)
        points.append(Point(t: t, f: clamped))
    }

    /// Linearly interpolate the zoom factor at an arbitrary time.
    /// Returns the endpoint value outside the recorded range.
    public func factor(at tMs: Int) -> Double {
        if tMs <= points.first!.t { return points.first!.f }
        if tMs >= points.last!.t  { return points.last!.f }
        // Binary search for the bracketing pair.
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= tMs { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = Double(b.t - a.t)
        if span == 0 { return a.f }
        let u = Double(tMs - a.t) / span
        return a.f + (b.f - a.f) * u
    }

    /// RMS deviation between this curve and an actual reached-zoom trace, aligned by time.
    /// Used server-side to flag attempts where the camera was obstructed or the app backgrounded.
    public func rmsDeviation(against actual: [Point]) -> Double {
        guard !actual.isEmpty else { return .infinity }
        var sumSq: Double = 0
        for p in actual {
            let target = factor(at: p.t)
            let d = p.f - target
            sumSq += d * d
        }
        return (sumSq / Double(actual.count)).squareRoot()
    }
}
