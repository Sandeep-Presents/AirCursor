import Foundation

/// Maps head angular velocity to cursor velocity.
///
/// Velocity ("relative") mapping is used rather than absolute angle mapping: it never
/// needs recalibration, survives sensor drift, and lets you "ratchet" across large or
/// multiple displays the way you'd lift and re-place a mouse.
public enum PointerMapper {
    /// Cursor pixels per degree of head rotation at sensitivity 1, no acceleration.
    public static let pixelsPerDegree: Double = 28

    /// Speed (px/s) for one axis given a rotation rate in deg/s. Sign is preserved.
    public static func axisSpeed(_ rate: Double, settings: PointerSettings) -> Double {
        let magnitude = abs(rate)
        guard magnitude > settings.deadzone else { return 0 }
        let effective = magnitude - settings.deadzone
        // Gentle, bounded acceleration: slow head = precise, fast head = travel.
        let boost = 1 + settings.acceleration * min(effective / 60, 3)
        let speed = effective * pixelsPerDegree * settings.sensitivity * boost
        return rate < 0 ? -speed : speed
    }

    /// Cursor velocity in screen points per second, in CoreGraphics global
    /// coordinates (origin top-left, +y is down).
    ///
    /// Turning the head left (+yaw) moves the cursor left; looking up (+pitch) moves it up.
    public static func cursorVelocity(rates: AngularRates, settings: PointerSettings) -> Vec2 {
        var dx = -axisSpeed(rates.yaw, settings: settings)
        var dy = -axisSpeed(rates.pitch, settings: settings)
        if settings.invertHorizontal { dx = -dx }
        if settings.invertVertical { dy = -dy }
        return Vec2(dx, dy)
    }
}

/// Headphone motion arrives at ~25 Hz; the screen refreshes at 60–120 Hz. The smoother
/// eases the cursor toward the latest target velocity every frame so motion is fluid,
/// and stops it promptly if samples go stale (AirPods removed or disconnected).
public struct PointerSmoother: Sendable {
    public static let staleAfter: TimeInterval = 0.12

    public private(set) var velocity: Vec2 = .zero
    private var target: Vec2 = .zero
    private var targetTime: TimeInterval = -.infinity

    public init() {}

    public mutating func setTarget(_ v: Vec2, at time: TimeInterval) {
        target = v
        targetTime = time
    }

    public mutating func reset() {
        velocity = .zero
        target = .zero
        targetTime = -.infinity
    }

    /// Advances by `dt` seconds and returns the cursor displacement for this frame.
    public mutating func step(now: TimeInterval, dt: Double, smoothing: Double) -> Vec2 {
        guard dt > 0 else { return .zero }
        let goal = (now - targetTime) > Self.staleAfter ? .zero : target
        let s = min(max(smoothing, 0), 0.97)
        // Frame-rate independent exponential smoothing (s is the per-1/60s retention).
        let alpha = 1 - pow(s, dt * 60)
        velocity += (goal - velocity) * alpha
        if goal == .zero, velocity.length < 2 { velocity = .zero }
        return velocity * dt
    }
}

/// Recent cursor positions, so a head gesture can click where you were pointing
/// *before* the gesture itself nudged the cursor.
public struct CursorHistory: Sendable {
    private var buffer: [(time: TimeInterval, position: Vec2)] = []
    private var head = 0
    public let capacity: Int

    public init(capacity: Int = 360) {
        self.capacity = max(1, capacity)
        buffer.reserveCapacity(self.capacity)
    }

    public mutating func append(_ position: Vec2, at time: TimeInterval) {
        if buffer.count < capacity {
            buffer.append((time, position))
        } else {
            buffer[head] = (time, position)
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Most recent position recorded at or before `time`; the oldest one if `time`
    /// predates the buffer; nil if empty.
    public func position(at time: TimeInterval) -> Vec2? {
        guard !buffer.isEmpty else { return nil }
        let ordered = buffer.count < capacity ? buffer : Array(buffer[head...] + buffer[..<head])
        var best = ordered[0].position
        for entry in ordered {
            if entry.time <= time { best = entry.position } else { break }
        }
        return best
    }
}

/// Continuous ("joystick") scrolling: hold your head up or down from where it was when
/// scroll mode started and the page keeps scrolling, faster the further you lean,
/// until you come back to neutral. Unlike the velocity mapping, a still head keeps
/// scrolling, so long pages don't need repeated head bobs.
public struct ScrollJoystick: Sendable {
    /// Degrees of pitch around neutral that don't scroll (reading posture wobble).
    public static let deadzone = 4.0
    /// Scroll speed (points/s) at scroll speed 1: linear + quadratic in degrees past the dead zone.
    public static let linearGain = 40.0
    public static let quadraticGain = 4.0
    public static let maxSpeed = 4000.0
    /// How long the speed takes to ease toward its target (seconds, ~63%). Slowing
    /// down is quicker than speeding up, so coming back level stops the page crisply.
    public static let easing: TimeInterval = 0.12
    public static let stopEasing: TimeInterval = 0.05

    public private(set) var neutralPitch: Double?
    public private(set) var speed = 0.0
    private var target = 0.0
    private var targetTime: TimeInterval = -.infinity

    public init() {}

    /// Forget neutral; the next sample becomes it. Call when scroll mode starts or on recenter.
    public mutating func reset() {
        neutralPitch = nil
        speed = 0
        target = 0
        targetTime = -.infinity
    }

    /// Target vertical scroll velocity (points/s, screen direction: negative = up)
    /// for a head pitch in degrees (+ = looking up).
    public static func velocity(offset: Double, scrollSpeed: Double) -> Double {
        let excess = abs(offset) - deadzone
        guard excess > 0 else { return 0 }
        let magnitude = min((linearGain * excess + quadraticGain * excess * excess) * scrollSpeed, maxSpeed)
        // Looking up reveals content above, matching the cursor (up = negative y).
        return offset > 0 ? -magnitude : magnitude
    }

    /// Feed each motion sample's pitch (degrees).
    public mutating func update(pitch: Double, scrollSpeed: Double, at time: TimeInterval) {
        guard let neutral = neutralPitch else {
            neutralPitch = pitch
            return
        }
        target = Self.velocity(offset: pitch - neutral, scrollSpeed: scrollSpeed)
        targetTime = time
    }

    /// Advances by `dt` and returns this frame's vertical scroll distance in points.
    /// Stops if samples go stale (AirPods removed or disconnected).
    public mutating func step(now: TimeInterval, dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        let goal = (now - targetTime) > PointerSmoother.staleAfter ? 0 : target
        let slowing = abs(goal) < abs(speed) || goal * speed < 0
        speed += (goal - speed) * (1 - exp(-dt / (slowing ? Self.stopEasing : Self.easing)))
        if goal == 0, abs(speed) < 5 { speed = 0 }
        return speed * dt
    }
}

/// Zoom mode: hold your head up to zoom in, down to zoom out, level to stop. Produces a
/// smooth, continuous pinch (magnification per frame), like spreading or closing two
/// fingers on a trackpad, faster the further you lean.
public struct ZoomJoystick: Sendable {
    /// Degrees of pitch around neutral that don't zoom.
    public static let deadzone = 6.0
    /// Pinch speed (magnification per second) just past the dead zone, per extra degree, and the cap.
    public static let baseRate = 0.35
    public static let ratePerDegree = 0.05
    public static let maxRate = 2.0
    /// Easing toward the target speed (seconds); stopping is quicker so it halts crisply.
    public static let easing: TimeInterval = 0.15
    public static let stopEasing: TimeInterval = 0.05

    public private(set) var neutralPitch: Double?
    /// Current pinch speed (magnification per second; + = zooming in).
    public private(set) var speed = 0.0
    private var target = 0.0
    private var targetTime: TimeInterval = -.infinity

    public init() {}

    /// Forget neutral; the next sample becomes it. Call when zoom mode starts or on recenter.
    public mutating func reset() {
        neutralPitch = nil
        speed = 0
        target = 0
        targetTime = -.infinity
    }

    /// Target pinch speed for a pitch offset from neutral (degrees, + = looking up).
    public static func velocity(offset: Double) -> Double {
        let excess = abs(offset) - deadzone
        guard excess > 0 else { return 0 }
        let magnitude = min(baseRate + ratePerDegree * excess, maxRate)
        return offset > 0 ? magnitude : -magnitude
    }

    /// Feed each motion sample's pitch (degrees).
    public mutating func update(pitch: Double, at time: TimeInterval) {
        guard let neutral = neutralPitch else {
            neutralPitch = pitch
            return
        }
        target = Self.velocity(offset: pitch - neutral)
        targetTime = time
    }

    /// Advances by `dt`; returns this frame's magnification (+ in, − out, 0 = not pinching).
    /// Stops if samples go stale (AirPods removed or disconnected).
    public mutating func step(now: TimeInterval, dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        let goal = (now - targetTime) > PointerSmoother.staleAfter ? 0 : target
        let slowing = abs(goal) < abs(speed) || goal * speed < 0
        speed += (goal - speed) * (1 - exp(-dt / (slowing ? Self.stopEasing : Self.easing)))
        if goal == 0, abs(speed) < 0.02 { speed = 0 }
        return speed * dt
    }
}
