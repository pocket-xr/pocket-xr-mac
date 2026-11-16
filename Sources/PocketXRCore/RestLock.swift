import Foundation

/// The still head's lock, ported from Pocket XR's RestLock.kt (0.5.32 to 0.5.41).
///
/// A worn head is never still: a 4 to 12 Hz tremor moves the windows by a pixel or two, and sub-pixel motion makes
/// text edges shimmer. Here, while the head's slow motion (its rate through a two pole [cutoffHz] low pass, which the
/// tremor barely gets through) stays under [enterDegS] for [enterS], the view holds one pose: the tremor moves nothing
/// on the display. A slow drift past [followDevDeg] is followed at [followDegS] at most, too slowly to see. A real move
/// (the slow rate over [releaseDegS], or the head [maxDevDeg] from the held pose) lets go at once: the view tracks the
/// head from that frame, with the held pose's small offset faded out over [releaseS] instead of a jump.
///
/// [update] once a frame with the frame's pose; [apply] for another pose of that frame. Not thread safe: HeadPose
/// holds its lock for every call.
public final class RestLock {
    /// Poses this close in time are one frame's, seconds (a refresh at 120 Hz is 8.3 ms).
    public static let sameFrameS: Double = 0.004

    public let enterDegS: Double
    public let releaseDegS: Double
    public let enterS: Double
    public let maxDevDeg: Double
    public let followDevDeg: Double
    public let followDegS: Double
    public let releaseS: Double
    public let cutoffHz: Double
    /// The slow pose's time constant, seconds.
    public let followTauS: Double
    /// How far the head may sit from the held pose before the hold is drawn along with it.
    public let bandDeg: Double
    /// The time constant of the pose the band follows: a deliberate wobble gets through, the tremor barely.
    public let bandTauS: Double

    /// Off: every pose passes as it is.
    public var enabled: Bool = true

    public private(set) var locked: Bool = false
    /// The head's slow rate now, deg/s.
    public private(set) var speedDegS: Double = 0

    private var prev: Quat?
    private var prevTime: Double = 0
    private var v1 = SIMD3<Double>(0, 0, 0)
    private var v2 = SIMD3<Double>(0, 0, 0)
    private var slow: Quat = Quat.identity
    private var mid: Quat = Quat.identity
    private var held: Quat?
    private var calmSince: Double?
    private var releaseOffset: Quat?
    private var releaseStart: Double = 0
    // This frame's correction: shown = tracked x correction (none when free).
    private var correction: Quat = Quat.identity
    private var hasCorrection: Bool = false

    public init(
        enterDegS: Double = 3,
        releaseDegS: Double = 5,
        enterS: Double = 0.120,
        maxDevDeg: Double = 1.0,
        followDevDeg: Double = 0.3,
        followDegS: Double = 0.3,
        releaseS: Double = 0.100,
        cutoffHz: Double = 2,
        followTauS: Double = 2.0,
        bandDeg: Double = 0.3,
        bandTauS: Double = 0.1
    ) {
        self.enterDegS = enterDegS
        self.releaseDegS = releaseDegS
        self.enterS = enterS
        self.maxDevDeg = maxDevDeg
        self.followDevDeg = followDevDeg
        self.followDegS = followDegS
        self.releaseS = releaseS
        self.cutoffHz = cutoffHz
        self.followTauS = followTauS
        self.bandDeg = bandDeg
        self.bandTauS = bandTauS
    }

    /// The pose to draw this frame for the tracked (predicted, smoothed) pose [q] at [now] seconds.
    public func update(_ q: Quat, _ now: Double) -> Quat {
        // A call within sameFrameS of the last one is that frame's again: it gets the frame's hold or correction and
        // moves nothing on.
        if prev != nil {
            let gap: Double = now - prevTime
            if gap >= 0 && gap <= RestLock.sameFrameS { return apply(q) }
        }
        var dt: Double = 0
        if prev != nil { dt = now - prevTime }
        if let p = prev, dt > 0, dt <= 0.2 {
            let v: SIMD3<Double> = HeadMath.turnVector(p, q) * (1 / dt)
            let a: Double = 1 - exp(-2 * Double.pi * cutoffHz * dt)
            v1 = HeadMath.toward(v1, v, a)
            v2 = HeadMath.toward(v2, v1, a)
            slow = HeadMath.slerp(slow, q, 1 - exp(-dt / followTauS))
            mid = HeadMath.slerp(mid, q, 1 - exp(-dt / bandTauS))
        } else {
            v1 = SIMD3<Double>(0, 0, 0)
            v2 = SIMD3<Double>(0, 0, 0)
            slow = q
            mid = q
        }
        prev = q
        prevTime = now
        speedDegS = HeadMath.length(v2) * HeadMath.degPerRad
        if !enabled {
            free()
            return q
        }
        if locked, let h = held {
            let dev: Double = HeadMath.angleDeg(h, q)
            if speedDegS > releaseDegS || dev > maxDevDeg {
                locked = false
                held = nil
                // The offset the view already had on the last frame (at most maxDevDeg), not this frame's whole turn:
                // from here the view moves with the head, only that small offset fading out.
                releaseOffset = hasCorrection ? correction : nil
                releaseStart = now
            } else {
                // The hold is drawn along once the head (through a bandTauS low pass, which the tremor barely gets
                // through) is bandDeg from it, so a small deliberate wobble moves the view as it should, only bandDeg
                // behind; the tremor, smaller, still moves nothing. The low pass's lag is made up with the slow rate.
                var shown: Quat = h
                let lead: Quat = HeadMath.turnedBy(mid, v2, bandTauS)
                let midDev: Double = HeadMath.angleDeg(h, lead)
                if midDev > bandDeg {
                    shown = HeadMath.slerp(h, lead, (midDev - bandDeg) / midDev)
                    held = shown
                }
                let drift: Double = HeadMath.angleDeg(shown, slow)
                if drift > followDevDeg && dt > 0 {
                    let stepDeg: Double = min(followDegS * dt, drift - followDevDeg)
                    shown = HeadMath.slerp(shown, slow, stepDeg / drift)
                    held = shown
                }
                correction = (q.conjugate * shown).normalized
                hasCorrection = true
                return shown
            }
        }
        // Free, or letting go: the head as tracked, with what is left of the held offset.
        var shown: Quat = q
        if let off = releaseOffset {
            let w: Double = HeadMath.clamp((now - releaseStart) / releaseS, 0, 1)
            if w >= 1 {
                releaseOffset = nil
                correction = Quat.identity
                hasCorrection = false
            } else {
                correction = HeadMath.slerp(off, Quat.identity, HeadMath.smooth(w))
                hasCorrection = true
                shown = (q * correction).normalized
            }
        } else {
            correction = Quat.identity
            hasCorrection = false
        }
        if speedDegS < enterDegS && releaseOffset == nil {
            if let since = calmSince {
                if now - since >= enterS {
                    locked = true
                    held = shown
                    calmSince = nil
                }
            } else {
                calmSince = now
            }
        } else {
            calmSince = nil
        }
        return shown
    }

    /// Another pose of the frame [update] last saw: the held pose, or the same correction.
    public func apply(_ q: Quat) -> Quat {
        if !enabled { return q }
        if locked, let h = held { return h }
        return hasCorrection ? (q * correction).normalized : q
    }

    /// Lets go at once with no blend (a recentre, a reconnect, the switch turned off).
    public func free() {
        locked = false
        held = nil
        releaseOffset = nil
        correction = Quat.identity
        hasCorrection = false
        calmSince = nil
    }
}
