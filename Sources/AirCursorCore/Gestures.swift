import Foundation

public enum HeadGesture: String, Sendable, CaseIterable {
    case nod, shake, tiltLeft, tiltRight
    /// A nod upward (chin up and back). Only told apart from `nod` when it's enabled;
    /// otherwise upward nods count as plain nods, as they always have.
    case nodUp
    /// A quick flick of the head to one side and back (like a three-finger swipe).
    case swipeLeft, swipeRight
}

public struct GestureEvent: Equatable, Sendable {
    public let gesture: HeadGesture
    /// When the movement began (sample clock), used to undo the cursor drift it caused.
    public let startTime: TimeInterval
    public let time: TimeInterval
    /// Size of the movement in degrees (nod depth, shake swing, tilt angle).
    public let magnitude: Double
    /// How long the movement itself took, from when the head actually started moving
    /// (`startTime` may include a still moment before it).
    public let duration: TimeInterval

    public init(gesture: HeadGesture, startTime: TimeInterval, time: TimeInterval, magnitude: Double,
                duration: TimeInterval? = nil) {
        self.gesture = gesture
        self.startTime = startTime
        self.time = time
        self.magnitude = magnitude
        self.duration = duration ?? (time - startTime)
    }

    /// Longest a nod may take (start to back) to count while scrolling or zooming. Those
    /// modes are all about leaning up and back, so only a short, snappy nod switches mode.
    public static let snappyNodDuration: TimeInterval = 0.5

    public var isSnappy: Bool { duration <= Self.snappyNodDuration }
}

/// Detects deliberate head gestures from the head's *angle over time*.
///
/// Shape-based detection is far more reliable than speed thresholds: AirPods report
/// ~25 samples/s, so the peak speed of a natural nod is often missed, but its shape —
/// dip a few degrees, come back — always shows up.
///
/// - Nod: pitch leaves its starting angle by ≥ `nodAmplitude`, then returns most of
///   the way, within `nodWindow`, with little sideways motion. Either direction.
/// - Shake: yaw swings back and forth ≥ `shakeAmplitude` at least four times within
///   `shakeWindow`, with little vertical motion.
/// - Tilt: roll held beyond `tiltAngle` from the neutral posture for `tiltHold`.
///   Fires once, then re-arms when the head returns toward neutral.
/// - Swipe: from a still head at its resting place, yaw flicks ≥ `swipeAmplitude` to one
///   side and comes back (the head arriving, not swinging through). Quick flicks (within
///   `swipeWindow`) always count; bigger ones up to `longSwipeWindow` count if fast at
///   their peak, so glances (slower) don't. Turning right = `swipeRight`. With shake off,
///   flicks fire right away and can follow each other back to back; with shake on they
///   wait for the head to settle, which is what tells a flick from a shake's first half.
public struct GestureDetector: Sendable {
    public var settings: GestureSettings

    private struct Pose {
        let t: TimeInterval
        let yaw: Double    // degrees, unwrapped (continuous)
        let pitch: Double  // degrees
    }

    private var history: [Pose] = []
    private var lastRawYaw: Double?
    private var cooldownUntil: TimeInterval = -.infinity
    /// After a gesture fires, nothing re-arms until the head settles, so one nod or
    /// shake (including its follow-through) can never fire twice.
    private var awaitingStill = false
    private var stillSince: TimeInterval?
    private var rollBaseline: Double?
    private var tiltCandidate: (gesture: HeadGesture, since: TimeInterval)?
    private var tiltLatched = false
    private var offNeutralSince: TimeInterval?
    /// A completed flick waiting for the head to settle before it fires.
    private var pendingSwipe: GestureEvent?
    private var swipeStillSince: TimeInterval?
    /// Flicks that began before this were already judged; don't re-detect them.
    private var swipeConsumedThrough: TimeInterval = -.infinity
    /// Where the head last rested (yaw, degrees). Flicks start from rest, so a pause at the
    /// far end of one flick can't be the start of another one back.
    private var restYaw: Double?
    private var restCandidateSince: TimeInterval?

    /// A head held off-neutral this long is a new posture (or a stale baseline taken
    /// while the AirPods were being put in), so it becomes the new neutral.
    static let reNeutralAfter: TimeInterval = 4
    /// A nod must come back at least this fraction of the way to where it started.
    static let nodReturnFraction = 0.65
    /// Sideways motion allowed during a nod, relative to its depth (and vice versa for shakes).
    static let crossAxisAllowance = 0.6
    /// Movements slower than this (deg/s at their fastest) are deliberate pointing, not gestures.
    static let minNodSpeed = 30.0
    static let minShakeSpeed = 80.0
    /// Swings needed for a shake: left-right-left-right. Three can happen just by
    /// glancing left, then right, then back to the screen.
    static let shakeSwings = 4
    /// A shake is one continuous back-and-forth. If the head stops this long between
    /// swings, they were separate movements (e.g. two flicks in a row), not a shake.
    static let shakeMaxPause: TimeInterval = 0.25
    static let historySpan: TimeInterval = 1.5
    /// Head speed (deg/s) below which it counts as settled, and for how long.
    static let settledSpeed = 25.0
    static let settledFor: TimeInterval = 0.15
    /// Floor on a flick's peak speed, so slow drift that happens to come back never counts.
    static let minSwipeSpeed = 60.0
    /// A flick starts from a nearly still head (looking at the screen).
    static let swipeStartSpeed = 50.0
    /// How far the head may swing past the start the other way and still be one flick.
    static let swipeOvershootFraction = 0.5
    /// A flick that hasn't settled this long after returning was part of something else.
    static let swipeSettleTimeout: TimeInterval = 0.5
    /// Big flicks take longer. A flick up to this long still counts if it's fast at its
    /// peak (a glance at another window is slower than that).
    static let longSwipeWindow: TimeInterval = 0.75
    static let fastSwipeSpeed = 150.0
    /// After a flick, how soon the next one may start (back-to-back flicks), when no
    /// shake is listening. Starting-from-still still keeps a flick's own rebound out.
    static let swipeRearm: TimeInterval = 0.2
    /// Upward "nods" bigger than this are looking up at something, not a chin-up nod.
    static let maxNodUpDepth = 20.0

    public init(settings: GestureSettings = GestureSettings()) {
        self.settings = settings
    }

    /// Current roll relative to neutral, in degrees (for live display).
    public func relativeRoll(_ rollDegrees: Double) -> Double {
        guard let base = rollBaseline else { return 0 }
        return AngleMath.wrappedDeltaDegrees(rollDegrees, base)
    }

    public mutating func resetTiltBaseline(to rollDegrees: Double? = nil) {
        rollBaseline = rollDegrees
        offNeutralSince = nil
        tiltCandidate = nil
        tiltLatched = false
    }

    public mutating func reset() {
        history.removeAll()
        lastRawYaw = nil
        cooldownUntil = -.infinity
        awaitingStill = false
        stillSince = nil
        pendingSwipe = nil
        swipeStillSince = nil
        swipeConsumedThrough = -.infinity
        restYaw = nil
        restCandidateSince = nil
        resetTiltBaseline()
    }

    /// Feed every motion sample (angles in radians, as CoreMotion reports them).
    public mutating func process(_ sample: MotionSample, enabled: Set<HeadGesture>) -> GestureEvent? {
        let t = sample.timestamp
        let rawYaw = AngleMath.degrees(sample.yaw)
        let pitch = AngleMath.degrees(sample.pitch)
        let roll = AngleMath.degrees(sample.roll)

        // Unwrap yaw so a turn across ±180° stays continuous; drop history after gaps.
        if let last = history.last, t - last.t > MotionDifferentiator.maxInterval || t <= last.t {
            history.removeAll()
            lastRawYaw = nil
        }
        let yaw: Double
        if let prev = lastRawYaw, let last = history.last {
            yaw = last.yaw + AngleMath.wrappedDeltaDegrees(rawYaw, prev)
        } else {
            yaw = rawYaw
        }
        lastRawYaw = rawYaw
        history.append(Pose(t: t, yaw: yaw, pitch: pitch))
        if let first = history.first, t - first.t > Self.historySpan {
            history.removeAll { t - $0.t > Self.historySpan }
        }

        let tilt = updateTilt(rollDegrees: roll, time: t, enabled: enabled)
        updateRest(time: t)

        if awaitingStill {
            let speed = history.count >= 2 ? peakSpeedBetween(history[history.count - 2], history[history.count - 1]) : 0
            if speed < Self.settledSpeed {
                stillSince = stillSince ?? t
                if t - (stillSince ?? t) >= Self.settledFor {
                    awaitingStill = false
                    stillSince = nil
                    // Start fresh from the settled pose.
                    history = Array(history.suffix(1))
                }
            } else {
                stillSince = nil
            }
            return nil
        }

        guard t >= cooldownUntil else { return nil }
        if enabled.contains(.nod) || enabled.contains(.nodUp), let e = detectNod(now: t, enabled: enabled) { return fire(e) }
        if enabled.contains(.shake), let e = detectShake(now: t) { return fire(e) }
        if let e = tilt { return fire(e) }
        if enabled.contains(.swipeLeft) || enabled.contains(.swipeRight),
           let e = updateSwipe(now: t, enabled: enabled) {
            // Without a shake to tell apart, flicks can follow each other back to back.
            return enabled.contains(.shake) ? fire(e) : fireSwipeQuickly(e)
        }
        return nil
    }

    /// Fires a swipe without waiting for the head to settle, so flick-flick-flick works.
    /// Its own movement can't fire again: history up to now is consumed, and a new flick
    /// must start from a still head (a rebound is still moving).
    private mutating func fireSwipeQuickly(_ event: GestureEvent) -> GestureEvent {
        cooldownUntil = event.time + Self.swipeRearm
        swipeConsumedThrough = event.time
        // A flick comes back to where it started: that's the resting place for the next one.
        if let origin = history.last(where: { $0.t <= event.startTime }) ?? history.first { restYaw = origin.yaw }
        tiltCandidate = nil
        pendingSwipe = nil
        swipeStillSince = nil
        return event
    }

    private mutating func fire(_ event: GestureEvent) -> GestureEvent {
        cooldownUntil = event.time + settings.cooldown
        awaitingStill = true
        stillSince = nil
        tiltCandidate = nil
        pendingSwipe = nil
        swipeStillSince = nil
        return event
    }

    /// Tracks where the head rests: still (below settled speed) for `settledFor`.
    private mutating func updateRest(time t: TimeInterval) {
        guard history.count >= 2, let current = history.last else { return }
        if peakSpeedBetween(history[history.count - 2], current) < Self.settledSpeed {
            restCandidateSince = restCandidateSince ?? t
            if t - (restCandidateSince ?? t) >= Self.settledFor { restYaw = current.yaw }
        } else {
            restCandidateSince = nil
        }
    }

    private static func arrivalSpeed(_ a: Pose, _ b: Pose) -> Double {
        guard b.t > a.t else { return 0 }
        return abs(b.yaw - a.yaw) / (b.t - a.t)
    }

    private func peakSpeedBetween(_ a: Pose, _ b: Pose) -> Double {
        guard b.t > a.t else { return 0 }
        return max(abs(b.pitch - a.pitch), abs(b.yaw - a.yaw)) / (b.t - a.t)
    }

    // MARK: Nod

    private func detectNod(now: TimeInterval, enabled: Set<HeadGesture>) -> GestureEvent? {
        guard history.count >= 3, let current = history.last else { return nil }
        let lastIndex = history.count - 1

        // Try every start point in the window, oldest first (earliest start = best
        // cursor-restore point).
        for j in 0..<(lastIndex - 1) where now - history[j].t <= settings.nodWindow {
            let start = history[j]
            var extreme = 0.0
            var extremeIndex = j
            for k in (j + 1)..<lastIndex {
                let d = history[k].pitch - start.pitch
                if abs(d) > abs(extreme) { extreme = d; extremeIndex = k }
            }
            let depth = abs(extreme)
            guard depth >= settings.nodAmplitude, extremeIndex > j else { continue }

            let remaining = abs(current.pitch - start.pitch)
            guard remaining <= depth * (1 - Self.nodReturnFraction) else { continue }

            let segment = history[j...lastIndex]
            let yawRange = (segment.map(\.yaw).max() ?? 0) - (segment.map(\.yaw).min() ?? 0)
            guard yawRange <= max(depth * Self.crossAxisAllowance, 3) else { continue }
            guard peakSpeed(segment, \.pitch) >= Self.minNodSpeed else { continue }

            // +pitch is looking up. Upward nods are their own gesture only when enabled.
            let gesture: HeadGesture = extreme > 0 && enabled.contains(.nodUp) ? .nodUp : .nod
            guard enabled.contains(gesture) else { continue }
            if gesture == .nodUp {
                // Glancing up from a laptop and back is bigger than a chin-up nod. It must
                // start from a still head, so a start partway up can't shrink a glance.
                if depth > Self.maxNodUpDepth { continue }
                if j > 0, peakSpeedBetween(history[j - 1], start) >= Self.swipeStartSpeed { continue }
            }
            // The head really started moving at the last sample still near the start.
            var departure = j
            for k in j..<extremeIndex where abs(history[k].pitch - start.pitch) <= depth * 0.2 { departure = k }
            return GestureEvent(gesture: gesture, startTime: start.t, time: now, magnitude: depth,
                                duration: now - history[departure].t)
        }
        return nil
    }

    // MARK: Shake

    private func detectShake(now: TimeInterval) -> GestureEvent? {
        let window = history.filter { now - $0.t <= settings.shakeWindow }
        guard window.count >= 4, let first = window.first else { return nil }

        var anchor = first.yaw
        var direction = 0
        var swings = 0
        var largest = 0.0
        var firstSwingIndex = 0, lastSwingIndex = 0
        for (i, pose) in window.enumerated().dropFirst() {
            let d = pose.yaw - anchor
            switch direction {
            case 0:
                if abs(d) >= settings.shakeAmplitude {
                    direction = d > 0 ? 1 : -1
                    swings = 1
                    largest = abs(d)
                    anchor = pose.yaw
                    firstSwingIndex = i; lastSwingIndex = i
                }
            case 1:
                if pose.yaw > anchor { anchor = pose.yaw }
                else if anchor - pose.yaw >= settings.shakeAmplitude {
                    swings += 1; largest = max(largest, anchor - pose.yaw)
                    direction = -1; anchor = pose.yaw
                    lastSwingIndex = i
                }
            default:
                if pose.yaw < anchor { anchor = pose.yaw }
                else if pose.yaw - anchor >= settings.shakeAmplitude {
                    swings += 1; largest = max(largest, pose.yaw - anchor)
                    direction = 1; anchor = pose.yaw
                    lastSwingIndex = i
                }
            }
        }
        guard swings >= Self.shakeSwings else { return nil }
        guard longestPause(window, from: firstSwingIndex, to: lastSwingIndex) < Self.shakeMaxPause else { return nil }

        let pitchRange = (window.map(\.pitch).max() ?? 0) - (window.map(\.pitch).min() ?? 0)
        guard pitchRange <= largest * Self.crossAxisAllowance else { return nil }
        guard peakSpeed(window[...], \.yaw) >= Self.minShakeSpeed else { return nil }

        return GestureEvent(gesture: .shake, startTime: first.t, time: now, magnitude: largest)
    }

    // MARK: Swipe

    /// Finds a completed flick, then holds it until the head settles. Returns it once
    /// it's safe to fire.
    private mutating func updateSwipe(now: TimeInterval, enabled: Set<HeadGesture>) -> GestureEvent? {
        if let pending = pendingSwipe {
            guard now - pending.time <= Self.swipeSettleTimeout else {
                // Kept moving (e.g. the start of a shake that never finished): not a swipe.
                swipeConsumedThrough = pending.time
                pendingSwipe = nil
                swipeStillSince = nil
                return nil
            }
            let speed = history.count >= 2 ? peakSpeedBetween(history[history.count - 2], history[history.count - 1]) : 0
            guard speed < Self.settledSpeed else {
                swipeStillSince = nil
                return nil
            }
            swipeStillSince = swipeStillSince ?? now
            guard now - (swipeStillSince ?? now) >= Self.settledFor else { return nil }
            pendingSwipe = nil
            swipeStillSince = nil
            guard enabled.contains(pending.gesture) else { return nil }
            return GestureEvent(gesture: pending.gesture, startTime: pending.startTime, time: now, magnitude: pending.magnitude)
        }

        guard let found = detectSwipe(now: now) else { return nil }
        // Only a shake can grow out of a flick, so only wait for the settle if one's listening.
        if !enabled.contains(.shake) {
            return enabled.contains(found.gesture) ? found : nil
        }
        pendingSwipe = found
        swipeStillSince = nil
        return nil
    }

    private func detectSwipe(now: TimeInterval) -> GestureEvent? {
        guard history.count >= 3, let current = history.last else { return nil }
        let lastIndex = history.count - 1

        let window = max(settings.swipeWindow, Self.longSwipeWindow)
        for j in 0..<(lastIndex - 1) where now - history[j].t <= window && history[j].t > swipeConsumedThrough {
            let start = history[j]
            if j > 0, peakSpeedBetween(history[j - 1], start) >= Self.swipeStartSpeed { continue }
            var extreme = 0.0
            var extremeIndex = j
            var minDelta = 0.0, maxDelta = 0.0
            for k in (j + 1)..<lastIndex {
                let d = history[k].yaw - start.yaw
                minDelta = min(minDelta, d)
                maxDelta = max(maxDelta, d)
                if abs(d) > abs(extreme) { extreme = d; extremeIndex = k }
            }
            let depth = abs(extreme)
            guard depth >= settings.swipeAmplitude, extremeIndex > j else { continue }
            if let rest = restYaw, abs(start.yaw - rest) > max(8, depth * 0.35) { continue }

            // One excursion only: no big swing the other way (that's a shake).
            let opposite = extreme > 0 ? -minDelta : maxDelta
            guard opposite <= depth * Self.swipeOvershootFraction else { continue }

            let remaining = abs(current.yaw - start.yaw)
            guard remaining <= depth * (1 - Self.nodReturnFraction) else { continue }
            // The head must be arriving back, not swinging through: a wind-up before a
            // flick the other way passes the start at full speed.
            guard Self.arrivalSpeed(history[lastIndex - 1], current) < Self.swipeStartSpeed else { continue }

            let segment = history[j...lastIndex]
            let pitchRange = (segment.map(\.pitch).max() ?? 0) - (segment.map(\.pitch).min() ?? 0)
            guard pitchRange <= max(depth * Self.crossAxisAllowance, 3) else { continue }
            let peak = peakSpeed(segment, \.yaw)
            guard peak >= Self.minSwipeSpeed else { continue }

            // Timed from when the head actually started moving. Quick flicks always count;
            // bigger, slower ones only if they were fast at their peak.
            var departure = j
            for k in j..<extremeIndex where abs(history[k].yaw - start.yaw) <= depth * 0.2 { departure = k }
            let duration = now - history[departure].t
            guard duration <= settings.swipeWindow
                    || (duration <= Self.longSwipeWindow && peak >= Self.fastSwipeSpeed) else { continue }

            // +yaw is turning left, so a flick toward negative yaw is to the right.
            let gesture: HeadGesture = extreme < 0 ? .swipeRight : .swipeLeft
            return GestureEvent(gesture: gesture, startTime: start.t, time: now, magnitude: depth, duration: duration)
        }
        return nil
    }

    /// Longest stretch (seconds) in `poses[from...to]` where the head was nearly still.
    private func longestPause(_ poses: [Pose], from: Int, to: Int) -> TimeInterval {
        guard from < to else { return 0 }
        var longest = 0.0
        var stillStart: TimeInterval?
        for i in (from + 1)...to {
            if peakSpeedBetween(poses[i - 1], poses[i]) < Self.settledSpeed {
                let start = stillStart ?? poses[i - 1].t
                stillStart = start
                longest = max(longest, poses[i].t - start)
            } else {
                stillStart = nil
            }
        }
        return longest
    }

    private func peakSpeed(_ poses: ArraySlice<Pose>, _ axis: KeyPath<Pose, Double>) -> Double {
        var best = 0.0
        var previous: Pose?
        for p in poses {
            if let prev = previous, p.t > prev.t {
                best = max(best, abs(p[keyPath: axis] - prev[keyPath: axis]) / (p.t - prev.t))
            }
            previous = p
        }
        return best
    }

    // MARK: Tilt

    private mutating func updateTilt(rollDegrees: Double, time t: TimeInterval, enabled: Set<HeadGesture>) -> GestureEvent? {
        guard let base = rollBaseline else {
            rollBaseline = rollDegrees
            return nil
        }
        let rel = AngleMath.wrappedDeltaDegrees(rollDegrees, base)

        if abs(rel) < settings.tiltAngle * 0.5 {
            // Near neutral: slowly follow posture changes and re-arm.
            rollBaseline = base + rel * 0.02
            tiltLatched = false
            tiltCandidate = nil
            offNeutralSince = nil
            return nil
        }

        if let since = offNeutralSince {
            if t - since > Self.reNeutralAfter {
                rollBaseline = rollDegrees
                offNeutralSince = nil
                tiltCandidate = nil
                tiltLatched = false
                return nil
            }
        } else {
            offNeutralSince = t
        }

        guard enabled.contains(.tiltLeft) || enabled.contains(.tiltRight), !tiltLatched else { return nil }

        guard abs(rel) >= settings.tiltAngle else {
            tiltCandidate = nil
            return nil
        }

        let gesture: HeadGesture = (rel > 0) != settings.swapTiltDirection ? .tiltRight : .tiltLeft
        guard let candidate = tiltCandidate, candidate.gesture == gesture else {
            tiltCandidate = (gesture, t)
            return nil
        }
        guard t - candidate.since >= settings.tiltHold else { return nil }

        tiltLatched = true
        tiltCandidate = nil
        guard enabled.contains(gesture), t >= cooldownUntil else { return nil }
        return GestureEvent(gesture: gesture, startTime: candidate.since, time: t, magnitude: abs(rel))
    }
}

/// Clicks when the cursor rests in one spot. Requires movement between clicks so a
/// stationary cursor never machine-guns.
public struct DwellDetector: Sendable {
    public var settings: DwellSettings

    private var anchor: Vec2?
    private var anchorTime: TimeInterval = 0
    private var armed = false

    /// Changes every time the pointer settles somewhere new, so the app can check
    /// (once per resting spot) whether what's under the pointer is clickable.
    public private(set) var anchorID = 0
    public private(set) var anchorPosition: Vec2?

    /// Fraction of the dwell before the progress ring appears (avoids flicker while moving).
    static let revealFraction = 0.2

    public init(settings: DwellSettings = DwellSettings()) {
        self.settings = settings
    }

    /// Disarm until the cursor moves again (call after any click).
    public mutating func reset() {
        armed = false
        anchor = nil
    }

    /// Run the rest timer again from `time` at the same spot, without needing a move.
    /// For when a click came due before the app knew the spot is clickable: it gets
    /// another full rest instead of being lost.
    public mutating func restartTimer(at time: TimeInterval) {
        guard anchor != nil else { return }
        anchorTime = time
        armed = true
    }

    public struct Update: Equatable, Sendable {
        /// 0...1 while dwelling (nil = hide indicator).
        public var progress: Double?
        public var fired: Bool
    }

    public mutating func update(position: Vec2, time: TimeInterval) -> Update {
        guard let a = anchor else {
            anchor = position
            anchorTime = time
            return Update(progress: nil, fired: false)
        }
        if position.distance(to: a) > settings.radius {
            anchor = position
            anchorTime = time
            armed = true
            anchorID &+= 1
            anchorPosition = position
            return Update(progress: nil, fired: false)
        }
        guard armed, settings.duration > 0 else { return Update(progress: nil, fired: false) }

        let fraction = (time - anchorTime) / settings.duration
        if fraction >= 1 {
            armed = false
            return Update(progress: 1, fired: true)
        }
        return Update(progress: fraction >= Self.revealFraction ? fraction : nil, fired: false)
    }
}
