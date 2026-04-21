import Foundation

/// A single IMU sample: 3 accel axes + 3 gyro axes in the gravity-aligned world frame.
/// Produced by ``MotionRecorder`` at 100 Hz.
public struct MotionSample: Sendable, Equatable, Codable {
    public var ax: Double; public var ay: Double; public var az: Double
    public var gx: Double; public var gy: Double; public var gz: Double

    public init(ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
        self.ax = ax; self.ay = ay; self.az = az
        self.gx = gx; self.gy = gy; self.gz = gz
    }
}

/// Multi-resolution Dynamic Time Warping (Salvador & Chan 2007) over a 6-D IMU series.
/// Gyro axes are weighted 1.5× vs accel — rotation is more distinctive than translation.
/// Complexity: approximately O(n · radius) vs O(n²) for full DTW.
public enum FastDTW {

    /// Relative weight of gyro axes in the local cost. Tune against calibration data.
    public static var gyroWeight: Double = 1.5

    /// Compute the DTW distance between two equally-preprocessed signatures.
    public static func distance(_ x: [MotionSample], _ y: [MotionSample], radius: Int = 10) -> Double {
        precondition(!x.isEmpty && !y.isEmpty, "signatures must be non-empty")
        return fastDTW(x, y, radius: max(1, radius)).cost
    }

    // MARK: - Recursion

    private static func fastDTW(_ x: [MotionSample], _ y: [MotionSample], radius: Int)
        -> (cost: Double, path: [(Int, Int)])
    {
        let minSize = radius + 2
        if x.count <= minSize || y.count <= minSize {
            return fullDTW(x, y)
        }
        let xLow = downsample(x)
        let yLow = downsample(y)
        let lower = fastDTW(xLow, yLow, radius: radius)
        let window = expandWindow(path: lower.path, nx: x.count, ny: y.count, radius: radius)
        return constrainedDTW(x, y, window: window)
    }

    // MARK: - Resolution reduction

    private static func downsample(_ s: [MotionSample]) -> [MotionSample] {
        var out: [MotionSample] = []
        out.reserveCapacity((s.count + 1) / 2)
        var i = 0
        while i < s.count {
            if i + 1 < s.count {
                let a = s[i], b = s[i + 1]
                out.append(MotionSample(
                    ax: (a.ax + b.ax) * 0.5, ay: (a.ay + b.ay) * 0.5, az: (a.az + b.az) * 0.5,
                    gx: (a.gx + b.gx) * 0.5, gy: (a.gy + b.gy) * 0.5, gz: (a.gz + b.gz) * 0.5
                ))
            } else {
                out.append(s[i])
            }
            i += 2
        }
        return out
    }

    /// Project the low-resolution warping path to the next-finer resolution, then
    /// dilate by ``radius`` cells. Cells are packed as `i*ny + j` for O(1) lookup.
    private static func expandWindow(path: [(Int, Int)], nx: Int, ny: Int, radius: Int) -> Set<Int> {
        var projected: Set<Int> = []
        for (i, j) in path {
            for xi in (2 * i)...(2 * i + 1) where xi < nx {
                for yj in (2 * j)...(2 * j + 1) where yj < ny {
                    projected.insert(xi * ny + yj)
                }
            }
        }
        var expanded: Set<Int> = []
        expanded.reserveCapacity(projected.count * (2 * radius + 1) * (2 * radius + 1))
        for key in projected {
            let pi = key / ny, pj = key % ny
            let iLo = max(0, pi - radius), iHi = min(nx - 1, pi + radius)
            let jLo = max(0, pj - radius), jHi = min(ny - 1, pj + radius)
            for xi in iLo...iHi {
                for yj in jLo...jHi {
                    expanded.insert(xi * ny + yj)
                }
            }
        }
        // Always include endpoints so a path exists.
        expanded.insert(0)
        expanded.insert((nx - 1) * ny + (ny - 1))
        return expanded
    }

    // MARK: - DTW cores

    private static func fullDTW(_ x: [MotionSample], _ y: [MotionSample])
        -> (cost: Double, path: [(Int, Int)])
    {
        let nx = x.count, ny = y.count
        var cost = Array(repeating: Array(repeating: Double.infinity, count: ny), count: nx)
        cost[0][0] = localCost(x[0], y[0])
        for i in 1..<nx { cost[i][0] = cost[i - 1][0] + localCost(x[i], y[0]) }
        for j in 1..<ny { cost[0][j] = cost[0][j - 1] + localCost(x[0], y[j]) }
        for i in 1..<nx {
            for j in 1..<ny {
                let m = Swift.min(cost[i - 1][j], cost[i][j - 1], cost[i - 1][j - 1])
                cost[i][j] = m + localCost(x[i], y[j])
            }
        }
        return (cost[nx - 1][ny - 1], backtrace(cost))
    }

    private static func constrainedDTW(
        _ x: [MotionSample], _ y: [MotionSample], window: Set<Int>
    ) -> (cost: Double, path: [(Int, Int)]) {
        let nx = x.count, ny = y.count
        var cost = Array(repeating: Array(repeating: Double.infinity, count: ny), count: nx)
        cost[0][0] = localCost(x[0], y[0])
        for i in 0..<nx {
            for j in 0..<ny where !(i == 0 && j == 0) {
                if !window.contains(i * ny + j) { continue }
                let up = i > 0 ? cost[i - 1][j] : .infinity
                let left = j > 0 ? cost[i][j - 1] : .infinity
                let diag = (i > 0 && j > 0) ? cost[i - 1][j - 1] : .infinity
                let m = Swift.min(up, left, diag)
                if m.isFinite { cost[i][j] = m + localCost(x[i], y[j]) }
            }
        }
        return (cost[nx - 1][ny - 1], backtrace(cost))
    }

    private static func backtrace(_ cost: [[Double]]) -> [(Int, Int)] {
        var path: [(Int, Int)] = []
        var i = cost.count - 1
        var j = cost[0].count - 1
        while i > 0 || j > 0 {
            path.append((i, j))
            if i == 0 { j -= 1 }
            else if j == 0 { i -= 1 }
            else {
                let up = cost[i - 1][j], left = cost[i][j - 1], diag = cost[i - 1][j - 1]
                if diag <= up && diag <= left { i -= 1; j -= 1 }
                else if up <= left { i -= 1 }
                else { j -= 1 }
            }
        }
        path.append((0, 0))
        return path.reversed()
    }

    @inline(__always)
    private static func localCost(_ a: MotionSample, _ b: MotionSample) -> Double {
        let dax = a.ax - b.ax, day = a.ay - b.ay, daz = a.az - b.az
        let dgx = a.gx - b.gx, dgy = a.gy - b.gy, dgz = a.gz - b.gz
        let accel = dax * dax + day * day + daz * daz
        let gyro  = dgx * dgx + dgy * dgy + dgz * dgz
        return (accel + gyroWeight * gyroWeight * gyro).squareRoot()
    }
}
