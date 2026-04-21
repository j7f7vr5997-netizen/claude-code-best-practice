import Foundation

/// The pass/fail decision for a single unlock attempt.
public struct MatchResult: Sendable, Equatable {
    public let passed: Bool
    public let dtwScore: Double
    public let zoomDeviation: Double
}

/// Orchestrates preprocess → FastDTW → zoom deviation check → threshold decision.
/// The same logic runs on-device (live feedback for the receiver) and server-side
/// (anti-cheat re-verification before unlocking the mutual exchange).
public enum Matcher {

    /// Initial empirical threshold. Re-tune from `motion_attempts` telemetry — plot
    /// self-match vs cross-motion distributions and pick the 90th percentile of
    /// honest self-matches. Ship target: ~70% pass-in-3-attempts.
    public static var dtwThreshold: Double = 6.0

    /// Zoom deviation cutoff. Below this, the receiver's zoom is considered faithful
    /// to the sender's curve. Above it, the attempt is invalid regardless of DTW.
    public static var zoomDeviationTolerance: Double = 0.3

    public static func compare(
        sender: Signature, receiver: Signature, receiverZoomActual: [ZoomCurve.Point]
    ) -> MatchResult {
        let durationMs = sender.durationMs
        let a = SignaturePipeline.preprocess(sender, targetDurationMs: durationMs)
        let b = SignaturePipeline.preprocess(receiver, targetDurationMs: durationMs)

        let score = FastDTW.distance(a, b, radius: 10)
        let deviation = sender.zoom.rmsDeviation(against: receiverZoomActual)

        let passed = score < dtwThreshold && deviation < zoomDeviationTolerance
        return MatchResult(passed: passed, dtwScore: score, zoomDeviation: deviation)
    }
}
