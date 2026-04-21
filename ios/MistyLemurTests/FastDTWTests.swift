import XCTest
@testable import MistyLemurMotion

final class FastDTWTests: XCTestCase {

    func testSelfMatchDistanceIsZero() {
        let series = (0..<200).map {
            MotionSample(
                ax: sin(Double($0) * 0.1), ay: 0, az: 0,
                gx: 0, gy: cos(Double($0) * 0.1), gz: 0
            )
        }
        let d = FastDTW.distance(series, series, radius: 10)
        XCTAssertLessThan(d, 1e-6)
    }

    func testCrossMotionDistanceIsLarge() {
        let pan = (0..<200).map { MotionSample(ax: sin(Double($0) * 0.1), ay: 0, az: 0, gx: 0, gy: 0, gz: 0) }
        let shake = (0..<200).map { MotionSample(ax: 0, ay: 0, az: 0, gx: sin(Double($0) * 0.4), gy: 0, gz: 0) }
        let d = FastDTW.distance(pan, shake, radius: 10)
        XCTAssertGreaterThan(d, 10.0)
    }

    func testZoomCurveInterpolation() {
        var c = ZoomCurve()
        c.append(t: 1000, factor: 3.0)
        c.append(t: 2000, factor: 5.0)
        XCTAssertEqual(c.factor(at: 0),    1.0, accuracy: 1e-9)
        XCTAssertEqual(c.factor(at: 1000), 3.0, accuracy: 1e-9)
        XCTAssertEqual(c.factor(at: 1500), 4.0, accuracy: 1e-9)  // midpoint of 3→5
        XCTAssertEqual(c.factor(at: 9999), 5.0, accuracy: 1e-9)  // clamps past end
    }

    func testZoomCurveClampsFactor() {
        var c = ZoomCurve()
        c.append(t: 100, factor: 10.0)    // above maxFactor
        c.append(t: 200, factor: 0.1)     // below minFactor
        XCTAssertEqual(c.points[1].f, ZoomCurve.maxFactor)
        XCTAssertEqual(c.points[2].f, ZoomCurve.minFactor)
    }
}
