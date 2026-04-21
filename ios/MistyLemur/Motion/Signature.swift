import Foundation

/// Full on-wire signature for a message. Written to `signature.json` in Supabase
/// Storage alongside the video. Contains both the IMU time-series (for DTW
/// matching) and the zoom curve (for auto-replay on the receiver).
public struct Signature: Sendable, Equatable, Codable {
    public var durationMs: Int
    public var sampleRateHz: Int     // 100 for MVP
    public var samples: [MotionSample]
    public var zoom: ZoomCurve
}

/// Preprocessing pipeline applied to both sender and receiver signatures before
/// DTW. Because the same pipeline runs on both sides, any phase delay the
/// low-pass filter introduces cancels out — we can use a one-pass biquad.
public enum SignaturePipeline {

    /// Trim to the target duration, resample to `duration_ms / 10` samples,
    /// per-axis z-score normalize, then 4th-order Butterworth low-pass at 10 Hz.
    public static func preprocess(
        _ signature: Signature, targetDurationMs: Int
    ) -> [MotionSample] {
        let targetLength = targetDurationMs / 10          // 100 Hz → one sample per 10 ms
        let trimmed = Array(signature.samples.prefix(targetLength * 2))  // generous upper bound
        let resampled = linearResample(trimmed, toLength: targetLength)
        let normalized = zscorePerAxis(resampled)
        return butterworthLowPass4thOrder(normalized, cutoffHz: 10, sampleRateHz: 100)
    }

    // MARK: - Resampling

    static func linearResample(_ input: [MotionSample], toLength n: Int) -> [MotionSample] {
        guard input.count >= 2, n >= 2 else { return input }
        var out: [MotionSample] = []
        out.reserveCapacity(n)
        let scale = Double(input.count - 1) / Double(n - 1)
        for i in 0..<n {
            let x = Double(i) * scale
            let lo = Int(x)
            let hi = min(lo + 1, input.count - 1)
            let u = x - Double(lo)
            let a = input[lo], b = input[hi]
            out.append(MotionSample(
                ax: a.ax + (b.ax - a.ax) * u,
                ay: a.ay + (b.ay - a.ay) * u,
                az: a.az + (b.az - a.az) * u,
                gx: a.gx + (b.gx - a.gx) * u,
                gy: a.gy + (b.gy - a.gy) * u,
                gz: a.gz + (b.gz - a.gz) * u
            ))
        }
        return out
    }

    // MARK: - Z-score per axis

    static func zscorePerAxis(_ input: [MotionSample]) -> [MotionSample] {
        guard input.count > 1 else { return input }
        let n = Double(input.count)
        var m = MotionSample(ax: 0, ay: 0, az: 0, gx: 0, gy: 0, gz: 0)
        for s in input {
            m.ax += s.ax; m.ay += s.ay; m.az += s.az
            m.gx += s.gx; m.gy += s.gy; m.gz += s.gz
        }
        m.ax /= n; m.ay /= n; m.az /= n; m.gx /= n; m.gy /= n; m.gz /= n

        var v = MotionSample(ax: 0, ay: 0, az: 0, gx: 0, gy: 0, gz: 0)
        for s in input {
            v.ax += (s.ax - m.ax) * (s.ax - m.ax); v.ay += (s.ay - m.ay) * (s.ay - m.ay); v.az += (s.az - m.az) * (s.az - m.az)
            v.gx += (s.gx - m.gx) * (s.gx - m.gx); v.gy += (s.gy - m.gy) * (s.gy - m.gy); v.gz += (s.gz - m.gz) * (s.gz - m.gz)
        }
        let eps = 1e-9
        let sax = (v.ax / n).squareRoot() + eps, say = (v.ay / n).squareRoot() + eps, saz = (v.az / n).squareRoot() + eps
        let sgx = (v.gx / n).squareRoot() + eps, sgy = (v.gy / n).squareRoot() + eps, sgz = (v.gz / n).squareRoot() + eps

        return input.map {
            MotionSample(
                ax: ($0.ax - m.ax) / sax, ay: ($0.ay - m.ay) / say, az: ($0.az - m.az) / saz,
                gx: ($0.gx - m.gx) / sgx, gy: ($0.gy - m.gy) / sgy, gz: ($0.gz - m.gz) / sgz
            )
        }
    }

    // MARK: - Butterworth 4th-order low-pass (two biquad sections in series)

    static func butterworthLowPass4thOrder(
        _ input: [MotionSample], cutoffHz: Double, sampleRateHz: Double
    ) -> [MotionSample] {
        // 4th-order Butterworth = two 2nd-order sections with Q1, Q2 below.
        let q1 = 1.0 / (2.0 * cos(.pi / 8.0))   // ≈ 0.5412
        let q2 = 1.0 / (2.0 * cos(3.0 * .pi / 8.0))   // ≈ 1.3066
        let s1 = Biquad(cutoffHz: cutoffHz, sampleRateHz: sampleRateHz, q: q1)
        let s2 = Biquad(cutoffHz: cutoffHz, sampleRateHz: sampleRateHz, q: q2)
        return runBiquads(input, sections: [s1, s2])
    }

    private static func runBiquads(_ input: [MotionSample], sections: [Biquad]) -> [MotionSample] {
        var out = input
        for var section in sections {
            for i in 0..<out.count {
                out[i] = section.apply(sample: out[i])
            }
        }
        return out
    }
}

/// 2nd-order biquad filter, applied independently per axis via a single state struct.
/// Designed with the bilinear transform; coefficients assume a low-pass response.
struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    // Per-axis state: [x1, x2, y1, y2].
    private var state: [[Double]] = Array(repeating: [0, 0, 0, 0], count: 6)

    init(cutoffHz: Double, sampleRateHz: Double, q: Double) {
        let omega = 2.0 * .pi * cutoffHz / sampleRateHz
        let k = tan(omega * 0.5)
        let norm = 1.0 / (1.0 + k / q + k * k)
        self.b0 = k * k * norm
        self.b1 = 2.0 * b0
        self.b2 = b0
        self.a1 = 2.0 * (k * k - 1.0) * norm
        self.a2 = (1.0 - k / q + k * k) * norm
    }

    mutating func apply(sample s: MotionSample) -> MotionSample {
        MotionSample(
            ax: step(s.ax, axis: 0), ay: step(s.ay, axis: 1), az: step(s.az, axis: 2),
            gx: step(s.gx, axis: 3), gy: step(s.gy, axis: 4), gz: step(s.gz, axis: 5)
        )
    }

    private mutating func step(_ x: Double, axis: Int) -> Double {
        let x1 = state[axis][0], x2 = state[axis][1]
        let y1 = state[axis][2], y2 = state[axis][3]
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        state[axis] = [x, x1, y, y1]
        return y
    }
}
