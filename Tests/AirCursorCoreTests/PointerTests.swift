import XCTest
@testable import AirCursorCore

final class PointerTests: XCTestCase {
    func testDeadzoneHoldsStill() {
        var s = PointerSettings()
        s.deadzone = 5
        XCTAssertEqual(PointerMapper.axisSpeed(4.9, settings: s), 0)
        XCTAssertEqual(PointerMapper.axisSpeed(-4.9, settings: s), 0)
        XCTAssertGreaterThan(PointerMapper.axisSpeed(6, settings: s), 0)
    }

    func testSpeedIsSymmetricAndMonotonic() {
        let s = PointerSettings()
        var previous = 0.0
        for rate in stride(from: 5.0, through: 300, by: 5) {
            let v = PointerMapper.axisSpeed(rate, settings: s)
            XCTAssertEqual(v, -PointerMapper.axisSpeed(-rate, settings: s), accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(v, previous)
            previous = v
        }
    }

    func testSensitivityScalesLinearly() {
        var s = PointerSettings()
        let base = PointerMapper.axisSpeed(40, settings: s)
        s.sensitivity = 2
        XCTAssertEqual(PointerMapper.axisSpeed(40, settings: s), base * 2, accuracy: 1e-9)
    }

    func testDirectionsAndInversion() {
        var s = PointerSettings()
        s.deadzone = 0
        // Turn left (+yaw) → cursor left (−x). Look up (+pitch) → cursor up (−y).
        let rates = AngularRates(timestamp: 0, yaw: 30, pitch: 30, roll: 0)
        let v = PointerMapper.cursorVelocity(rates: rates, settings: s)
        XCTAssertLessThan(v.x, 0)
        XCTAssertLessThan(v.y, 0)

        s.invertHorizontal = true
        s.invertVertical = true
        let inv = PointerMapper.cursorVelocity(rates: rates, settings: s)
        XCTAssertEqual(inv.x, -v.x, accuracy: 1e-9)
        XCTAssertEqual(inv.y, -v.y, accuracy: 1e-9)
    }

    func testDifferentiatorHandlesWrapAround() {
        var d = MotionDifferentiator()
        XCTAssertNil(d.push(MotionSample(timestamp: 0, yaw: .pi - 0.01, pitch: 0, roll: 0)))
        let r = d.push(MotionSample(timestamp: 0.04, yaw: -.pi + 0.01, pitch: 0, roll: 0))
        // 0.02 rad over 0.04 s ≈ 28.6 deg/s, not a huge negative spin.
        XCTAssertEqual(r?.yaw ?? 0, AngleMath.degrees(0.02) / 0.04, accuracy: 1e-6)
    }

    func testDifferentiatorRejectsGaps() {
        var d = MotionDifferentiator()
        _ = d.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0))
        XCTAssertNil(d.push(MotionSample(timestamp: 1.0, yaw: 1, pitch: 0, roll: 0)))
        XCTAssertNotNil(d.push(MotionSample(timestamp: 1.04, yaw: 1.01, pitch: 0, roll: 0)))
    }

    func testSmootherConvergesAndStopsWhenStale() {
        var s = PointerSmoother()
        s.setTarget(Vec2(1000, 0), at: 0)
        var t = 0.0
        for _ in 0..<12 { t += 1.0 / 120; _ = s.step(now: t, dt: 1.0 / 120, smoothing: 0.5) }
        XCTAssertEqual(s.velocity.x, 1000, accuracy: 30)

        // No new samples → decays to a full stop.
        for _ in 0..<120 { t += 1.0 / 120; _ = s.step(now: t, dt: 1.0 / 120, smoothing: 0.5) }
        XCTAssertEqual(s.velocity, .zero)
    }

    func testSmootherZeroSmoothingIsImmediate() {
        var s = PointerSmoother()
        s.setTarget(Vec2(120, -60), at: 0)
        let delta = s.step(now: 0.01, dt: 0.01, smoothing: 0)
        XCTAssertEqual(delta.x, 1.2, accuracy: 1e-9)
        XCTAssertEqual(delta.y, -0.6, accuracy: 1e-9)
    }

    func testCursorHistoryLookup() {
        var h = CursorHistory(capacity: 4)
        XCTAssertNil(h.position(at: 1))
        for i in 0..<6 { h.append(Vec2(Double(i), 0), at: Double(i)) }
        // Capacity 4 keeps t = 2...5.
        XCTAssertEqual(h.position(at: 3.5)?.x, 3)
        XCTAssertEqual(h.position(at: 100)?.x, 5)
        XCTAssertEqual(h.position(at: -1)?.x, 2)
    }
}

final class ScrollJoystickTests: XCTestCase {
    /// Feeds a constant pitch at 25 Hz and steps frames at 120 Hz; returns total scroll.
    private func run(_ j: inout ScrollJoystick, pitch: Double, seconds: Double, from start: Double = 0) -> Double {
        var total = 0.0
        var t = start
        var nextSample = start
        let dt = 1.0 / 120
        while t < start + seconds {
            if t >= nextSample {
                j.update(pitch: pitch, scrollSpeed: 1, at: t)
                nextSample += 1.0 / 25
            }
            t += dt
            total += j.step(now: t, dt: dt)
        }
        return total
    }

    func testHoldingHeadDownKeepsScrolling() {
        var j = ScrollJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)                   // neutral
        let first = run(&j, pitch: -15, seconds: 1, from: 0.2)
        let second = run(&j, pitch: -15, seconds: 1, from: 1.2)
        // Looking down scrolls toward content below (+y), and a held head never stops.
        XCTAssertGreaterThan(first, 100)
        XCTAssertGreaterThan(second, first * 0.95)
    }

    func testLookingUpScrollsUp() {
        var j = ScrollJoystick()
        _ = run(&j, pitch: 5, seconds: 0.2)                   // neutral need not be level
        XCTAssertLessThan(run(&j, pitch: 20, seconds: 1, from: 0.2), -100)
    }

    func testWithinDeadzoneDoesNotScroll() {
        var j = ScrollJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        XCTAssertEqual(run(&j, pitch: ScrollJoystick.deadzone - 0.5, seconds: 2, from: 0.2), 0)
    }

    func testReturningToNeutralStops() {
        var j = ScrollJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        _ = run(&j, pitch: -20, seconds: 1, from: 0.2)
        _ = run(&j, pitch: 0, seconds: 0.5, from: 1.2)
        XCTAssertEqual(j.speed, 0)
        XCTAssertEqual(run(&j, pitch: 0, seconds: 1, from: 1.7), 0)
    }

    func testFurtherLeanScrollsFasterAndIsCapped() {
        let small = abs(ScrollJoystick.velocity(offset: -10, scrollSpeed: 1))
        let large = abs(ScrollJoystick.velocity(offset: -25, scrollSpeed: 1))
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(abs(ScrollJoystick.velocity(offset: -90, scrollSpeed: 4)), ScrollJoystick.maxSpeed)
        XCTAssertEqual(ScrollJoystick.velocity(offset: -10, scrollSpeed: 2), 2 * ScrollJoystick.velocity(offset: -10, scrollSpeed: 1), accuracy: 1e-9)
    }

    func testStaleSamplesStopScrolling() {
        var j = ScrollJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        _ = run(&j, pitch: -20, seconds: 0.5, from: 0.2)
        // No more samples (AirPods taken out): it winds down instead of running forever.
        var t = 0.7
        for _ in 0..<120 { t += 1.0 / 120; _ = j.step(now: t, dt: 1.0 / 120) }
        XCTAssertEqual(j.speed, 0)
    }

    func testResetTakesNewNeutral() {
        var j = ScrollJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        j.reset()
        // Leaning back after reset becomes the new neutral, so it doesn't scroll.
        XCTAssertEqual(run(&j, pitch: -20, seconds: 1, from: 0.2), 0)
        XCTAssertEqual(j.neutralPitch, -20)
    }
}

final class ZoomJoystickTests: XCTestCase {
    /// Feeds a constant pitch at 25 Hz, steps at 120 Hz; returns total magnification.
    private func run(_ j: inout ZoomJoystick, pitch: Double, seconds: Double, from start: Double = 0) -> Double {
        var total = 0.0
        var t = start
        var nextSample = start
        let dt = 1.0 / 120
        while t < start + seconds {
            if t >= nextSample {
                j.update(pitch: pitch, at: t)
                nextSample += 1.0 / 25
            }
            t += dt
            total += j.step(now: t, dt: dt)
        }
        return total
    }

    func testLevelHeadDoesNotZoom() {
        var j = ZoomJoystick()
        XCTAssertEqual(run(&j, pitch: 0, seconds: 0.2), 0)
        XCTAssertEqual(run(&j, pitch: ZoomJoystick.deadzone - 1, seconds: 3, from: 0.2), 0)
    }

    func testHoldingHeadUpKeepsZoomingInSmoothly() {
        var j = ZoomJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        let first = run(&j, pitch: 14, seconds: 1, from: 0.2)
        let second = run(&j, pitch: 14, seconds: 1, from: 1.2)
        XCTAssertGreaterThan(first, 0.3)
        XCTAssertGreaterThan(second, first * 0.95)      // a held head never stops
        XCTAssertLessThan(second, 2)                    // but stays a readable pace
    }

    func testLeaningDownZoomsOut() {
        var j = ZoomJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        XCTAssertLessThan(run(&j, pitch: -14, seconds: 1, from: 0.2), -0.3)
    }

    func testComingBackLevelStopsQuickly() {
        var j = ZoomJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        _ = run(&j, pitch: 20, seconds: 1, from: 0.2)
        _ = run(&j, pitch: 0, seconds: 0.4, from: 1.2)
        XCTAssertEqual(j.speed, 0)
        XCTAssertEqual(run(&j, pitch: 0, seconds: 1, from: 1.6), 0)
    }

    func testFurtherLeanZoomsFasterUpToACap() {
        XCTAssertEqual(ZoomJoystick.velocity(offset: 3), 0)
        XCTAssertGreaterThan(ZoomJoystick.velocity(offset: 25), ZoomJoystick.velocity(offset: 10))
        XCTAssertEqual(ZoomJoystick.velocity(offset: 90), ZoomJoystick.maxRate)
        XCTAssertEqual(ZoomJoystick.velocity(offset: -90), -ZoomJoystick.maxRate)
    }

    func testStaleSamplesStopZooming() {
        var j = ZoomJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        _ = run(&j, pitch: 20, seconds: 0.5, from: 0.2)
        var t = 0.7
        for _ in 0..<120 { t += 1.0 / 120; _ = j.step(now: t, dt: 1.0 / 120) }
        XCTAssertEqual(j.speed, 0)
    }

    func testResetTakesNewNeutral() {
        var j = ZoomJoystick()
        _ = run(&j, pitch: 0, seconds: 0.2)
        j.reset()
        XCTAssertEqual(run(&j, pitch: 20, seconds: 1, from: 0.2), 0)
        XCTAssertEqual(j.neutralPitch, 20)
    }
}
