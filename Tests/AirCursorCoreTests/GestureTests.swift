import XCTest
@testable import AirCursorCore

final class GestureTests: XCTestCase {
    private let all = Set(HeadGesture.allCases)
    private let hz = 25.0

    /// Feeds angle tracks (degrees) at 25 Hz; returns every gesture fired.
    private func feed(
        _ d: inout GestureDetector,
        pitch: [Double],
        yaw: [Double]? = nil,
        roll: [Double]? = nil,
        start: Double = 0,
        enabled: Set<HeadGesture>? = nil
    ) -> [GestureEvent] {
        var out: [GestureEvent] = []
        for i in pitch.indices {
            let s = MotionSample(
                timestamp: start + Double(i) / hz,
                yaw: AngleMath.radians(yaw?[i] ?? 0),
                pitch: AngleMath.radians(pitch[i]),
                roll: AngleMath.radians(roll?[i] ?? 0)
            )
            if let e = d.process(s, enabled: enabled ?? all) { out.append(e) }
        }
        return out
    }

    /// Flat, then a smooth dip of `depth` degrees lasting `duration` seconds, then flat.
    private func dip(_ depth: Double, over duration: Double, lead: Int = 5, tail: Int = 8) -> [Double] {
        let n = max(2, Int(duration * hz))
        let curve = (0...n).map { i in depth * sin(.pi * Double(i) / Double(n)) }
        return Array(repeating: 0, count: lead) + curve + Array(repeating: 0, count: tail)
    }

    func testNaturalNodDetected() {
        var d = GestureDetector()
        let events = feed(&d, pitch: dip(-12, over: 0.4))
        XCTAssertEqual(events.map(\.gesture), [.nod])
        XCTAssertEqual(events.first?.magnitude ?? 0, 12, accuracy: 1)
        // Starts at (or just before) the beginning of the dip, for cursor restore.
        XCTAssertLessThanOrEqual(events.first?.startTime ?? 99, 5 / hz + 0.01)
    }

    func testGentleNodDetected() {
        var d = GestureDetector()
        XCTAssertEqual(feed(&d, pitch: dip(-7, over: 0.5)).map(\.gesture), [.nod])
    }

    func testUpwardNodDetected() {
        var d = GestureDetector()
        // With "nod up" bound (the default), an upward nod is its own gesture.
        let events = feed(&d, pitch: dip(10, over: 0.4))
        XCTAssertEqual(events.map(\.gesture), [.nodUp])
        XCTAssertTrue(events.first?.isSnappy ?? false)
    }

    func testDownwardNodStaysANodWhenNodUpEnabled() {
        var d = GestureDetector()
        XCTAssertEqual(feed(&d, pitch: dip(-10, over: 0.4)).map(\.gesture), [.nod])
    }

    func testDownwardNodWithUpwardReboundIsStillANod() {
        var d = GestureDetector()
        let nod = dip(-12, over: 0.4, tail: 0) + dip(6, over: 0.3, lead: 0)
        XCTAssertEqual(feed(&d, pitch: nod).map(\.gesture), [.nod])
    }

    func testUpwardNodClicksWhenNodUpIsUnbound() {
        var d = GestureDetector()
        // Without a nod-up binding, upward nods keep working as clicks.
        XCTAssertEqual(feed(&d, pitch: dip(10, over: 0.4), enabled: [.nod]).map(\.gesture), [.nod])
    }

    func testOnlyNodUpEnabledIgnoresDownwardNods() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-10, over: 0.4), enabled: [.nodUp]).isEmpty)
    }

    func testSlowLeanUpAndBackIsNotSnappy() {
        var d = GestureDetector()
        // Leaning up to scroll a little and coming back: still a nod shape, but slow,
        // so it won't switch mode while scrolling.
        let events = feed(&d, pitch: dip(10, over: 0.72))
        XCTAssertEqual(events.map(\.gesture), [.nodUp])
        XCTAssertFalse(events.first?.isSnappy ?? true)
    }

    func testTinyJitterIsNotANod() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-3, over: 0.3)).isEmpty)
    }

    func testSlowLookDownAndBackIsNotANod() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-15, over: 2.0)).isEmpty)
    }

    func testLookingDownAndStayingIsNotANod() {
        var d = GestureDetector()
        let pitch = Array(repeating: 0.0, count: 5) + (0...10).map { -1.5 * Double($0) } + Array(repeating: -15.0, count: 30)
        XCTAssertTrue(feed(&d, pitch: pitch).isEmpty)
    }

    func testDiagonalMoveIsNotANod() {
        var d = GestureDetector()
        let pitch = dip(-10, over: 0.4)
        let yaw = pitch.indices.map { Double($0) * 1.5 }   // sweeping sideways ~37°/s
        XCTAssertTrue(feed(&d, pitch: pitch, yaw: yaw, enabled: [.nod]).isEmpty)
    }

    func testNodWithReboundFiresOnce() {
        var d = GestureDetector()
        // Real nods often overshoot upward on the way back before settling.
        let nod = dip(-12, over: 0.4, tail: 0) + dip(6, over: 0.3, lead: 0)
        XCTAssertEqual(feed(&d, pitch: nod).count, 1)
    }

    func testNodBurstWithoutSettlingFiresOnce() {
        var d = GestureDetector()
        // Nodding repeatedly without ever holding still = one click, not three.
        let burst = dip(-10, over: 0.4, tail: 0) + dip(-10, over: 0.4, lead: 0, tail: 0) + dip(-10, over: 0.4, lead: 0)
        XCTAssertEqual(feed(&d, pitch: burst).count, 1)
    }

    func testSeparateNodsEachFire() {
        var d = GestureDetector()
        let two = dip(-10, over: 0.4, tail: 15) + dip(-10, over: 0.4, lead: 0)
        XCTAssertEqual(feed(&d, pitch: two).map(\.gesture), [.nod, .nod])
    }

    func testLongShakeFiresOnce() {
        var d = GestureDetector()
        // Two full seconds of shaking must toggle once, not off-on-off-on.
        let n = Int(2.0 * hz)
        let yaw = (0...n).map { 14 * sin(2 * .pi * Double($0) / (0.45 * hz)) } + Array(repeating: 0.0, count: 10)
        let events = feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw)
        XCTAssertEqual(events.map(\.gesture), [.shake])
    }

    func testDisabledGesturesDoNotFire() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-12, over: 0.4), enabled: [.shake]).isEmpty)
    }

    func testShakeDetected() {
        var d = GestureDetector()
        let n = Int(1.1 * hz)
        let yaw = Array(repeating: 0.0, count: 4) + (0...n).map { 15 * sin(2 * .pi * Double($0) / (0.5 * hz)) } + Array(repeating: 0.0, count: 4)
        let events = feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw)
        XCTAssertEqual(events.map(\.gesture), [.shake])
    }

    func testGlancingLeftThenRightThenBackIsNotAShake() {
        var d = GestureDetector()
        // Look at a window on the left, one on the right, then back to center: 3 swings.
        var yaw: [Double] = Array(repeating: 0, count: 4)
        for i in 0...6 { yaw.append(-18.0 * Double(i) / 6.0) }
        for i in 0...10 { yaw.append(-18.0 + 36.0 * Double(i) / 10.0) }
        for i in 0...6 { yaw.append(18.0 - 18.0 * Double(i) / 6.0) }
        yaw += Array(repeating: 0.0, count: 6)
        XCTAssertTrue(feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw).isEmpty)
    }

    func testSingleLookAsideAndBackIsNotAShake() {
        var d = GestureDetector()
        let yaw = dip(-25, over: 0.6)
        XCTAssertTrue(feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw).isEmpty)
    }

    func testYawWrapAroundIsContinuous() {
        var d = GestureDetector()
        // Hovering around ±180° must not look like a 360° swing.
        let yaw = (0..<30).map { i in i % 2 == 0 ? 179.0 : -179.0 }
        XCTAssertTrue(feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw).isEmpty)
    }

    // MARK: Swipe (head flick)

    private func flat(_ yaw: [Double]) -> [Double] { Array(repeating: 0, count: yaw.count) }

    func testQuickFlickRightSwipesRight() {
        var d = GestureDetector()
        let yaw = dip(-20, over: 0.3)   // −yaw = turning right
        let events = feed(&d, pitch: flat(yaw), yaw: yaw)
        XCTAssertEqual(events.map(\.gesture), [.swipeRight])
        XCTAssertEqual(events.first?.magnitude ?? 0, 20, accuracy: 1.5)
        // Starts at the beginning of the flick, so the cursor can be put back.
        XCTAssertLessThanOrEqual(events.first?.startTime ?? 99, 5 / hz + 0.01)
    }

    func testQuickFlickLeftSwipesLeft() {
        var d = GestureDetector()
        let yaw = dip(20, over: 0.3)
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw).map(\.gesture), [.swipeLeft])
    }

    func testSwipeWaitsForTheHeadToSettle() {
        var d = GestureDetector()
        // Flick and come back, but no settled samples yet: not fired yet.
        let yaw = dip(-20, over: 0.3, tail: 1)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw).isEmpty)
    }

    func testSeparateFlicksEachFireOnce() {
        var d = GestureDetector()
        let yaw = dip(-20, over: 0.3, tail: 15) + dip(20, over: 0.3, lead: 0)
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw).map(\.gesture), [.swipeRight, .swipeLeft])
    }

    func testSlowGlanceAsideIsNotASwipe() {
        var d = GestureDetector()
        let yaw = dip(-25, over: 0.9)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw).isEmpty)
    }

    func testTurningAsideAndStayingIsNotASwipe() {
        var d = GestureDetector()
        let yaw = Array(repeating: 0.0, count: 5) + (0...5).map { -4.0 * Double($0) } + Array(repeating: -20.0, count: 30)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw).isEmpty)
    }

    func testTinyFlickIsNotASwipe() {
        var d = GestureDetector()
        let yaw = dip(-6, over: 0.2)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw).isEmpty)
    }

    func testSmallRelaxedFlickSwipes() {
        var d = GestureDetector()
        // About 11° out and back in a third of a second: easy on the neck.
        let yaw = dip(-11, over: 0.35)
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw).map(\.gesture), [.swipeRight])
    }

    func testGlanceAsideAndBackIsNotASwipe() {
        var d = GestureDetector()
        // Looking at something to the side and back takes longer than a flick, even
        // though part of it (mid-movement) fits in the flick window.
        let yaw = dip(-25, over: 0.6)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw).isEmpty)
    }

    // Real-world flicks (from a recording standing at a laptop, looking down): bigger,
    // a bit slower, back to back, sometimes with a wind-up. Shake is off by default.
    private var noShake: Set<HeadGesture> { all.subtracting([.shake]) }

    /// Smooth path through (value, seconds-to-get-there) waypoints at 25 Hz, from 0.
    private func path(_ points: [(Double, Double)], lead: Int = 5, tail: Int = 10) -> [Double] {
        var out = Array(repeating: 0.0, count: lead)
        var from = 0.0
        for (to, seconds) in points {
            let n = max(1, Int(seconds * hz))
            for i in 1...n { out.append(from + (to - from) * (1 - cos(.pi * Double(i) / Double(n))) / 2) }
            from = to
        }
        return out + Array(repeating: from, count: tail)
    }

    func testBigFastFlickTakingLongerStillSwipes() {
        var d = GestureDetector()
        let yaw = path([(-40, 0.3), (0, 0.32)])          // ~0.6 s out and back, fast at its peak
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: noShake).map(\.gesture), [.swipeRight])
    }

    func testSlowGlanceIsStillNotASwipeWithShakeOff() {
        var d = GestureDetector()
        let yaw = dip(-25, over: 0.6)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: noShake).isEmpty)
    }

    func testBackToBackFlicksEachSwipe() {
        var d = GestureDetector()
        // Flick right three times with only a brief stop at center between them.
        let one: [(Double, Double)] = [(-25, 0.2), (0, 0.24), (0, 0.12)]
        let yaw = path(one + one + one)
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: noShake).map(\.gesture),
                       [.swipeRight, .swipeRight, .swipeRight])
    }

    func testFlickWithOvershootFiresOnce() {
        var d = GestureDetector()
        // Comes back past center a little before settling: still one flick, not two.
        let yaw = path([(-25, 0.2), (7, 0.28), (0, 0.2)])
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: noShake).map(\.gesture), [.swipeRight])
    }

    func testWindUpBeforeAFlickDoesNotSwipeTheOtherWay() {
        var d = GestureDetector()
        // A small right wind-up, then the real flick left and back.
        let yaw = path([(-9, 0.16), (25, 0.28), (0, 0.28)])
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: noShake).map(\.gesture), [.swipeLeft])
    }

    func testPauseAtTheFarEndIsNotAFlickBack() {
        var d = GestureDetector()
        // Rest at center, flick right, stop briefly at the far end, then back to center:
        // the way back must not count as a left flick.
        let yaw = path([(0, 0.4), (-30, 0.2), (-30, 0.12), (0, 0.24), (0, 0.4), (-30, 0.2), (-30, 0.12), (0, 0.24)])
        let events = feed(&d, pitch: flat(yaw), yaw: yaw, enabled: noShake).map(\.gesture)
        XCTAssertFalse(events.contains(.swipeLeft))
    }

    func testGlancingUpFromTheLaptopIsNotANodUp() {
        var d = GestureDetector()
        // Looking up 25° to the screen above and straight back down: not a chin-up nod.
        XCTAssertTrue(feed(&d, pitch: dip(25, over: 0.45)).filter { $0.gesture == .nodUp }.isEmpty)
    }

    func testBriefRollIsNotATilt() {
        var d = GestureDetector()
        // A sideways head roll held under the tilt hold (e.g. flicking while looking down).
        let rolls = [0.0] + Array(repeating: 30.0, count: 11) + Array(repeating: 0.0, count: 10)
        XCTAssertTrue(tiltRun(&d, rolls: rolls).isEmpty)
    }

    func testShakeIsNotMistakenForSwipes() {
        var d = GestureDetector()
        // Every shake starts with a flick; it must still be one shake and nothing else.
        let n = Int(1.1 * hz)
        let yaw = Array(repeating: 0.0, count: 4) + (0...n).map { 18 * sin(2 * .pi * Double($0) / (0.5 * hz)) } + Array(repeating: 0.0, count: 15)
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw).map(\.gesture), [.shake])
    }

    func testTwoFlicksInARowAreNotAShake() {
        var d = GestureDetector()
        // Flick right, pause, flick right again: four swings within the shake window,
        // but with a stop in between. Must never pause tracking, even with swipes off.
        let yaw = dip(-20, over: 0.3, tail: 8) + dip(-20, over: 0.3, lead: 0)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: [.shake]).isEmpty)
        var both = GestureDetector()
        let events = feed(&both, pitch: flat(yaw), yaw: yaw).map(\.gesture)
        XCTAssertEqual(events.first, .swipeRight)
        XCTAssertFalse(events.contains(.shake))
    }

    func testLeftThenRightFlicksAreNotAShake() {
        var d = GestureDetector()
        let yaw = dip(20, over: 0.3, tail: 8) + dip(-20, over: 0.3, lead: 0)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: [.shake]).isEmpty)
    }

    func testSlowerShakeStillCounts() {
        var d = GestureDetector()
        // A lazier shake (0.65 s per back-and-forth) slows at each turn but never stops.
        let n = Int(1.35 * hz)
        let yaw = Array(repeating: 0.0, count: 4) + (0...n).map { 16 * sin(2 * .pi * Double($0) / (0.65 * hz)) } + Array(repeating: 0.0, count: 6)
        XCTAssertEqual(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: [.shake]).map(\.gesture), [.shake])
    }

    func testDisabledSwipeDoesNotFire() {
        var d = GestureDetector()
        let yaw = dip(-20, over: 0.3)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw, enabled: [.nod, .shake, .swipeLeft]).isEmpty)
    }

    func testSwipeAmplitudeSettingIsRespected() {
        var s = GestureSettings()
        s.swipeAmplitude = 25
        var d = GestureDetector(settings: s)
        let yaw = dip(-20, over: 0.3)
        XCTAssertTrue(feed(&d, pitch: flat(yaw), yaw: yaw).isEmpty)
    }

    // MARK: Tilt

    private func tiltRun(_ d: inout GestureDetector, rolls: [Double], start: Double = 0) -> [GestureEvent] {
        feed(&d, pitch: Array(repeating: 0, count: rolls.count), roll: rolls, start: start)
    }

    func testTiltFiresOnceAfterHold() {
        var s = GestureSettings()
        s.tiltAngle = 20
        s.tiltHold = 0.3
        var d = GestureDetector(settings: s)
        var events = tiltRun(&d, rolls: Array(repeating: 0, count: 5) + Array(repeating: 30, count: 30))
        XCTAssertEqual(events.map(\.gesture), [.tiltRight])
        events += tiltRun(&d, rolls: Array(repeating: 0, count: 5) + Array(repeating: -30, count: 15), start: 35 / hz)
        XCTAssertEqual(events.map(\.gesture), [.tiltRight, .tiltLeft])
    }

    func testSwapTiltDirection() {
        var s = GestureSettings()
        s.swapTiltDirection = true
        var d = GestureDetector(settings: s)
        XCTAssertEqual(tiltRun(&d, rolls: [0] + Array(repeating: 30, count: 20)).map(\.gesture), [.tiltLeft])
    }

    func testBriefTiltDoesNotFire() {
        var d = GestureDetector()
        XCTAssertTrue(tiltRun(&d, rolls: [0, 0, 30, 30, 0, 0]).isEmpty)
    }

    func testStaleNeutralRecovers() {
        var d = GestureDetector()
        // Neutral captured at a weird angle (e.g. while inserting the AirPods)…
        _ = tiltRun(&d, rolls: [50])
        // …then the user sits upright for a while.
        _ = tiltRun(&d, rolls: Array(repeating: 0, count: 150), start: 1 / hz)
        XCTAssertEqual(d.relativeRoll(0), 0, accuracy: 1)
        // A real tilt from the new neutral still fires.
        let events = tiltRun(&d, rolls: Array(repeating: 30, count: 20), start: 151 / hz)
        XCTAssertEqual(events.map(\.gesture), [.tiltRight])
    }
}

final class DwellTests: XCTestCase {
    private func settings() -> DwellSettings {
        var s = DwellSettings()
        s.enabled = true
        s.duration = 1.0
        s.radius = 10
        return s
    }

    func testFiresOnceAfterMovingThenResting() {
        var d = DwellDetector(settings: settings())
        _ = d.update(position: Vec2(0, 0), time: 0)
        _ = d.update(position: Vec2(50, 0), time: 0.1)   // movement arms it
        var fires = 0
        var t = 0.1
        while t < 4 {
            t += 1.0 / 60
            if d.update(position: Vec2(52, 1), time: t).fired { fires += 1 }
        }
        XCTAssertEqual(fires, 1)
    }

    func testDoesNotFireWithoutMovement() {
        var d = DwellDetector(settings: settings())
        var t = 0.0
        while t < 3 {
            XCTAssertFalse(d.update(position: Vec2(5, 5), time: t).fired)
            t += 0.05
        }
    }

    func testContinuousMovementNeverFires() {
        var d = DwellDetector(settings: settings())
        var t = 0.0
        var x = 0.0
        while t < 3 {
            XCTAssertFalse(d.update(position: Vec2(x, 0), time: t).fired)
            t += 0.05
            x += 15
        }
    }

    func testAnchorIDChangesOnlyWhenPointerSettlesSomewhereNew() {
        var d = DwellDetector(settings: settings())
        _ = d.update(position: .zero, time: 0)
        _ = d.update(position: Vec2(50, 0), time: 0.1)
        let first = d.anchorID
        _ = d.update(position: Vec2(52, 2), time: 0.2)
        XCTAssertEqual(d.anchorID, first)
        _ = d.update(position: Vec2(120, 0), time: 0.3)
        XCTAssertNotEqual(d.anchorID, first)
        XCTAssertEqual(d.anchorPosition, Vec2(120, 0))
    }

    func testRestartTimerGivesASuppressedClickAnotherRest() {
        var d = DwellDetector(settings: settings())
        _ = d.update(position: .zero, time: 0)
        _ = d.update(position: Vec2(40, 0), time: 0)          // moved: armed
        XCTAssertTrue(d.update(position: Vec2(40, 0), time: 1.0).fired)
        // The app wasn't sure yet, so it asks for another full rest at the same spot.
        d.restartTimer(at: 1.0)
        XCTAssertFalse(d.update(position: Vec2(40, 0), time: 1.5).fired)
        XCTAssertTrue(d.update(position: Vec2(41, 0), time: 2.0).fired)
        // Without a restart, resting longer never fires again.
        XCTAssertFalse(d.update(position: Vec2(41, 0), time: 5.0).fired)
    }

    func testRestartTimerNeedsARestingSpot() {
        var d = DwellDetector(settings: settings())
        d.restartTimer(at: 0)                                  // nothing to restart yet
        XCTAssertFalse(d.update(position: .zero, time: 0).fired)
        XCTAssertFalse(d.update(position: .zero, time: 3).fired)
    }

    func testProgressRevealsAndResetDisarms() {
        var d = DwellDetector(settings: settings())
        _ = d.update(position: .zero, time: 0)
        _ = d.update(position: Vec2(40, 0), time: 0)
        XCTAssertNil(d.update(position: Vec2(40, 0), time: 0.1).progress)
        XCTAssertEqual(d.update(position: Vec2(40, 0), time: 0.5).progress ?? 0, 0.5, accuracy: 1e-9)
        d.reset()
        XCTAssertFalse(d.update(position: Vec2(40, 0), time: 2).fired)
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = AppSettings()
        s.pointer.sensitivity = 2.5
        s.actions[.nod] = .doubleClick
        s.dwell.enabled = true
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), s)
    }

    func testMissingAndUnknownKeysFallBackToDefaults() throws {
        let json = #"{"pointer":{"sensitivity":3},"actions":{"nod":"rightClick","bogus":"leftClick","shake":"notAnAction"},"futureKey":1}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.pointer.sensitivity, 3)
        XCTAssertEqual(s.pointer.deadzone, PointerSettings().deadzone)
        XCTAssertEqual(s.actions[.nod], .rightClick)
        XCTAssertEqual(s.actions[.shake], ActionMap.defaults[.shake])
        XCTAssertEqual(s.gestures, GestureSettings())
    }

    func testV1SettingsMigrateToSmartHoverClick() throws {
        let v1 = #"{"dwell":{"enabled":false,"duration":1.0},"gestures":{"nodAmplitude":9},"pointer":{"sensitivity":2}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v1.utf8)).migrated()
        XCTAssertTrue(s.dwell.enabled)
        XCTAssertTrue(s.dwell.smart)
        XCTAssertEqual(s.gestures.nodAmplitude, GestureSettings().nodAmplitude)
        XCTAssertEqual(s.pointer.sensitivity, 2)          // unrelated choices survive
        XCTAssertEqual(s.version, AppSettings.currentVersion)
    }

    func testV2SettingsGetDeliberateShake() throws {
        let v2 = #"{"version":2,"gestures":{"shakeAmplitude":8,"shakeWindow":1.1},"dwell":{"enabled":false}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v2.utf8)).migrated()
        XCTAssertEqual(s.gestures.shakeAmplitude, GestureSettings().shakeAmplitude)
        XCTAssertFalse(s.dwell.enabled)   // a v2 user's own hover-click choice is kept
    }

    func testV3SettingsMovePauseFromShakeToTiltRight() throws {
        let v3 = #"{"version":3,"actions":{"shake":"toggleTracking","tiltRight":"none","tiltLeft":"missionControl"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v3.utf8)).migrated()
        XCTAssertEqual(s.actions[.shake], PointerAction.none)
        XCTAssertEqual(s.actions[.tiltRight], .toggleTracking)
        XCTAssertEqual(s.actions[.tiltLeft], .missionControl)   // unrelated choices survive
        XCTAssertTrue(s.actions.headGestureCanToggleTracking)
        XCTAssertEqual(s.version, AppSettings.currentVersion)
    }

    func testV3CustomPauseChoicesAreKept() throws {
        let v3 = #"{"version":3,"actions":{"shake":"toggleTracking","tiltRight":"forward"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v3.utf8)).migrated()
        XCTAssertEqual(s.actions[.shake], .toggleTracking)
        XCTAssertEqual(s.actions[.tiltRight], .forward)
    }

    func testV4SettingsGetEasierFlicks() throws {
        let v4 = #"{"version":4,"gestures":{"swipeAmplitude":15,"swipeWindow":0.6,"nodAmplitude":7}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v4.utf8)).migrated()
        XCTAssertEqual(s.gestures.swipeAmplitude, GestureSettings().swipeAmplitude)
        XCTAssertEqual(s.gestures.swipeWindow, GestureSettings().swipeWindow)
        XCTAssertEqual(s.gestures.nodAmplitude, 7)

        let tuned = #"{"version":4,"gestures":{"swipeAmplitude":22}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(tuned.utf8)).migrated().gestures.swipeAmplitude, 22)
    }

    func testV5SettingsGetZoomOnTiltLeftWhenFree() throws {
        let free = #"{"version":5,"actions":{"tiltLeft":"none","tiltRight":"toggleTracking"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(free.utf8)).migrated()
        XCTAssertEqual(s.actions[.tiltLeft], .toggleZoomMode)
        XCTAssertEqual(s.actions[.tiltRight], .toggleTracking)

        let taken = #"{"version":5,"actions":{"tiltLeft":"missionControl"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(taken.utf8)).migrated().actions[.tiltLeft], .missionControl)
    }

    func testModeSwitchActions() {
        XCTAssertTrue(ActionMap.isModeSwitch(.toggleZoomMode))
        XCTAssertTrue(ActionMap.isModeSwitch(.toggleScrollMode))
        XCTAssertTrue(ActionMap.isModeSwitch(.toggleTracking))
        XCTAssertFalse(ActionMap.isModeSwitch(.leftClick))
        XCTAssertFalse(ActionMap.isModeSwitch(.missionControl))
        XCTAssertEqual(ActionMap()[.tiltLeft], .toggleZoomMode)
    }

    func testOlderSettingsGainNodUpForScrollMode() throws {
        let v6 = #"{"version":6,"actions":{"nod":"leftClick","stemTriple":"toggleScrollMode"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v6.utf8)).migrated()
        XCTAssertEqual(s.actions[.nodUp], .toggleScrollMode)
        XCTAssertEqual(s.actions[.nod], .leftClick)
        XCTAssertTrue(ActionMap.isModeSwitch(s.actions[.nodUp]))
    }

    func testV6SettingsGetLongerTiltHold() throws {
        let v6 = #"{"version":6,"gestures":{"tiltHold":0.3}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(v6.utf8)).migrated().gestures.tiltHold,
                       GestureSettings().tiltHold)
        let tuned = #"{"version":6,"gestures":{"tiltHold":0.8}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(tuned.utf8)).migrated().gestures.tiltHold, 0.8)
    }

    func testTripleStemPressDictatesByDefault() {
        let m = ActionMap()
        XCTAssertEqual(m[.stemTriple], .dictate)
        XCTAssertEqual(m[.nodUp], .toggleScrollMode)              // scroll mode stays reachable
        XCTAssertFalse(ActionMap.isModeSwitch(.dictate))
        XCTAssertTrue(PointerAction.groups.contains { $0.actions.contains(.dictate) && $0.actions.contains(.pressReturn) })
    }

    func testV7SettingsGetDictationOnTripleStemPress() throws {
        let v7 = #"{"version":7,"actions":{"stemTriple":"toggleScrollMode","nodUp":"toggleScrollMode"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(v7.utf8)).migrated().actions[.stemTriple], .dictate)

        // If the chin-up nod isn't scroll mode, the triple press keeps it so no one loses scrolling.
        let noNod = #"{"version":7,"actions":{"stemTriple":"toggleScrollMode","nodUp":"none"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(noNod.utf8)).migrated().actions[.stemTriple], .toggleScrollMode)

        let custom = #"{"version":7,"actions":{"stemTriple":"screenshot"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(custom.utf8)).migrated().actions[.stemTriple], .screenshot)
    }

    func testCurrentSettingsAreNotReMigrated() throws {
        var s = AppSettings()
        s.dwell.enabled = false
        let data = try JSONEncoder().encode(s)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: data).migrated().dwell.enabled)
    }

    func testOlderSettingsGainSwipesAndContinuousScroll() throws {
        let v3 = #"{"version":3,"pointer":{"scrollSpeed":2},"actions":{"nod":"rightClick"},"gestures":{"nodAmplitude":7}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v3.utf8)).migrated()
        XCTAssertEqual(s.actions[.swipeLeft], .previousSpace)
        XCTAssertEqual(s.actions[.swipeRight], .nextSpace)
        XCTAssertTrue(s.actions.enabledHeadGestures.isSuperset(of: [.swipeLeft, .swipeRight]))
        XCTAssertTrue(s.pointer.continuousScroll)
        XCTAssertEqual(s.gestures.swipeAmplitude, GestureSettings().swipeAmplitude)
        XCTAssertEqual(s.pointer.scrollSpeed, 2)        // the user's own choices survive
        XCTAssertEqual(s.actions[.nod], .rightClick)
        XCTAssertEqual(s.gestures.nodAmplitude, 7)
    }

    func testSwipeChoicesRoundTrip() throws {
        var s = AppSettings()
        s.actions[.swipeRight] = .none
        s.pointer.continuousScroll = false
        s.gestures.swipeAmplitude = 22
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertFalse(back.actions.enabledHeadGestures.contains(.swipeRight))
    }

    func testActionMapQueries() {
        var m = ActionMap()
        XCTAssertTrue(m.headGestureCanToggleTracking)  // tilt right by default
        XCTAssertFalse(m.stemCanToggleTracking)
        m[.tiltRight] = .none
        m[.nod] = .none
        XCTAssertFalse(m.headGestureCanToggleTracking)
        XCTAssertFalse(m.enabledHeadGestures.contains(.nod))
        m[.stemTriple] = .toggleTracking
        XCTAssertTrue(m.stemCanToggleTracking)
    }
}
